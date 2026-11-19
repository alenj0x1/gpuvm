//! hvlab: Hyper-V socket (AF_HYPERV) probe for GpuVM lab 047.
//!
//! Same binary on host and guest:
//!   hvlab listen  --bind children|wildcard|parent|<vmid> --service <guid> [--log file.jsonl]
//!   hvlab bench   --vm parent|<vmid> --service <guid> [--lat 600] [--sizes 1,2,4] [--frames 60] [--connects 60] [--out f.json]
//!   hvlab watch   --vm parent|<vmid> --service <guid> [--seconds 600] [--interval 200] [--log f.jsonl]
//!   hvlab once    --vm parent|<vmid> --service <guid>        (connect, ask the server who we are, print, exit)
//!
//! Wire protocol (little endian): request = op u32, len u32, reply u32, then `len` payload bytes.
//! op 1: server reads the payload and answers `reply` bytes. op 2: server answers 16 bytes = the peer VmId it saw.
//! Everything is timed with Instant (QPC). No external crates besides windows-sys.

use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use windows_sys::core::GUID;
use windows_sys::Win32::Networking::WinSock::*;

const AF_HYPERV: u16 = 34;
const HV_PROTOCOL_RAW: i32 = 1;
const HVSOCKET_CONNECT_TIMEOUT: i32 = 1;

const HV_GUID_WILDCARD: u128 = 0;
const HV_GUID_CHILDREN: u128 = 0x90db8b89_0d35_4f79_8ce9_49ea0ac8b7cd;
const HV_GUID_PARENT: u128 = 0xa42e7cda_d03f_480c_9cc2_a4de20abb878;
const HV_GUID_LOOPBACK: u128 = 0xe0e16197_dd56_4a10_9195_5ee7a155a838;

#[repr(C)]
#[derive(Clone, Copy)]
struct SockaddrHv {
    family: u16,
    reserved: u16,
    vm_id: GUID,
    service_id: GUID,
}

fn guid_to_u128(g: &GUID) -> u128 {
    ((g.data1 as u128) << 96)
        | ((g.data2 as u128) << 80)
        | ((g.data3 as u128) << 64)
        | u64::from_be_bytes(g.data4) as u128
}

fn fmt_guid(g: &GUID) -> String {
    let v = guid_to_u128(g);
    let h = format!("{:032x}", v);
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

fn parse_guid(s: &str) -> GUID {
    match s.to_ascii_lowercase().as_str() {
        "parent" => return GUID::from_u128(HV_GUID_PARENT),
        "children" => return GUID::from_u128(HV_GUID_CHILDREN),
        "wildcard" => return GUID::from_u128(HV_GUID_WILDCARD),
        "loopback" => return GUID::from_u128(HV_GUID_LOOPBACK),
        _ => {}
    }
    let hex: String = s.chars().filter(|c| c.is_ascii_hexdigit()).collect();
    if hex.len() != 32 {
        die(&format!("bad guid '{s}'"));
    }
    GUID::from_u128(u128::from_str_radix(&hex, 16).unwrap())
}

fn die(msg: &str) -> ! {
    eprintln!("hvlab: {msg}");
    std::process::exit(2)
}

fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

fn wsa_err() -> i32 {
    unsafe { WSAGetLastError() }
}

fn startup() {
    unsafe {
        let mut d: WSADATA = std::mem::zeroed();
        if WSAStartup(0x0202, &mut d) != 0 {
            die("WSAStartup failed");
        }
    }
}

struct Sock(SOCKET);
impl Drop for Sock {
    fn drop(&mut self) {
        unsafe { closesocket(self.0) };
    }
}

fn new_socket() -> Result<Sock, i32> {
    let s = unsafe { socket(AF_HYPERV as i32, SOCK_STREAM, HV_PROTOCOL_RAW) };
    if s == INVALID_SOCKET {
        return Err(wsa_err());
    }
    Ok(Sock(s))
}

fn addr(vm: GUID, svc: GUID) -> SockaddrHv {
    SockaddrHv { family: AF_HYPERV, reserved: 0, vm_id: vm, service_id: svc }
}

fn set_timeouts(s: &Sock, ms: u32) {
    unsafe {
        let v = ms;
        let p = &v as *const u32 as *const u8;
        setsockopt(s.0, SOL_SOCKET, SO_RCVTIMEO, p, 4);
        setsockopt(s.0, SOL_SOCKET, SO_SNDTIMEO, p, 4);
    }
}

fn connect_to(vm: GUID, svc: GUID, timeout_ms: u32) -> Result<(Sock, Duration), i32> {
    let s = new_socket()?;
    unsafe {
        let v = timeout_ms;
        setsockopt(s.0, HV_PROTOCOL_RAW, HVSOCKET_CONNECT_TIMEOUT, &v as *const u32 as *const u8, 4);
    }
    let a = addr(vm, svc);
    let t = Instant::now();
    let r = unsafe { connect(s.0, &a as *const SockaddrHv as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) };
    let el = t.elapsed();
    if r != 0 {
        return Err(wsa_err());
    }
    set_timeouts(&s, 15000);
    Ok((s, el))
}

fn send_all(s: &Sock, mut buf: &[u8]) -> Result<(), i32> {
    while !buf.is_empty() {
        let chunk = buf.len().min(1 << 30) as i32;
        let n = unsafe { send(s.0, buf.as_ptr(), chunk, 0) };
        if n <= 0 {
            return Err(if n == 0 { -1 } else { wsa_err() });
        }
        buf = &buf[n as usize..];
    }
    Ok(())
}

fn recv_all(s: &Sock, buf: &mut [u8]) -> Result<(), i32> {
    let mut off = 0;
    while off < buf.len() {
        let want = (buf.len() - off).min(1 << 30) as i32;
        let n = unsafe { recv(s.0, buf.as_mut_ptr().add(off), want, 0) };
        if n == 0 {
            return Err(-1); // orderly close
        }
        if n < 0 {
            return Err(wsa_err());
        }
        off += n as usize;
    }
    Ok(())
}

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

fn arg_or(args: &[String], name: &str, def: &str) -> String {
    arg(args, name).unwrap_or_else(|| def.to_string())
}

static CONN_ID: AtomicU64 = AtomicU64::new(0);

fn log_line(log: &Option<std::sync::Arc<std::sync::Mutex<std::fs::File>>>, line: &str) {
    println!("{line}");
    let _ = std::io::stdout().flush();
    if let Some(f) = log {
        let mut f = f.lock().unwrap();
        let _ = writeln!(f, "{line}");
        let _ = f.flush();
    }
}

fn cmd_listen(args: &[String]) {
    let bind_vm = parse_guid(&arg_or(args, "--bind", "children"));
    let svc = parse_guid(&arg(args, "--service").unwrap_or_else(|| die("--service needed")));
    let log = arg(args, "--log").map(|p| {
        std::sync::Arc::new(std::sync::Mutex::new(
            std::fs::OpenOptions::new().create(true).append(true).open(p).unwrap(),
        ))
    });
    let s = new_socket().unwrap_or_else(|e| die(&format!("socket: {e}")));
    let a = addr(bind_vm, svc);
    if unsafe { bind(s.0, &a as *const SockaddrHv as *const SOCKADDR, std::mem::size_of::<SockaddrHv>() as i32) } != 0 {
        log_line(&log, &format!("{{\"ev\":\"bind_failed\",\"t\":{},\"err\":{}}}", now_ms(), wsa_err()));
        std::process::exit(3);
    }
    if unsafe { listen(s.0, 16) } != 0 {
        die(&format!("listen: {}", wsa_err()));
    }
    log_line(&log, &format!(
        "{{\"ev\":\"listening\",\"t\":{},\"bind\":\"{}\",\"service\":\"{}\",\"pid\":{}}}",
        now_ms(), fmt_guid(&bind_vm), fmt_guid(&svc), std::process::id()
    ));
    loop {
        let mut peer: SockaddrHv = unsafe { std::mem::zeroed() };
        let mut len = std::mem::size_of::<SockaddrHv>() as i32;
        let c = unsafe { accept(s.0, &mut peer as *mut SockaddrHv as *mut SOCKADDR, &mut len) };
        if c == INVALID_SOCKET {
            log_line(&log, &format!("{{\"ev\":\"accept_failed\",\"t\":{},\"err\":{}}}", now_ms(), wsa_err()));
            std::thread::sleep(Duration::from_millis(100));
            continue;
        }
        let id = CONN_ID.fetch_add(1, Ordering::Relaxed) + 1;
        log_line(&log, &format!(
            "{{\"ev\":\"accept\",\"t\":{},\"conn\":{},\"peerVm\":\"{}\",\"peerService\":\"{}\",\"addrLen\":{}}}",
            now_ms(), id, fmt_guid(&peer.vm_id), fmt_guid(&peer.service_id), len
        ));
        let log2 = log.clone();
        let c = Sock(c);
        std::thread::spawn(move || serve(c, peer, id, log2));
    }
}

fn serve(c: Sock, peer: SockaddrHv, id: u64, log: Option<std::sync::Arc<std::sync::Mutex<std::fs::File>>>) {
    set_timeouts(&c, 0);
    let mut reqs = 0u64;
    let mut bytes_in = 0u64;
    let mut bytes_out = 0u64;
    let mut buf: Vec<u8> = Vec::new();
    let mut hdr = [0u8; 12];
    let why = loop {
        if let Err(e) = recv_all(&c, &mut hdr) {
            break e;
        }
        let op = u32::from_le_bytes(hdr[0..4].try_into().unwrap());
        let len = u32::from_le_bytes(hdr[4..8].try_into().unwrap()) as usize;
        let reply = u32::from_le_bytes(hdr[8..12].try_into().unwrap()) as usize;
        if len > 64 << 20 || reply > 64 << 20 {
            break -2; // refuse absurd sizes: the peer is untrusted
        }
        if buf.len() < len.max(reply) {
            buf.resize(len.max(reply), 0x5a);
        }
        if let Err(e) = recv_all(&c, &mut buf[..len]) {
            break e;
        }
        bytes_in += (12 + len) as u64;
        let r = match op {
            2 => {
                let v = guid_to_u128(&peer.vm_id).to_be_bytes();
                send_all(&c, &v)
            }
            _ => send_all(&c, &buf[..reply]),
        };
        if let Err(e) = r {
            break e;
        }
        bytes_out += reply as u64;
        reqs += 1;
    };
    log_line(&log, &format!(
        "{{\"ev\":\"close\",\"t\":{},\"conn\":{},\"why\":{},\"requests\":{},\"bytesIn\":{},\"bytesOut\":{}}}",
        now_ms(), id, why, reqs, bytes_in, bytes_out
    ));
}

fn request(s: &Sock, op: u32, payload: &[u8], reply: &mut [u8]) -> Result<(), i32> {
    let mut msg = Vec::with_capacity(12 + payload.len());
    msg.extend_from_slice(&op.to_le_bytes());
    msg.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    msg.extend_from_slice(&(reply.len() as u32).to_le_bytes());
    msg.extend_from_slice(payload);
    send_all(s, &msg)?;
    recv_all(s, reply)
}

fn json_arr(v: &[f64]) -> String {
    let parts: Vec<String> = v.iter().map(|x| format!("{:.1}", x)).collect();
    format!("[{}]", parts.join(","))
}

fn pct(v: &[f64], p: f64) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if s.is_empty() {
        return f64::NAN;
    }
    let i = ((p / 100.0) * (s.len() - 1) as f64).round() as usize;
    s[i]
}

fn cmd_bench(args: &[String]) {
    let vm = parse_guid(&arg(args, "--vm").unwrap_or_else(|| die("--vm needed")));
    let svc = parse_guid(&arg(args, "--service").unwrap_or_else(|| die("--service needed")));
    let lat: usize = arg_or(args, "--lat", "600").parse().unwrap();
    let frames: usize = arg_or(args, "--frames", "60").parse().unwrap();
    let connects: usize = arg_or(args, "--connects", "60").parse().unwrap();
    let sizes: Vec<usize> = arg_or(args, "--sizes", "1,2,4").split(',').map(|x| x.parse().unwrap()).collect();
    let mut out = String::from("{");

    // Connect time (new connection + first 100-byte round trip), fresh socket each time.
    let mut conn_us = Vec::new();
    let mut first_rt_us = Vec::new();
    let mut fails = Vec::new();
    for _ in 0..connects {
        match connect_to(vm, svc, 5000) {
            Ok((s, el)) => {
                conn_us.push(el.as_secs_f64() * 1e6);
                let mut r = [0u8; 100];
                let t = Instant::now();
                match request(&s, 1, &[1u8; 100], &mut r) {
                    Ok(()) => first_rt_us.push(t.elapsed().as_secs_f64() * 1e6),
                    Err(e) => fails.push(e),
                }
            }
            Err(e) => fails.push(e),
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    out += &format!(
        "\"connect\":{{\"us\":{},\"firstRoundTripUs\":{},\"failures\":{:?}}},",
        json_arr(&conn_us), json_arr(&first_rt_us), fails
    );
    eprintln!("connect p50 {:.0} us p95 {:.0} us, first rt p50 {:.0} us ({} fails)", pct(&conn_us, 50.0), pct(&conn_us, 95.0), pct(&first_rt_us, 50.0), fails.len());

    let (s, _) = connect_to(vm, svc, 5000).unwrap_or_else(|e| die(&format!("connect: {e}")));
    // Who does the server think we are?
    let mut who = [0u8; 16];
    request(&s, 2, &[], &mut who).unwrap_or_else(|e| die(&format!("who: {e}")));
    let seen = GUID::from_u128(u128::from_be_bytes(who));
    out += &format!("\"serverSawVm\":\"{}\",", fmt_guid(&seen));

    // Warm-up, then small request/response latency.
    let payload = [7u8; 100];
    let mut r100 = [0u8; 100];
    for _ in 0..50 {
        request(&s, 1, &payload, &mut r100).unwrap();
    }
    let mut lat_us = Vec::with_capacity(lat);
    for i in 0..lat {
        let t = Instant::now();
        request(&s, 1, &payload, &mut r100).unwrap_or_else(|e| die(&format!("latency {i}: {e}")));
        lat_us.push(t.elapsed().as_secs_f64() * 1e6);
        // small random-ish pause so samples don't lock to a timer
        std::thread::sleep(Duration::from_micros(200 + (i as u64 * 7919) % 1800));
    }
    out += &format!("\"latency100\":{{\"us\":{}}},", json_arr(&lat_us));
    eprintln!("100B rt p50 {:.0} us p95 {:.0} us p99 {:.0} us", pct(&lat_us, 50.0), pct(&lat_us, 95.0), pct(&lat_us, 99.0));

    // Throughput: client -> server (upload) and server -> client (download), MB frames.
    out += "\"frames\":[";
    let mut first = true;
    for mb in &sizes {
        let n = mb << 20;
        let big = vec![0xa5u8; n];
        let mut bigr = vec![0u8; n];
        let mut ack = [0u8; 4];
        for dir in ["up", "down"] {
            let mut ms = Vec::with_capacity(frames);
            for _ in 0..3 {
                if dir == "up" { request(&s, 1, &big, &mut ack).unwrap() } else { request(&s, 1, &[], &mut bigr).unwrap() }
            }
            for _ in 0..frames {
                let t = Instant::now();
                let res = if dir == "up" { request(&s, 1, &big, &mut ack) } else { request(&s, 1, &[], &mut bigr) };
                res.unwrap_or_else(|e| die(&format!("frame: {e}")));
                ms.push(t.elapsed().as_secs_f64() * 1e3);
            }
            let p50 = pct(&ms, 50.0);
            eprintln!("{mb} MB {dir}: p50 {:.2} ms p95 {:.2} ms -> {:.0} MB/s", p50, pct(&ms, 95.0), *mb as f64 / (p50 / 1e3));
            if !first {
                out += ",";
            }
            first = false;
            out += &format!("{{\"mb\":{mb},\"dir\":\"{dir}\",\"ms\":{}}}", json_arr(&ms).replace(".1", ".1"));
        }
    }
    out += "]}";
    match arg(args, "--out") {
        Some(p) => std::fs::write(p, out).unwrap(),
        None => println!("{out}"),
    }
}

fn cmd_watch(args: &[String]) {
    let vm = parse_guid(&arg(args, "--vm").unwrap_or_else(|| die("--vm needed")));
    let svc = parse_guid(&arg(args, "--service").unwrap_or_else(|| die("--service needed")));
    let seconds: u64 = arg_or(args, "--seconds", "600").parse().unwrap();
    let interval: u64 = arg_or(args, "--interval", "200").parse().unwrap();
    let log = arg(args, "--log").map(|p| {
        std::sync::Arc::new(std::sync::Mutex::new(
            std::fs::OpenOptions::new().create(true).append(true).open(p).unwrap(),
        ))
    });
    let end = Instant::now() + Duration::from_secs(seconds);
    let mut conn: Option<Sock> = None;
    let mut last_err: Option<i32> = None;
    let mut fails_in_row = 0u64;
    log_line(&log, &format!("{{\"ev\":\"watch_start\",\"t\":{},\"pid\":{}}}", now_ms(), std::process::id()));
    while Instant::now() < end {
        if conn.is_none() {
            match connect_to(vm, svc, 1000) {
                Ok((s, el)) => {
                    log_line(&log, &format!("{{\"ev\":\"connected\",\"t\":{},\"connectUs\":{:.0},\"failedAttempts\":{},\"lastErr\":{}}}",
                        now_ms(), el.as_secs_f64() * 1e6, fails_in_row, last_err.unwrap_or(0)));
                    set_timeouts(&s, 3000);
                    conn = Some(s);
                    fails_in_row = 0;
                }
                Err(e) => {
                    if last_err != Some(e) {
                        log_line(&log, &format!("{{\"ev\":\"connect_failed\",\"t\":{},\"err\":{}}}", now_ms(), e));
                    }
                    last_err = Some(e);
                    fails_in_row += 1;
                }
            }
        }
        if let Some(s) = &conn {
            let mut r = [0u8; 100];
            let t = Instant::now();
            if let Err(e) = request(s, 1, &[3u8; 100], &mut r) {
                log_line(&log, &format!("{{\"ev\":\"broken\",\"t\":{},\"err\":{},\"afterMs\":{:.0}}}", now_ms(), e, t.elapsed().as_secs_f64() * 1e3));
                conn = None;
                last_err = Some(e);
            }
        }
        std::thread::sleep(Duration::from_millis(interval));
    }
    log_line(&log, &format!("{{\"ev\":\"watch_end\",\"t\":{}}}", now_ms()));
}

fn cmd_once(args: &[String]) {
    let vm = parse_guid(&arg(args, "--vm").unwrap_or_else(|| die("--vm needed")));
    let svc = parse_guid(&arg(args, "--service").unwrap_or_else(|| die("--service needed")));
    let timeout: u32 = arg_or(args, "--timeout", "3000").parse().unwrap();
    match connect_to(vm, svc, timeout) {
        Ok((s, el)) => {
            let mut who = [0u8; 16];
            match request(&s, 2, &[], &mut who) {
                Ok(()) => println!("{{\"ok\":true,\"connectUs\":{:.0},\"serverSawVm\":\"{}\"}}", el.as_secs_f64() * 1e6, fmt_guid(&GUID::from_u128(u128::from_be_bytes(who)))),
                Err(e) => println!("{{\"ok\":false,\"stage\":\"request\",\"err\":{e}}}"),
            }
        }
        Err(e) => println!("{{\"ok\":false,\"stage\":\"connect\",\"err\":{e}}}"),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    startup();
    match args.get(1).map(|s| s.as_str()) {
        Some("listen") => cmd_listen(&args),
        Some("bench") => cmd_bench(&args),
        Some("watch") => cmd_watch(&args),
        Some("once") => cmd_once(&args),
        _ => die("usage: hvlab listen|bench|watch|once ..."),
    }
}
