//! The network of an isolated HCS machine (labs 070-073, host side in app/host/src/hcs/relay.rs). Its adapter sits on
//! GpuVM's isolated network, where the only peer is the host and nothing is forwarded; it gets a fixed address
//! there. Internet goes through a Wintun adapter that holds the default route: a user-mode stack ends each TCP or
//! UDP flow and the host relay opens it, over one Hyper-V socket per flow, only to public addresses.
//! The guest also drops what the host would refuse and answers refused TCP at once, so apps fail fast; that is a
//! courtesy, the host's check is the one that holds.

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr};
use std::pin::Pin;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::task::{Context, Poll};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};

use crate::hv::{dial, HvStream};
use crate::proto::HV_GUID_PARENT;

const RELAY_SERVICE: u128 = 0x6e1a3c5f_1d2b_4f0e_9a65_0657b0c0e073;
const CONFIG: &str = r"C:\ProgramData\GpuVM\Agent\net.json";
pub const TUN_NAME: &str = "GpuVMNet";
const TUN_ADDR: Ipv4Addr = Ipv4Addr::new(10, 255, 255, 2);
const TUN_GATEWAY: &str = "10.255.255.1";
const DNS: [&str; 2] = ["1.1.1.1", "1.0.0.1"];
const MTU: u16 = 1500;
const OK: u8 = 0;
/// Flows open at once; past it new ones are dropped (each costs two threads).
const MAX_FLOWS: usize = 512;

/// Whether the relay holds the default route: only while the machine is set up as isolated.
static ISOLATED: AtomicBool = AtomicBool::new(false);
static FLOWS: AtomicUsize = AtomicUsize::new(0);

/// Same rule as the host relay (without the host's own addresses, which only the host knows).
pub fn is_public(ip: Ipv4Addr) -> bool {
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
        || o[0] >= 240)
}

#[derive(Clone, Debug, PartialEq)]
pub struct Isolated {
    pub mac: String,
    pub ip: Ipv4Addr,
    pub prefix: u8,
}

/// `sys.net`: {"mode":"isolated","mac","ip","prefixLength"} or {"mode":"dhcp","mac"}.
pub fn configure(params: &Value) -> Result<Value, String> {
    crate::secret::check_acl(crate::secret::DIR).map_err(|e| format!("{}: {e}", crate::secret::DIR))?;
    let mac = params["mac"].as_str().map(normal_mac).ok_or("mac is required")?.ok_or("not a MAC address")?;
    match params["mode"].as_str() {
        Some("isolated") => {
            let ip: Ipv4Addr = params["ip"].as_str().and_then(|s| s.parse().ok()).ok_or("ip is not an IPv4 address")?;
            let prefix = params["prefixLength"].as_u64().unwrap_or(24);
            if !(8..=30).contains(&prefix) {
                return Err("prefixLength is out of range".into());
            }
            let cfg = Isolated { mac, ip, prefix: prefix as u8 };
            save(Some(&cfg))?;
            apply_isolated(&cfg)?;
            Ok(json!({ "mode": "isolated", "ip": ip.to_string(), "relay": relay_state() }))
        }
        Some("dhcp") => {
            save(None)?;
            apply_dhcp(&mac)?;
            Ok(json!({ "mode": "dhcp" }))
        }
        _ => Err("mode is isolated or dhcp".into()),
    }
}

/// At service start: a machine set up as isolated gets its address and its internet before the host asks again.
pub fn resume() {
    if crate::secret::check_acl(crate::secret::DIR).is_err() {
        return;
    }
    if let Some(cfg) = load() {
        if let Err(e) = apply_isolated(&cfg) {
            crate::logf!("net: {e}");
        }
    }
}

fn normal_mac(s: &str) -> Option<String> {
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect::<String>().to_ascii_uppercase();
    if hex.len() != 12 || s.chars().any(|c| !(c.is_ascii_hexdigit() || c == '-' || c == ':')) {
        return None;
    }
    Some((0..6).map(|i| &hex[i * 2..i * 2 + 2]).collect::<Vec<_>>().join("-"))
}

fn save(cfg: Option<&Isolated>) -> Result<(), String> {
    match cfg {
        Some(c) => std::fs::write(CONFIG, json!({ "mode": "isolated", "mac": c.mac, "ip": c.ip.to_string(), "prefixLength": c.prefix }).to_string())
            .map_err(|e| format!("{CONFIG}: {e}")),
        None => match std::fs::remove_file(CONFIG) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(format!("{CONFIG}: {e}")),
            _ => Ok(()),
        },
    }
}

fn load() -> Option<Isolated> {
    let v: Value = serde_json::from_slice(&std::fs::read(CONFIG).ok()?).ok()?;
    Some(Isolated {
        mac: normal_mac(v["mac"].as_str()?)?,
        ip: v["ip"].as_str()?.parse().ok()?,
        prefix: v["prefixLength"].as_u64().filter(|p| (8..=30).contains(p))? as u8,
    })
}

fn powershell(script: &str) -> Result<String, String> {
    let root = std::env::var_os("SystemRoot").map(std::path::PathBuf::from).unwrap_or_else(|| r"C:\Windows".into());
    let out = Command::new(root.join(r"System32\WindowsPowerShell\v1.0\powershell.exe"))
        .args(["-NoProfile", "-NonInteractive", "-Command", script])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("powershell: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if out.status.success() {
        Ok(text)
    } else {
        Err(format!("{} {}", text, String::from_utf8_lossy(&out.stderr).trim()))
    }
}

/// The adapter with this MAC: a fixed address, no gateway, no DHCP. Values are validated before they get here.
fn apply_isolated(cfg: &Isolated) -> Result<(), String> {
    powershell(&format!(
        "$ErrorActionPreference = 'Stop'; $a = Get-NetAdapter -Physical | Where-Object MacAddress -eq '{mac}' | Select-Object -First 1; \
         if (-not $a) {{ throw 'no adapter with MAC {mac}' }}; \
         $have = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue; \
         if (-not ($have | Where-Object {{ $_.IPAddress -eq '{ip}' -and $_.PrefixOrigin -eq 'Manual' }})) {{ \
           Set-NetIPInterface -InterfaceIndex $a.ifIndex -Dhcp Disabled; \
           $have | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue; \
           New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress {ip} -PrefixLength {prefix} | Out-Null }}; \
         Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false; \
         Disable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue; \
         Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses",
        mac = cfg.mac, ip = cfg.ip, prefix = cfg.prefix
    ))?;
    ISOLATED.store(true, Ordering::SeqCst);
    start_relay();
    Ok(())
}

fn apply_dhcp(mac: &str) -> Result<(), String> {
    ISOLATED.store(false, Ordering::SeqCst);
    powershell(&format!(
        "$ErrorActionPreference = 'Stop'; $a = Get-NetAdapter -Physical | Where-Object MacAddress -eq '{mac}' | Select-Object -First 1; \
         if (-not $a) {{ throw 'no adapter with MAC {mac}' }}; \
         Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object PrefixOrigin -eq 'Manual' | Remove-NetIPAddress -Confirm:$false; \
         Set-NetIPInterface -InterfaceIndex $a.ifIndex -Dhcp Enabled; \
         Enable-NetAdapterBinding -Name $a.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue; \
         $t = Get-NetAdapter -Name {TUN_NAME} -ErrorAction SilentlyContinue; \
         if ($t) {{ Get-NetRoute -InterfaceIndex $t.ifIndex -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false }}; \
         ipconfig /renew | Out-Null"
    ))?;
    Ok(())
}

fn state() -> &'static Mutex<Value> {
    static S: OnceLock<Mutex<Value>> = OnceLock::new();
    S.get_or_init(|| Mutex::new(json!({ "running": false })))
}

fn relay_state() -> Value {
    state().lock().map(|v| v.clone()).unwrap_or(Value::Null)
}

fn set_state(v: Value) {
    if let Ok(mut s) = state().lock() {
        *s = v;
    }
}

/// Starts the relay once per service run; it keeps the default route on its adapter.
fn start_relay() {
    static STARTED: OnceLock<()> = OnceLock::new();
    if STARTED.set(()).is_err() {
        // Already running: put the route back without holding up the host's call.
        std::thread::spawn(|| {
            if let Err(e) = route_through_tun() {
                crate::logf!("net: {e}");
            }
        });
        return;
    }
    std::thread::spawn(|| loop {
        let rt = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
            Ok(rt) => rt,
            Err(e) => {
                set_state(json!({ "running": false, "error": format!("runtime: {e}") }));
                return;
            }
        };
        if let Err(e) = rt.block_on(relay()) {
            crate::logf!("net: relay stopped: {e}");
            set_state(json!({ "running": false, "error": e }));
        }
        drop(rt);
        std::thread::sleep(Duration::from_secs(5));
    });
}

/// Only the copy next to the agent (Program Files, administrators only): never a search by name.
fn wintun_path() -> Result<String, String> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.join("wintun.dll")))
        .filter(|p| p.is_file())
        .map(|p| p.to_string_lossy().into_owned())
        .ok_or_else(|| "wintun.dll is not next to the agent".into())
}

/// The default route through the relay adapter, only while the machine is isolated (a machine switched to DHCP
/// keeps its own adapter's route even if the relay restarts).
fn route_through_tun() -> Result<(), String> {
    if !ISOLATED.load(Ordering::SeqCst) {
        return Ok(());
    }
    powershell(&format!(
        "$ErrorActionPreference = 'Stop'; $t = $null; foreach ($i in 1..30) {{ $t = Get-NetAdapter -Name {TUN_NAME} -ErrorAction SilentlyContinue; if ($t -and $t.Status -eq 'Up') {{ break }}; Start-Sleep 1 }}; \
         if (-not $t) {{ throw 'the relay adapter did not appear' }}; \
         if (-not (Get-NetRoute -InterfaceIndex $t.ifIndex -DestinationPrefix 0.0.0.0/0 -ErrorAction SilentlyContinue)) {{ \
           New-NetRoute -InterfaceIndex $t.ifIndex -DestinationPrefix 0.0.0.0/0 -NextHop {TUN_GATEWAY} -RouteMetric 1 | Out-Null }}; \
         Set-DnsClientServerAddress -InterfaceIndex $t.ifIndex -ServerAddresses {}, {}",
        DNS[0], DNS[1]
    ))
    .map(|_| ())
}

async fn relay() -> Result<(), String> {
    let mut cfg = tun::Configuration::default();
    cfg.tun_name(TUN_NAME).address(TUN_ADDR).netmask(Ipv4Addr::new(255, 255, 255, 0)).mtu(MTU).up();
    let dll = wintun_path()?;
    cfg.platform_config(|p| {
        p.wintun_file(dll.clone());
    });
    let dev = tun::create_as_async(&cfg).map_err(|e| format!("Wintun adapter: {e}"))?;
    let mut sc = ipstack::IpStackConfig::default();
    sc.mtu(MTU).map_err(|e| e.to_string())?;
    let mut tc = ipstack::TcpConfig::default();
    tc.options = Some(vec![ipstack::TcpOptions::MaximumSegmentSize(MTU - 40)]);
    tc.max_unacked_bytes = 1024 * 1024;
    sc.with_tcp_config(tc);
    sc.udp_timeout(Duration::from_secs(120));
    let mut stack = ipstack::IpStack::new(sc, Guard::new(dev));
    tokio::task::spawn_blocking(route_through_tun).await.map_err(|e| e.to_string())??;
    set_state(json!({ "running": true }));
    crate::logf!("net: relay up");
    let rt = tokio::runtime::Handle::current();
    loop {
        match stack.accept().await.map_err(|e| e.to_string())? {
            ipstack::IpStackStream::Tcp(tcp) => {
                let dst = tcp.peer_addr();
                flow(1, dst, Box::new(tcp), false, rt.clone());
            }
            ipstack::IpStackStream::Udp(udp) => {
                let dst = udp.peer_addr();
                flow(2, dst, Box::new(udp), true, rt.clone());
            }
            _ => {}
        }
    }
}

trait Duplex: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> Duplex for T {}

/// One flow: ask the host on a blocking thread, then copy both ways (UDP datagrams carry a length prefix).
/// Counts a flow while it lives.
struct FlowSlot;

impl FlowSlot {
    fn take() -> Option<FlowSlot> {
        let n = FLOWS.fetch_add(1, Ordering::SeqCst);
        if n >= MAX_FLOWS {
            FLOWS.fetch_sub(1, Ordering::SeqCst);
            return None;
        }
        Some(FlowSlot)
    }
}

impl Drop for FlowSlot {
    fn drop(&mut self) {
        FLOWS.fetch_sub(1, Ordering::SeqCst);
    }
}

fn flow(kind: u8, dst: SocketAddr, s: Box<dyn Duplex>, framed: bool, rt: tokio::runtime::Handle) {
    let Some(slot) = FlowSlot::take() else {
        let _g = rt.enter();
        drop(s);
        return;
    };
    let rt_fail = rt.clone();
    let spawned = std::thread::Builder::new().spawn(move || {
        let _slot = slot;
        let SocketAddr::V4(d) = dst else { return };
        let Some(hv) = open(kind, *d.ip(), d.port()) else {
            // Dropping the stream ends the guest's side of the flow.
            let _g = rt.enter();
            drop(s);
            return;
        };
        let hv = Arc::new(hv);
        let (mut r, mut w) = tokio::io::split(s);
        let hv_in = hv.clone();
        let rt_in = rt.clone();
        let reader = std::thread::Builder::new().spawn(move || {
            let mut buf = vec![0u8; 65536];
            if framed {
                let mut len = [0u8; 2];
                while (&*hv_in).read_exact(&mut len).is_ok() {
                    let n = u16::from_be_bytes(len) as usize;
                    if (&*hv_in).read_exact(&mut buf[..n]).is_err() {
                        break;
                    }
                    // One write is one datagram; the stack cuts anything over its MTU, so such a datagram is dropped
                    // whole instead of reaching the app in two pieces.
                    if n > (MTU - 28) as usize {
                        continue;
                    }
                    if rt_in.block_on(w.write(&buf[..n])).is_err() {
                        break;
                    }
                }
            } else {
                while let Ok(n) = (&*hv_in).read(&mut buf) {
                    if n == 0 || rt_in.block_on(w.write_all(&buf[..n])).is_err() {
                        break;
                    }
                }
                let _ = rt_in.block_on(w.shutdown());
            }
        });
        if reader.is_err() {
            hv.shutdown();
            return;
        }
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(64);
        rt.spawn(async move {
            let mut buf = vec![0u8; 65536];
            while let Ok(n) = r.read(&mut buf).await {
                if n == 0 || tx.send(buf[..n].to_vec()).await.is_err() {
                    break;
                }
            }
        });
        while let Some(v) = rx.blocking_recv() {
            let sent = if framed {
                let mut f = Vec::with_capacity(v.len() + 2);
                f.extend_from_slice(&(v.len() as u16).to_be_bytes());
                f.extend_from_slice(&v);
                (&*hv).write_all(&f)
            } else {
                (&*hv).write_all(&v)
            };
            if sent.is_err() {
                break;
            }
        }
        hv.shutdown_send();
    });
    if spawned.is_err() {
        // The closure and the stream in it were dropped with the error; nothing else holds the flow.
        let _g = rt_fail.enter();
    }
}

fn open(kind: u8, ip: Ipv4Addr, port: u16) -> Option<HvStream> {
    let hv = dial(HV_GUID_PARENT, RELAY_SERVICE, 2000).ok()?;
    hv.set_timeouts(15_000, 15_000);
    let mut h = vec![kind];
    h.extend_from_slice(&ip.octets());
    h.extend_from_slice(&port.to_be_bytes());
    (&hv).write_all(&h).ok()?;
    let mut s = [0u8; 1];
    (&hv).read_exact(&mut s).ok()?;
    hv.set_timeouts(0, 0);
    (s[0] == OK).then_some(hv)
}

/// What the guest does with a packet before the stack sees it.
#[derive(Debug, PartialEq)]
enum Verdict {
    Pass,
    Drop,
    Reset(Vec<u8>),
}

/// Lets IPv4 TCP/UDP to public addresses through; answers a TCP SYN to anything else with a reset at once and
/// drops the rest (IPv6 has no route through the relay).
fn verdict(p: &[u8]) -> Verdict {
    if p.len() < 20 || p[0] >> 4 != 4 {
        return Verdict::Drop;
    }
    let ihl = ((p[0] & 0x0F) as usize) * 4;
    if ihl < 20 || p.len() < ihl {
        return Verdict::Drop;
    }
    let dst = Ipv4Addr::new(p[16], p[17], p[18], p[19]);
    let proto = p[9];
    if proto != 6 && proto != 17 {
        return Verdict::Drop;
    }
    if is_public(dst) {
        return Verdict::Pass;
    }
    if proto == 6 && p.len() >= ihl + 20 {
        let flags = p[ihl + 13];
        if flags & 0x02 != 0 && flags & 0x10 == 0 {
            return Verdict::Reset(reset_for(p, ihl));
        }
    }
    Verdict::Drop
}

fn checksum(data: &[u8], mut sum: u32) -> u16 {
    for c in data.chunks(2) {
        sum += u16::from_be_bytes([c[0], *c.get(1).unwrap_or(&0)]) as u32;
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    !(sum as u16)
}

/// RST+ACK answering a SYN, from the address the guest tried to reach.
fn reset_for(syn: &[u8], ihl: usize) -> Vec<u8> {
    let t = &syn[ihl..];
    let seq = u32::from_be_bytes([t[4], t[5], t[6], t[7]]);
    let mut out = vec![0u8; 40];
    out[0] = 0x45;
    out[2..4].copy_from_slice(&40u16.to_be_bytes());
    out[8] = 64;
    out[9] = 6;
    out[12..16].copy_from_slice(&syn[16..20]);
    out[16..20].copy_from_slice(&syn[12..16]);
    let c = checksum(&out[..20], 0);
    out[10..12].copy_from_slice(&c.to_be_bytes());
    out[20..22].copy_from_slice(&t[2..4]);
    out[22..24].copy_from_slice(&t[0..2]);
    out[28..32].copy_from_slice(&seq.wrapping_add(1).to_be_bytes());
    out[32] = 5 << 4;
    out[33] = 0x14;
    let mut pseudo = Vec::with_capacity(12);
    pseudo.extend_from_slice(&out[12..20]);
    pseudo.extend_from_slice(&[0, 6, 0, 20]);
    let sum: u32 = pseudo.chunks(2).map(|c| u16::from_be_bytes([c[0], c[1]]) as u32).sum();
    let c = checksum(&out[20..40], sum);
    out[36..38].copy_from_slice(&c.to_be_bytes());
    out
}

/// The Wintun device with `verdict` in front of the stack.
struct Guard<D> {
    inner: D,
    pending: Vec<Vec<u8>>,
}

impl<D> Guard<D> {
    fn new(inner: D) -> Self {
        Self { inner, pending: Vec::new() }
    }
}

impl<D: AsyncRead + AsyncWrite + Unpin> Guard<D> {
    fn flush_resets(&mut self, cx: &mut Context<'_>) {
        while let Some(p) = self.pending.first() {
            match Pin::new(&mut self.inner).poll_write(cx, p) {
                Poll::Ready(_) => {
                    self.pending.remove(0);
                }
                Poll::Pending => break,
            }
        }
    }
}

impl<D: AsyncRead + AsyncWrite + Unpin> AsyncRead for Guard<D> {
    fn poll_read(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &mut ReadBuf<'_>) -> Poll<std::io::Result<()>> {
        loop {
            self.flush_resets(cx);
            let mut tmp = [0u8; MTU as usize + 64];
            let mut rb = ReadBuf::new(&mut tmp);
            match Pin::new(&mut self.inner).poll_read(cx, &mut rb) {
                Poll::Ready(Ok(())) => {
                    let p = rb.filled();
                    if p.is_empty() {
                        return Poll::Ready(Ok(()));
                    }
                    match verdict(p) {
                        Verdict::Pass => {
                            let n = p.len().min(buf.remaining());
                            buf.put_slice(&p[..n]);
                            return Poll::Ready(Ok(()));
                        }
                        Verdict::Reset(r) => {
                            if self.pending.len() < 256 {
                                self.pending.push(r);
                            }
                        }
                        Verdict::Drop => {}
                    }
                }
                other => return other,
            }
        }
    }
}

impl<D: AsyncRead + AsyncWrite + Unpin> AsyncWrite for Guard<D> {
    fn poll_write(mut self: Pin<&mut Self>, cx: &mut Context<'_>, buf: &[u8]) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn syn(dst: [u8; 4]) -> Vec<u8> {
        let mut p = vec![0u8; 40];
        p[0] = 0x45;
        p[9] = 6;
        p[12..16].copy_from_slice(&[10, 255, 255, 2]);
        p[16..20].copy_from_slice(&dst);
        p[20..22].copy_from_slice(&50000u16.to_be_bytes());
        p[22..24].copy_from_slice(&445u16.to_be_bytes());
        p[24..28].copy_from_slice(&1000u32.to_be_bytes());
        p[32] = 5 << 4;
        p[33] = 0x02;
        p
    }

    #[test]
    fn public_flows_pass_and_private_syn_gets_a_valid_reset() {
        assert_eq!(verdict(&syn([1, 1, 1, 1])), Verdict::Pass);
        let Verdict::Reset(r) = verdict(&syn([192, 168, 100, 1])) else { panic!("no reset") };
        assert_eq!(&r[12..16], &[192, 168, 100, 1], "from the address the guest tried");
        assert_eq!(&r[16..20], &[10, 255, 255, 2]);
        assert_eq!(u16::from_be_bytes([r[20], r[21]]), 445);
        assert_eq!(u16::from_be_bytes([r[22], r[23]]), 50000);
        assert_eq!(u32::from_be_bytes([r[28], r[29], r[30], r[31]]), 1001);
        assert_eq!(r[33], 0x14, "RST+ACK");
        assert_eq!(checksum(&r[..20], 0), 0, "IP checksum");
        let mut pseudo = r[12..20].to_vec();
        pseudo.extend_from_slice(&[0, 6, 0, 20]);
        let sum: u32 = pseudo.chunks(2).map(|c| u16::from_be_bytes([c[0], c[1]]) as u32).sum();
        assert_eq!(checksum(&r[20..40], sum), 0, "TCP checksum");
    }

    #[test]
    fn private_udp_and_ipv6_are_dropped() {
        let mut udp = syn([224, 0, 0, 251]);
        udp[9] = 17;
        assert_eq!(verdict(&udp), Verdict::Drop);
        let mut v6 = syn([1, 1, 1, 1]);
        v6[0] = 0x60;
        assert_eq!(verdict(&v6), Verdict::Drop);
        let mut ack = syn([10, 0, 0, 1]);
        ack[33] = 0x10;
        assert_eq!(verdict(&ack), Verdict::Drop);
    }

    #[test]
    fn macs_are_normalized_and_checked() {
        assert_eq!(normal_mac("00:15:5d:aa:bb:cc").as_deref(), Some("00-15-5D-AA-BB-CC"));
        assert_eq!(normal_mac("00-15-5D-AA-BB-CC").as_deref(), Some("00-15-5D-AA-BB-CC"));
        assert!(normal_mac("00-15-5D-AA-BB").is_none());
        assert!(normal_mac("00-15-5D-AA-BB-CC'; rm").is_none());
    }

    #[test]
    fn same_public_rule_as_the_host() {
        for bad in ["10.0.0.1", "172.16.0.1", "192.168.1.1", "100.64.0.1", "169.254.0.1", "224.0.0.1", "0.0.0.1", "198.18.0.1"] {
            assert!(!is_public(bad.parse().unwrap()), "{bad}");
        }
        assert!(is_public("1.1.1.1".parse().unwrap()));
    }
}
