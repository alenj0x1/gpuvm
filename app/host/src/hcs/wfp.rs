//! The host's lock on GpuVM's isolated network (net.rs), with Windows Filtering Platform filters on the host's
//! interface there: the host accepts no connection that arrives from it (Moonlight still works, because the host
//! opens those) and forwards nothing that comes from it. The filters match the interface, not an address, so a
//! guest cannot step around them by changing its own address. They are persistent: they stay across reboots.

use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::HANDLE;
use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::NetworkManagement::WindowsFilteringPlatform::*;
use windows_sys::Win32::Networking::WinSock::AF_INET;

use crate::win::wide;

const SUBLAYER: GUID = GUID::from_u128(0x6e1a3c5f_1d2b_4f0e_9a65_0657b0c0f000);
const RPC_C_AUTHN_DEFAULT: u32 = 0xFFFF_FFFF;
const FWP_E_ALREADY_EXISTS: u32 = 0x8032_0009;
const FWP_E_FILTER_NOT_FOUND: u32 = 0x8032_0003;

/// One process at a time makes, filters or removes isolated networks (each `gpuvm-host hcs start` is its own
/// process): two starts could otherwise pick the same subnet, or the startup sweep remove a new network's filters.
pub struct HostLock(HANDLE);

impl HostLock {
    pub fn take() -> Result<HostLock, String> {
        use windows_sys::Win32::System::Threading::{CreateMutexW, WaitForSingleObject};
        let name = wide(r"Global\GpuVMIsolatedNetworks");
        let h = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        if h.is_null() {
            return Err("couldn't create the isolated networks' lock".into());
        }
        // WAIT_OBJECT_0 or WAIT_ABANDONED (a holder that died): either way this process holds it now.
        match unsafe { WaitForSingleObject(h, 120_000) } {
            0 | 0x80 => Ok(HostLock(h)),
            _ => {
                unsafe { windows_sys::Win32::Foundation::CloseHandle(h) };
                Err("another start kept the isolated networks busy for two minutes".into())
            }
        }
    }
}

impl Drop for HostLock {
    fn drop(&mut self) {
        unsafe {
            windows_sys::Win32::System::Threading::ReleaseMutex(self.0);
            windows_sys::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

/// The host adapter named `alias` ("vEthernet (GpuVM-<machine>)"): its LUID and index.
pub fn interface_by_alias(alias: &str) -> Result<(u64, u32), String> {
    use windows_sys::Win32::NetworkManagement::Ndis::NET_LUID_LH;
    let a = wide(alias);
    let mut luid: NET_LUID_LH = unsafe { std::mem::zeroed() };
    if unsafe { ConvertInterfaceAliasToLuid(a.as_ptr(), &mut luid) } != 0 {
        return Err(format!("no host adapter {alias}"));
    }
    let mut index = 0u32;
    if unsafe { ConvertInterfaceLuidToIndex(&luid, &mut index) } != 0 {
        return Err(format!("no index for host adapter {alias}"));
    }
    Ok((unsafe { luid.Value }, index))
}

/// The LUIDs of every host interface holding the IPv4 address `ip`.
pub fn interfaces_with(ip: &str) -> Vec<u64> {
    let Ok(want) = ip.parse::<std::net::Ipv4Addr>() else { return Vec::new() };
    let mut table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
    if unsafe { GetUnicastIpAddressTable(AF_INET, &mut table) } != 0 {
        return Vec::new();
    }
    let v = unsafe {
        std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize)
            .iter()
            .filter(|r| std::net::Ipv4Addr::from(u32::from_be(r.Address.Ipv4.sin_addr.S_un.S_addr)) == want)
            .map(|r| r.InterfaceLuid.Value)
            .collect()
    };
    unsafe { FreeMibTable(table.cast()) };
    v
}

/// The host interface whose IPv4 address is `host_ip`: its LUID and index.
pub fn interface_of(host_ip: &str) -> Result<(u64, u32), String> {
    let want: std::net::Ipv4Addr = host_ip.parse().map_err(|_| format!("not an IPv4 address: {host_ip}"))?;
    let mut table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
    let rc = unsafe { GetUnicastIpAddressTable(AF_INET, &mut table) };
    if rc != 0 {
        return Err(format!("GetUnicastIpAddressTable failed ({rc})"));
    }
    let found = unsafe {
        let rows = std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize);
        rows.iter()
            .find(|r| std::net::Ipv4Addr::from(u32::from_be(r.Address.Ipv4.sin_addr.S_un.S_addr)) == want)
            .map(|r| (r.InterfaceLuid.Value, r.InterfaceIndex))
    };
    unsafe { FreeMibTable(table.cast()) };
    found.ok_or_else(|| format!("no host interface has {host_ip}"))
}

struct Engine(HANDLE);

impl Engine {
    fn open() -> Result<Self, String> {
        let mut h: HANDLE = std::ptr::null_mut();
        let rc = unsafe { FwpmEngineOpen0(std::ptr::null(), RPC_C_AUTHN_DEFAULT, std::ptr::null(), std::ptr::null(), &mut h) };
        if rc != 0 {
            return Err(format!("open the filtering engine failed (0x{rc:08x})"));
        }
        Ok(Self(h))
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        unsafe { FwpmEngineClose0(self.0) };
    }
}

/// Filter keys come from the interface and the filter's place in the list, so removing them needs nothing stored.
fn key(luid: u64, n: u16) -> u128 {
    0x6e1a3c5f_0000_4000_8000_000000000000 | ((n as u128) << 64) | (luid as u128 & 0xFFFF_FFFF_FFFF)
}

const LAYERS: [GUID; 4] = [FWPM_LAYER_IPFORWARD_V4, FWPM_LAYER_IPFORWARD_V6, FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4, FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6];

/// Puts the filters on the host interface `luid`/`index`, in one transaction. Filters of an earlier adapter with the
/// same LUID are replaced: the forward layers match the interface index, which can change.
pub fn isolate_interface(luid: u64, index: u32) -> Result<(), String> {
    let e = Engine::open()?;
    if unsafe { FwpmTransactionBegin0(e.0, 0) } != 0 {
        return Err("start a filtering transaction failed".into());
    }
    let r = add_all(&e, luid, index);
    unsafe {
        if r.is_ok() {
            if FwpmTransactionCommit0(e.0) != 0 {
                return Err("commit the isolation filters failed".into());
            }
        } else {
            FwpmTransactionAbort0(e.0);
        }
    }
    r
}

fn add_all(e: &Engine, luid: u64, index: u32) -> Result<(), String> {
    let name = wide("GpuVM isolated network");
    let mut sub: FWPM_SUBLAYER0 = unsafe { std::mem::zeroed() };
    sub.subLayerKey = SUBLAYER;
    sub.displayData.name = name.as_ptr() as *mut u16;
    sub.flags = FWPM_SUBLAYER_FLAG_PERSISTENT;
    sub.weight = 0x8000;
    let rc = unsafe { FwpmSubLayerAdd0(e.0, &sub, std::ptr::null_mut()) };
    if rc != 0 && rc != FWP_E_ALREADY_EXISTS {
        return Err(format!("add GpuVM's filter sublayer failed (0x{rc:08x})"));
    }
    for (n, layer) in LAYERS.into_iter().enumerate() {
        let rc = unsafe { FwpmFilterDeleteByKey0(e.0, &GUID::from_u128(key(luid, n as u16))) };
        if rc != 0 && rc != FWP_E_FILTER_NOT_FOUND {
            return Err(format!("replace an isolation filter failed (0x{rc:08x})"));
        }
        let mut luid_value = luid;
        let mut fc: FWPM_FILTER_CONDITION0 = unsafe { std::mem::zeroed() };
        fc.matchType = FWP_MATCH_EQUAL;
        if n < 2 {
            // IP forward layers: the interface the packet came in on.
            fc.fieldKey = FWPM_CONDITION_SOURCE_INTERFACE_INDEX;
            fc.conditionValue.r#type = FWP_UINT32;
            fc.conditionValue.Anonymous.uint32 = index;
        } else {
            fc.fieldKey = FWPM_CONDITION_IP_ARRIVAL_INTERFACE;
            fc.conditionValue.r#type = FWP_UINT64;
            fc.conditionValue.Anonymous.uint64 = &mut luid_value;
        }
        let mut f: FWPM_FILTER0 = unsafe { std::mem::zeroed() };
        f.filterKey = GUID::from_u128(key(luid, n as u16));
        f.displayData.name = name.as_ptr() as *mut u16;
        f.flags = FWPM_FILTER_FLAG_PERSISTENT;
        f.layerKey = layer;
        f.subLayerKey = SUBLAYER;
        f.weight.r#type = FWP_UINT8;
        f.weight.Anonymous.uint8 = 1;
        f.numFilterConditions = 1;
        f.filterCondition = &mut fc;
        f.action.r#type = FWP_ACTION_BLOCK;
        let mut id = 0u64;
        let rc = unsafe { FwpmFilterAdd0(e.0, &f, std::ptr::null_mut(), &mut id) };
        if rc != 0 {
            return Err(format!("add an isolation filter failed (0x{rc:08x})"));
        }
    }
    Ok(())
}

/// Removes the filters of the host interface `luid`.
pub fn release_interface(luid: u64) -> Result<(), String> {
    let e = Engine::open()?;
    for n in 0..LAYERS.len() as u16 {
        let rc = unsafe { FwpmFilterDeleteByKey0(e.0, &GUID::from_u128(key(luid, n))) };
        if rc != 0 && rc != FWP_E_FILTER_NOT_FOUND {
            return Err(format!("remove an isolation filter failed (0x{rc:08x})"));
        }
    }
    Ok(())
}

/// Removes GpuVM's filters whose interface no longer exists (a machine's network that vanished with a crash or a
/// reboot), so an index Windows hands to another adapter later is never matched. Run when the service starts.
pub fn sweep() -> Result<usize, String> {
    let _lock = HostLock::take()?;
    let stale = stale_filters()?;
    let e = Engine::open()?;
    for k in &stale {
        unsafe { FwpmFilterDeleteByKey0(e.0, k) };
    }
    Ok(stale.len())
}

/// GpuVM's filters whose interface is gone. The filters are listed before the interfaces: a filter always comes
/// after its interface, so one made in between is never taken for stale.
fn stale_filters() -> Result<Vec<GUID>, String> {
    let filters = gpuvm_filters()?;
    let present: Vec<u64> = {
        let mut table: *mut MIB_IF_TABLE2 = std::ptr::null_mut();
        if unsafe { GetIfTable2(&mut table) } != 0 {
            return Err("GetIfTable2 failed".into());
        }
        let v = unsafe {
            std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize).iter().map(|r| r.InterfaceLuid.Value & 0xFFFF_FFFF_FFFF).collect()
        };
        unsafe { FreeMibTable(table.cast()) };
        v
    };
    Ok(filters.into_iter().filter(|k| !present.contains(&((guid_u128(k) & 0xFFFF_FFFF_FFFF) as u64))).collect())
}

/// The keys of every filter in GpuVM's sublayer.
fn gpuvm_filters() -> Result<Vec<GUID>, String> {
    let e = Engine::open()?;
    let mut handle: HANDLE = std::ptr::null_mut();
    if unsafe { FwpmFilterCreateEnumHandle0(e.0, std::ptr::null(), &mut handle) } != 0 {
        return Err("list filters failed".into());
    }
    let mut keys = Vec::new();
    loop {
        let mut entries: *mut *mut FWPM_FILTER0 = std::ptr::null_mut();
        let mut n = 0u32;
        if unsafe { FwpmFilterEnum0(e.0, handle, 256, &mut entries, &mut n) } != 0 {
            break;
        }
        for i in 0..n as usize {
            let f = unsafe { &**entries.add(i) };
            if guid_u128(&f.subLayerKey) == guid_u128(&SUBLAYER) {
                keys.push(f.filterKey);
            }
        }
        if !entries.is_null() {
            unsafe { FwpmFreeMemory0(&mut (entries as *mut core::ffi::c_void)) };
        }
        if n < 256 {
            break;
        }
    }
    unsafe { FwpmFilterDestroyEnumHandle0(e.0, handle) };
    Ok(keys)
}

fn guid_u128(g: &GUID) -> u128 {
    ((g.data1 as u128) << 96) | ((g.data2 as u128) << 80) | ((g.data3 as u128) << 64) | u64::from_be_bytes(g.data4) as u128
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keys_differ_per_interface_and_filter() {
        assert_ne!(key(1, 0), key(1, 1));
        assert_ne!(key(1, 0), key(2, 0));
        assert_eq!(key(0xABCDEF, 3) & 0xFFFF_FFFF_FFFF, 0xABCDEF, "the sweep reads the interface back from the key");
        assert_eq!(guid_u128(&GUID::from_u128(key(7, 2))), key(7, 2));
    }
}
