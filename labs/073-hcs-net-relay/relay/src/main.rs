//! Lab 073: internet for an isolated HCS machine without any Windows NAT in the path.
//!   guest: a Wintun adapter takes the guest's internet traffic, a user-mode TCP/IP stack ends each TCP or UDP flow,
//!          and every flow goes to the host over its own Hyper-V socket as "connect to ip:port".
//!   host:  listens only for one VM, refuses every destination that is not a public address, and opens the
//!          connection itself. The host never parses the guest's packets.
//! Header guest -> host: kind (1 TCP, 2 UDP), IPv4 (4 bytes), port (2 bytes, big endian). Reply: one status byte.
//! UDP datagrams travel as a 2-byte big-endian length followed by the payload.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpStream, UdpSocket};
use std::sync::Arc;
use std::time::Duration;

use windows_sys::core::GUID;
use windows_sys::Win32::Networking::WinSock::*;

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const HVSOCKET_CONNECT_TIMEOUT: i32 = 1;
const HV_GUID_PARENT: u128 = 0xa42e7cda_d03f_480c_9cc2_a4de20abb878;
pub const SERVICE: u128 = 0x6e1a3c5f_1d2b_4f0e_9a65_0657b0c0e073;

const OK: u8 = 0;
const REFUSED: u8 = 1;
const UNREACHABLE: u8 = 2;

#[repr(C)]
struct SockaddrHv {
    family: u16,
    reserved: u16,
    vm_id: GUID,
    service_id: GUID,
}

struct Sock(SOCKET);
unsafe impl Send for Sock {}
unsafe impl Sync for Sock {}

impl Drop for Sock {
    fn drop(&mut self) {
        unsafe { closesocket(self.0) };
    }
}

fn wsa() -> std::io::Error {
    std::io::Error::from_raw_os_error(unsafe { WSAGetLastError() })
}

impl Sock {
    fn new() -> std::io::Result<Sock> {
        let mut d: WSADATA = unsafe { std::mem::zeroed() };
        unsafe { WSAStartup(0x0202, &mut d) };
        let s = unsafe { socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) };
        if s == INVALID_SOCKET { Err(wsa()) } else { Ok(Sock(s)) }
    }
    fn addr(vm: u128) -> SockaddrHv {
        SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: GUID::from_u128(vm), service_id: GUID::from_u128(SERVICE) }
    }
    fn connect(vm: u128, timeout_ms: u32) -> std::io::Result<Sock> {
        let s = Sock::new()?;
        unsafe { setsockopt(s.0, HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT, &timeout_ms as *const u32 as *const u8, 4) };
        let a = Sock::addr(vm);
        if unsafe { connect(s.0, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) } != 0 {
            return Err(wsa());
        }
        Ok(s)
    }
    fn listen(vm: u128) -> std::io::Result<Sock> {
        let s = Sock::new()?;
        let a = Sock::addr(vm);
        if unsafe { bind(s.0, &a as *const _ as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) } != 0
            || unsafe { listen(s.0, 128) } != 0
        {
            return Err(wsa());
        }
        Ok(s)
    }
    fn accept(&self) -> std::io::Result<(Sock, u128)> {
        let mut peer: SockaddrHv = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of::<SockaddrHv>() as i32;
        let c = unsafe { accept(self.0, &mut peer as *mut _ as *mut SOCKADDR, &mut len) };
        if c == INVALID_SOCKET {
            return Err(wsa());
        }
        Ok((Sock(c), peer.vm_id.to_u128()))
    }
    fn shutdown_send(&self) {
        unsafe { shutdown(self.0, SD_SEND) };
    }
    fn recv_timeout(&self, ms: u32) {
        unsafe { setsockopt(self.0, SOL_SOCKET, SO_RCVTIMEO, &ms as *const u32 as *const u8, 4) };
    }
}

trait ToU128 {
    fn to_u128(&self) -> u128;
}
impl ToU128 for GUID {
    fn to_u128(&self) -> u128 {
        ((self.data1 as u128) << 96) | ((self.data2 as u128) << 80) | ((self.data3 as u128) << 64) | u64::from_be_bytes(self.data4) as u128
    }
}

impl Read for &Sock {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = unsafe { recv(self.0, buf.as_mut_ptr(), buf.len().min(1 << 30) as i32, 0) };
        if n < 0 { Err(wsa()) } else { Ok(n as usize) }
    }
}

impl Write for &Sock {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        let n = unsafe { send(self.0, buf.as_ptr(), buf.len().min(1 << 30) as i32, 0) };
        if n < 0 { Err(wsa()) } else { Ok(n as usize) }
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// Only addresses on the public internet: never private, shared (CGNAT), loopback, link-local, multicast,
/// broadcast, documentation, benchmarking or reserved ranges, and never one of the host's own addresses.
pub fn is_public(ip: Ipv4Addr, host_addrs: &[Ipv4Addr]) -> bool {
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
        || host_addrs.contains(&ip))
}

fn host_addresses() -> Vec<Ipv4Addr> {
    let out = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-Command", "(Get-NetIPAddress -AddressFamily IPv4).IPAddress"])
        .output();
    out.map(|o| String::from_utf8_lossy(&o.stdout).lines().filter_map(|l| l.trim().parse().ok()).collect()).unwrap_or_default()
}

fn host(vm: u128) {
    let addrs = Arc::new(host_addresses());
    let l = Sock::listen(vm).expect("listen");
    eprintln!("host relay listening for {vm:032x}; host addresses refused: {}", addrs.len());
    loop {
        let (c, peer) = match l.accept() {
            Ok(x) => x,
            Err(e) => { eprintln!("accept: {e}"); continue; }
        };
        if peer != vm {
            continue;
        }
        let addrs = addrs.clone();
        std::thread::spawn(move || {
            if let Err(e) = flow(Arc::new(c), &addrs) {
                eprintln!("flow: {e}");
            }
        });
    }
}

fn flow(hv: Arc<Sock>, addrs: &[Ipv4Addr]) -> std::io::Result<()> {
    hv.recv_timeout(10_000);
    let mut h = [0u8; 7];
    (&*hv).read_exact(&mut h)?;
    hv.recv_timeout(0);
    let ip = Ipv4Addr::new(h[1], h[2], h[3], h[4]);
    let port = u16::from_be_bytes([h[5], h[6]]);
    let dst = SocketAddr::V4(SocketAddrV4::new(ip, port));
    if !is_public(ip, addrs) || port == 0 {
        eprintln!("refused {dst}");
        (&*hv).write_all(&[REFUSED])?;
        return Ok(());
    }
    match h[0] {
        1 => {
            let t = match TcpStream::connect_timeout(&dst, Duration::from_secs(5)) {
                Ok(t) => t,
                Err(_) => return (&*hv).write_all(&[UNREACHABLE]),
            };
            t.set_nodelay(true).ok();
            (&*hv).write_all(&[OK])?;
            let (t2, hv2) = (t.try_clone()?, hv.clone());
            let up = std::thread::spawn(move || {
                let _ = std::io::copy(&mut &*hv2, &mut &t2);
                let _ = t2.shutdown(std::net::Shutdown::Write);
            });
            let _ = std::io::copy(&mut &t, &mut &*hv);
            hv.shutdown_send();
            let _ = up.join();
        }
        2 => {
            let u = UdpSocket::bind("0.0.0.0:0")?;
            if u.connect(dst).is_err() {
                return (&*hv).write_all(&[UNREACHABLE]);
            }
            (&*hv).write_all(&[OK])?;
            u.set_read_timeout(Some(Duration::from_secs(60)))?;
            let (u2, hv2) = (u.try_clone()?, hv.clone());
            std::thread::spawn(move || {
                let mut buf = vec![0u8; 65536];
                while let Ok(n) = u2.recv(&mut buf) {
                    let mut f = (n as u16).to_be_bytes().to_vec();
                    f.extend_from_slice(&buf[..n]);
                    if (&*hv2).write_all(&f).is_err() {
                        break;
                    }
                }
                hv2.shutdown_send();
            });
            let mut len = [0u8; 2];
            let mut buf = vec![0u8; 65536];
            while (&*hv).read_exact(&mut len).is_ok() {
                let n = u16::from_be_bytes(len) as usize;
                if (&*hv).read_exact(&mut buf[..n]).is_err() {
                    break;
                }
                let _ = u.send(&buf[..n]);
            }
        }
        _ => (&*hv).write_all(&[REFUSED])?,
    }
    Ok(())
}

fn open(kind: u8, dst: SocketAddr) -> Option<Arc<Sock>> {
    let SocketAddr::V4(d) = dst else { return None };
    let hv = Sock::connect(HV_GUID_PARENT, 2000).ok()?;
    let mut h = vec![kind];
    h.extend_from_slice(&d.ip().octets());
    h.extend_from_slice(&d.port().to_be_bytes());
    (&hv).write_all(&h).ok()?;
    let mut s = [0u8; 1];
    (&hv).read_exact(&mut s).ok()?;
    (s[0] == OK).then(|| Arc::new(hv))
}

/// Moves bytes the stack hands over to the Hyper-V socket on a blocking thread, framed for UDP.
fn to_hv(hv: Arc<Sock>, framed: bool) -> tokio::sync::mpsc::Sender<Vec<u8>> {
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
    std::thread::spawn(move || {
        while let Some(v) = rx.blocking_recv() {
            let r = if framed {
                let mut f = (v.len() as u16).to_be_bytes().to_vec();
                f.extend_from_slice(&v);
                (&*hv).write_all(&f)
            } else {
                (&*hv).write_all(&v)
            };
            if r.is_err() {
                break;
            }
        }
        hv.shutdown_send();
    });
    tx
}

async fn guest(dll: String) -> Result<(), Box<dyn std::error::Error>> {
    use ipstack::IpStackStream;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let mut cfg = tun::Configuration::default();
    cfg.tun_name("GpuVMNet").address(Ipv4Addr::new(10, 255, 255, 2)).netmask(Ipv4Addr::new(255, 255, 255, 0)).mtu(1500).up();
    cfg.platform_config(|p| {
        p.wintun_file(dll.clone());
        p.dns_servers(&["1.1.1.1".parse().unwrap()]);
    });
    let mut sc = ipstack::IpStackConfig::default();
    sc.mtu(1500)?;
    let mut tc = ipstack::TcpConfig::default();
    tc.options = Some(vec![ipstack::TcpOptions::MaximumSegmentSize(1460)]);
    tc.max_unacked_bytes = 1024 * 1024;
    sc.with_tcp_config(tc);
    sc.udp_timeout(Duration::from_secs(60));
    let mut stack = ipstack::IpStack::new(sc, tun::create_as_async(&cfg)?);
    eprintln!("guest relay up");
    let rt = tokio::runtime::Handle::current();
    loop {
        match stack.accept().await? {
            IpStackStream::Tcp(tcp) => {
                let dst = tcp.peer_addr();
                let rt2 = rt.clone();
                let f: Box<dyn FnOnce(Arc<Sock>) + Send> = Box::new(move |hv: Arc<Sock>| {
                    let (mut r, mut w) = tokio::io::split(tcp);
                    let hv_in = hv.clone();
                    std::thread::spawn(move || {
                        let mut buf = vec![0u8; 65536];
                        while let Ok(n) = (&*hv_in).read(&mut buf) {
                            if n == 0 || rt2.block_on(w.write_all(&buf[..n])).is_err() {
                                break;
                            }
                        }
                        let _ = rt2.block_on(w.shutdown());
                    });
                    let tx = to_hv(hv, false);
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 65536];
                        while let Ok(n) = r.read(&mut buf).await {
                            if n == 0 || tx.send(buf[..n].to_vec()).await.is_err() {
                                break;
                            }
                        }
                    });
                });
                pending(1, dst, f, &rt);
                continue;
            }
            IpStackStream::Udp(udp) => {
                let dst = udp.peer_addr();
                let rt2 = rt.clone();
                let f: Box<dyn FnOnce(Arc<Sock>) + Send> = Box::new(move |hv: Arc<Sock>| {
                    let (mut r, mut w) = tokio::io::split(udp);
                    let hv_in = hv.clone();
                    std::thread::spawn(move || {
                        let mut len = [0u8; 2];
                        let mut buf = vec![0u8; 65536];
                        while (&*hv_in).read_exact(&mut len).is_ok() {
                            let n = u16::from_be_bytes(len) as usize;
                            if (&*hv_in).read_exact(&mut buf[..n]).is_err() || rt2.block_on(w.write_all(&buf[..n])).is_err() {
                                break;
                            }
                        }
                    });
                    let tx = to_hv(hv, true);
                    tokio::spawn(async move {
                        let mut buf = vec![0u8; 65536];
                        while let Ok(n) = r.read(&mut buf).await {
                            if n == 0 || tx.send(buf[..n].to_vec()).await.is_err() {
                                break;
                            }
                        }
                    });
                });
                pending(2, dst, f, &rt);
                continue;
            }
            _ => continue,
        }
    }
}

/// Asks the host for the flow on a blocking thread; the flow starts only when the host accepted the destination.
fn pending(kind: u8, dst: SocketAddr, start: Box<dyn FnOnce(Arc<Sock>) + Send>, rt: &tokio::runtime::Handle) {
    let rt = rt.clone();
    std::thread::spawn(move || {
        if let Some(hv) = open(kind, dst) {
            let _g = rt.enter();
            start(hv);
        }
    });
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("host") => {
            let vm = u128::from_str_radix(&args[2].replace('-', ""), 16).expect("vm id");
            host(vm);
        }
        Some("guest") => {
            let dll = args.get(2).cloned().unwrap_or_else(|| "wintun.dll".into());
            let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
            if let Err(e) = rt.block_on(guest(dll)) {
                eprintln!("guest: {e}");
                std::process::exit(1);
            }
        }
        _ => eprintln!("netrelay host <vm-id> | guest [wintun.dll]"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_public_addresses_pass() {
        let host = [Ipv4Addr::new(203, 0, 114, 7)];
        for bad in ["10.0.0.1", "172.16.5.4", "192.168.100.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "224.0.0.1",
                    "255.255.255.255", "0.1.2.3", "192.0.0.8", "198.18.0.1", "240.0.0.1", "203.0.113.5", "203.0.114.7"] {
            assert!(!is_public(bad.parse().unwrap(), &host), "{bad}");
        }
        for good in ["1.1.1.1", "8.8.8.8", "142.250.80.46", "172.32.0.1", "100.128.0.1"] {
            assert!(is_public(good.parse().unwrap(), &host), "{good}");
        }
    }
}
