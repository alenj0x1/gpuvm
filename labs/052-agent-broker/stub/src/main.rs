//! stub052: a stand-in guest agent for lab 052, built on the broker's own wire code (app/host/src/wire.rs), so the
//! host can be tested before the real agent (guest/agent) lands, and attacked on purpose.
//!
//!   stub052 run    [--secret F] [--vm-id X] [--log F]   a well-behaved agent: dials the host, answers requests
//!   stub052 attack <case> [--secret F] [--vm-id X]      one hostile behaviour; prints a JSON line with the outcome
//!
//! Cases: wrong-secret wrong-vm replay big-hello bad-kind garbage-hello slow-hello big-json big-blob unsigned malformed
//! stray-res stray-blob frame-flood event-flood silent conn-flood good

#[path = "../../../../app/host/src/hv.rs"]
mod hv;
#[path = "../../../../app/host/src/wire.rs"]
mod wire;

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};
use wire::{Frame, Sealer};

const SERVICE: u128 = 0x94aca5ef_a5b6_45a9_8c15_c7724a63f3da;

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn vm_id(args: &[String]) -> String {
    if let Some(v) = arg(args, "--vm-id") {
        return v.to_lowercase();
    }
    use windows_sys::Win32::System::Registry::*;
    let mut buf = [0u16; 128];
    let mut len = (buf.len() * 2) as u32;
    let key: Vec<u16> = r"SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters".encode_utf16().chain(Some(0)).collect();
    let name: Vec<u16> = "VirtualMachineId".encode_utf16().chain(Some(0)).collect();
    let r = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), name.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut len) };
    if r != 0 {
        eprintln!("no VirtualMachineId ({r}); pass --vm-id");
        std::process::exit(2);
    }
    let s = String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]);
    s.trim_matches(|c| c == '{' || c == '}').to_lowercase()
}

fn secret(args: &[String]) -> [u8; 32] {
    let path = arg(args, "--secret").unwrap_or(r"C:\ProgramData\GpuVM\Agent\secret".into());
    let raw = std::fs::read(&path).unwrap_or_else(|e| {
        eprintln!("{path}: {e}");
        std::process::exit(2)
    });
    raw.try_into().unwrap_or_else(|_| {
        eprintln!("secret: not 32 bytes");
        std::process::exit(2)
    })
}

/// Where to dial: the host (from a guest), or Hyper-V's loopback (on the host itself, for runs without a VM;
/// `STUB052_TARGET=loopback`).
fn dial() -> Result<hv::Sock, i32> {
    const HV_GUID_LOOPBACK: u128 = 0xe0e16197_dd56_4a10_9195_5ee7a155a838;
    let target = if std::env::var("STUB052_TARGET").as_deref() == Ok("loopback") { HV_GUID_LOOPBACK } else { hv::HV_GUID_PARENT };
    let s = hv::Sock::connect(target, SERVICE, 2000)?;
    s.set_timeouts(15000, 15000);
    Ok(s)
}

fn obj(v: Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap()
}

// ---------------------------------------------------------------- the well-behaved agent

struct Out {
    sock: Arc<hv::Sock>,
    sealer: Mutex<Sealer>,
}

impl Out {
    fn send(&self, v: Value, blob: Option<&[u8]>) -> std::io::Result<()> {
        let mut sealer = self.sealer.lock().unwrap();
        let mut o = obj(v);
        if let Some(b) = blob {
            wire::describe_blob(&mut o, b);
        }
        let frame = sealer.seal(o);
        let mut w = &*self.sock;
        wire::write_frame(&mut w, wire::KIND_JSON, &frame)?;
        if let Some(b) = blob {
            wire::write_frame(&mut w, wire::KIND_BLOB, b)?;
        }
        Ok(())
    }
}

/// On the host (loopback runs) the agent's Outbox is a lab folder: STUB052_OUTBOX.
fn local_path(path: &str) -> String {
    const OUTBOX: &str = r"C:\Users\agent\Desktop\Outbox";
    // Paths relative to the agent's home, like the real agent takes them.
    let path = &if path.len() > 1 && path.as_bytes()[1] != b':' { format!(r"C:\Users\agent\{path}") } else { path.to_string() };
    match std::env::var("STUB052_OUTBOX") {
        Ok(dir) if path.to_lowercase().starts_with(&OUTBOX.to_lowercase()) => format!("{dir}{}", &path[OUTBOX.len()..]),
        _ => path.to_string(),
    }
}

fn answer(method: &str, params: &Value) -> Result<(Value, Option<Vec<u8>>), (&'static str, String)> {
    match method {
        // vmId: lets the lab check each answer came from the machine it asked (two machines at once).
        "agent.info" => Ok((json!({ "version": "stub-052", "os": "stub", "user": "agent", "session": 1, "screen": { "w": 1920, "h": 1080 },
            "signedIn": true, "vmId": VM_ID.get() }), None)),
        "screen.state" => Ok((json!({ "desktop": "default", "foreground": { "title": "stub", "process": "stub052.exe", "integrity": "medium", "blocked": false } }), None)),
        "screen.capture" => {
            // A stand-in for a 1280x720 lossless WebP (~257 KB in lab 048), or the size asked for.
            let n = params["bytes"].as_u64().unwrap_or(257_000).min(wire::MAX_BLOB as u64) as usize;
            let blob: Vec<u8> = (0..n).map(|i| (i * 31 % 251) as u8).collect();
            Ok((json!({ "w": 1280, "h": 720, "scale": 0.667, "format": "webp" }), Some(blob)))
        }
        "input.act" => {
            let mut done = 0;
            for a in params["actions"].as_array().cloned().unwrap_or_default() {
                if let Some(ms) = a["wait"]["ms"].as_u64().or(if a["type"] == "wait" { a["ms"].as_u64() } else { None }) {
                    std::thread::sleep(Duration::from_millis(ms.min(60_000)));
                }
                done += 1;
            }
            Ok((json!({ "done": done }), None))
        }
        "files.list" => {
            let path = local_path(params["path"].as_str().unwrap_or(""));
            let entries: Vec<Value> = std::fs::read_dir(&path).map_err(|e| ("not_found", e.to_string()))?.flatten()
                .map(|e| {
                    let m = e.metadata().ok();
                    json!({ "name": e.file_name().to_string_lossy(), "size": m.as_ref().map(|m| m.len()), "dir": m.map(|m| m.is_dir()) })
                })
                .collect();
            Ok((json!({ "entries": entries }), None))
        }
        "files.read" => {
            let path = local_path(params["path"].as_str().unwrap_or(""));
            let mut f = std::fs::File::open(&path).map_err(|e| ("not_found", e.to_string()))?;
            let size = f.metadata().map(|m| m.len()).unwrap_or(0);
            let offset = params["offset"].as_u64().unwrap_or(0);
            let length = params["length"].as_u64().unwrap_or(wire::MAX_BLOB as u64).min(wire::MAX_BLOB as u64);
            use std::io::Seek;
            f.seek(std::io::SeekFrom::Start(offset)).map_err(|e| ("internal", e.to_string()))?;
            let mut buf = Vec::new();
            f.take(length).read_to_end(&mut buf).map_err(|e| ("internal", e.to_string()))?;
            Ok((json!({ "path": path, "size": size, "offset": offset }), Some(buf)))
        }
        "exec.run" => Ok((json!({ "exitCode": 0, "stdout": params["args"].to_string(), "stderr": "", "truncated": false }), None)),
        _ => Err(("not_found", format!("stub has no {method}"))),
    }
}

fn serve(sock: hv::Sock, session: wire::Session, log: &mut Option<std::fs::File>) -> String {
    let sock = Arc::new(sock);
    let wire::Session { sealer, mut opener, .. } = session;
    let out = Arc::new(Out { sock: sock.clone(), sealer: Mutex::new(sealer) });
    let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
    {
        let (out, alive) = (out.clone(), alive.clone());
        std::thread::spawn(move || {
            while alive.load(std::sync::atomic::Ordering::SeqCst) {
                if out.send(json!({ "t": "ping" }), None).is_err() {
                    break;
                }
                std::thread::sleep(Duration::from_secs(2));
            }
        });
    }
    let mut r = &*sock;
    let reason = loop {
        let frame = match wire::read_frame(&mut r, wire::MAX_JSON) {
            Ok(f) => f,
            Err(e) => break e,
        };
        let Frame::Json(p) = frame else { break "unexpected blob".into() };
        let msg = match opener.open(&p) {
            Ok(m) => m,
            Err(e) => break e,
        };
        let blob_in = if msg.get("blob") == Some(&json!(true)) {
            match wire::read_frame(&mut r, wire::MAX_JSON) {
                Ok(Frame::Blob(b)) => Some(b),
                _ => break "missing blob".into(),
            }
        } else {
            None
        };
        match msg.get("t").and_then(Value::as_str) {
            Some("req") => {
                let out = out.clone();
                let id = msg["id"].clone();
                let method = msg["method"].as_str().unwrap_or("").to_string();
                let params = msg["params"].clone();
                if let Some(l) = log.as_mut() {
                    let _ = writeln!(l, "{}", json!({ "req": method, "id": id, "blobIn": blob_in.as_ref().map(Vec::len) }));
                }
                std::thread::spawn(move || {
                    let _ = match answer(&method, &params) {
                        Ok((result, blob)) => {
                            let mut v = json!({ "t": "res", "id": id, "ok": true, "result": result });
                            if blob.is_some() {
                                v["blob"] = json!(true);
                            }
                            out.send(v, blob.as_deref())
                        }
                        Err((code, message)) => out.send(json!({ "t": "res", "id": id, "ok": false, "error": { "code": code, "message": message } }), None),
                    };
                });
            }
            Some("cancel") | Some("ping") => {}
            _ => break "unknown message".into(),
        }
    };
    alive.store(false, std::sync::atomic::Ordering::SeqCst);
    sock.shutdown();
    reason
}

static VM_ID: std::sync::OnceLock<String> = std::sync::OnceLock::new();

fn run(args: &[String]) {
    hv::startup();
    let vm = vm_id(args);
    let _ = VM_ID.set(vm.clone());
    let mut log = arg(args, "--log").and_then(|p| std::fs::OpenOptions::new().create(true).append(true).open(p).ok());
    loop {
        let k = secret(args);
        match dial() {
            Ok(sock) => {
                let mut s = &sock;
                match wire::guest_handshake(&mut s, &k, &vm, "stub-052", None) {
                    Ok(session) => {
                        if let Some(l) = log.as_mut() {
                            let _ = writeln!(l, "{}", json!({ "event": "connected", "t": now() }));
                        }
                        let reason = serve(sock, session, &mut log);
                        if let Some(l) = log.as_mut() {
                            let _ = writeln!(l, "{}", json!({ "event": "disconnected", "reason": reason, "t": now() }));
                        }
                    }
                    Err(e) => {
                        if let Some(l) = log.as_mut() {
                            let _ = writeln!(l, "{}", json!({ "event": "handshake_failed", "reason": e, "t": now() }));
                        }
                    }
                }
            }
            Err(_) => {}
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn now() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
}

// ---------------------------------------------------------------- attacks

/// Waits until the host closes the connection (read returns 0 or fails), up to `limit`; returns the wait in ms.
fn wait_closed(sock: &hv::Sock, limit: Duration) -> Option<f64> {
    let t = Instant::now();
    sock.set_timeouts(limit.as_millis() as u32, 2000);
    let mut r = sock;
    let mut buf = [0u8; 65536];
    loop {
        match r.read(&mut buf) {
            Ok(0) => return Some(t.elapsed().as_secs_f64() * 1000.0),
            Ok(_) => {
                if t.elapsed() > limit {
                    return None;
                }
            }
            Err(e) => {
                let code = e.raw_os_error().unwrap_or(0);
                // 10060 = our own read timeout: the host kept it open.
                return if code == 10060 { None } else { Some(t.elapsed().as_secs_f64() * 1000.0) };
            }
        }
    }
}

fn authed(k: &[u8; 32], vm: &str) -> Result<(hv::Sock, wire::Session), String> {
    let sock = dial().map_err(|e| format!("dial {e}"))?;
    let mut s = &sock;
    let session = wire::guest_handshake(&mut s, k, vm, "stub-052", None)?;
    Ok((sock, session))
}

fn attack(case: &str, args: &[String]) -> Value {
    hv::startup();
    let vm = vm_id(args);
    let k = secret(args);
    let limit = Duration::from_secs(15);
    let t0 = Instant::now();
    let closed = |sock: &hv::Sock| wait_closed(sock, limit);
    let raw_hello = |s: &hv::Sock, ng: &str| {
        let mut w = s;
        wire::write_frame(&mut w, wire::KIND_JSON, json!({ "t": "hello", "v": 1, "agent": "attack", "ng": ng }).to_string().as_bytes())
    };
    let read_json = |s: &hv::Sock| -> Option<Value> {
        let mut r = s;
        match wire::read_frame(&mut r, wire::MAX_JSON) {
            Ok(Frame::Json(p)) => serde_json::from_slice(&p).ok(),
            _ => None,
        }
    };
    let result: Result<Value, String> = (|| {
        Ok(match case {
            "good" => {
                let sock = dial().map_err(|e| format!("dial {e}"))?;
                let dial_ms = t0.elapsed().as_secs_f64() * 1000.0;
                let mut s = &sock;
                wire::guest_handshake(&mut s, &k, &vm, "stub-052", None)?;
                json!({ "dialMs": dial_ms, "handshakeMs": t0.elapsed().as_secs_f64() * 1000.0 - dial_ms })
            }
            "wrong-secret" | "wrong-vm" => {
                // Answers the challenge with the wrong key, or for another VmId; checks the host's challenge too.
                let sock = dial().map_err(|e| format!("dial {e}"))?;
                let (key, bound) = if case == "wrong-secret" { (wire::random::<32>(), vm.clone()) } else { (k, "00000000-0000-0000-0000-000000000001".to_string()) };
                let ng = wire::hex(&wire::random::<16>());
                raw_hello(&sock, &ng).map_err(|e| e.to_string())?;
                let ch = read_json(&sock).ok_or("no challenge")?;
                let nh = ch["nh"].as_str().unwrap_or("").to_string();
                let host_ok = ch["mac"].as_str() == Some(wire::hex(&wire::hmac(&key, format!("host|{bound}|{ng}|{nh}").as_bytes())).as_str());
                let mac = wire::hex(&wire::hmac(&key, format!("guest|{bound}|{nh}|{ng}").as_bytes()));
                let mut w = &sock;
                wire::write_frame(&mut w, wire::KIND_JSON, json!({ "t": "proof", "mac": mac }).to_string().as_bytes()).map_err(|e| e.to_string())?;
                json!({ "guestAcceptsHost": host_ok, "closedMs": closed(&sock) })
            }
            "replay" => {
                // A full good handshake is recorded, then its hello and proof are sent again on a new connection.
                let sock = dial().map_err(|e| format!("dial {e}"))?;
                let ng = wire::hex(&wire::random::<16>());
                raw_hello(&sock, &ng).map_err(|e| e.to_string())?;
                let ch = read_json(&sock).ok_or("no challenge")?;
                let nh = ch["nh"].as_str().unwrap_or("").to_string();
                let proof = json!({ "t": "proof", "mac": wire::hex(&wire::hmac(&k, format!("guest|{vm}|{nh}|{ng}").as_bytes())) });
                let mut w = &sock;
                wire::write_frame(&mut w, wire::KIND_JSON, proof.to_string().as_bytes()).map_err(|e| e.to_string())?;
                let first_kept = closed(&sock).is_none();
                drop(sock);
                let sock = dial().map_err(|e| format!("dial {e}"))?;
                raw_hello(&sock, &ng).map_err(|e| e.to_string())?;
                let ch2 = read_json(&sock).ok_or("no challenge")?;
                let mut w = &sock;
                wire::write_frame(&mut w, wire::KIND_JSON, proof.to_string().as_bytes()).map_err(|e| e.to_string())?;
                json!({ "recordedHandshakeAccepted": first_kept, "newNonce": ch2["nh"] != ch["nh"], "closedMs": closed(&sock) })
            }
            "big-hello" | "bad-kind" | "garbage-hello" | "slow-hello" => {
                let sock = dial().map_err(|e| format!("dial {e}"))?;
                let mut w = &sock;
                match case {
                    "big-hello" => {
                        w.write_all(&(2000u32).to_le_bytes()).and_then(|_| w.write_all(&[1])).map_err(|e| e.to_string())?;
                    }
                    "bad-kind" => w.write_all(&[4, 0, 0, 0, 9, 1, 2, 3, 4]).map_err(|e| e.to_string())?,
                    "garbage-hello" => wire::write_frame(&mut w, wire::KIND_JSON, b"{\"t\":\"hello\",\"v\":1,\"agent\":\"\\u0007\",\"ng\":\"zz\"}").map_err(|e| e.to_string())?,
                    _ => {}
                }
                json!({ "closedMs": closed(&sock) })
            }
            "big-json" | "big-blob" | "unsigned" | "malformed" | "stray-res" | "stray-blob" | "bad-blob-hash" | "silent" | "frame-flood" | "event-flood" => {
                let (sock, mut session) = authed(&k, &vm)?;
                let mut w = &sock;
                let sent = Instant::now();
                let mut frames = 0u64;
                match case {
                    "big-json" => w.write_all(&(70_000u32).to_le_bytes()).and_then(|_| w.write_all(&[1])).map_err(|e| e.to_string())?,
                    "big-blob" => w.write_all(&((17u32) << 20).to_le_bytes()).and_then(|_| w.write_all(&[2])).map_err(|e| e.to_string())?,
                    "unsigned" => wire::write_frame(&mut w, 1, br#"{"t":"ping","seq":1}"#).map_err(|e| e.to_string())?,
                    "malformed" => wire::write_frame(&mut w, 1, b"{not json at all, but long enough to have a tail.....................}").map_err(|e| e.to_string())?,
                    "stray-res" => wire::write_frame(&mut w, 1, &session.sealer.seal(obj(json!({ "t": "res", "id": 999999, "ok": true })))).map_err(|e| e.to_string())?,
                    "stray-blob" => wire::write_frame(&mut w, 2, &[0u8; 100]).map_err(|e| e.to_string())?,
                    "bad-blob-hash" => {
                        // Answers the host's first request (agent.info) with a blob that isn't the one its frame announces.
                        let mut r = &sock;
                        let id = loop {
                            let Frame::Json(p) = wire::read_frame(&mut r, wire::MAX_JSON)? else { return Err("blob".into()) };
                            let m = session.opener.open(&p)?;
                            if m.get("t").and_then(Value::as_str) == Some("req") {
                                break m["id"].clone();
                            }
                        };
                        let mut res = obj(json!({ "t": "res", "id": id, "ok": true, "result": {} }));
                        wire::describe_blob(&mut res, b"the announced bytes");
                        wire::write_frame(&mut w, 1, &session.sealer.seal(res)).map_err(|e| e.to_string())?;
                        wire::write_frame(&mut w, 2, b"other bytes, same size").map_err(|e| e.to_string())?;
                    }
                    "frame-flood" => {
                        while sent.elapsed() < Duration::from_secs(3) {
                            if wire::write_frame(&mut w, 1, &session.sealer.seal(obj(json!({ "t": "ping" })))).is_err() {
                                break;
                            }
                            frames += 1;
                        }
                    }
                    "event-flood" => {
                        while sent.elapsed() < Duration::from_secs(5) {
                            let e = json!({ "t": "evt", "event": "foreground", "data": { "title": "x".repeat(2000) } });
                            if wire::write_frame(&mut w, 1, &session.sealer.seal(obj(e))).is_err() {
                                break;
                            }
                            frames += 1;
                            std::thread::sleep(Duration::from_millis(2));
                        }
                    }
                    _ => {}
                }
                // From the first hostile byte to the host closing.
                let c = closed(&sock).map(|_| sent.elapsed().as_secs_f64() * 1000.0);
                json!({ "closedMs": c, "framesSent": frames, "sinceFirstMs": sent.elapsed().as_secs_f64() * 1000.0 })
            }
            "conn-flood" => {
                // 100 connections at once, saying nothing; then how long until a good handshake works again.
                let mut socks = Vec::new();
                let mut refused = 0;
                for _ in 0..100 {
                    match dial() {
                        Ok(s) => socks.push(s),
                        Err(_) => refused += 1,
                    }
                }
                let held = socks.len();
                let mut closed_now = 0;
                for s in &socks {
                    if wait_closed(s, Duration::from_millis(20)).is_some() {
                        closed_now += 1;
                    }
                }
                drop(socks);
                let t = Instant::now();
                let mut recovered = None;
                while t.elapsed() < Duration::from_secs(30) {
                    if authed(&k, &vm).is_ok() {
                        recovered = Some(t.elapsed().as_secs_f64() * 1000.0);
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
                json!({ "dialed": held, "refused": refused, "closedAtOnce": closed_now, "goodHandshakeAfterMs": recovered })
            }
            other => return Err(format!("unknown case {other}")),
        })
    })();
    match result {
        Ok(mut v) => {
            v["case"] = json!(case);
            v["ok"] = json!(true);
            v
        }
        Err(e) => json!({ "case": case, "ok": false, "error": e }),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("run") => run(&args),
        Some("attack") => {
            let case = args.get(2).cloned().unwrap_or_default();
            println!("{}", attack(&case, &args));
        }
        _ => eprintln!("usage: stub052 run|attack <case> [--secret F] [--vm-id X]"),
    }
}
