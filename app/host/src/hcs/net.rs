//! GpuVM's own networks for HCS machines (Host Compute Network), which exist on editions without Hyper-V:
//! - "GpuVM", an ICS network like Hyper-V's Default Switch (DHCP, DNS and NAT), for machines that are not isolated;
//! - one Internal network per isolated machine, "GpuVM-<machine>" (no NAT, no forwarding): its only other member is
//!   the host, locked by the host's filters (wfp.rs), so isolated machines reach neither the LAN nor each other.
//!   They reach the internet only through the relay (relay.rs).
//! Client Windows does not enforce HCN endpoint ACLs and its NAT engines skip every filter (labs 070-072).

use std::net::Ipv4Addr;

use serde_json::{json, Value};
use windows_sys::core::{GUID, PWSTR};
use windows_sys::Win32::Foundation::{LocalFree, ERROR_BUFFER_OVERFLOW, ERROR_SUCCESS};
use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::Networking::WinSock::{AF_INET, SOCKADDR_IN};
use windows_sys::Win32::System::Com::CoCreateGuid;
use windows_sys::Win32::System::HostComputeNetwork::*;

use crate::win::wide;

/// The network's id is fixed so every part of GpuVM finds the same one.
pub const NETWORK_ID: GUID = GUID::from_u128(0x6e1a3c5f_1d2b_4f0e_9a65_0657b0c0e7a1);
const NETWORK_NAME: &str = "GpuVM";

/// Private /24 subnets tried in order; the first one no host interface already uses is taken.
const CANDIDATES: [[u8; 3]; 6] = [[192, 168, 165], [192, 168, 185], [172, 31, 165], [172, 30, 185], [10, 165, 65], [10, 185, 65]];

fn take(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe {
        let len = (0..).take_while(|&i| *p.add(i) != 0).count();
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, len));
        LocalFree(p.cast());
        s
    }
}

fn check(hr: i32, record: PWSTR, what: &str) -> Result<(), String> {
    let detail = take(record);
    if hr < 0 {
        let msg = serde_json::from_str::<Value>(&detail).ok().and_then(|v| v["Error"].as_str().or(v["ErrorMessage"].as_str()).map(String::from)).unwrap_or(detail);
        return Err(format!("{what}: 0x{:08X} {msg}", hr as u32));
    }
    Ok(())
}

pub fn guid_string(g: &GUID) -> String {
    format!("{:08x}-{:04x}-{:04x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        g.data1, g.data2, g.data3, g.data4[0], g.data4[1], g.data4[2], g.data4[3], g.data4[4], g.data4[5], g.data4[6], g.data4[7])
}

fn new_guid() -> GUID {
    let mut g = GUID::from_u128(0);
    unsafe { CoCreateGuid(&mut g) };
    g
}

/// A MAC in Microsoft's Hyper-V range (00-15-5D) with random low bytes.
pub fn new_mac() -> String {
    let b = new_guid().data4;
    format!("00-15-5D-{:02X}-{:02X}-{:02X}", b[5], b[6], b[7])
}

pub fn network_document(subnet: [u8; 3]) -> Value {
    let prefix = format!("{}.{}.{}", subnet[0], subnet[1], subnet[2]);
    json!({
        "SchemaVersion": { "Major": 2, "Minor": 0 },
        "Name": NETWORK_NAME,
        "Type": "ICS",
        // DNS proxy + DHCP server + isolated switch, as Windows sets up its Default Switch; without them guests get no address.
        "Flags": 11,
        "Ipams": [{ "Type": "Static", "Subnets": [{
            "IpAddressPrefix": format!("{prefix}.0/24"),
            "Routes": [{ "NextHop": format!("{prefix}.1"), "DestinationPrefix": "0.0.0.0/0" }]
        }] }]
    })
}

/// The first candidate subnet that overlaps none of the host's IPv4 networks.
pub fn pick_subnet(host: &[(Ipv4Addr, u8)]) -> Option<[u8; 3]> {
    pick_from(CANDIDATES.into_iter(), host)
}

/// /24s for isolated machines' networks, one each.
fn isolated_candidates() -> impl Iterator<Item = [u8; 3]> {
    (0..=255u8).map(|n| [172, 29, n]).chain((0..=255u8).map(|n| [10, 229, n]))
}

fn pick_from(mut candidates: impl Iterator<Item = [u8; 3]>, host: &[(Ipv4Addr, u8)]) -> Option<[u8; 3]> {
    candidates.find(|c| {
        let ours = u32::from(Ipv4Addr::new(c[0], c[1], c[2], 0));
        host.iter().all(|(addr, len)| {
            let len = (*len).min(32);
            let shorter = len.min(24) as u32;
            let mask = if shorter == 0 { 0 } else { u32::MAX << (32 - shorter) };
            (u32::from(*addr) & mask) != (ours & mask)
        })
    })
}

fn host_networks() -> Vec<(Ipv4Addr, u8)> {
    let mut out = Vec::new();
    let mut size = 16 * 1024u32;
    for _ in 0..3 {
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let first = buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        let code = unsafe { GetAdaptersAddresses(AF_INET as u32, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, std::ptr::null(), first, &mut size) };
        if code == ERROR_BUFFER_OVERFLOW {
            continue;
        }
        if code != ERROR_SUCCESS {
            return out;
        }
        unsafe {
            let mut a = first;
            while !a.is_null() {
                let mut u = (*a).FirstUnicastAddress;
                while !u.is_null() {
                    let sa = (*u).Address.lpSockaddr as *const SOCKADDR_IN;
                    if !sa.is_null() && (*sa).sin_family == AF_INET {
                        let ip = Ipv4Addr::from(u32::from_be((*sa).sin_addr.S_un.S_addr));
                        out.push((ip, (*u).OnLinkPrefixLength));
                    }
                    u = (*u).Next;
                }
                a = (*a).Next;
            }
        }
        return out;
    }
    out
}

pub fn network_exists() -> bool {
    let mut net: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnOpenNetwork(&NETWORK_ID, &mut net, &mut record) };
    take(record);
    if hr >= 0 && !net.is_null() {
        unsafe { HcnCloseNetwork(net) };
        return true;
    }
    false
}

/// Makes sure GpuVM's network exists (it survives restarts of the host's network service, not always a reboot).
pub fn ensure_network() -> Result<(), String> {
    if network_exists() {
        return Ok(());
    }
    let subnet = pick_subnet(&host_networks()).ok_or("every subnet GpuVM can use is already taken on this PC")?;
    let doc = wide(&network_document(subnet).to_string());
    let mut net: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnCreateNetwork(&NETWORK_ID, doc.as_ptr(), &mut net, &mut record) };
    if !net.is_null() {
        unsafe { HcnCloseNetwork(net) };
    }
    // Two machines starting at once can both try: the one that loses finds the network made by the other.
    match check(hr, record, "create GpuVM's network") {
        Err(_) if network_exists() => Ok(()),
        other => other,
    }
}

pub fn delete_network() -> Result<(), String> {
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnDeleteNetwork(&NETWORK_ID, &mut record) };
    check(hr, record, "delete GpuVM's network")
}

fn open_network(id: &GUID) -> Option<*mut core::ffi::c_void> {
    let mut net: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnOpenNetwork(id, &mut net, &mut record) };
    take(record);
    (hr >= 0 && !net.is_null()).then_some(net)
}

fn network_properties(id: &GUID, what: &str) -> Result<Value, String> {
    let net = open_network(id).ok_or_else(|| format!("{what} doesn't exist"))?;
    let query = wide(r#"{"SchemaVersion":{"Major":2,"Minor":0}}"#);
    let mut props: PWSTR = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnQueryNetworkProperties(net, query.as_ptr(), &mut props, &mut record) };
    unsafe { HcnCloseNetwork(net) };
    let text = take(props);
    check(hr, record, &format!("read {what}"))?;
    serde_json::from_str(&text).map_err(|e| format!("network properties: {e}"))
}

/// The isolated network of machine `name`: its id comes from the name, so it is found again after a crash.
pub fn isolated_network_id(name: &str) -> GUID {
    let h = crate::wire::sha256(format!("gpuvm-isolated-network/{name}").as_bytes());
    let mut v = u128::from_be_bytes(h[..16].try_into().unwrap());
    v = (v & !(0xF << 76)) | (0x5 << 76);
    v = (v & !(0x3 << 62)) | (0x2 << 62);
    GUID::from_u128(v)
}

/// The host's adapter on it is "vEthernet (GpuVM-<name>)".
pub fn isolated_network_name(name: &str) -> String {
    format!("{NETWORK_NAME}-{name}")
}

pub fn isolated_network_document(name: &str, subnet: [u8; 3]) -> Value {
    let prefix = format!("{}.{}.{}", subnet[0], subnet[1], subnet[2]);
    json!({
        "SchemaVersion": { "Major": 2, "Minor": 0 },
        "Name": isolated_network_name(name),
        "Type": "Internal",
        "Ipams": [{ "Type": "Static", "Subnets": [{ "IpAddressPrefix": format!("{prefix}.0/24") }] }]
    })
}

pub fn subnet_text(s: [u8; 3]) -> String {
    format!("{}.{}.{}", s[0], s[1], s[2])
}

pub fn parse_subnet(s: &str) -> Option<[u8; 3]> {
    let p: Vec<u8> = s.split('.').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    (p.len() == 3).then(|| [p[0], p[1], p[2]])
}

/// The address of `n` on a /24.
pub fn host_part(subnet: [u8; 3], n: u8) -> String {
    Ipv4Addr::new(subnet[0], subnet[1], subnet[2], n).to_string()
}

/// A fresh isolated network for machine `name` (one left by a crash is removed first), on `preferred` if the host
/// has no network there, and the host's filters on its adapter. Returns the subnet: the host is .1, the machine .2.
pub fn create_isolated_network(name: &str, preferred: Option<[u8; 3]>) -> Result<[u8; 3], String> {
    let _lock = super::wfp::HostLock::take()?;
    let id = isolated_network_id(name);
    if open_network(&id).map(|n| unsafe { HcnCloseNetwork(n) }).is_some() {
        delete_isolated_network(name)?;
    }
    let host = host_networks();
    let subnet = preferred
        .filter(|p| pick_from(std::iter::once(*p), &host).is_some())
        .or_else(|| pick_from(isolated_candidates(), &host))
        .ok_or("every subnet GpuVM can use for isolated machines is already taken on this PC")?;
    let doc = wide(&isolated_network_document(name, subnet).to_string());
    let mut net: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnCreateNetwork(&id, doc.as_ptr(), &mut net, &mut record) };
    if !net.is_null() {
        unsafe { HcnCloseNetwork(net) };
    }
    check(hr, record, "create the machine's isolated network")?;
    // The filters go on this network's own adapter, found by name. The lock is held until it has its address, so
    // the next start sees the subnet taken; the address must be on no other adapter.
    let host_ip = host_part(subnet, 1);
    let alias = host_adapter(name);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    let locked = loop {
        let found = super::wfp::interface_by_alias(&alias).and_then(|(luid, index)| {
            match super::wfp::interfaces_with(&host_ip).as_slice() {
                [only] if *only == luid => super::wfp::isolate_interface(luid, index),
                [] => Err(format!("{alias} has no address yet")),
                _ => Err(format!("{host_ip} is on more than one host adapter")),
            }
        });
        match found {
            Ok(()) => break Ok(()),
            Err(e) if std::time::Instant::now() > deadline => break Err(e),
            Err(_) => std::thread::sleep(std::time::Duration::from_millis(250)),
        }
    };
    if let Err(e) = locked {
        let _ = delete_isolated_network(name);
        return Err(e);
    }
    Ok(subnet)
}

/// Removes machine `name`'s isolated network and the host's filters on it (nothing to do if it is gone).
pub fn delete_isolated_network(name: &str) -> Result<(), String> {
    let _lock = super::wfp::HostLock::take()?;
    let id = isolated_network_id(name);
    if open_network(&id).map(|n| unsafe { HcnCloseNetwork(n) }).is_none() {
        return Ok(());
    }
    let adapter = super::wfp::interface_by_alias(&host_adapter(name)).ok();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnDeleteNetwork(&id, &mut record) };
    // The filters go only once the network is gone: if it can't be deleted (a machine still on it), they stay.
    check(hr, record, "delete the machine's isolated network")?;
    if let Some((luid, _)) = adapter {
        let _ = super::wfp::release_interface(luid);
    }
    // Filters whose adapter was already gone (it couldn't be found by name) go now, not at the next service start.
    let _ = super::wfp::sweep();
    Ok(())
}

/// The host's adapter on machine `name`'s isolated network.
pub fn host_adapter(name: &str) -> String {
    format!("vEthernet ({})", isolated_network_name(name))
}

/// Every network GpuVM made (its ICS network and the isolated machines' ones), by id.
fn gpuvm_networks() -> Vec<GUID> {
    let query = wide("{}");
    let mut list: PWSTR = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnEnumerateNetworks(query.as_ptr(), &mut list, &mut record) };
    take(record);
    let text = take(list);
    if hr < 0 {
        return Vec::new();
    }
    let ids: Vec<String> = serde_json::from_str(&text).unwrap_or_default();
    ids.iter()
        .filter_map(|i| parse_guid(i))
        .filter(|g| guid_string(g) == guid_string(&NETWORK_ID) || network_properties(g, "network").is_ok_and(|v| {
            v["Name"].as_str().is_some_and(|n| n.starts_with(&format!("{NETWORK_NAME}-")) && v["Type"].as_str() == Some("Internal"))
        }))
        .collect()
}

/// A port on machine `name`'s isolated network, with the machine's fixed address (.2).
pub fn create_isolated_endpoint(mac: &str, name: &str, subnet: [u8; 3]) -> Result<Endpoint, String> {
    let id = new_guid();
    let settings = json!({
        "SchemaVersion": { "Major": 2, "Minor": 0 },
        "HostComputeNetwork": guid_string(&isolated_network_id(name)),
        "MacAddress": mac,
        "IpConfigurations": [{ "IpAddress": host_part(subnet, 2), "PrefixLength": 24 }]
    });
    let doc = wide(&settings.to_string());
    let net = open_network(&isolated_network_id(name)).ok_or("the machine's isolated network doesn't exist")?;
    let mut ep: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnCreateEndpoint(net, &id, doc.as_ptr(), &mut ep, &mut record) };
    unsafe {
        if !ep.is_null() {
            HcnCloseEndpoint(ep);
        }
        HcnCloseNetwork(net);
    }
    check(hr, record, "create the machine's isolated network port")?;
    Ok(Endpoint { id: guid_string(&id), mac: mac.to_string() })
}

/// Deletes every network GpuVM made (ICS and isolated ones) with the host's filters; for tests and uninstall.
pub fn delete_all_networks() -> Result<(), String> {
    for id in gpuvm_networks() {
        if guid_string(&id) == guid_string(&NETWORK_ID) {
            delete_network()?;
        } else if let Ok(v) = network_properties(&id, "network") {
            let name = v["Name"].as_str().unwrap_or("").trim_start_matches(&format!("{NETWORK_NAME}-")).to_string();
            delete_isolated_network(&name)?;
        }
    }
    Ok(())
}

/// One machine's port on the network. The machine's document names it by id with the same MAC.
pub struct Endpoint {
    pub id: String,
    pub mac: String,
}

/// The host's address on GpuVM's network (the subnet's gateway, where its DHCP and DNS answer).
pub fn gateway() -> Result<String, String> {
    let v = network_properties(&NETWORK_ID, "GpuVM's network")?;
    v["Ipams"][0]["Subnets"][0]["Routes"][0]["NextHop"].as_str().map(String::from).ok_or_else(|| "GpuVM's network has no gateway".into())
}

pub fn create_endpoint(mac: &str) -> Result<Endpoint, String> {
    let id = new_guid();
    let settings = json!({ "SchemaVersion": { "Major": 2, "Minor": 0 }, "HostComputeNetwork": guid_string(&NETWORK_ID), "MacAddress": mac });
    let doc = wide(&settings.to_string());
    let mut net: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnOpenNetwork(&NETWORK_ID, &mut net, &mut record) };
    check(hr, record, "open GpuVM's network")?;
    let mut ep: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnCreateEndpoint(net, &id, doc.as_ptr(), &mut ep, &mut record) };
    unsafe {
        if !ep.is_null() {
            HcnCloseEndpoint(ep);
        }
        HcnCloseNetwork(net);
    }
    check(hr, record, "create the machine's network port")?;
    Ok(Endpoint { id: guid_string(&id), mac: mac.to_string() })
}

pub fn endpoint_properties(id: &str) -> Result<Value, String> {
    let g = parse_guid(id).ok_or_else(|| format!("not an endpoint id: {id}"))?;
    let mut ep: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnOpenEndpoint(&g, &mut ep, &mut record) };
    check(hr, record, "open the endpoint")?;
    let query = wide(r#"{"SchemaVersion":{"Major":2,"Minor":0}}"#);
    let mut props: PWSTR = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnQueryEndpointProperties(ep, query.as_ptr(), &mut props, &mut record) };
    unsafe { HcnCloseEndpoint(ep) };
    let text = take(props);
    check(hr, record, "read the endpoint")?;
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

fn endpoint_network(id: &GUID) -> Option<String> {
    let mut ep: *mut core::ffi::c_void = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnOpenEndpoint(id, &mut ep, &mut record) };
    take(record);
    if hr < 0 || ep.is_null() {
        return None;
    }
    let query = wide(r#"{"SchemaVersion":{"Major":2,"Minor":0}}"#);
    let mut props: PWSTR = std::ptr::null_mut();
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnQueryEndpointProperties(ep, query.as_ptr(), &mut props, &mut record) };
    unsafe { HcnCloseEndpoint(ep) };
    take(record);
    let text = take(props);
    if hr < 0 {
        return None;
    }
    serde_json::from_str::<Value>(&text).ok()?["HostComputeNetwork"].as_str().map(|s| s.to_ascii_lowercase())
}

/// Deletes a port of GpuVM's network; a port of any other network (WSL, Docker...) is left alone.
pub fn delete_endpoint(id: &str) -> Result<(), String> {
    let g = parse_guid(id).ok_or_else(|| format!("not an endpoint id: {id}"))?;
    match endpoint_network(&g) {
        None => return Ok(()),
        Some(net) if !gpuvm_networks().iter().any(|g| guid_string(g) == net) => return Err(format!("endpoint {id} is not on GpuVM's network")),
        Some(_) => {}
    }
    let mut record: PWSTR = std::ptr::null_mut();
    let hr = unsafe { HcnDeleteEndpoint(&g, &mut record) };
    check(hr, record, "delete the machine's network port")
}

pub fn parse_guid(s: &str) -> Option<GUID> {
    let hex: String = s.trim_matches(|c| c == '{' || c == '}').chars().filter(|c| *c != '-').collect();
    if hex.len() != 32 {
        return None;
    }
    u128::from_str_radix(&hex, 16).ok().map(GUID::from_u128)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn network_document_matches_what_got_dhcp_in_lab_065() {
        let d = network_document([192, 168, 165]);
        assert_eq!(d["Type"], json!("ICS"));
        assert_eq!(d["Flags"], json!(11));
        assert_eq!(d["Ipams"][0]["Subnets"][0]["IpAddressPrefix"], json!("192.168.165.0/24"));
        assert_eq!(d["Ipams"][0]["Subnets"][0]["Routes"][0]["NextHop"], json!("192.168.165.1"));
    }

    #[test]
    fn subnet_avoids_networks_the_host_already_has() {
        assert_eq!(pick_subnet(&[]), Some([192, 168, 165]));
        assert_eq!(pick_subnet(&[(Ipv4Addr::new(192, 168, 165, 20), 24)]), Some([192, 168, 185]));
        // A /16 on the host covers every 192.168.x.0/24.
        assert_eq!(pick_subnet(&[(Ipv4Addr::new(192, 168, 1, 10), 16)]), Some([172, 31, 165]));
        // Narrower host networks inside one of our /24s still collide.
        assert_eq!(pick_subnet(&[(Ipv4Addr::new(192, 168, 165, 130), 25)]), Some([192, 168, 185]));
        let all: Vec<_> = CANDIDATES.iter().map(|c| (Ipv4Addr::new(c[0], c[1], c[2], 1), 24)).collect();
        assert_eq!(pick_subnet(&all), None);
    }

    #[test]
    fn each_isolated_machine_has_its_own_internal_network() {
        let d = isolated_network_document("m1", [172, 29, 4]);
        assert_eq!(d["Type"], json!("Internal"));
        assert_eq!(d["Name"], json!("GpuVM-m1"));
        assert!(d["Ipams"][0]["Subnets"][0]["Routes"].is_null(), "no gateway: nothing is routed");
        assert_eq!(guid_string(&isolated_network_id("m1")), guid_string(&isolated_network_id("m1")));
        assert_ne!(guid_string(&isolated_network_id("m1")), guid_string(&isolated_network_id("m2")));
        assert_ne!(guid_string(&isolated_network_id("m1")), guid_string(&NETWORK_ID));
        assert_eq!(parse_subnet(&subnet_text([172, 29, 4])), Some([172, 29, 4]));
        assert_eq!(parse_subnet("172.29"), None);
        assert_eq!(host_part([172, 29, 4], 2), "172.29.4.2");
        let busy: Vec<_> = (0..=255u8).map(|n| (Ipv4Addr::new(172, 29, n, 1), 24)).collect();
        assert_eq!(pick_from(isolated_candidates(), &busy), Some([10, 229, 0]));
    }

    #[test]
    fn guid_round_trips_through_text() {
        let s = guid_string(&NETWORK_ID);
        assert_eq!(s, "6e1a3c5f-1d2b-4f0e-9a65-0657b0c0e7a1");
        assert_eq!(parse_guid(&s).map(|g| guid_string(&g)), Some(s.clone()));
        assert_eq!(parse_guid(&format!("{{{s}}}")).map(|g| guid_string(&g)), Some(s));
        assert!(parse_guid("nope").is_none());
    }

    #[test]
    fn macs_are_in_the_hyper_v_range() {
        let m = new_mac();
        assert!(m.starts_with("00-15-5D-") && m.len() == 17, "{m}");
    }
}

#[cfg(test)]
mod live {
    use super::*;

    // Needs an elevated shell; run with `cargo test -- --ignored hcs_net`.
    #[test]
    #[ignore]
    fn hcs_net_network_and_endpoint() {
        let existed = network_exists();
        ensure_network().unwrap();
        assert!(network_exists());
        ensure_network().unwrap();
        let ep = create_endpoint(&new_mac()).unwrap();
        assert_eq!(endpoint_network(&parse_guid(&ep.id).unwrap()), Some(guid_string(&NETWORK_ID)));
        delete_endpoint(&ep.id).unwrap();
        assert_eq!(endpoint_network(&parse_guid(&ep.id).unwrap()), None);
        delete_endpoint(&ep.id).unwrap();
        if !existed {
            delete_network().unwrap();
            assert!(!network_exists());
        }
    }
}
