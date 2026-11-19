//! The agent broker: the host end of the channel to GpuVM's guest agents (docs/agents/protocol.md, labs 047-052).
//!
//! - Listens on Hyper-V sockets at HV_GUID_CHILDREN:{SERVICE_ID}; Hyper-V tells which VM dialed (the VmId from
//!   accept), the guest never does. The VM must have an agent installed by GpuVM (a registration in
//!   ProgramData\GpuVM\agents\<vmid>, administrators only) and prove it knows that VM's secret.
//! - Everything from a guest is hostile: frames are bounded, signed and numbered; events are rate-limited and only
//!   stored; replies only answer requests the host sent. Nothing a guest sends makes the host do anything.
//! - Requests come from the app and `gpuvm.exe --mcp` on the service pipe (commands answered here, see `command`) and
//!   from the module on an administrators-only pipe. Each one is logged in the VM's folder (agent.log).

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::mpsc::{sync_channel, RecvTimeoutError, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Cryptography::*;
use windows_sys::Win32::System::Registry::*;

use crate::hv::{self, Sock};
use crate::server::log;
use crate::win::wide;
use crate::wire::{self, Frame, Opener, Sealer};

/// The agent channel's Hyper-V socket service id (protocol.md).
pub const SERVICE_ID: u128 = 0x94aca5ef_a5b6_45a9_8c15_c7724a63f3da;
const SERVICE_KEY: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{94aca5ef-a5b6-45a9-8c15-c7724a63f3da}";
/// Mixed into the DPAPI encryption of each VM's secret (Install-GpuVMAgent uses the same).
const SECRET_ENTROPY: &[u8] = b"GpuVM agent secret v1";

const PING_EVERY: Duration = Duration::from_secs(2);
const DEAD_AFTER_MS: u32 = 6000;
const HANDSHAKE_MS: u32 = 5000;
/// Connections still in their handshake, across all VMs, and new connections per VM in 10 s.
const MAX_PRE_AUTH: usize = 16;
const MAX_ACCEPTS_PER_10S: usize = 30;
/// More frames than this in one second closes the connection (a flood, not an agent).
const MAX_FRAMES_PER_SEC: u32 = 2000;
const MAX_EVENTS_PER_SEC: f64 = 10.0;
const MAX_IN_FLIGHT: usize = 32;
const MAX_TIMEOUT_SEC: u64 = 600;
const MAX_OFFER_BYTES: u64 = 2 << 30;
const READ_CHUNK: u64 = 8 << 20;
const OUTBOX: &str = r"C:\Users\agent\Desktop\Outbox\";

/// The guest methods of protocol.md; anything else is refused before it reaches a guest.
const METHODS: &[&str] = &["agent.info", "screen.capture", "screen.state", "input.act", "ui.tree", "ui.invoke", "exec.run", "files.list",
    "files.read", "files.write"];
const EVENTS: &[&str] = &["secure_desktop", "signed_in", "foreground", "error_box"];

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Text a guest sent, made safe to show and log: no control characters, bounded length.
fn clean(s: &str, max: usize) -> String {
    s.chars().filter(|&c| !hidden_char(c)).take(max).collect()
}

/// Control characters and the invisible ones that reorder or hide text (a name that reads backwards).
pub fn hidden_char(c: char) -> bool {
    c.is_control() || matches!(c, '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
}

/// A copy of a guest's value small enough to keep and show: strings cut, lists and depth bounded.
fn bounded(v: &Value, depth: usize) -> Value {
    match v {
        Value::String(s) => Value::String(clean(s, 300)),
        Value::Array(a) if depth > 0 => Value::Array(a.iter().take(50).map(|x| bounded(x, depth - 1)).collect()),
        Value::Object(o) if depth > 0 => Value::Object(o.iter().take(50).map(|(k, x)| (clean(k, 64), bounded(x, depth - 1))).collect()),
        Value::Array(_) | Value::Object(_) => Value::Null,
        other => other.clone(),
    }
}

// ---------------------------------------------------------------- registrations and secrets

pub fn agents_dir() -> PathBuf {
    PathBuf::from(std::env::var("ProgramData").unwrap_or(r"C:\ProgramData".into())).join("GpuVM").join("agents")
}

#[derive(Clone)]
struct Reg {
    vm_id: String,
    name: String,
    folder: PathBuf,
}

/// The VMs with an agent installed by GpuVM. Written by Install-GpuVMAgent into a folder only administrators can
/// change; a registration whose folder name isn't its VmId is ignored.
fn registrations() -> Vec<Reg> {
    let mut out = Vec::new();
    let Ok(dir) = std::fs::read_dir(agents_dir()) else { return out };
    for entry in dir.flatten() {
        let folder_name = entry.file_name().to_string_lossy().to_lowercase();
        let Some(id) = hv::parse_guid(&folder_name) else { continue };
        let Ok(text) = std::fs::read_to_string(entry.path().join("agent.json")) else { continue };
        let Ok(data) = serde_json::from_str::<Value>(text.trim_start_matches('\u{feff}')) else { continue };
        let vm_id = hv::fmt_guid(id);
        if data["vmId"].as_str().map(|s| s.to_lowercase()) != Some(vm_id.clone()) {
            continue;
        }
        let (Some(name), Some(folder)) = (data["name"].as_str(), data["folder"].as_str()) else { continue };
        out.push(Reg { vm_id, name: name.to_string(), folder: PathBuf::from(folder) });
    }
    out
}

fn reg_by_id(vm_id: &str) -> Option<Reg> {
    registrations().into_iter().find(|r| r.vm_id == vm_id)
}

/// Machine names are compared like Hyper-V does: without regard to case.
fn reg_by_name(name: &str) -> Option<Reg> {
    registrations().into_iter().find(|r| r.name.eq_ignore_ascii_case(name) || r.name.to_lowercase() == name.to_lowercase())
}

/// The VM's 32-byte secret: DPAPI (machine scope, GpuVM's entropy) in a file only SYSTEM can read.
fn load_secret(vm_id: &str) -> Result<[u8; 32], String> {
    let data = std::fs::read(agents_dir().join(vm_id).join("secret")).map_err(|e| format!("secret: {e}"))?;
    let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
    let entropy = CRYPT_INTEGER_BLOB { cbData: SECRET_ENTROPY.len() as u32, pbData: SECRET_ENTROPY.as_ptr() as *mut u8 };
    let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe {
        CryptUnprotectData(&input, std::ptr::null_mut(), &entropy, std::ptr::null(), std::ptr::null(), CRYPTPROTECT_UI_FORBIDDEN, &mut output)
    };
    if ok == 0 {
        return Err(crate::win::last_error("CryptUnprotectData"));
    }
    let plain = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe {
        std::ptr::write_bytes(output.pbData, 0, output.cbData as usize);
        LocalFree(output.pbData.cast());
    }
    plain.try_into().map_err(|_| "secret: not 32 bytes".to_string())
}

/// Registers the channel's service id with Hyper-V, so guests may dial it (the installer and the service at start).
pub fn register_service_id() -> Result<(), String> {
    let mut key: HKEY = std::ptr::null_mut();
    let status = unsafe {
        RegCreateKeyExW(HKEY_LOCAL_MACHINE, wide(SERVICE_KEY).as_ptr(), 0, std::ptr::null(), REG_OPTION_NON_VOLATILE, KEY_SET_VALUE,
            std::ptr::null(), &mut key, std::ptr::null_mut())
    };
    if status != 0 {
        return Err(format!("RegCreateKeyExW failed ({status})"));
    }
    let value = wide("GpuVM agent");
    let status = unsafe { RegSetValueExW(key, wide("ElementName").as_ptr(), 0, REG_SZ, value.as_ptr().cast(), (value.len() * 2) as u32) };
    unsafe { RegCloseKey(key) };
    if status != 0 { Err(format!("RegSetValueExW failed ({status})")) } else { Ok(()) }
}

pub fn unregister_service_id() {
    unsafe { RegDeleteKeyW(HKEY_LOCAL_MACHINE, wide(SERVICE_KEY).as_ptr()) };
}

// ---------------------------------------------------------------- the per-VM request log

/// Appends one line to the VM's agent.log (method, params without blobs, result code, duration). Kept at two files of
/// 20 MB at most.
fn vm_log(reg: &Reg, entry: Value) {
    static LOCK: Mutex<()> = Mutex::new(());
    let _guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    if !reg.folder.is_dir() {
        return;
    }
    let path = reg.folder.join("agent.log");
    if std::fs::metadata(&path).map(|m| m.len() > 20 << 20).unwrap_or(false) {
        let _ = std::fs::rename(&path, reg.folder.join("agent.old.log"));
    }
    let mut line = entry;
    line["t"] = json!(now_ms());
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(f, "{line}");
    }
}

// ---------------------------------------------------------------- connected agents

type Reply = Result<(Value, Option<Vec<u8>>), (String, String)>;

struct Pending {
    tx: SyncSender<Reply>,
    /// The MCP connection that asked (pausing or stopping it cancels its requests).
    client: Option<String>,
}

struct Conn {
    serial: u64,
    sock: Sock,
    out: Mutex<Sealer>,
    pending: Mutex<HashMap<u64, Pending>>,
    next_req: AtomicU64,
    agent: String,
    since: u64,
    dead: AtomicBool,
    info: Mutex<Value>,
    events: Mutex<Map<String, Value>>,
}

impl Conn {
    /// Sends one signed JSON frame, and its blob right after it (under the same lock, so nothing comes between).
    fn send(&self, obj: Value, blob: Option<&[u8]>) -> Result<(), String> {
        let Value::Object(obj) = obj else { return Err("not an object".into()) };
        let mut sealer = self.out.lock().unwrap_or_else(|e| e.into_inner());
        let frame = sealer.seal(obj);
        let mut w = &self.sock;
        wire::write_frame(&mut w, wire::KIND_JSON, &frame).map_err(|e| e.to_string())?;
        if let Some(b) = blob {
            wire::write_frame(&mut w, wire::KIND_BLOB, b).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn close(&self) {
        self.dead.store(true, Ordering::SeqCst);
        self.sock.shutdown();
        let pending: Vec<Pending> = self.pending.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, p)| p).collect();
        for p in pending {
            let _ = p.tx.try_send(Err(("off".into(), "The agent disconnected.".into())));
        }
    }

    /// Ends the requests that match (paused, stopped): they get `code` now and the guest is told to stop them.
    fn cancel_where(&self, code: &str, message: &str, matches: impl Fn(&Pending) -> bool) {
        let ids: Vec<(u64, Pending)> = {
            let mut map = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            let ids: Vec<u64> = map.iter().filter(|(_, p)| matches(p)).map(|(id, _)| *id).collect();
            ids.into_iter().filter_map(|id| map.remove(&id).map(|p| (id, p))).collect()
        };
        for (id, p) in ids {
            let _ = p.tx.try_send(Err((code.into(), message.into())));
            let _ = self.send(json!({ "t": "cancel", "id": id }), None);
        }
    }

    fn request(&self, method: &str, params: &Value, blob: Option<&[u8]>, timeout: Duration, client: Option<&str>) -> Reply {
        if self.dead.load(Ordering::SeqCst) {
            return Err(("off".into(), "The agent isn't connected.".into()));
        }
        let id = self.next_req.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = sync_channel(1);
        {
            let mut map = self.pending.lock().unwrap_or_else(|e| e.into_inner());
            if map.len() >= MAX_IN_FLIGHT {
                return Err(("busy".into(), "Too many requests are running on this machine.".into()));
            }
            map.insert(id, Pending { tx, client: client.map(str::to_string) });
        }
        let mut req = json!({ "t": "req", "id": id, "method": method, "params": params });
        if blob.is_some() {
            req["blob"] = json!(true);
        }
        if let Err(e) = self.send(req, blob) {
            self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
            return Err(("off".into(), format!("The agent connection broke: {e}")));
        }
        match rx.recv_timeout(timeout) {
            Ok(reply) => reply,
            Err(RecvTimeoutError::Timeout) => {
                if self.pending.lock().unwrap_or_else(|e| e.into_inner()).remove(&id).is_some() {
                    let _ = self.send(json!({ "t": "cancel", "id": id }), None);
                    return Err(("timeout".into(), format!("No answer in {} s.", timeout.as_secs())));
                }
                // Answered (or cancelled) at the same moment.
                rx.recv_timeout(Duration::from_millis(100)).unwrap_or(Err(("timeout".into(), "No answer.".into())))
            }
            Err(RecvTimeoutError::Disconnected) => Err(("off".into(), "The agent disconnected.".into())),
        }
    }
}

#[derive(Default)]
struct Machine {
    paused: Option<Value>,
    taken_by: Option<String>,
    accepts: VecDeque<Instant>,
    last_error: Option<String>,
}

struct Client {
    name: String,
    version: String,
    pid: u32,
    started: Instant,
    started_ms: u64,
    steps: u64,
    killed: bool,
    max_steps: u64,
    max_minutes: u64,
}

#[derive(Clone)]
struct Offer {
    id: String,
    vm_id: String,
    path: String,
    file_name: String,
    size: Option<u64>,
    note: String,
    state: String,
    created: u64,
    host_path: Option<String>,
    error: Option<String>,
    client: Option<String>,
}

impl Offer {
    fn to_json(&self, name: &str) -> Value {
        json!({ "id": self.id, "name": name, "path": self.path, "fileName": self.file_name, "size": self.size, "note": self.note,
            "state": self.state, "created": self.created, "hostPath": self.host_path, "error": self.error, "connection": self.client })
    }
}

struct Broker {
    conns: Mutex<HashMap<String, Arc<Conn>>>,
    machines: Mutex<HashMap<String, Machine>>,
    clients: Mutex<HashMap<String, Client>>,
    offers: Mutex<Vec<Offer>>,
    listener: Mutex<Value>,
    pre_auth: AtomicUsize,
    serial: AtomicU64,
}

fn broker() -> &'static Broker {
    static B: OnceLock<Broker> = OnceLock::new();
    B.get_or_init(|| Broker {
        conns: Mutex::new(HashMap::new()),
        machines: Mutex::new(HashMap::new()),
        clients: Mutex::new(HashMap::new()),
        offers: Mutex::new(Vec::new()),
        listener: Mutex::new(json!({ "listening": false, "error": "starting" })),
        pre_auth: AtomicUsize::new(0),
        serial: AtomicU64::new(1),
    })
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn conn_of(vm_id: &str) -> Option<Arc<Conn>> {
    lock(&broker().conns).get(vm_id).cloned()
}

// ---------------------------------------------------------------- listening

/// Starts the listener (and retries while the name is taken) and the module's pipe. Called once by the service.
pub fn start() {
    std::thread::spawn(listen_loop);
    std::thread::spawn(crate::agent_pipe::serve);
}

fn listen_loop() {
    hv::startup();
    if let Err(e) = register_service_id() {
        log(&format!("agent: couldn't register the service id: {e}"));
    }
    let mut warned = false;
    loop {
        match Sock::listen(hv::HV_GUID_CHILDREN, SERVICE_ID) {
            Ok(listener) => {
                *lock(&broker().listener) = json!({ "listening": true, "since": now_ms() });
                log("agent: listening for guest agents");
                warned = false;
                accept_loop(&listener);
            }
            Err(code) => {
                // 10048: another program holds the name (lab 050: even an unelevated one can). Agents won't trust it
                // (it can't answer the handshake), but they can't reach GpuVM either until it lets go.
                let error = if code == 10048 {
                    "Another program on this PC holds the agent channel's name; agents can't connect to GpuVM.".to_string()
                } else {
                    format!("The agent channel couldn't start (error {code}).")
                };
                if !warned {
                    log(&format!("agent: {error}"));
                    warned = true;
                }
                *lock(&broker().listener) = json!({ "listening": false, "error": error, "code": code });
                std::thread::sleep(Duration::from_secs(5));
            }
        }
    }
}

fn accept_loop(listener: &Sock) {
    loop {
        let (sock, peer) = match listener.accept() {
            Ok(x) => x,
            Err(code) => {
                if code == -1 {
                    continue;
                }
                log(&format!("agent: accept failed ({code})"));
                std::thread::sleep(Duration::from_millis(200));
                if matches!(code, 10004 | 10038 | 10050 | 10093) {
                    return;
                }
                continue;
            }
        };
        let vm_id = hv::fmt_guid(peer);
        // Per VM: at most 30 new connections every 10 s; everywhere: at most 16 handshakes at once.
        let flooding = {
            let mut machines = lock(&broker().machines);
            let m = machines.entry(vm_id.clone()).or_default();
            m.accepts.retain(|t| t.elapsed() < Duration::from_secs(10));
            m.accepts.push_back(Instant::now());
            m.accepts.len() > MAX_ACCEPTS_PER_10S
        };
        if flooding || broker().pre_auth.load(Ordering::SeqCst) >= MAX_PRE_AUTH {
            continue; // dropped: the socket closes
        }
        broker().pre_auth.fetch_add(1, Ordering::SeqCst);
        std::thread::spawn(move || serve_agent(sock, vm_id));
    }
}

struct PreAuth(bool);
impl PreAuth {
    fn done(&mut self) {
        if self.0 {
            broker().pre_auth.fetch_sub(1, Ordering::SeqCst);
            self.0 = false;
        }
    }
}
impl Drop for PreAuth {
    fn drop(&mut self) {
        self.done();
    }
}

fn set_last_error(vm_id: &str, error: Option<String>) {
    lock(&broker().machines).entry(vm_id.to_string()).or_default().last_error = error;
}

fn serve_agent(sock: Sock, vm_id: String) {
    let mut pre = PreAuth(true);
    // Unknown VMs (no agent installed by GpuVM) are closed without a word.
    let Some(reg) = reg_by_id(&vm_id) else { return };
    sock.set_timeouts(HANDSHAKE_MS, 10_000);
    let secret = match load_secret(&vm_id) {
        Ok(k) => k,
        Err(e) => {
            vm_log(&reg, json!({ "event": "refused", "reason": e }));
            return;
        }
    };
    let mut stream = &sock;
    let session = match wire::host_handshake(&mut stream, &secret, &vm_id) {
        Ok(s) => s,
        Err(reason) => {
            // Logged at most once a second per VM (a guest could otherwise fill the disk).
            let quiet = lock(&broker().machines).get(&vm_id).is_some_and(|m| m.accepts.len() > 3);
            if !quiet {
                vm_log(&reg, json!({ "event": "handshake_failed", "reason": reason }));
            }
            set_last_error(&vm_id, Some(format!("handshake: {reason}")));
            return;
        }
    };
    pre.done();
    set_last_error(&vm_id, None);
    sock.set_timeouts(DEAD_AFTER_MS, 10_000);
    let wire::Session { sealer, mut opener, agent } = session;
    let conn = Arc::new(Conn {
        serial: broker().serial.fetch_add(1, Ordering::SeqCst),
        sock,
        out: Mutex::new(sealer),
        pending: Mutex::new(HashMap::new()),
        next_req: AtomicU64::new(1),
        agent,
        since: now_ms(),
        dead: AtomicBool::new(false),
        info: Mutex::new(Value::Null),
        events: Mutex::new(Map::new()),
    });
    // A new connection from the same VM replaces the old one (the agent restarted).
    if let Some(old) = lock(&broker().conns).insert(vm_id.clone(), conn.clone()) {
        old.close();
    }
    vm_log(&reg, json!({ "event": "connected", "agent": conn.agent }));
    {
        let c = conn.clone();
        std::thread::spawn(move || {
            while !c.dead.load(Ordering::SeqCst) {
                if c.send(json!({ "t": "ping" }), None).is_err() {
                    c.close();
                    break;
                }
                std::thread::sleep(PING_EVERY);
            }
        });
    }
    {
        let c = conn.clone();
        std::thread::spawn(move || {
            if let Ok((info, _)) = c.request("agent.info", &json!({}), None, Duration::from_secs(10), None) {
                *lock(&c.info) = bounded(&info, 3);
            }
        });
    }
    let reason = read_loop(&conn, &mut opener);
    conn.close();
    {
        let mut conns = lock(&broker().conns);
        if conns.get(&vm_id).is_some_and(|c| c.serial == conn.serial) {
            conns.remove(&vm_id);
        }
    }
    vm_log(&reg, json!({ "event": "disconnected", "reason": reason }));
}

/// Reads the guest's frames until the connection ends; returns why it ended.
fn read_loop(conn: &Conn, opener: &mut Opener) -> String {
    let mut stream = &conn.sock;
    let mut window = Instant::now();
    let mut frames = 0u32;
    let mut tokens = MAX_EVENTS_PER_SEC * 2.0;
    let mut last_refill = Instant::now();
    let mut dropped_events = 0u64;
    loop {
        let frame = match wire::read_frame(&mut stream, wire::MAX_JSON) {
            Ok(f) => f,
            Err(e) => return if e.contains("10060") { "no heartbeat for 6 s".into() } else { e },
        };
        if window.elapsed() >= Duration::from_secs(1) {
            window = Instant::now();
            frames = 0;
        }
        frames += 1;
        if frames > MAX_FRAMES_PER_SEC {
            return "flood".into();
        }
        let Frame::Json(payload) = frame else { return "blob without a request".into() };
        let msg = match opener.open(&payload) {
            Ok(m) => m,
            Err(e) => return e,
        };
        match msg.get("t").and_then(Value::as_str) {
            Some("ping") => {}
            Some("res") => {
                let Some(id) = msg.get("id").and_then(Value::as_u64) else { return "reply without id".into() };
                if id == 0 || id >= conn.next_req.load(Ordering::SeqCst) {
                    return "reply to a request never sent".into();
                }
                let blob = if msg.get("blob") == Some(&json!(true)) {
                    match wire::read_frame(&mut stream, wire::MAX_JSON) {
                        Ok(Frame::Blob(b)) => Some(b),
                        Ok(_) => return "missing blob".into(),
                        Err(e) => return e,
                    }
                } else {
                    None
                };
                let reply = match msg.get("ok") {
                    Some(Value::Bool(true)) => Ok((msg.get("result").cloned().unwrap_or(json!({})), blob)),
                    Some(Value::Bool(false)) => {
                        let e = msg.get("error").cloned().unwrap_or(Value::Null);
                        Err((clean(e["code"].as_str().unwrap_or("internal"), 32), clean(e["message"].as_str().unwrap_or(""), 1000)))
                    }
                    _ => return "reply without ok".into(),
                };
                if let Some(p) = lock(&conn.pending).remove(&id) {
                    let _ = p.tx.try_send(reply);
                }
            }
            Some("evt") => {
                let now = Instant::now();
                tokens = (tokens + now.duration_since(last_refill).as_secs_f64() * MAX_EVENTS_PER_SEC).min(MAX_EVENTS_PER_SEC * 2.0);
                last_refill = now;
                if tokens < 1.0 {
                    dropped_events += 1;
                    if dropped_events > 1000 {
                        return "event flood".into();
                    }
                    continue;
                }
                tokens -= 1.0;
                let Some(name) = msg.get("event").and_then(Value::as_str).filter(|n| EVENTS.contains(n)) else { continue };
                let data = bounded(msg.get("data").unwrap_or(&Value::Null), 3);
                lock(&conn.events).insert(name.to_string(), json!({ "data": data, "at": now_ms() }));
            }
            _ => return "unknown message".into(),
        }
    }
}

// ---------------------------------------------------------------- running VMs (Host Compute Service)

/// VmIds of the compute systems running now, or None when HCS can't be asked. Cached for a second.
fn running_vms() -> Option<Vec<String>> {
    use windows_sys::Win32::System::HostComputeSystem::*;
    static CACHE: Mutex<Option<(Instant, Option<Vec<String>>)>> = Mutex::new(None);
    if let Some((at, v)) = lock(&CACHE).as_ref() {
        if at.elapsed() < Duration::from_secs(1) {
            return v.clone();
        }
    }
    let result = unsafe {
        let op = HcsCreateOperation(std::ptr::null(), None);
        if op.is_null() {
            None
        } else {
            let mut doc: windows_sys::core::PWSTR = std::ptr::null_mut();
            let hr = HcsEnumerateComputeSystems(std::ptr::null(), op);
            let hr = if hr >= 0 { HcsWaitForOperationResult(op, 5000, &mut doc) } else { hr };
            HcsCloseOperation(op);
            let text = if doc.is_null() {
                String::new()
            } else {
                let len = (0..).take_while(|&i| *doc.add(i) != 0).count();
                let s = String::from_utf16_lossy(std::slice::from_raw_parts(doc, len));
                LocalFree(doc.cast());
                s
            };
            (hr >= 0).then(|| {
                serde_json::from_str::<Value>(&text).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default().iter()
                    .filter_map(|s| s["Id"].as_str().map(str::to_lowercase)).collect()
            })
        }
    };
    *lock(&CACHE) = Some((Instant::now(), result.clone()));
    result
}

// ---------------------------------------------------------------- commands

/// Who sent a command: the pipe (to impersonate them), their process, and which pipe.
pub struct Ctx {
    pub pipe: HANDLE,
    pub pid: u32,
    /// The module's administrators-only pipe: blobs come back as files instead of base64.
    pub admin: bool,
    /// MCP connections registered over this pipe connection: dropped when it closes.
    owned: Vec<String>,
}

impl Ctx {
    pub fn new(pipe: HANDLE, pid: u32, admin: bool) -> Self {
        Ctx { pipe, pid, admin, owned: Vec::new() }
    }

    /// A process that registered as an agent client (the MCP server) acts for a model: it never approves anything.
    fn is_agent_side(&self) -> bool {
        lock(&broker().clients).values().any(|c| c.pid == self.pid)
    }

    fn label(&self) -> &'static str {
        if self.admin { "module" } else { "app" }
    }
}

impl Drop for Ctx {
    fn drop(&mut self) {
        for id in std::mem::take(&mut self.owned) {
            disconnect_client(&id);
        }
    }
}

pub struct CmdError {
    pub code: String,
    pub message: String,
}

fn err<T>(code: &str, message: impl Into<String>) -> Result<T, CmdError> {
    Err(CmdError { code: code.into(), message: message.into() })
}

/// The commands the broker answers itself, with their exact arguments (exact case, like the bridge).
const COMMANDS: &[(&str, &[&str])] = &[
    ("Get-GpuVMAgent", &["Name"]),
    ("Get-GpuVMAgentBroker", &[]),
    ("Invoke-GpuVMAgent", &["Name", "Method", "Params", "TimeoutSec", "Connection", "Blob"]),
    ("Connect-GpuVMAgentClient", &["Client"]),
    ("Disconnect-GpuVMAgentClient", &["Connection"]),
    ("Lock-GpuVMAgent", &["Name", "Connection"]),
    ("Unlock-GpuVMAgent", &["Name", "Connection"]),
    ("Request-GpuVMHuman", &["Name", "Connection", "Message"]),
    ("Suspend-GpuVMAgent", &["Name", "Message"]),
    ("Resume-GpuVMAgent", &["Name"]),
    ("Stop-GpuVMAgentClient", &["Connection", "All"]),
    ("New-GpuVMAgentOffer", &["Name", "Path", "Note", "Connection"]),
    ("Get-GpuVMAgentOffer", &["Id", "Name"]),
    ("Resolve-GpuVMAgentOffer", &["Id", "Answer"]),
];

pub fn is_command(cmd: &str) -> bool {
    COMMANDS.iter().any(|(c, _)| *c == cmd)
}

/// The result line, shaped like the bridge's: `data` is a list (a single object becomes a one-item list).
pub fn result_line(id: &Value, result: Result<Value, CmdError>) -> Value {
    match result {
        Ok(Value::Array(list)) => json!({ "id": id, "type": "result", "ok": true, "data": list }),
        Ok(v) => json!({ "id": id, "type": "result", "ok": true, "data": [v] }),
        Err(e) => json!({ "id": id, "type": "result", "ok": false, "error": e.message, "code": e.code }),
    }
}

/// Runs one broker command. The caller already knows it is one (`is_command`).
pub fn command(cmd: &str, args: &Value, ctx: &mut Ctx) -> Result<Value, CmdError> {
    let allowed = COMMANDS.iter().find(|(c, _)| *c == cmd).map(|(_, a)| *a).unwrap_or(&[]);
    let empty = Map::new();
    let args = match args {
        Value::Object(o) => o,
        Value::Null => &empty,
        _ => return err("bad_request", "Arguments must be an object."),
    };
    if let Some(key) = args.keys().find(|k| !allowed.contains(&k.as_str())) {
        return err("bad_request", format!("Argument not allowed: {key}"));
    }
    let s = |k: &str| args.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    match cmd {
        "Get-GpuVMAgent" => Ok(get_agents(s("Name"))),
        "Get-GpuVMAgentBroker" => {
            let mut v = lock(&broker().listener).clone();
            v["connected"] = json!(lock(&broker().conns).len());
            v["serviceId"] = json!(hv::fmt_guid(SERVICE_ID));
            Ok(v)
        }
        "Invoke-GpuVMAgent" => invoke(args, ctx),
        "Connect-GpuVMAgentClient" => connect_client(args.get("Client").unwrap_or(&Value::Null), ctx),
        "Disconnect-GpuVMAgentClient" => {
            let id = s("Connection").ok_or_else(|| CmdError { code: "bad_request".into(), message: "Connection is required.".into() })?;
            own_client(id, ctx)?;
            disconnect_client(id);
            ctx.owned.retain(|c| c != id);
            Ok(json!({}))
        }
        "Lock-GpuVMAgent" | "Unlock-GpuVMAgent" | "Request-GpuVMHuman" => {
            let (Some(name), Some(id)) = (s("Name"), s("Connection")) else { return err("bad_request", "Name and Connection are required.") };
            own_client(id, ctx)?;
            let reg = reg_by_name(name).ok_or_else(|| CmdError { code: "not_found".into(), message: format!("No agent on '{name}'.") })?;
            let mut machines = lock(&broker().machines);
            let m = machines.entry(reg.vm_id.clone()).or_default();
            match cmd {
                "Lock-GpuVMAgent" => {
                    match &m.taken_by {
                        Some(other) if other != id => return err("taken", format!("'{}' is in use by another agent session.", reg.name)),
                        _ => m.taken_by = Some(id.to_string()),
                    }
                    Ok(json!({ "name": reg.name, "connection": id }))
                }
                "Unlock-GpuVMAgent" => {
                    if m.taken_by.as_deref() == Some(id) {
                        m.taken_by = None;
                    }
                    Ok(json!({}))
                }
                _ => {
                    if m.taken_by.as_deref() != Some(id) {
                        return err("not_taken", format!("Take '{}' first.", reg.name));
                    }
                    let message = clean(s("Message").unwrap_or(""), 500);
                    let request = wire::hex(&wire::random::<8>());
                    m.paused = Some(json!({ "by": "agent", "message": message, "requestId": request, "since": now_ms(), "connection": id }));
                    drop(machines);
                    vm_log(&reg, json!({ "event": "paused", "by": "agent", "connection": id, "message": message }));
                    Ok(json!({ "requestId": request }))
                }
            }
        }
        "Suspend-GpuVMAgent" | "Resume-GpuVMAgent" => {
            if ctx.is_agent_side() {
                return err("denied", "Only the person can take or give back control.");
            }
            let name = s("Name").ok_or_else(|| CmdError { code: "bad_request".into(), message: "Name is required.".into() })?;
            let reg = reg_by_name(name).ok_or_else(|| CmdError { code: "not_found".into(), message: format!("No agent on '{name}'.") })?;
            if cmd == "Suspend-GpuVMAgent" {
                let message = clean(s("Message").unwrap_or(""), 500);
                lock(&broker().machines).entry(reg.vm_id.clone()).or_default().paused =
                    Some(json!({ "by": "person", "message": message, "since": now_ms() }));
                if let Some(c) = conn_of(&reg.vm_id) {
                    c.cancel_where("paused", "The person took control of this machine.", |p| p.client.is_some());
                }
                vm_log(&reg, json!({ "event": "paused", "by": "person", "via": ctx.label() }));
            } else {
                lock(&broker().machines).entry(reg.vm_id.clone()).or_default().paused = None;
                vm_log(&reg, json!({ "event": "resumed", "via": ctx.label() }));
            }
            Ok(json!({ "name": reg.name }))
        }
        "Stop-GpuVMAgentClient" => {
            if ctx.is_agent_side() {
                return err("denied", "Only the person can stop agent sessions.");
            }
            let all = args.get("All") == Some(&json!(true));
            let target = s("Connection");
            if !all && target.is_none() {
                return err("bad_request", "Connection or All is required.");
            }
            let stopped: Vec<String> = {
                let mut clients = lock(&broker().clients);
                clients.iter_mut().filter(|(id, _)| all || Some(id.as_str()) == target).map(|(id, c)| {
                    c.killed = true;
                    id.clone()
                }).collect()
            };
            for id in &stopped {
                release_and_cancel(id, "killed", "The person stopped this agent session.");
            }
            Ok(json!({ "stopped": stopped }))
        }
        "New-GpuVMAgentOffer" => {
            let (Some(name), Some(path)) = (s("Name"), s("Path")) else { return err("bad_request", "Name and Path are required.") };
            new_offer(name, path, s("Note").unwrap_or(""), s("Connection"), ctx)
        }
        "Get-GpuVMAgentOffer" => {
            let regs = registrations();
            let filter_vm = s("Name").map(|n| reg_by_name(n).map(|r| r.vm_id).unwrap_or_default());
            let list: Vec<Value> = lock(&broker().offers).iter()
                .filter(|o| s("Id").is_none_or(|id| o.id == id) && filter_vm.as_ref().is_none_or(|vm| &o.vm_id == vm))
                .map(|o| o.to_json(&regs.iter().find(|r| r.vm_id == o.vm_id).map(|r| r.name.clone()).unwrap_or_default()))
                .collect();
            Ok(Value::Array(list))
        }
        "Resolve-GpuVMAgentOffer" => {
            if ctx.is_agent_side() {
                return err("denied", "Only the person can approve files leaving a machine.");
            }
            let (Some(id), Some(answer)) = (s("Id"), s("Answer")) else { return err("bad_request", "Id and Answer are required.") };
            crate::offer::resolve(id, answer, ctx)
        }
        _ => err("bad_request", format!("Unknown command {cmd}")),
    }
}

fn get_agents(name: Option<&str>) -> Value {
    let regs = registrations();
    let running = running_vms();
    let mut list = Vec::new();
    let selected: Vec<Reg> = match name {
        Some(n) => match reg_by_name(n) {
            Some(r) => vec![r],
            None => return json!([{ "name": n, "state": "no-agent" }]),
        },
        None => regs,
    };
    let clients = lock(&broker().clients);
    for reg in selected {
        let conn = conn_of(&reg.vm_id);
        let machines = lock(&broker().machines);
        let m = machines.get(&reg.vm_id);
        let state = if conn.is_some() {
            "ready"
        } else {
            match &running {
                Some(list) if list.contains(&reg.vm_id) => "starting",
                Some(_) => "off",
                None => "starting",
            }
        };
        let gpuvm = std::fs::read_to_string(reg.folder.join("gpuvm.json")).ok()
            .and_then(|t| serde_json::from_str::<Value>(t.trim_start_matches('\u{feff}')).ok()).unwrap_or(Value::Null);
        let disposable = gpuvm["disposable"].is_object();
        let template = gpuvm["disposable"]["template"].as_str().or(gpuvm["template"].as_str()).map(str::to_string);
        let taken = m.and_then(|m| m.taken_by.clone()).map(|id| {
            let client = clients.get(&id);
            json!({ "connection": id, "client": client.map(|c| json!({ "name": c.name, "version": c.version })),
                "steps": client.map(|c| c.steps), "startedAt": client.map(|c| c.started_ms) })
        });
        let (agent, events) = match &conn {
            Some(c) => (lock(&c.info).clone(), Value::Object(lock(&c.events).clone())),
            None => (Value::Null, Value::Null),
        };
        let desktop = match events["secure_desktop"]["data"]["on"].as_bool() {
            Some(true) => json!("secure"),
            Some(false) => json!("default"),
            None if conn.is_some() => json!("default"),
            None => Value::Null,
        };
        list.push(json!({
            "name": reg.name, "vmId": reg.vm_id, "state": state, "version": conn.as_ref().map(|c| c.agent.clone()),
            "agent": agent, "desktop": desktop, "events": events, "connectedSince": conn.as_ref().map(|c| c.since),
            "paused": m.and_then(|m| m.paused.clone()), "takenBy": taken,
            "lastError": m.and_then(|m| m.last_error.clone()), "disposable": disposable, "template": template,
        }));
    }
    Value::Array(list)
}

fn settings() -> (u64, u64) {
    let data = std::fs::read_to_string(agents_dir().join("settings.json")).ok()
        .and_then(|t| serde_json::from_str::<Value>(t.trim_start_matches('\u{feff}')).ok()).unwrap_or(Value::Null);
    (data["maxSteps"].as_u64().unwrap_or(500).clamp(1, 100_000), data["maxMinutes"].as_u64().unwrap_or(60).clamp(1, 24 * 60))
}

fn connect_client(client: &Value, ctx: &mut Ctx) -> Result<Value, CmdError> {
    if ctx.admin {
        return err("denied", "Agent clients connect through the GpuVM app's pipe.");
    }
    let name = clean(client["name"].as_str().unwrap_or("unknown"), 64);
    let version = clean(client["version"].as_str().unwrap_or(""), 32);
    let (max_steps, max_minutes) = settings();
    let id = wire::hex(&wire::random::<16>());
    lock(&broker().clients).insert(id.clone(), Client {
        name: name.clone(), version, pid: ctx.pid, started: Instant::now(), started_ms: now_ms(), steps: 0, killed: false, max_steps, max_minutes,
    });
    ctx.owned.push(id.clone());
    log(&format!("agent: client {name} connected (pid {})", ctx.pid));
    Ok(json!({ "connection": id, "settings": { "elicitation": false, "maxSteps": max_steps, "maxMinutes": max_minutes } }))
}

/// A connection id is only usable from the process that registered it.
fn own_client(id: &str, ctx: &Ctx) -> Result<(), CmdError> {
    match lock(&broker().clients).get(id) {
        Some(c) if c.pid == ctx.pid => Ok(()),
        _ => err("not_found", "Unknown agent connection."),
    }
}

fn release_and_cancel(id: &str, code: &str, message: &str) {
    for m in lock(&broker().machines).values_mut() {
        if m.taken_by.as_deref() == Some(id) {
            m.taken_by = None;
        }
    }
    let conns: Vec<Arc<Conn>> = lock(&broker().conns).values().cloned().collect();
    for c in conns {
        c.cancel_where(code, message, |p| p.client.as_deref() == Some(id));
    }
}

fn disconnect_client(id: &str) {
    if let Some(c) = lock(&broker().clients).remove(id) {
        log(&format!("agent: client {} disconnected", c.name));
    }
    release_and_cancel(id, "cancelled", "The agent session ended.");
}

/// What a request of an MCP connection may do now: its own, unstopped, within budget, on a machine it took and
/// that isn't paused. Counts the step.
fn admit(id: &str, vm_id: &str, name: &str, ctx: &Ctx) -> Result<(), CmdError> {
    {
        let mut clients = lock(&broker().clients);
        let Some(c) = clients.get_mut(id).filter(|c| c.pid == ctx.pid) else { return err("not_found", "Unknown agent connection.") };
        if c.killed {
            return err("killed", "The person stopped this agent session.");
        }
        if c.steps >= c.max_steps || c.started.elapsed() >= Duration::from_secs(c.max_minutes * 60) {
            return err("budget", format!("This session reached its limit ({} steps or {} minutes).", c.max_steps, c.max_minutes));
        }
        c.steps += 1;
    }
    let machines = lock(&broker().machines);
    let m = machines.get(vm_id);
    match m.and_then(|m| m.taken_by.as_deref()) {
        Some(owner) if owner == id => {}
        Some(_) => return err("taken", format!("'{name}' is in use by another agent session.")),
        None => return err("not_taken", format!("Take '{name}' first.")),
    }
    if let Some(p) = m.and_then(|m| m.paused.as_ref()) {
        let who = if p["by"] == "agent" { "waiting for the person" } else { "the person took control" };
        return err("paused", format!("'{name}' is paused ({who})."));
    }
    Ok(())
}

/// Shape of params kept in the log: blobs out, strings cut.
fn loggable(v: &Value) -> Value {
    let mut copy = bounded(v, 4);
    if let Some(o) = copy.as_object_mut() {
        for key in ["data", "blob", "stdin"] {
            if let Some(x) = o.get_mut(key) {
                *x = json!(format!("<{} chars>", x.as_str().map(str::len).unwrap_or(0)));
            }
        }
    }
    copy
}

fn invoke(args: &Map<String, Value>, ctx: &Ctx) -> Result<Value, CmdError> {
    let s = |k: &str| args.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    let (Some(name), Some(method)) = (s("Name"), s("Method")) else { return err("bad_request", "Name and Method are required.") };
    let params = match args.get("Params") {
        None | Some(Value::Null) => json!({}),
        Some(p @ Value::Object(_)) => p.clone(),
        Some(_) => return err("bad_request", "Params must be an object."),
    };
    if method == "outbox.offer" {
        let path = params["path"].as_str().unwrap_or("");
        return new_offer(name, path, params["note"].as_str().unwrap_or(""), s("Connection"), ctx).map(|v| json!({ "ok": true, "result": v }));
    }
    if !METHODS.contains(&method) {
        return err("bad_request", format!("Unknown method {method}"));
    }
    if params.to_string().len() > wire::MAX_JSON - 1024 {
        return err("too_large", "Params are too large.");
    }
    let timeout = args.get("TimeoutSec").and_then(Value::as_u64).unwrap_or(30).clamp(1, MAX_TIMEOUT_SEC);
    let blob = match s("Blob") {
        Some(b) => Some(wire::unbase64(b).filter(|b| b.len() <= wire::MAX_BLOB)
            .ok_or_else(|| CmdError { code: "bad_request".into(), message: "Blob must be base64, 16 MiB at most.".into() })?),
        None => None,
    };
    let reg = reg_by_name(name).ok_or_else(|| CmdError { code: "not_found".into(), message: format!("No agent on '{name}'.") })?;
    let client = s("Connection");
    match client {
        Some(id) => admit(id, &reg.vm_id, &reg.name, ctx)?,
        // The MCP server always names its connection: unnamed requests are the person's (the app) or the module's.
        None if ctx.is_agent_side() => return err("not_taken", "Connection is required."),
        None => {}
    }
    let started = Instant::now();
    let reply = match conn_of(&reg.vm_id) {
        Some(c) => c.request(method, &params, blob.as_deref(), Duration::from_secs(timeout), client),
        None => Err(("off".into(), format!("The agent on '{}' isn't connected.", reg.name))),
    };
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let code = match &reply { Ok(_) => "ok".to_string(), Err((c, _)) => c.clone() };
    let blob_len = reply.as_ref().ok().and_then(|(_, b)| b.as_ref().map(Vec::len));
    vm_log(&reg, json!({ "method": method, "params": loggable(&params), "client": client.unwrap_or(ctx.label()), "code": code,
        "ms": (ms * 100.0).round() / 100.0, "blobIn": blob.as_ref().map(Vec::len), "blobOut": blob_len }));
    let mut out = match reply {
        Ok((result, blob)) => {
            let mut v = json!({ "ok": true, "result": result });
            if let Some(b) = blob {
                let format = v["result"]["format"].as_str().map(|f| clean(f, 8)).unwrap_or_else(|| "bin".into());
                if ctx.admin {
                    v["blobPath"] = json!(save_blob(&b, &format).map_err(|e| CmdError { code: "internal".into(), message: e })?);
                } else {
                    v["blob"] = json!(wire::base64(&b));
                }
                v["blobFormat"] = json!(format);
                v["blobBytes"] = json!(b.len());
            }
            v
        }
        Err((code, message)) => json!({ "ok": false, "error": { "code": code, "message": message } }),
    };
    out["ms"] = json!((ms * 100.0).round() / 100.0);
    Ok(out)
}

/// A blob for the module: a file in ProgramData\GpuVM\agents\blobs (administrators only), deleted after an hour.
fn save_blob(data: &[u8], format: &str) -> Result<String, String> {
    let dir = agents_dir().join("blobs");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for e in entries.flatten() {
            if e.metadata().and_then(|m| m.modified()).is_ok_and(|t| t.elapsed().unwrap_or_default() > Duration::from_secs(3600)) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
    let ext: String = format.chars().filter(|c| c.is_ascii_alphanumeric()).take(8).collect();
    let path = dir.join(format!("{}.{}", wire::hex(&wire::random::<12>()), if ext.is_empty() { "bin".into() } else { ext }));
    std::fs::write(&path, data).map_err(|e| e.to_string())?;
    Ok(path.display().to_string())
}

// ---------------------------------------------------------------- Outbox offers

/// A file name safe on this PC: no path, no reserved names or characters, no trailing dots or spaces.
pub fn safe_file_name(name: &str) -> Option<String> {
    let cleaned: String = name.chars().filter(|&c| !hidden_char(c) && !r#"<>:"/\|?*"#.contains(c)).take(200).collect();
    let cleaned = cleaned.trim_end_matches(['.', ' ']).trim_start().to_string();
    let stem = cleaned.split('.').next().unwrap_or("").trim_end().to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem.as_str())
        || ((stem.starts_with("COM") || stem.starts_with("LPT")) && stem.len() == 4 && stem.as_bytes()[3].is_ascii_alphanumeric());
    (!cleaned.is_empty() && !reserved && cleaned != "." && cleaned != "..").then_some(cleaned)
}

/// Only a file directly inside the agent's Outbox: no subfolders, links are the guest's problem (it reads as
/// `agent` and the host only receives bytes).
pub fn outbox_file(path: &str) -> Option<String> {
    let lower = path.to_lowercase();
    if !lower.starts_with(&OUTBOX.to_lowercase()) || path.contains('/') {
        return None;
    }
    let rest = &path[OUTBOX.len()..];
    if rest.is_empty() || rest.contains('\\') || rest.contains(':') || rest == "." || rest == ".." {
        return None;
    }
    Some(rest.to_string())
}

fn new_offer(name: &str, path: &str, note: &str, client: Option<&str>, ctx: &Ctx) -> Result<Value, CmdError> {
    let reg = reg_by_name(name).ok_or_else(|| CmdError { code: "not_found".into(), message: format!("No agent on '{name}'.") })?;
    if let Some(id) = client {
        admit(id, &reg.vm_id, &reg.name, ctx)?;
    } else if ctx.is_agent_side() {
        return err("not_taken", "Connection is required.");
    }
    let Some(guest_name) = outbox_file(path) else {
        return err("denied", format!("Only files directly inside {OUTBOX} can leave the machine."));
    };
    let Some(file_name) = safe_file_name(&guest_name) else { return err("bad_request", "That file name can't be saved on this PC.") };
    let conn = conn_of(&reg.vm_id).ok_or_else(|| CmdError { code: "off".into(), message: format!("The agent on '{}' isn't connected.", reg.name) })?;
    // The size, as the guest reports it (shown to the person; the copy re-checks every byte count).
    let size = conn.request("files.list", &json!({ "path": OUTBOX.trim_end_matches('\\') }), None, Duration::from_secs(10), client).ok()
        .and_then(|(v, _)| {
            let list = v.get("entries").or(v.get("items")).cloned().unwrap_or(v);
            list.as_array()?.iter().find(|e| e["name"].as_str() == Some(guest_name.as_str())).and_then(|e| e["size"].as_u64())
        });
    if size.is_some_and(|s| s > MAX_OFFER_BYTES) {
        return err("too_large", "Files over 2 GB can't leave the machine this way.");
    }
    let mut offers = lock(&broker().offers);
    if offers.iter().filter(|o| o.vm_id == reg.vm_id && o.state == "pending").count() >= 50 {
        return err("busy", "Too many files are waiting for the person's approval.");
    }
    if offers.len() >= 500 {
        if let Some(i) = offers.iter().position(|o| o.state != "pending" && o.state != "copying") {
            offers.remove(i);
        }
    }
    let id = wire::hex(&wire::random::<8>());
    let note = clean(note, 500);
    offers.push(Offer { id: id.clone(), vm_id: reg.vm_id.clone(), path: path.to_string(), file_name: file_name.clone(), size, note: note.clone(),
        state: "pending".into(), created: now_ms(), host_path: None, error: None, client: client.map(str::to_string) });
    drop(offers);
    vm_log(&reg, json!({ "event": "offer", "id": id, "file": file_name, "size": size, "note": note }));
    Ok(json!({ "offerId": id }))
}

/// An approved offer being copied: where it comes from and how to read it from the guest.
pub(crate) struct OfferJob {
    pub machine: String,
    pub file_name: String,
    conn: Option<Arc<Conn>>,
    path: String,
}

impl OfferJob {
    /// One piece of the file: (the file's total size as the guest says, the bytes from `offset`).
    pub fn read(&self, offset: u64, length: u64) -> Result<(Option<u64>, Vec<u8>), String> {
        let c = self.conn.as_ref().ok_or("The agent isn't connected.")?;
        let (v, blob) = c.request("files.read", &json!({ "path": self.path, "offset": offset, "length": length }), None, Duration::from_secs(120), None)
            .map_err(|(code, m)| format!("{code}: {m}"))?;
        Ok((v["size"].as_u64(), blob.unwrap_or_default()))
    }
}

/// For offer.rs: takes a pending offer (marks it as being copied, so it is answered once) or declines it.
pub(crate) fn take_offer(id: &str, approve: bool) -> Result<Option<OfferJob>, CmdError> {
    let (vm_id, path, file_name) = {
        let mut offers = lock(&broker().offers);
        let Some(o) = offers.iter_mut().find(|o| o.id == id) else { return err("not_found", "No such offer.") };
        if o.state != "pending" {
            return err("bad_request", format!("This offer is already {}.", o.state));
        }
        if !approve {
            o.state = "declined".into();
            return Ok(None);
        }
        o.state = "copying".into();
        (o.vm_id.clone(), o.path.clone(), o.file_name.clone())
    };
    let machine = reg_by_id(&vm_id).map(|r| r.name).unwrap_or_else(|| vm_id.clone());
    Ok(Some(OfferJob { machine, file_name, conn: conn_of(&vm_id), path }))
}

pub(crate) fn finish_offer(id: &str, state: &str, host_path: Option<String>, error: Option<String>) -> Value {
    let mut offers = lock(&broker().offers);
    let Some(o) = offers.iter_mut().find(|o| o.id == id) else { return Value::Null };
    o.state = state.into();
    o.host_path = host_path;
    o.error = error;
    let o = o.clone();
    drop(offers);
    let reg = reg_by_id(&o.vm_id);
    if let Some(r) = &reg {
        vm_log(r, json!({ "event": "offer_resolved", "id": o.id, "state": o.state, "hostPath": o.host_path, "error": o.error }));
    }
    o.to_json(&reg.map(|r| r.name).unwrap_or_default())
}

pub(crate) const MAX_OFFER: u64 = MAX_OFFER_BYTES;
pub(crate) const CHUNK: u64 = READ_CHUNK;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outbox_paths() {
        assert_eq!(outbox_file(r"C:\Users\agent\Desktop\Outbox\report.html").as_deref(), Some("report.html"));
        assert_eq!(outbox_file(r"c:\users\AGENT\desktop\outbox\a.png").as_deref(), Some("a.png"));
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outbox\..\secret").is_none());
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outbox\sub\a.txt").is_none());
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outbox\a.txt:stream").is_none());
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outbox\").is_none());
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outboxx\a").is_none());
        assert!(outbox_file(r"C:\Windows\a.txt").is_none());
        assert!(outbox_file("C:/Users/agent/Desktop/Outbox/a.txt").is_none());
    }

    #[test]
    fn file_names() {
        assert_eq!(safe_file_name("report.html").as_deref(), Some("report.html"));
        assert_eq!(safe_file_name("a<b>c?.txt").as_deref(), Some("abc.txt"));
        assert_eq!(safe_file_name("name. . ").as_deref(), Some("name"));
        assert!(safe_file_name("CON").is_none());
        assert!(safe_file_name("con.txt").is_none());
        assert!(safe_file_name("COM1.log").is_none());
        assert!(safe_file_name("...").is_none());
        assert_eq!(safe_file_name("COMMON.txt").as_deref(), Some("COMMON.txt"));
        assert_eq!(safe_file_name("x\u{202e}y\u{7}").as_deref(), Some("xy"));
    }

    #[test]
    fn bounded_values() {
        let long = "a".repeat(1000);
        let v = bounded(&json!({ "s": long, "deep": {"a": {"b": {"c": {"d": 1}}}} }), 3);
        assert_eq!(v["s"].as_str().unwrap().len(), 300);
        assert!(v["deep"]["a"]["b"].is_null());
    }
}
