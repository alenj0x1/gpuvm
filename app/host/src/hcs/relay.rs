//! Internet for isolated HCS machines (labs 070-073). Their only network adapter is on the isolated network, where
//! the host forwards nothing; GpuVM's agent in the guest ends each TCP or UDP flow in a user-mode stack and opens one
//! Hyper-V socket per flow to this relay, saying where it wants to go. The relay refuses every destination that is
//! not on the public internet and opens the connection itself. It never parses the guest's packets, only the
//! 7-byte request below, and Hyper-V fills in which machine is calling.
//!
//! Request (guest -> host): kind (1 TCP, 2 UDP), IPv4 (4 bytes), port (2 bytes, big endian).
//! Reply: one status byte; after OK the socket carries the TCP bytes, or UDP datagrams as a 2-byte big-endian
//! length followed by the payload, in both directions.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use windows_sys::Win32::NetworkManagement::IpHelper::*;
use windows_sys::Win32::Networking::WinSock::AF_INET;

use crate::hv::{self, Sock};

/// The relay's Hyper-V socket service; isolated machines get it in their service table (machine.rs).
pub const SERVICE: &str = "6e1a3c5f-1d2b-4f0e-9a65-0657b0c0e073";
const SERVICE_ID: u128 = 0x6e1a3c5f_1d2b_4f0e_9a65_0657b0c0e073;

pub const OK: u8 = 0;
pub const REFUSED: u8 = 1;
pub const UNREACHABLE: u8 = 2;
pub const BUSY: u8 = 3;

const TCP: u8 = 1;
const UDP: u8 = 2;
/// Flows one machine may have open at once.
const MAX_FLOWS: usize = 1024;
const REQUEST_TIMEOUT_MS: u32 = 10_000;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
const UDP_IDLE: Duration = Duration::from_secs(120);
/// TCP keepalive: a peer that vanished (a NAT that dropped the flow) frees its slot within about two minutes.
const KEEPALIVE_IDLE_S: u32 = 60;
const KEEPALIVE_INTERVAL_S: u32 = 10;

/// The host's own networks: each address with its on-link prefix length, and its default gateways (/32). A LAN with
/// public addresses (some campuses and offices) is still the LAN.
pub type HostNets = Vec<(Ipv4Addr, u8)>;

fn on_host_network(ip: Ipv4Addr, nets: &[(Ipv4Addr, u8)]) -> bool {
    nets.iter().any(|(a, len)| {
        let len = (*len).min(32) as u32;
        let mask = if len == 0 { 0 } else { u32::MAX << (32 - len) };
        // A /0 would be everything: only networks of at least /8 count, plus exact addresses.
        len >= 8 && (u32::from(ip) & mask) == (u32::from(*a) & mask)
    })
}

/// Only addresses on the public internet: never private, shared (CGNAT), loopback, link-local, multicast,
/// broadcast, documentation, benchmarking or reserved ranges, and never one of the host's own networks or gateways.
pub fn is_public(ip: Ipv4Addr, host_nets: &[(Ipv4Addr, u8)]) -> bool {
    let o = ip.octets();
    !(ip.is_private()
        || ip.is_loopback()
        || ip.is_link_local()
        || ip.is_multicast()
        || ip.is_broadcast()
        || ip.is_unspecified()
        || ip.is_documentation()
        || o[0] == 0
        || (o[0] == 100 && (o[1] & 0xC0) == 64)
        || (o[0] == 192 && o[1] == 0 && o[2] == 0)
        || (o[0] == 198 && (o[1] & 0xFE) == 18)
        || o[0] >= 240
        || on_host_network(ip, host_nets))
}

fn host_networks() -> HostNets {
    let mut out = HostNets::new();
    let mut table: *mut MIB_UNICASTIPADDRESS_TABLE = std::ptr::null_mut();
    if unsafe { GetUnicastIpAddressTable(AF_INET, &mut table) } == 0 {
        unsafe {
            for r in std::slice::from_raw_parts((*table).Table.as_ptr(), (*table).NumEntries as usize) {
                out.push((Ipv4Addr::from(u32::from_be(r.Address.Ipv4.sin_addr.S_un.S_addr)), r.OnLinkPrefixLength.max(8)));
                out.push((Ipv4Addr::from(u32::from_be(r.Address.Ipv4.sin_addr.S_un.S_addr)), 32));
            }
            FreeMibTable(table.cast());
        }
    }
    let mut routes: *mut MIB_IPFORWARD_TABLE2 = std::ptr::null_mut();
    if unsafe { GetIpForwardTable2(AF_INET, &mut routes) } == 0 {
        unsafe {
            for r in std::slice::from_raw_parts((*routes).Table.as_ptr(), (*routes).NumEntries as usize) {
                let hop = Ipv4Addr::from(u32::from_be(r.NextHop.Ipv4.sin_addr.S_un.S_addr));
                if r.DestinationPrefix.PrefixLength == 0 && !hop.is_unspecified() {
                    out.push((hop, 32));
                }
            }
            FreeMibTable(routes.cast());
        }
    }
    out
}

/// The host's addresses, read again at most every 30 s (an address a host gets later is refused within that time;
/// it is public only when the host itself sits on the internet).
fn current_host_networks() -> HostNets {
    static CACHE: OnceLock<Mutex<(Instant, HostNets)>> = OnceLock::new();
    let c = CACHE.get_or_init(|| Mutex::new((Instant::now(), host_networks())));
    let mut g = c.lock().unwrap_or_else(|e| e.into_inner());
    if g.0.elapsed() > Duration::from_secs(30) {
        *g = (Instant::now(), host_networks());
    }
    g.1.clone()
}

fn flows() -> &'static Mutex<HashMap<u128, usize>> {
    static F: OnceLock<Mutex<HashMap<u128, usize>>> = OnceLock::new();
    F.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Counts a machine's flow while it lives.
struct FlowSlot(u128);

impl FlowSlot {
    fn take(vm: u128) -> Option<FlowSlot> {
        let mut f = flows().lock().unwrap_or_else(|e| e.into_inner());
        let n = f.entry(vm).or_insert(0);
        if *n >= MAX_FLOWS {
            return None;
        }
        *n += 1;
        Some(FlowSlot(vm))
    }
}

impl Drop for FlowSlot {
    fn drop(&mut self) {
        let mut f = flows().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = f.get_mut(&self.0) {
            *n -= 1;
            if *n == 0 {
                f.remove(&self.0);
            }
        }
    }
}

/// Runs the relay for as long as the service runs.
pub fn start() {
    match super::wfp::sweep() {
        Ok(0) => {}
        Ok(n) => crate::server::log(&format!("relay: removed {n} filters of networks that no longer exist")),
        Err(e) => crate::server::log(&format!("relay: couldn't check old filters: {e}")),
    }
    std::thread::spawn(|| {
        hv::startup();
        loop {
            match Sock::listen(hv::HV_GUID_CHILDREN, SERVICE_ID) {
                Ok(l) => {
                    crate::server::log("relay: listening for isolated machines");
                    loop {
                        match l.accept() {
                            Ok((c, vm)) if vm != 0 => {
                                std::thread::spawn(move || flow(Arc::new(c), vm));
                            }
                            Ok(_) => {}
                            Err(_) => break,
                        }
                    }
                    std::thread::sleep(Duration::from_secs(1));
                }
                Err(code) => {
                    crate::server::log(&format!("relay: couldn't listen (error {code}); isolated machines have no internet"));
                    std::thread::sleep(Duration::from_secs(5));
                }
            }
        }
    });
}

fn flow(hv: Arc<Sock>, vm: u128) {
    let Some(_slot) = FlowSlot::take(vm) else {
        let _ = (&*hv).write_all(&[BUSY]);
        return;
    };
    hv.set_timeouts(REQUEST_TIMEOUT_MS, REQUEST_TIMEOUT_MS);
    let mut h = [0u8; 7];
    if (&*hv).read_exact(&mut h).is_err() {
        return;
    }
    let ip = Ipv4Addr::new(h[1], h[2], h[3], h[4]);
    let port = u16::from_be_bytes([h[5], h[6]]);
    if !(h[0] == TCP || h[0] == UDP) || port == 0 || !is_public(ip, &current_host_networks()) {
        let _ = (&*hv).write_all(&[REFUSED]);
        return;
    }
    let dst = SocketAddr::V4(SocketAddrV4::new(ip, port));
    if h[0] == TCP {
        let Ok(t) = TcpStream::connect_timeout(&dst, CONNECT_TIMEOUT) else {
            let _ = (&*hv).write_all(&[UNREACHABLE]);
            return;
        };
        let _ = t.set_nodelay(true);
        keepalive(&t);
        if (&*hv).write_all(&[OK]).is_err() {
            return;
        }
        hv.set_timeouts(0, 0);
        let Ok(t2) = t.try_clone() else { return };
        let hv2 = hv.clone();
        let up = std::thread::spawn(move || {
            let _ = std::io::copy(&mut &*hv2, &mut &t2);
            let _ = t2.shutdown(std::net::Shutdown::Write);
        });
        let _ = std::io::copy(&mut &t, &mut &*hv);
        hv.shutdown_send();
        let _ = up.join();
    } else {
        let Ok(u) = UdpSocket::bind("0.0.0.0:0") else { return };
        if u.connect(dst).is_err() {
            let _ = (&*hv).write_all(&[UNREACHABLE]);
            return;
        }
        if (&*hv).write_all(&[OK]).is_err() {
            return;
        }
        hv.set_timeouts(0, 0);
        let _ = u.set_read_timeout(Some(Duration::from_secs(1)));
        let Ok(u2) = u.try_clone() else { return };
        let (hv2, done) = (hv.clone(), Arc::new(AtomicBool::new(false)));
        let done2 = done.clone();
        // Last datagram either way, in ms since `born`: a flow that only sends stays alive too.
        let born = Instant::now();
        let last = Arc::new(AtomicU64::new(0));
        let last2 = last.clone();
        let down = std::thread::spawn(move || {
            let mut buf = vec![0u8; 65535];
            loop {
                let n = match u2.recv(&mut buf) {
                    Ok(n) => n,
                    // An ICMP "port unreachable" for an earlier datagram shows up as a reset; the flow goes on.
                    Err(e) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut | std::io::ErrorKind::ConnectionReset) => {
                        let idle = born.elapsed().saturating_sub(Duration::from_millis(last2.load(Ordering::Relaxed)));
                        if done2.load(Ordering::Relaxed) || idle > UDP_IDLE {
                            break;
                        }
                        continue;
                    }
                    Err(_) => break,
                };
                last2.store(born.elapsed().as_millis() as u64, Ordering::Relaxed);
                let mut f = Vec::with_capacity(n + 2);
                f.extend_from_slice(&(n as u16).to_be_bytes());
                f.extend_from_slice(&buf[..n]);
                if (&*hv2).write_all(&f).is_err() {
                    break;
                }
            }
            hv2.shutdown();
        });
        let mut len = [0u8; 2];
        let mut buf = vec![0u8; 65535];
        while (&*hv).read_exact(&mut len).is_ok() {
            let n = u16::from_be_bytes(len) as usize;
            if (&*hv).read_exact(&mut buf[..n]).is_err() {
                break;
            }
            let _ = u.send(&buf[..n]);
            last.store(born.elapsed().as_millis() as u64, Ordering::Relaxed);
        }
        // The guest closed the flow: the receiving side stops within a second, so the slot is freed.
        done.store(true, Ordering::Relaxed);
        let _ = down.join();
    }
}

fn keepalive(t: &TcpStream) {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{setsockopt, IPPROTO_TCP, SOL_SOCKET, SO_KEEPALIVE};
    const TCP_KEEPIDLE: i32 = 3;
    const TCP_KEEPINTVL: i32 = 17;
    let s = t.as_raw_socket() as usize;
    let on: u32 = 1;
    unsafe {
        setsockopt(s, SOL_SOCKET, SO_KEEPALIVE, &on as *const u32 as *const u8, 4);
        setsockopt(s, IPPROTO_TCP, TCP_KEEPIDLE, &KEEPALIVE_IDLE_S as *const u32 as *const u8, 4);
        setsockopt(s, IPPROTO_TCP, TCP_KEEPINTVL, &KEEPALIVE_INTERVAL_S as *const u32 as *const u8, 4);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_public_addresses_pass() {
        let host = [(Ipv4Addr::new(203, 0, 114, 7), 32), (Ipv4Addr::new(130, 50, 0, 20), 16)];
        for bad in ["10.0.0.1", "172.16.5.4", "172.31.255.255", "192.168.100.1", "127.0.0.1", "169.254.1.1", "100.64.0.1",
                    "100.127.255.255", "224.0.0.251", "239.255.255.250", "255.255.255.255", "0.1.2.3", "192.0.0.8",
                    "192.0.2.1", "198.18.0.1", "198.19.255.1", "198.51.100.1", "203.0.113.5", "240.0.0.1", "203.0.114.7",
                    "130.50.9.9"] {
            assert!(!is_public(bad.parse().unwrap(), &host), "{bad}");
        }
        for good in ["1.1.1.1", "8.8.8.8", "142.250.80.46", "172.32.0.1", "100.128.0.1", "198.20.0.1", "11.0.0.1"] {
            assert!(is_public(good.parse().unwrap(), &host), "{good}");
        }
    }

    #[test]
    fn a_machine_cannot_hold_more_than_its_share_of_flows() {
        let vm = 0x1234;
        let slots: Vec<_> = (0..MAX_FLOWS).map(|_| FlowSlot::take(vm).unwrap()).collect();
        assert!(FlowSlot::take(vm).is_none());
        assert!(FlowSlot::take(vm + 1).is_some(), "another machine is not affected");
        drop(slots);
        assert!(FlowSlot::take(vm).is_some());
        assert!(flows().lock().unwrap().get(&vm).is_none_or(|n| *n <= 1));
    }
}
