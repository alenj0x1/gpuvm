//! The `GpuVMAgent` Windows service (SYSTEM): dials the host over Hyper-V sockets, proves itself with the per-VM
//! secret, keeps the heartbeat, enforces sizes and times, and relays requests to the session helper it supervises.
//! The service itself never touches the desktop: everything the agent does on screen happens in the helper, with the
//! signed-in user's medium token.
use crate::hv::*;
use crate::proto::*;
use crate::session;
use crate::util::*;
use crate::{logf, secret};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::fs::File;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub static STOP: AtomicBool = AtomicBool::new(false);
static WAKE_M: Mutex<bool> = Mutex::new(false);
static WAKE_C: Condvar = Condvar::new();

/// Wakes the supervisor (session change, helper exit, stop).
pub fn wake() {
    *WAKE_M.lock().unwrap() = true;
    WAKE_C.notify_all();
}

fn sleep_wake(ms: u64) {
    let g = WAKE_M.lock().unwrap();
    let (mut g, _) = WAKE_C.wait_timeout_while(g, Duration::from_millis(ms), |w| !*w).unwrap();
    *g = false;
}

fn sleep_stop(ms: u64) {
    let end = Instant::now() + Duration::from_millis(ms);
    while !STOP.load(Ordering::SeqCst) && Instant::now() < end {
        std::thread::sleep(Duration::from_millis(ms.min(50)));
    }
}

pub const METHODS: &[&str] = &[
    "agent.info", "screen.capture", "screen.state", "input.act", "ui.tree", "ui.invoke", "exec.run", "files.list", "files.read",
    "files.write",
];
const HELPER_EVENTS: &[&str] = &["secure_desktop", "foreground", "error_box", "screen"];
const MAX_PENDING: usize = 32;

struct HostLink {
    stream: Arc<HvStream>,
    sealer: Sealer,
}

struct HelperLink {
    /// frames for the helper, written by its own writer thread (never under a lock: security review M1)
    tx: std::sync::mpsc::SyncSender<Vec<u8>>,
    /// set while the writer thread is inside a write; the ticker kills a helper that stops reading
    busy: Arc<Mutex<Option<Instant>>>,
    process: Arc<crate::token::Owned>,
    pid: u32,
    user: Option<String>,
}

impl HelperLink {
    /// Queues frames (JSON + optional blob) for the helper; false when the queue is full or the helper is gone.
    fn send(&self, v: &Value, blob: Option<&[u8]>) -> bool {
        let mut buf = Vec::new();
        if write_frame(&mut buf, KIND_JSON, &serde_json::to_vec(v).unwrap()).is_err() {
            return false;
        }
        if let Some(b) = blob {
            if write_frame(&mut buf, KIND_BLOB, b).is_err() {
                return false;
            }
        }
        self.tx.try_send(buf).is_ok()
    }
}

fn helper_writer(mut f: File, rx: std::sync::mpsc::Receiver<Vec<u8>>, busy: Arc<Mutex<Option<Instant>>>) {
    use std::io::Write;
    while let Ok(buf) = rx.recv() {
        *busy.lock().unwrap() = Some(Instant::now());
        let ok = f.write_all(&buf).and_then(|_| f.flush()).is_ok();
        *busy.lock().unwrap() = None;
        if !ok {
            break;
        }
    }
}

struct Pending {
    deadline: Instant,
    conn: u64,
    helper: u32,
}

pub struct Agent {
    host: Mutex<Option<HostLink>>,
    helper: Mutex<Option<HelperLink>>,
    pending: Mutex<HashMap<u64, Pending>>,
    conn: AtomicU64,
    no_helper_reason: Mutex<String>,
    events: Mutex<(Instant, u32)>,
    exe: PathBuf,
}

fn err_res(id: u64, code: &str, msg: &str) -> Value {
    json!({"t": "res", "id": id, "ok": false, "error": {"code": code, "message": msg}})
}

/// The VmId the host sees in accept(): the KVP parameter `VirtualMachineId` that Hyper-V writes into the guest
/// (public, not a secret). getsockname's local VmId is NOT it (lab 051: the handshake failed with it), so it is only
/// a fallback when KVP is off.
fn vm_id(s: &HvStream) -> Option<(String, &'static str)> {
    if let Some(g) = reg_hklm(r"SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters", "VirtualMachineId").and_then(|r| parse_guid(&r)) {
        return Some((fmt_guid(&g), "kvp"));
    }
    let a = s.local()?;
    let v = guid_u128(&a.vm_id);
    (v != 0 && v != HV_GUID_PARENT).then(|| (fmt_guid(&a.vm_id), "getsockname"))
}

fn method_deadline(method: &str, params: &Value) -> Duration {
    match method {
        "exec.run" => Duration::from_millis(params["timeoutMs"].as_u64().unwrap_or(60_000).min(600_000) + 10_000),
        "input.act" | "files.read" | "files.write" | "files.list" => Duration::from_secs(60),
        _ => Duration::from_secs(30),
    }
}

impl Agent {
    pub fn new() -> Arc<Agent> {
        Arc::new(Agent {
            host: Mutex::new(None),
            helper: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            conn: AtomicU64::new(0),
            no_helper_reason: Mutex::new("nobody is signed in yet".into()),
            events: Mutex::new((Instant::now(), 0)),
            exe: std::env::current_exe().unwrap_or_else(|_| PathBuf::from(r"C:\Program Files\GpuVM Agent\gpuvm-agent.exe")),
        })
    }

    /// Seals and sends one JSON frame (plus its blob) to the host. False when not connected or the send failed.
    fn send_host(&self, mut v: Value, blob: Option<&[u8]>) -> bool {
        let mut g = self.host.lock().unwrap();
        let Some(link) = g.as_mut() else { return false };
        if let Some(b) = blob {
            v["blob"] = json!(true);
            v["blobLen"] = json!(b.len());
            v["blobSha256"] = json!(hex(&sha256(b)));
        }
        let id = v["id"].as_u64().unwrap_or(0);
        let Some(frame) = link.sealer.try_seal(v, MAX_JSON) else {
            // a result too big for one JSON frame: tell the host instead of dropping the connection (and without
            // a gap in seq: security review M3)
            let f = link.sealer.seal(err_res(id, "too_large", "the result is over 64 KiB"));
            let mut s = &*link.stream;
            return write_frame(&mut s, KIND_JSON, &f).is_ok();
        };
        let mut s = &*link.stream;
        let ok = write_frame(&mut s, KIND_JSON, &frame).is_ok() && blob.map_or(true, |b| write_frame(&mut s, KIND_BLOB, b).is_ok());
        if !ok {
            link.stream.shutdown();
        }
        ok
    }

    fn info_without_helper(&self) -> Value {
        let (os, lang) = os_info();
        json!({"version": VERSION, "os": os, "lang": lang, "user": null, "session": session::active_session(), "screen": null, "signedIn": false})
    }

    // ---- host side ----

    fn handshake(&self, s: &HvStream, k: &[u8; 32], vm: &str) -> Result<[u8; 32], String> {
        let ng = hex(&random::<16>());
        let mut w = s;
        write_frame(&mut w, KIND_JSON, &hello(VERSION, &ng)).map_err(|e| format!("send hello: {e}"))?;
        let f = read_frame(&mut w).map_err(|e| format!("read challenge: {e}"))?;
        let Frame::Json(b) = f else { return Err("challenge: blob frame".into()) };
        let v: Value = serde_json::from_slice(&b).map_err(|_| "challenge: bad JSON")?;
        let nh = v["nh"].as_str().unwrap_or("");
        let mac = v["mac"].as_str().and_then(unhex).unwrap_or_default();
        if v["t"] != "challenge" || !is_nonce(nh) || mac.len() != 32 {
            return Err("challenge: malformed".into());
        }
        if !ct_eq(&host_mac(k, vm, &ng, nh), &mac) {
            return Err("challenge: the host's proof is wrong (not GpuVM's broker, or another secret)".into());
        }
        let proof = json!({"t": "proof", "mac": hex(&guest_mac(k, vm, &ng, nh))});
        write_frame(&mut w, KIND_JSON, &serde_json::to_vec(&proof).unwrap()).map_err(|e| format!("send proof: {e}"))?;
        Ok(session_key(k, &ng, nh))
    }

    pub fn host_loop(self: Arc<Self>) {
        let mut last = String::new();
        let mut note = |m: String| {
            if m != last {
                logf!("{m}");
                last = m;
            }
        };
        while !STOP.load(Ordering::SeqCst) {
            let k = match secret::load() {
                Ok(k) => k,
                Err(e) => {
                    note(format!("not dialing the host: {e}"));
                    sleep_stop(5000);
                    continue;
                }
            };
            let t_dial = Instant::now();
            let s = match dial(HV_GUID_PARENT, SERVICE_ID, 1000) {
                Ok(s) => s,
                Err(e) => {
                    note(format!("dial failed: {e}"));
                    sleep_stop(200);
                    continue;
                }
            };
            let dial_ms = t_dial.elapsed().as_secs_f64() * 1e3;
            let Some((vm, vm_src)) = vm_id(&s) else {
                note("can't learn this VM's id (getsockname and KVP both empty)".into());
                sleep_stop(2000);
                continue;
            };
            s.set_timeouts(5000, 5000);
            let t_hs = Instant::now();
            let key = match self.handshake(&s, &k, &vm) {
                Ok(key) => key,
                Err(e) => {
                    note(format!("handshake failed (vm {vm} from {vm_src}): {e}"));
                    sleep_stop(1000);
                    continue;
                }
            };
            s.set_timeouts(DEAD_AFTER_MS as u32, 5000);
            let conn = self.conn.fetch_add(1, Ordering::SeqCst) + 1;
            let stream = Arc::new(s);
            *self.host.lock().unwrap() = Some(HostLink { stream: stream.clone(), sealer: Sealer::new(key) });
            let uptime = unsafe { windows::Win32::System::SystemInformation::GetTickCount64() };
            note(format!(
                "connected to the host (conn {conn}, vm {vm} from {vm_src}, dial {dial_ms:.1} ms, handshake {:.1} ms, {:.1} s after boot)",
                t_hs.elapsed().as_secs_f64() * 1e3,
                uptime as f64 / 1000.0
            ));
            let user = self.helper.lock().unwrap().as_ref().and_then(|h| h.user.clone());
            if let Some(u) = user {
                self.send_host(json!({"t": "evt", "event": "signed_in", "data": {"user": u}}), None);
            }
            let why = self.read_loop(&stream, Opener::new(key));
            stream.shutdown();
            *self.host.lock().unwrap() = None;
            self.pending.lock().unwrap().retain(|_, p| p.conn != conn);
            note(format!("disconnected from the host: {why}"));
            sleep_stop(200);
        }
    }

    fn read_loop(&self, stream: &HvStream, mut opener: Opener) -> String {
        let mut announced: Option<Value> = None;
        loop {
            let mut r = stream;
            let f = match read_frame(&mut r) {
                Ok(f) => f,
                Err(FrameError::Io(e)) if e.raw_os_error() == Some(10060) => return "no frame for 6 s".into(),
                Err(e) => return e.to_string(),
            };
            match f {
                Frame::Json(b) => {
                    if announced.is_some() {
                        return "a JSON frame came where a blob was announced".into();
                    }
                    let v = match opener.open(&b) {
                        Ok(v) => v,
                        Err(e) => return format!("rejected frame: {e}"),
                    };
                    match v["t"].as_str() {
                        Some("ping") => {}
                        Some("req") if v["blob"] == true => announced = Some(v),
                        Some("req") => {
                            if let Err(e) = self.handle_req(v, None) {
                                return e;
                            }
                        }
                        Some("cancel") => self.cancel(v["id"].as_u64().unwrap_or(0)),
                        _ => {} // unknown types are ignored (newer hosts), never acted on
                    }
                }
                Frame::Blob(b) => {
                    let Some(v) = announced.take() else { return "a blob nobody announced".into() };
                    if v["blobLen"].as_u64().is_some_and(|n| n != b.len() as u64) {
                        return "blob length differs from blobLen".into();
                    }
                    // blobSha256 is required (protocol): the blob frame itself carries no MAC
                    let Some(h) = v["blobSha256"].as_str() else { return "blob without blobSha256".into() };
                    if !ct_eq(hex(&sha256(&b)).as_bytes(), h.to_ascii_lowercase().as_bytes()) {
                        return "blob differs from blobSha256".into();
                    }
                    if let Err(e) = self.handle_req(v, Some(b)) {
                        return e;
                    }
                }
            }
        }
    }

    fn handle_req(&self, v: Value, blob: Option<Vec<u8>>) -> Result<(), String> {
        let id = v["id"].as_u64().ok_or("request without a numeric id")?;
        let method = v["method"].as_str().unwrap_or("");
        let params = v.get("params").cloned().unwrap_or(json!({}));
        if !METHODS.contains(&method) {
            self.send_host(err_res(id, "bad_request", "unknown method"), None);
            return Ok(());
        }
        if !params.is_object() {
            self.send_host(err_res(id, "bad_request", "params must be an object"), None);
            return Ok(());
        }
        let mut hg = self.helper.lock().unwrap();
        let Some(h) = hg.as_mut() else {
            drop(hg);
            if method == "agent.info" {
                self.send_host(json!({"t": "res", "id": id, "ok": true, "result": self.info_without_helper()}), None);
            } else {
                let why = self.no_helper_reason.lock().unwrap().clone();
                self.send_host(err_res(id, "not_signed_in", &why), None);
            }
            return Ok(());
        };
        let conn = self.conn.load(Ordering::SeqCst);
        {
            let mut p = self.pending.lock().unwrap();
            if p.len() >= MAX_PENDING {
                drop(p);
                drop(hg);
                self.send_host(err_res(id, "internal", "too many requests in flight"), None);
                return Ok(());
            }
            if p.contains_key(&id) {
                drop(p);
                drop(hg);
                self.send_host(err_res(id, "bad_request", "that id is already in flight"), None);
                return Ok(());
            }
            p.insert(id, Pending { deadline: Instant::now() + method_deadline(method, &params), conn, helper: h.pid });
        }
        let req = json!({"t": "req", "id": id, "method": method, "params": params, "blob": blob.is_some()});
        let ok = h.send(&req, blob.as_deref());
        drop(hg);
        if !ok {
            self.pending.lock().unwrap().remove(&id);
            self.send_host(err_res(id, "internal", "the session helper is busy or gone"), None);
        }
        Ok(())
    }

    /// Host cancel: answer `cancelled` now, drop the helper's late answer, and ask the helper to stop the work.
    fn cancel(&self, id: u64) {
        let p = self.pending.lock().unwrap().remove(&id);
        if p.is_none() {
            return;
        }
        if let Some(h) = self.helper.lock().unwrap().as_ref() {
            let _ = h.send(&json!({"t": "cancel", "id": id}), None);
        }
        self.send_host(err_res(id, "cancelled", "cancelled by the host"), None);
    }

    /// Heartbeat every 2 s and request deadlines.
    pub fn ticker(self: Arc<Self>) {
        let mut last_ping = Instant::now();
        while !STOP.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(100));
            // a helper that stopped reading for 10 s (hung, or suspended by another process of its user) is ended;
            // the supervisor starts a new one (security review M1)
            if let Some(h) = self.helper.lock().unwrap().as_ref() {
                if h.busy.lock().unwrap().is_some_and(|t| t.elapsed() > Duration::from_secs(10)) {
                    logf!("session helper {} stopped reading for 10 s: ending it", h.pid);
                    unsafe {
                        let _ = windows::Win32::System::Threading::TerminateProcess(h.process.0, 1);
                    }
                }
            }
            if last_ping.elapsed() >= Duration::from_millis(PING_EVERY_MS) {
                self.send_host(json!({"t": "ping"}), None);
                last_ping = Instant::now();
            }
            let now = Instant::now();
            let expired: Vec<u64> = {
                let mut p = self.pending.lock().unwrap();
                let ids: Vec<u64> = p.iter().filter(|(_, x)| x.deadline <= now).map(|(id, _)| *id).collect();
                for id in &ids {
                    p.remove(id);
                }
                ids
            };
            for id in expired {
                self.send_host(err_res(id, "timeout", "the guest didn't answer in time"), None);
            }
        }
    }

    // ---- helper side ----

    fn helper_reader(self: Arc<Self>, mut from: File, pid: u32) {
        let mut said_hello = false;
        let mut logs = (Instant::now(), 0u32);
        let why = loop {
            let f = match read_frame(&mut from) {
                Ok(f) => f,
                Err(e) => break e.to_string(),
            };
            let Frame::Json(b) = f else { break "unannounced blob from the helper".into() };
            let Ok(v) = serde_json::from_slice::<Value>(&b) else { break "bad JSON from the helper".into() };
            let blob = if v["blob"] == true {
                match read_frame(&mut from) {
                    Ok(Frame::Blob(b)) => Some(b),
                    _ => break "announced blob missing".into(),
                }
            } else {
                None
            };
            match v["t"].as_str() {
                Some("res") => {
                    let Some(id) = v["id"].as_u64() else { continue };
                    let p = self.pending.lock().unwrap().remove(&id);
                    let cur = self.conn.load(Ordering::SeqCst);
                    if !p.is_some_and(|p| p.conn == cur && p.helper == pid) {
                        continue; // timed out already, or from an old connection
                    }
                    let mut out = json!({"t": "res", "id": id, "ok": v["ok"] == true});
                    if v["ok"] == true {
                        out["result"] = v.get("result").cloned().unwrap_or(json!({}));
                    } else {
                        let code = v["error"]["code"].as_str().unwrap_or("internal");
                        out["error"] = json!({"code": code, "message": v["error"]["message"].as_str().unwrap_or("")});
                    }
                    self.send_host(out, blob.as_deref());
                }
                Some("evt") => {
                    let name = v["event"].as_str().unwrap_or("");
                    if HELPER_EVENTS.contains(&name) && self.event_budget() {
                        self.send_host(json!({"t": "evt", "event": name, "data": v.get("data").cloned().unwrap_or(json!({}))}), None);
                    }
                }
                Some("hello") if !said_hello => {
                    said_hello = true; // once per helper: nothing else may announce a user (security review H1)
                    let user = v["user"].as_str().unwrap_or("?").chars().take(256).collect::<String>();
                    logf!("session helper {pid} is up as {user} (session {})", v["session"]);
                    if let Some(h) = self.helper.lock().unwrap().as_mut().filter(|h| h.pid == pid) {
                        h.user = Some(user.clone());
                    }
                    self.send_host(json!({"t": "evt", "event": "signed_in", "data": {"user": user}}), None);
                }
                Some("log") => {
                    if logs.0.elapsed() > Duration::from_secs(1) {
                        logs = (Instant::now(), 0);
                    }
                    logs.1 += 1;
                    if logs.1 <= 20 {
                        logf!("helper {pid}: {}", v["msg"].as_str().unwrap_or(""));
                    }
                }
                _ => {}
            }
        };
        logf!("session helper {pid} gone: {why}");
        let mut g = self.helper.lock().unwrap();
        if g.as_ref().is_some_and(|h| h.pid == pid) {
            *g = None;
            drop(g);
            let lost: Vec<u64> = {
                let mut p = self.pending.lock().unwrap();
                let ids: Vec<u64> = p.iter().filter(|(_, x)| x.helper == pid).map(|(id, _)| *id).collect();
                for id in &ids {
                    p.remove(id);
                }
                ids
            };
            for id in lost {
                self.send_host(err_res(id, "not_signed_in", "the session helper exited (sign-out or session change)"), None);
            }
            self.send_host(json!({"t": "evt", "event": "signed_in", "data": {"user": null}}), None);
        }
        wake();
    }

    /// At most 20 events per second reach the host, whatever the helper sends.
    fn event_budget(&self) -> bool {
        let mut e = self.events.lock().unwrap();
        if e.0.elapsed() >= Duration::from_secs(1) {
            *e = (Instant::now(), 0);
        }
        e.1 += 1;
        e.1 <= 20
    }

    /// Keeps one helper in the active console session: starts it on sign-in, replaces it on a session change,
    /// restarts it if it dies (backing off when it keeps dying).
    pub fn supervise(self: Arc<Self>) {
        let mut current: Option<(session::Helper, Instant)> = None;
        let mut backoff = 200u64;
        let mut next_try = Instant::now();
        let mut last_err = String::new();
        while !STOP.load(Ordering::SeqCst) {
            let sess = session::active_session();
            if let Some((h, started)) = &current {
                let gone = h.exited();
                if gone || Some(h.session) != sess {
                    if !gone {
                        h.kill();
                    }
                    if started.elapsed() < Duration::from_secs(10) {
                        backoff = (backoff * 2).min(5000);
                        next_try = Instant::now() + Duration::from_millis(backoff);
                    } else {
                        backoff = 200;
                    }
                    let pid = h.pid;
                    let mut g = self.helper.lock().unwrap();
                    if g.as_ref().is_some_and(|x| x.pid == pid) {
                        *g = None;
                    }
                    current = None;
                }
            }
            if current.is_none() && Instant::now() >= next_try {
                match sess.ok_or_else(|| "no console session".to_string()).and_then(|s| session::launch(&self.exe, s)) {
                    Ok(h) => {
                        let reader = h.from_helper.try_clone();
                        let writer = h.to_helper.try_clone();
                        match (reader, writer) {
                            (Ok(r), Ok(w)) => {
                                let pid = h.pid;
                                logf!("session helper {pid} started in session {}", h.session);
                                let (tx, rx) = std::sync::mpsc::sync_channel::<Vec<u8>>(64);
                                let busy = Arc::new(Mutex::new(None));
                                let b2 = busy.clone();
                                std::thread::spawn(move || helper_writer(w, rx, b2));
                                *self.helper.lock().unwrap() = Some(HelperLink { tx, busy, process: h.process.clone(), pid, user: None });
                                let me = self.clone();
                                std::thread::spawn(move || me.helper_reader(r, pid));
                                current = Some((h, Instant::now()));
                                last_err.clear();
                            }
                            _ => h.kill(),
                        }
                    }
                    Err(e) => {
                        if e != last_err {
                            logf!("no session helper: {e}");
                            last_err = e.clone();
                        }
                        *self.no_helper_reason.lock().unwrap() = e;
                        next_try = Instant::now() + Duration::from_millis(1000);
                    }
                }
            }
            sleep_wake(1000);
        }
        if let Some((h, _)) = current {
            h.kill();
        }
    }
}

/// Runs the agent until STOP: host connection, heartbeat, helper supervision.
pub fn run() {
    // a log file only inside a folder that passed the secret's ACL check and isn't a link: a SYSTEM service
    // writing through a junction a user planted would be an arbitrary file write (security review H2)
    let logs = std::path::Path::new(secret::DIR).join("logs");
    let link = std::fs::symlink_metadata(&logs).map(|m| {
        use std::os::windows::fs::MetadataExt;
        m.file_attributes() & 0x400 != 0
    });
    if secret::check_acl(secret::DIR).is_ok() && !matches!(link, Ok(true)) {
        log_to(&logs.join("agent.log"));
    }
    logf!("GpuVM agent {VERSION} starting (pid {})", std::process::id());
    let a = Agent::new();
    let (h1, h2) = (a.clone(), a.clone());
    let t1 = std::thread::spawn(move || h1.host_loop());
    let t2 = std::thread::spawn(move || h2.ticker());
    a.clone().supervise();
    if let Some(l) = a.host.lock().unwrap().as_ref() {
        l.stream.shutdown();
    }
    let _ = t1.join();
    let _ = t2.join();
    logf!("GpuVM agent stopped");
}

// ---- Service Control Manager glue ----

mod scm {
    use super::*;
    use windows::core::PWSTR;
    use windows::Win32::Foundation::*;
    use windows::Win32::System::Services::*;

    static mut HANDLE: SERVICE_STATUS_HANDLE = SERVICE_STATUS_HANDLE(std::ptr::null_mut());

    fn status(state: SERVICE_STATUS_CURRENT_STATE, exit: u32) {
        let s = SERVICE_STATUS {
            dwServiceType: SERVICE_WIN32_OWN_PROCESS,
            dwCurrentState: state,
            dwControlsAccepted: if state == SERVICE_RUNNING { SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN | SERVICE_ACCEPT_SESSIONCHANGE } else { 0 },
            dwWin32ExitCode: exit,
            dwServiceSpecificExitCode: 0,
            dwCheckPoint: 0,
            dwWaitHint: if state == SERVICE_STOP_PENDING { 5000 } else { 0 },
        };
        unsafe {
            let _ = SetServiceStatus(HANDLE, &s);
        }
    }

    unsafe extern "system" fn handler(ctrl: u32, _ev: u32, _data: *mut core::ffi::c_void, _ctx: *mut core::ffi::c_void) -> u32 {
        match ctrl {
            SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN => {
                status(SERVICE_STOP_PENDING, 0);
                STOP.store(true, Ordering::SeqCst);
                wake();
                NO_ERROR.0
            }
            SERVICE_CONTROL_SESSIONCHANGE => {
                wake();
                NO_ERROR.0
            }
            SERVICE_CONTROL_INTERROGATE => NO_ERROR.0,
            _ => ERROR_CALL_NOT_IMPLEMENTED.0,
        }
    }

    unsafe extern "system" fn service_main(_argc: u32, _argv: *mut PWSTR) {
        let name = wide(super::NAME);
        match RegisterServiceCtrlHandlerExW(windows::core::PCWSTR(name.as_ptr()), Some(handler), None) {
            Ok(h) => HANDLE = h,
            Err(_) => return,
        }
        status(SERVICE_RUNNING, 0);
        run();
        status(SERVICE_STOPPED, 0);
    }

    pub fn dispatch() -> Result<(), String> {
        let mut name = wide(super::NAME);
        let table = [
            SERVICE_TABLE_ENTRYW { lpServiceName: PWSTR(name.as_mut_ptr()), lpServiceProc: Some(service_main) },
            SERVICE_TABLE_ENTRYW::default(),
        ];
        unsafe { StartServiceCtrlDispatcherW(table.as_ptr()).map_err(|e| format!("not started by the service manager: {e}")) }
    }
}

pub const NAME: &str = "GpuVMAgent";

pub fn run_as_service() -> Result<(), String> {
    scm::dispatch()
}
