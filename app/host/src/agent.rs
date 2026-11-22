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
const SERVICE_KEY: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\94aca5ef-a5b6-45a9-8c15-c7724a63f3da";
const LEGACY_SERVICE_KEY: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{94aca5ef-a5b6-45a9-8c15-c7724a63f3da}";
/// Mixed into the DPAPI encryption of each VM's secret (Install-GpuVMAgent uses the same).
const SECRET_ENTROPY: &[u8] = b"GpuVM agent secret v1";

const PING_EVERY: Duration = Duration::from_secs(2);
const DEAD_AFTER_MS: u32 = 6000;
const HANDSHAKE_MS: u32 = 5000;
/// Connections still in their handshake, across all VMs and per VM.
const MAX_PRE_AUTH: usize = 16;
const MAX_PRE_AUTH_PER_VM: usize = 4;
/// More frames than this in one second closes the connection (a flood, not an agent).
const MAX_FRAMES_PER_SEC: u32 = 2000;
const MAX_EVENTS_PER_SEC: f64 = 10.0;
const MAX_IN_FLIGHT: usize = 32;
const MAX_TIMEOUT_SEC: u64 = 600;
const MAX_OFFER_BYTES: u64 = 2 << 30;
const READ_CHUNK: u64 = 8 << 20;
/// The agent's Outbox, relative to its home (files.* take paths relative to the agent's home).
const OUTBOX: &str = r"Desktop\Outbox\";
const DEFAULT_HOME: &str = r"C:\Users\agent";

/// The guest methods of protocol.md; anything else is refused before it reaches a guest.
const METHODS: &[&str] = &["agent.info", "screen.capture", "screen.state", "screen.refresh", "input.act", "ui.tree", "ui.invoke", "exec.run",
    "files.list", "files.read", "files.write"];
const EVENTS: &[&str] = &["screen", "secure_desktop", "signed_in", "foreground", "error_box"];

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
    #[cfg(test)]
    if let Some(dir) = tests::TEST_AGENTS.get() {
        return dir.clone();
    }
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
/// Stores a VM's new secret (Install-GpuVMAgent, through the module's administrators-only pipe). Done here, as
/// SYSTEM: the file is created with its final SYSTEM-only ACL and filled in one go, then renamed over the old one, so
/// it is never readable by anyone else and an elevated user (the app's bridge) never has to handle a file it can't open.
fn store_secret(vm_id: &str, secret: &[u8]) -> Result<(), String> {
    use windows_sys::Win32::Security::Authorization::*;
    use windows_sys::Win32::Storage::FileSystem::*;
    if secret.len() != 32 {
        return Err("the secret must be 32 bytes".into());
    }
    let dir = agents_dir().join(vm_id);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let input = CRYPT_INTEGER_BLOB { cbData: 32, pbData: secret.as_ptr() as *mut u8 };
    let entropy = CRYPT_INTEGER_BLOB { cbData: SECRET_ENTROPY.len() as u32, pbData: SECRET_ENTROPY.as_ptr() as *mut u8 };
    let mut output = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    if unsafe {
        CryptProtectData(&input, std::ptr::null(), &entropy, std::ptr::null(), std::ptr::null(), CRYPTPROTECT_LOCAL_MACHINE | CRYPTPROTECT_UI_FORBIDDEN, &mut output)
    } == 0 {
        return Err(crate::win::last_error("CryptProtectData"));
    }
    let protected = unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize) }.to_vec();
    unsafe { LocalFree(output.pbData.cast()) };
    let mut sd = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide("O:SYD:P(A;;FA;;;SY)").as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        return Err(crate::win::last_error("SDDL"));
    }
    let sa = windows_sys::Win32::Security::SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<windows_sys::Win32::Security::SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    let temp = dir.join("secret.new");
    let _ = std::fs::remove_file(&temp);
    let h = unsafe {
        CreateFileW(crate::win::wide_path(&temp).as_ptr(), GENERIC_WRITE, 0, &sa, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, std::ptr::null_mut())
    };
    unsafe { LocalFree(sd) };
    if h == INVALID_HANDLE_VALUE {
        return Err(crate::win::last_error("CreateFileW secret"));
    }
    let mut file = unsafe { <std::fs::File as std::os::windows::io::FromRawHandle>::from_raw_handle(h) };
    let written = file.write_all(&protected).and_then(|_| file.sync_all());
    drop(file);
    if let Err(e) = written {
        let _ = std::fs::remove_file(&temp);
        return Err(e.to_string());
    }
    std::fs::rename(&temp, dir.join("secret")).map_err(|e| {
        let _ = std::fs::remove_file(&temp);
        e.to_string()
    })
}

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
    // The first builds wrote the name with braces; Hyper-V's own entries (and its docs) have none.
    unsafe { RegDeleteKeyW(HKEY_LOCAL_MACHINE, wide(LEGACY_SERVICE_KEY).as_ptr()) };
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
    unsafe {
        RegDeleteKeyW(HKEY_LOCAL_MACHINE, wide(SERVICE_KEY).as_ptr());
        RegDeleteKeyW(HKEY_LOCAL_MACHINE, wide(LEGACY_SERVICE_KEY).as_ptr());
    }
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
    /// The machine this connection serves (to see its pause right before a session's request goes out).
    vm_id: String,
    /// Held while a session's request is checked and sent, and while a pause cancels requests: a pause never slips
    /// between the two (review 3, #4).
    dispatch: Mutex<()>,
    sock: Sock,
    out: Mutex<Sealer>,
    pending: Mutex<HashMap<u64, Pending>>,
    next_req: AtomicU64,
    agent: String,
    since: u64,
    dead: AtomicBool,
    info: Mutex<Value>,
    events: Mutex<Map<String, Value>>,
    /// When the agent last said its screen changed size (ms since 1970; 0 = not since it connected).
    screen_changed: AtomicU64,
    /// An agent.info refresh is on its way (one at a time, whatever the events).
    refreshing: AtomicBool,
    /// Since when (ms) someone is signed in and the agent sees no display (0 = not so).
    blank_since: AtomicU64,
}

impl Conn {
    /// Sends one signed JSON frame, and its blob right after it (under the same lock, so nothing comes between).
    fn send(&self, obj: Value, blob: Option<&[u8]>) -> Result<(), String> {
        let Value::Object(mut obj) = obj else { return Err("not an object".into()) };
        if let Some(b) = blob {
            wire::describe_blob(&mut obj, b);
        }
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
        let _dispatch = self.dispatch.lock().unwrap_or_else(|e| e.into_inner());
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
            // A session's request goes out only if the machine isn't paused at that very moment.
            let _dispatch = self.dispatch.lock().unwrap_or_else(|e| e.into_inner());
            if client.is_some() && lock(&broker().machines).get(&self.vm_id).is_some_and(|m| m.paused.is_some()) {
                return Err(("paused".into(), "The person took control of this machine.".into()));
            }
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
    pre_auth: usize,
    failures: VecDeque<Instant>,
    last_error: Option<String>,
    /// When the person last gave control back (the agent should look at the screen again).
    resumed_at: Option<u64>,
    /// The one automatic power cycle for a machine whose agent sees no display: 0 none yet, 1 running, 2 done.
    display_repair: u8,
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
    /// What the session works on (Lock-GpuVMAgent -Task), shown in the app.
    task: Option<String>,
    /// Last requests, newest last (the app shows them newest first), and the images of the last captures.
    actions: VecDeque<Value>,
    captures: VecDeque<(u64, String, Vec<u8>)>,
    last_activity: Instant,
    /// For its line in the history (agent_log.rs): the machines it took, scripts run, approvals asked, files offered,
    /// times the person took control, and how it ended when not by itself ("stopped", "limit").
    machines: Vec<String>,
    runs: u64,
    approvals: u64,
    offers: u64,
    controls: u64,
    ended: Option<&'static str>,
}

const MAX_ACTIONS: usize = 30;
const MAX_CAPTURES: usize = 10;

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
    expires: u64,
    host_path: Option<String>,
    error: Option<String>,
    client: Option<String>,
    client_name: Option<String>,
}

impl Offer {
    fn to_json(&self, machine: &str) -> Value {
        json!({ "id": self.id, "machine": machine, "connection": self.client, "clientName": self.client_name, "name": self.file_name,
            "path": self.path, "sizeBytes": self.size, "note": self.note, "createdAt": self.created, "expiresAt": self.expires,
            "state": self.state, "savedTo": self.host_path, "error": self.error })
    }
}

/// Something an agent session asks the person for (approval level "with approval"): network, an administrator's
/// step, going back to a restore point, deleting a machine...
#[derive(Clone)]
struct Request {
    id: String,
    connection: String,
    client_name: String,
    vm_id: String,
    machine: String,
    kind: String,
    title: String,
    reason: String,
    created: u64,
    expires: u64,
    state: String,
    for_task: bool,
    used: bool,
    /// Held by a command that is running with it (spent if that command succeeds).
    reserved: bool,
    resolved: Option<u64>,
    /// Kind "send": the exact paths of this PC, and what they held when the session asked (files, bytes).
    send: Option<SendSet>,
}

/// What a "send" request lets one Send-GpuVMFile copy: these paths, as big as they were when the person saw them.
#[derive(Clone, PartialEq, Debug)]
struct SendSet {
    paths: Vec<String>,
    files: u64,
    bytes: u64,
}

impl Request {
    fn to_json(&self) -> Value {
        json!({ "id": self.id, "connection": self.connection, "clientName": self.client_name, "machine": self.machine, "kind": self.kind,
            "title": self.title, "reason": self.reason, "createdAt": self.created, "expiresAt": self.expires, "state": self.state,
            "forTask": self.for_task,
            "paths": self.send.as_ref().map(|s| json!(s.paths)), "files": self.send.as_ref().map(|s| s.files),
            "bytes": self.send.as_ref().map(|s| s.bytes) })
    }
}

struct Broker {
    conns: Mutex<HashMap<String, Arc<Conn>>>,
    machines: Mutex<HashMap<String, Machine>>,
    clients: Mutex<HashMap<String, Client>>,
    offers: Mutex<Vec<Offer>>,
    requests: Mutex<Vec<Request>>,
    claims: Mutex<HashMap<String, String>>,
    /// Disposable copies each agent session made (lowercase name → connection): only it may delete one at once.
    made: Mutex<HashMap<String, String>>,
    /// The VM id of each machine a session made (by name, lowercase): `claims` and `made` are keyed by VM id, so a
    /// later machine with the same name is never that session's (review 2, #7).
    names: Mutex<HashMap<String, String>>,
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
        requests: Mutex::new(Vec::new()),
        claims: Mutex::new(HashMap::new()),
        made: Mutex::new(HashMap::new()),
        names: Mutex::new(HashMap::new()),
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

// ---------------------------------------------------------------- sweeping registrations of deleted VMs

/// Registrations (and so per-VM secrets) younger than this are left alone: an install may be writing one.
const SWEEP_MIN_AGE: Duration = Duration::from_secs(600);

/// The VmIds Hyper-V knows now, from Get-VM in GpuVM's own PowerShell (administrators-only folder). None when that
/// can't be told for sure: then nothing is deleted.
fn hyperv_vm_ids() -> Option<Vec<String>> {
    let local = crate::server::install_dir().join("pwsh").join("pwsh.exe");
    let installed = PathBuf::from(std::env::var("ProgramFiles").unwrap_or(r"C:\Program Files".into())).join("GpuVM").join("pwsh").join("pwsh.exe");
    let pwsh = [local, installed].into_iter().find(|p| p.is_file())?;
    let script = "$ErrorActionPreference='Stop'; Import-Module Hyper-V; $ids = @(Get-VM).Id.Guid; 'OK:' + ($ids -join ',')";
    let output = std::process::Command::new(pwsh)
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
        .stdin(std::process::Stdio::null())
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    parse_vm_ids(&String::from_utf8_lossy(&output.stdout))
}

/// The VM id Hyper-V has now for a machine name: `Some(None)` when there is no such machine, `None` when it can't be
/// told (then nothing is assumed). The name is a plain machine name (no wildcards) and reaches PowerShell as an
/// environment variable, never as code.
fn hyperv_id_of(name: &str) -> Option<Option<String>> {
    if name.is_empty() || name.len() > 40 || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Some(None);
    }
    #[cfg(test)]
    {
        return Some(tests::TEST_HV.lock().unwrap_or_else(|e| e.into_inner()).get(&name.to_lowercase()).cloned());
    }
    #[allow(unreachable_code)]
    {
        let local = crate::server::install_dir().join("pwsh").join("pwsh.exe");
        let installed = PathBuf::from(std::env::var("ProgramFiles").unwrap_or(r"C:\Program Files".into())).join("GpuVM").join("pwsh").join("pwsh.exe");
        let pwsh = [local, installed].into_iter().find(|p| p.is_file())?;
        let script = "$ErrorActionPreference='Stop'; Import-Module Hyper-V; $vm = Get-VM | Where-Object Name -eq $env:GPUVM_VM_NAME | Select-Object -First 1; 'OK:' + $(if ($vm) { $vm.Id.Guid } else { '' })";
        let output = std::process::Command::new(pwsh)
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
            .env("GPUVM_VM_NAME", name)
            .stdin(std::process::Stdio::null())
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let ids = parse_vm_ids(&String::from_utf8_lossy(&output.stdout))?;
        Some(ids.into_iter().next())
    }
}

/// Deletes a VM's registration folder (agent.json and its SYSTEM-only secret) and forgets the machine. `Ok(false)`
/// when there was none. The id is a canonical VM id (checked by the caller), so the path stays inside agents\.
fn remove_registration(vm_id: &str) -> Result<bool, String> {
    let dir = agents_dir().join(vm_id);
    lock(&broker().machines).remove(vm_id);
    if !dir.exists() {
        return Ok(false);
    }
    std::fs::remove_dir_all(&dir).map_err(|e| e.to_string())?;
    log(&format!("agent: removed the registration and secret of VM {vm_id}"));
    Ok(true)
}

/// `OK:<id>,<id>` (the last line); anything else means the list isn't known.
fn parse_vm_ids(text: &str) -> Option<Vec<String>> {
    let line = text.lines().rev().find(|l| !l.trim().is_empty())?.trim();
    let list = line.strip_prefix("OK:")?;
    let mut ids = Vec::new();
    for part in list.split(',').filter(|p| !p.is_empty()) {
        ids.push(hv::fmt_guid(hv::parse_guid(part)?));
    }
    Some(ids)
}

/// The registration folders to delete: named after a VmId Hyper-V doesn't have, and older than the minimum age.
fn orphans(folders: &[(String, Duration)], existing: &[String]) -> Vec<String> {
    folders.iter()
        .filter(|(name, age)| hv::parse_guid(name).is_some() && *age >= SWEEP_MIN_AGE && !existing.contains(&name.to_lowercase()))
        .map(|(name, _)| name.clone())
        .collect()
}

/// Deletes the registrations (agent.json and the DPAPI secret) of VMs that no longer exist: a secret never outlives
/// its machine. At the service's start and every hour; logged.
pub fn sweep_registrations() -> Vec<String> {
    let Some(existing) = hyperv_vm_ids() else {
        log("agent: sweep skipped (Hyper-V's machines couldn't be listed)");
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(agents_dir()) else { return Vec::new() };
    let folders: Vec<(String, Duration)> = entries.flatten()
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| {
            let age = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).unwrap_or_default();
            (e.file_name().to_string_lossy().to_string(), age)
        })
        .collect();
    let mut removed = Vec::new();
    prune_made(&existing);
    for name in orphans(&folders, &existing) {
        match std::fs::remove_dir_all(agents_dir().join(&name)) {
            Ok(()) => {
                log(&format!("agent: removed the registration and secret of VM {name} (it no longer exists)"));
                lock(&broker().machines).remove(&name.to_lowercase());
                removed.push(name);
            }
            Err(e) => log(&format!("agent: couldn't remove the registration of VM {name}: {e}")),
        }
    }
    removed
}

fn listen_loop() {
    hv::startup();
    std::thread::spawn(|| loop {
        sweep_registrations();
        std::thread::sleep(Duration::from_secs(3600));
    });
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
        // Handshakes in progress: at most 4 per VM and 16 in all; more are closed at once. A count of connections
        // at the same time, not a rate: a rate a flood keeps full would also lock out the real agent's redials (lab
        // 052 saw that). A guest can still keep its own 4 slots busy, which only hurts that VM's channel.
        let admitted = {
            let mut machines = lock(&broker().machines);
            let m = machines.entry(vm_id.clone()).or_default();
            let ok = m.pre_auth < MAX_PRE_AUTH_PER_VM && broker().pre_auth.load(Ordering::SeqCst) < MAX_PRE_AUTH;
            if ok {
                m.pre_auth += 1;
                broker().pre_auth.fetch_add(1, Ordering::SeqCst);
            }
            ok
        };
        if admitted {
            std::thread::spawn(move || serve_agent(sock, vm_id));
        }
    }
}

struct PreAuth(Option<String>);
impl PreAuth {
    fn done(&mut self) {
        if let Some(vm_id) = self.0.take() {
            broker().pre_auth.fetch_sub(1, Ordering::SeqCst);
            if let Some(m) = lock(&broker().machines).get_mut(&vm_id) {
                m.pre_auth = m.pre_auth.saturating_sub(1);
            }
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
    let mut pre = PreAuth(Some(vm_id.clone()));
    let started = Instant::now();
    // Unknown VMs (no agent installed by GpuVM) are closed without a word.
    let Some(reg) = reg_by_id(&vm_id) else { return };
    let reg_ms = started.elapsed().as_secs_f64() * 1000.0;
    sock.set_timeouts(HANDSHAKE_MS, 10_000);
    let secret = match load_secret(&vm_id) {
        Ok(k) => k,
        Err(e) => {
            vm_log(&reg, json!({ "event": "refused", "reason": e }));
            return;
        }
    };
    let secret_ms = started.elapsed().as_secs_f64() * 1000.0 - reg_ms;
    let mut stream = &sock;
    let session = match wire::host_handshake(&mut stream, &secret, &vm_id) {
        Ok(s) => s,
        Err(reason) => {
            // At most 5 failures logged per VM every 10 s: a guest could otherwise fill the disk.
            let quiet = {
                let mut machines = lock(&broker().machines);
                let m = machines.entry(vm_id.clone()).or_default();
                m.failures.retain(|t| t.elapsed() < Duration::from_secs(10));
                m.failures.push_back(Instant::now());
                m.failures.len() > 5
            };
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
        vm_id: vm_id.clone(),
        dispatch: Mutex::new(()),
        sock,
        out: Mutex::new(sealer),
        pending: Mutex::new(HashMap::new()),
        next_req: AtomicU64::new(1),
        agent,
        since: now_ms(),
        dead: AtomicBool::new(false),
        info: Mutex::new(Value::Null),
        events: Mutex::new(Map::new()),
        screen_changed: AtomicU64::new(0),
        refreshing: AtomicBool::new(false),
        blank_since: AtomicU64::new(0),
    });
    // A new connection from the same VM replaces the old one (the agent restarted).
    if let Some(old) = lock(&broker().conns).insert(vm_id.clone(), conn.clone()) {
        old.close();
    }
    let round = |ms: f64| (ms * 100.0).round() / 100.0;
    vm_log(&reg, json!({ "event": "connected", "agent": conn.agent, "regMs": round(reg_ms), "secretMs": round(secret_ms),
        "totalMs": round(started.elapsed().as_secs_f64() * 1000.0) }));
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

/// The agent's screen changed size (`screen{w,h}` event): the agent info follows it and clients learn to recapture.
/// Sizes out of range (a hostile guest) are ignored.
fn note_screen(info: &Mutex<Value>, changed: &AtomicU64, data: &Value) -> bool {
    let size = |k: &str| data[k].as_u64().filter(|v| (1..=16384).contains(v));
    let (Some(w), Some(h)) = (size("w"), size("h")) else { return false };
    let mut info = lock(info);
    if !info.is_object() {
        *info = json!({});
    }
    info["screen"] = json!({ "w": w, "h": h });
    changed.store(now_ms(), Ordering::SeqCst);
    true
}

/// Someone signed in (`signed_in` event): the agent info says so at once, before its next refresh.
fn note_signed_in(info: &Mutex<Value>, data: &Value) {
    let mut info = lock(info);
    if !info.is_object() {
        *info = json!({});
    }
    // `user: null` is the agent saying nobody is signed in any more.
    match data["user"].as_str().filter(|u| !u.is_empty()) {
        Some(user) => {
            info["signedIn"] = json!(true);
            info["user"] = json!(clean(user, 120));
        }
        None => {
            info["signedIn"] = json!(false);
            info["user"] = Value::Null;
        }
    }
}

/// How long a signed-in agent has seen no display at all (agent.info `displays: []`), in ms; `None` when it sees
/// one or nobody is signed in. Starts counting the first time it is asked.
fn blank_for(info: &Value, since: &AtomicU64, now: u64) -> Option<u64> {
    let blank = info["signedIn"] == json!(true) && info["displays"].as_array().is_some_and(Vec::is_empty);
    if !blank {
        since.store(0, Ordering::SeqCst);
        return None;
    }
    let start = match since.compare_exchange(0, now, Ordering::SeqCst, Ordering::SeqCst) {
        Ok(_) => now,
        Err(t) => t,
    };
    Some(now.saturating_sub(start))
}

/// A signed-in agent with no display for this long is "no-display", not "ready" (lab 052: 4 of 13 copies never get
/// one; nothing the host can do brings it back).
const NO_DISPLAY_AFTER_MS: u64 = 20_000;

/// Turns the machine off and on (the module's Restart-GpuVMCold, which keeps a disposable copy from being swept while
/// it is off), in the background; the repair is "done" when it returns, whatever happened.
fn power_cycle(reg: Reg) {
    log(&format!("agent: {} sees no display; turning it off and on", reg.name));
    vm_log(&reg, json!({ "event": "display_repair" }));
    std::thread::spawn(move || {
        #[cfg(test)]
        tests::TEST_CYCLES.lock().unwrap_or_else(|e| e.into_inner()).push(reg.name.clone());
        #[cfg(not(test))]
        {
            let pwsh = crate::server::install_dir().join("pwsh").join("pwsh.exe");
            let module = crate::server::install_dir().join("gpuvm").join("src").join("GpuVM").join("GpuVM.psd1");
            let script = "$ErrorActionPreference='Stop'; Import-Module $env:GPUVM_MODULE; & (Get-Module GpuVM) { param($n) Restart-GpuVMCold -Name $n } $env:GPUVM_VM_NAME";
            let ok = std::process::Command::new(pwsh)
                .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script])
                .env("GPUVM_MODULE", module).env("GPUVM_VM_NAME", &reg.name)
                .stdin(std::process::Stdio::null()).output()
                .map(|o| o.status.success()).unwrap_or(false);
            log(&format!("agent: {} turned off and on: {}", reg.name, if ok { "done" } else { "failed" }));
        }
        lock(&broker().machines).entry(reg.vm_id.clone()).or_default().display_repair = 2;
    });
}

#[derive(Debug, PartialEq)]
enum Verdict {
    /// Nothing to say about its display.
    Fine,
    /// No display: turn it off and on now (the first time).
    Repair,
    /// The power cycle is under way.
    Repairing,
    /// Still none after the power cycle: say so (ms without a display).
    NoDisplay(u64),
    /// A display again after a repair: a later loss may be repaired once more.
    Recovered,
}

/// What a machine's display situation means: `connected` (its agent is), `blank` (ms signed in with no display),
/// `said` (the agent reported no display path), `repair` (0 none, 1 running, 2 done).
fn display_verdict(connected: bool, blank: Option<u64>, said: bool, signed_in: bool, repair: u8) -> Verdict {
    if repair == 1 {
        return Verdict::Repairing;
    }
    match blank {
        Some(ms) if ms > NO_DISPLAY_AFTER_MS || said => if repair == 0 { Verdict::Repair } else { Verdict::NoDisplay(ms) },
        Some(_) => Verdict::Fine,
        None if connected && signed_in && repair == 2 => Verdict::Recovered,
        None => Verdict::Fine,
    }
}

/// The longest repaint burst (screen.refresh repeatMs), and the one burst per machine at a time.
const REFRESH_BURST_MAX_MS: u64 = 15_000;
static BURSTS: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// screen.refresh every 250 ms for `ms`, in the background; a burst already running for that machine is enough.
fn refresh_burst(conn: Arc<Conn>, ms: u64, client: Option<String>) {
    {
        let mut running = lock(&BURSTS);
        if running.contains(&conn.vm_id) {
            return;
        }
        running.push(conn.vm_id.clone());
    }
    std::thread::spawn(move || {
        let end = Instant::now() + Duration::from_millis(ms);
        while Instant::now() < end && !conn.dead.load(Ordering::SeqCst) {
            let _ = conn.request("screen.refresh", &json!({}), None, Duration::from_secs(3), client.as_deref());
            std::thread::sleep(Duration::from_millis(250));
        }
        lock(&BURSTS).retain(|v| v != &conn.vm_id);
    });
}

/// Asks the agent for agent.info again, in the background, one request at a time.
fn refresh_info(conn: Arc<Conn>) {
    if conn.refreshing.swap(true, Ordering::SeqCst) {
        return;
    }
    std::thread::spawn(move || {
        if let Ok((info, _)) = conn.request("agent.info", &json!({}), None, Duration::from_secs(10), None) {
            *lock(&conn.info) = bounded(&info, 3);
        }
        conn.refreshing.store(false, Ordering::SeqCst);
    });
}

/// Reads the guest's frames until the connection ends; returns why it ended.
fn read_loop(conn: &Arc<Conn>, opener: &mut Opener) -> String {
    let mut stream = &conn.sock;
    let mut window = Instant::now();
    let mut frames = 0u32;
    let mut tokens = MAX_EVENTS_PER_SEC * 2.0;
    let mut last_refill = Instant::now();
    let mut dropped_events = 0u64;
    loop {
        let frame = match wire::read_frame(&mut stream, wire::MAX_JSON) {
            Ok(f) => f,
            Err(e) if e.contains("10060") => return "no heartbeat for 6 s".into(),
            Err(e) if e.contains("fill whole buffer") => return "closed by the guest".into(),
            Err(e) => return e,
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
                        // The blob carries no MAC itself: its length and SHA-256 are in the signed frame before it.
                        Ok(Frame::Blob(b)) => match wire::check_blob(&msg, &b) {
                            Ok(()) => Some(b),
                            Err(e) => return e,
                        },
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
                if name == "screen" {
                    note_screen(&conn.info, &conn.screen_changed, &data);
                }
                if name == "signed_in" {
                    note_signed_in(&conn.info, &data);
                }
                lock(&conn.events).insert(name.to_string(), json!({ "data": data, "at": now_ms() }));
                // What Get-GpuVMAgent shows follows the machine: someone signed in, or the screen changed, means its
                // displays and sign-in are asked again (agent-mcp 2026-11-19: a stale signedIn:false made a new copy
                // wait 600 s for "ready").
                if name == "signed_in" || name == "screen" {
                    refresh_info(conn.clone());
                }
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
    /// This pipe connection said it acts for a model (Register-GpuVMAgentPipe): limited like an agent session for as
    /// long as it is open, and never taken for the person.
    agent_pipe: bool,
}

/// Processes that ever registered as agents (a session or an agent pipe), with an open handle to each: while the
/// handle is held Windows never gives the pid to another process, and the entry goes once the process ended.
/// Ending a session or closing a pipe doesn't make the process the person again (review 2, #2b).
struct AgentProcess(HANDLE);
unsafe impl Send for AgentProcess {}
impl Drop for AgentProcess {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseHandle(self.0) };
        }
    }
}

static AGENT_PIDS: OnceLock<Mutex<HashMap<u32, AgentProcess>>> = OnceLock::new();

fn agent_pids() -> std::sync::MutexGuard<'static, HashMap<u32, AgentProcess>> {
    lock(AGENT_PIDS.get_or_init(|| Mutex::new(HashMap::new())))
}

/// Marks a process as an agent's for as long as it lives.
fn mark_agent_pid(pid: u32) {
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_SYNCHRONIZE};
    let mut map = agent_pids();
    if map.contains_key(&pid) {
        return;
    }
    // In tests the pids are made up: remembered without a handle.
    let h = unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    map.insert(pid, AgentProcess(h));
}

/// Whether `pid` belongs to a live process that registered as an agent.
fn is_agent_pid(pid: u32) -> bool {
    use windows_sys::Win32::System::Threading::WaitForSingleObject;
    let mut map = agent_pids();
    let Some(p) = map.get(&pid) else { return false };
    if p.0.is_null() {
        return true;
    }
    // Only a process seen to have ended (WAIT_OBJECT_0) stops being an agent's; anything else (still running, or the
    // wait failing) keeps it one. Ended: its handle closes and the pid may be reused afterwards.
    if unsafe { WaitForSingleObject(p.0, 0) } != 0 {
        return true;
    }
    map.remove(&pid);
    false
}

impl Ctx {
    pub fn new(pipe: HANDLE, pid: u32, admin: bool) -> Self {
        Ctx { pipe, pid, admin, owned: Vec::new(), agent_pipe: false }
    }

    /// Whether this pipe connection acts for a model (the gate limits its module commands too).
    pub fn is_agent_pipe(&self) -> bool {
        self.agent_pipe
    }

    /// A process that registered as an agent client (the MCP server) acts for a model: it never approves anything.
    fn is_agent_side(&self) -> bool {
        self.agent_pipe || is_agent_pid(self.pid) || lock(&broker().clients).values().any(|c| c.pid == self.pid)
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

#[derive(Debug)]
pub struct CmdError {
    pub code: String,
    pub message: String,
}

fn err<T>(code: &str, message: impl Into<String>) -> Result<T, CmdError> {
    Err(CmdError { code: code.into(), message: message.into() })
}

/// The commands the broker answers itself, with their exact arguments (exact case, like the bridge).
const COMMANDS: &[(&str, &[&str])] = &[
    // Machines with an agent, and the channel itself.
    ("Get-GpuVMAgent", &["Name"]),
    ("Get-GpuVMAgentBroker", &[]),
    // One request to a machine's agent.
    ("Invoke-GpuVMAgent", &["Name", "Method", "Params", "TimeoutSec", "Connection", "Blob", "Note", "Intent"]),
    // Agent sessions (the MCP server registers one per client), what they do, and taking a machine.
    ("Connect-GpuVMAgentClient", &["Client"]),
    // The MCP server's first line on every pipe connection it opens: from then on that connection is an agent's
    // (deny by default), even before or without a session. It can't be undone on that connection.
    ("Register-GpuVMAgentPipe", &["Connection"]),
    ("Disconnect-GpuVMAgentClient", &["Connection"]),
    ("Get-GpuVMAgentClient", &["Connection"]),
    ("Get-GpuVMAgentCapture", &["Connection", "Action"]),
    ("Lock-GpuVMAgent", &["Name", "Connection", "Task"]),
    ("Unlock-GpuVMAgent", &["Name", "Connection"]),
    // Control: the person pauses, takes control, gives it back, stops a session; the agent asks for the person.
    ("Request-GpuVMHuman", &["Name", "Connection", "Message"]),
    ("Suspend-GpuVMAgent", &["Name", "Connection", "Reason", "Message"]),
    ("Resume-GpuVMAgent", &["Name", "Connection"]),
    ("Stop-GpuVMAgentClient", &["Connection", "All"]),
    // Approvals ("with approval" actions) and files leaving a machine.
    ("New-GpuVMAgentRequest", &["Name", "Connection", "Kind", "Title", "Reason", "TimeoutSec", "Path", "SizeBytes", "Files"]),
    ("Get-GpuVMAgentRequest", &["Id"]),
    ("Resolve-GpuVMAgentRequest", &["Id", "Allow", "ForTask"]),
    // A session withdraws its own pending request (an approval or a call for a human); never the person's pause.
    ("Revoke-GpuVMAgentRequest", &["Id", "Connection"]),
    ("New-GpuVMAgentOffer", &["Name", "Path", "Note", "Connection"]),
    ("Get-GpuVMAgentOffer", &["Id", "Name"]),
    ("Resolve-GpuVMAgentOffer", &["Id", "Accept"]),
    // What sessions do, live (the viewer's overlay) and once finished (the Agents page's history): the person's only.
    ("Wait-GpuVMAgentActivity", &["After", "TimeoutMs"]),
    ("Get-GpuVMAgentHistory", &["Limit"]),
    // The person's settings.
    ("Get-GpuVMAgentSettings", &[]),
    ("Set-GpuVMAgentSettings", &["MaxSteps", "MaxMinutes", "ApprovalTimeoutSec"]),
    ("Set-GpuVMAgentClient", &["Name", "ClientApprovals"]),
    // The module's Install-GpuVMAgent only (administrators' pipe): the service keeps the new secret as SYSTEM.
    ("Set-GpuVMAgentSecret", &["VmId", "Secret"]),
    // Remove-GpuVM and Uninstall-GpuVMAgent: the secret is SYSTEM-only, so only the service can delete it.
    ("Remove-GpuVMAgentRegistration", &["VmId"]),
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

/// What an agent caller may read: only its own sessions (review 2, #8). `None` = the person or the module, who see all.
fn own_scope(ctx: &Ctx) -> Option<Vec<String>> {
    if !ctx.is_agent_side() {
        return None;
    }
    Some(lock(&broker().clients).iter().filter(|(_, c)| c.pid == ctx.pid).map(|(id, _)| id.clone()).collect())
}

fn person_only(ctx: &Ctx, what: &str) -> Result<(), CmdError> {
    if ctx.is_agent_side() { err("denied", format!("Only the person can {what}.")) } else { Ok(()) }
}

fn need<'a>(v: Option<&'a str>, what: &str) -> Result<&'a str, CmdError> {
    v.ok_or_else(|| CmdError { code: "bad_request".into(), message: format!("{what} is required.") })
}

fn find_reg(name: &str) -> Result<Reg, CmdError> {
    reg_by_name(name).ok_or_else(|| CmdError { code: "not_found".into(), message: format!("No agent on '{name}'.") })
}

/// The machines a Suspend/Resume names: one by Name, or those taken by a session (`Connection`, "*" = all).
fn targets(name: Option<&str>, connection: Option<&str>) -> Result<Vec<Reg>, CmdError> {
    if let Some(n) = name {
        let reg = find_reg(n)?;
        // Name and Connection: that machine, only if that session holds it.
        if let Some(c) = connection.filter(|c| *c != "*") {
            let holder = lock(&broker().machines).get(&reg.vm_id).and_then(|m| m.taken_by.clone());
            if holder.as_deref() != Some(c) {
                return err("not_found", format!("'{}' isn't held by that agent session.", reg.name));
            }
        }
        return Ok(vec![reg]);
    }
    let c = need(connection, "Name or Connection")?;
    let taken: Vec<String> = lock(&broker().machines).iter()
        .filter(|(_, m)| m.taken_by.as_deref().is_some_and(|t| c == "*" || t == c)).map(|(vm, _)| vm.clone()).collect();
    Ok(registrations().into_iter().filter(|r| taken.contains(&r.vm_id)).collect())
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
    let flag = |k: &str| args.get(k) == Some(&json!(true));
    match cmd {
        "Get-GpuVMAgent" => Ok(get_agents(s("Name"))),
        "Get-GpuVMAgentBroker" => {
            let mut v = lock(&broker().listener).clone();
            v["connected"] = json!(lock(&broker().conns).len());
            v["serviceId"] = json!(hv::fmt_guid(SERVICE_ID));
            Ok(v)
        }
        "Invoke-GpuVMAgent" => invoke(args, ctx),
        "Connect-GpuVMAgentClient" => {
            // Registering a session also marks the connection for good: closing the session doesn't lift the limits.
            if !ctx.admin {
                ctx.agent_pipe = true;
                mark_agent_pid(ctx.pid);
            }
            connect_client(args.get("Client").unwrap_or(&Value::Null), ctx)
        }
        "Register-GpuVMAgentPipe" => {
            if ctx.admin {
                return err("denied", "The module's pipe isn't an agent's.");
            }
            // Marked first: even a wrong Connection leaves this connection (and process) an agent's.
            ctx.agent_pipe = true;
            mark_agent_pid(ctx.pid);
            if let Some(c) = s("Connection") {
                own_client(c, ctx)?;
            }
            Ok(json!({ "agent": true }))
        }
        "Disconnect-GpuVMAgentClient" => {
            let id = need(s("Connection"), "Connection")?;
            own_client(id, ctx)?;
            disconnect_client(id);
            ctx.owned.retain(|c| c != id);
            Ok(json!({}))
        }
        "Get-GpuVMAgentClient" => match own_scope(ctx) {
            None => Ok(get_clients(s("Connection"))),
            Some(own) => match s("Connection") {
                Some(c) if own.iter().any(|o| o == c) => Ok(get_clients(Some(c))),
                Some(_) => err("not_found", "Unknown agent connection."),
                None => Ok(Value::Array(own.iter().filter_map(|c| get_clients(Some(c)).as_array().and_then(|a| a.first().cloned())).collect())),
            },
        },
        "Get-GpuVMAgentCapture" => {
            let id = need(s("Connection"), "Connection")?;
            if own_scope(ctx).is_some_and(|own| !own.iter().any(|o| o == id)) {
                return err("not_found", "Unknown agent connection.");
            }
            let action = args.get("Action").and_then(Value::as_u64).ok_or_else(|| CmdError { code: "bad_request".into(), message: "Action is required.".into() })?;
            let clients = lock(&broker().clients);
            let c = clients.get(id).ok_or_else(|| CmdError { code: "not_found".into(), message: "Unknown agent connection.".into() })?;
            let (_, format, data) = c.captures.iter().find(|(a, _, _)| *a == action)
                .ok_or_else(|| CmdError { code: "not_found".into(), message: "That screenshot is no longer kept.".into() })?;
            Ok(json!({ "action": action, "format": format, "data": wire::base64(data) }))
        }
        "Lock-GpuVMAgent" | "Unlock-GpuVMAgent" | "Request-GpuVMHuman" => {
            let (name, id) = (need(s("Name"), "Name")?, need(s("Connection"), "Connection")?);
            own_client(id, ctx)?;
            // A stopped session takes nothing (checked before the machines' lock: clients are always locked first).
            if cmd == "Lock-GpuVMAgent" && lock(&broker().clients).get(id).is_some_and(|c| c.killed) {
                return err("killed", "The person stopped this agent session.");
            }
            let reg = find_reg(name)?;
            let _ = owner_of_name(&reg.name);
            let mut machines = lock(&broker().machines);
            let m = machines.entry(reg.vm_id.clone()).or_default();
            match cmd {
                "Lock-GpuVMAgent" => {
                    match &m.taken_by {
                        Some(other) if other != id => return err("taken", format!("'{}' is in use by another agent session.", reg.name)),
                        _ => m.taken_by = Some(id.to_string()),
                    }
                    drop(machines);
                    if let Some(c) = lock(&broker().clients).get_mut(id) {
                        if let Some(task) = s("Task") {
                            c.task = Some(clean(task, 300));
                        }
                        if !c.machines.contains(&reg.name) {
                            c.machines.push(reg.name.clone());
                        }
                    }
                    vm_log(&reg, json!({ "event": "taken", "connection": id }));
                    Ok(json!({ "name": reg.name, "connection": id }))
                }
                "Unlock-GpuVMAgent" => {
                    if m.taken_by.as_deref() == Some(id) {
                        m.taken_by = None;
                        if m.paused.as_ref().is_some_and(|p| p["by"] == "agent" && p["connection"].as_str() == Some(id)) {
                            m.paused = None;
                        }
                    }
                    Ok(json!({}))
                }
                _ => {
                    if m.taken_by.as_deref() != Some(id) {
                        return err("not_taken", format!("Take '{}' first.", reg.name));
                    }
                    let message = clean(s("Message").unwrap_or(""), 500);
                    let request = wire::hex(&wire::random::<8>());
                    m.paused = Some(json!({ "by": "agent", "reason": "human", "message": message, "requestId": request, "since": now_ms(), "connection": id }));
                    drop(machines);
                    vm_log(&reg, json!({ "event": "paused", "by": "agent", "connection": id, "message": message }));
                    Ok(json!({ "requestId": request }))
                }
            }
        }
        "Suspend-GpuVMAgent" | "Resume-GpuVMAgent" => {
            person_only(ctx, "take or give back control")?;
            let reason = s("Reason").unwrap_or("person");
            if !["person", "control"].contains(&reason) {
                return err("bad_request", "Reason is person or control.");
            }
            let mut regs = targets(s("Name"), s("Connection"))?;
            // By session alone, Resume never gives back a machine the person took (a pause by the person, either
            // reason): that one is resumed by its Name. Only the session's own call for a human is lifted.
            if cmd == "Resume-GpuVMAgent" && s("Name").is_none() {
                let machines = lock(&broker().machines);
                regs.retain(|r| machines.get(&r.vm_id).and_then(|m| m.paused.as_ref()).is_none_or(|p| p["by"] != "person"));
            }
            for reg in &regs {
                if cmd == "Suspend-GpuVMAgent" {
                    let message = clean(s("Message").unwrap_or(""), 500);
                    lock(&broker().machines).entry(reg.vm_id.clone()).or_default().paused =
                        Some(json!({ "by": "person", "reason": reason, "message": message, "since": now_ms() }));
                    if let Some(c) = conn_of(&reg.vm_id) {
                        c.cancel_where("paused", "The person took control of this machine.", |p| p.client.is_some());
                    }
                    vm_log(reg, json!({ "event": "paused", "by": "person", "reason": reason, "via": ctx.label() }));
                    if reason == "control" {
                        let holder = lock(&broker().machines).get(&reg.vm_id).and_then(|m| m.taken_by.clone());
                        if let Some(h) = holder {
                            if let Some(c) = lock(&broker().clients).get_mut(&h) {
                                c.controls += 1;
                            }
                        }
                    }
                } else {
                    let mut machines = lock(&broker().machines);
                    let m = machines.entry(reg.vm_id.clone()).or_default();
                    m.paused = None;
                    m.resumed_at = Some(now_ms());
                    drop(machines);
                    vm_log(reg, json!({ "event": "resumed", "via": ctx.label() }));
                }
            }
            Ok(Value::Array(regs.iter().map(|r| json!({ "name": r.name })).collect()))
        }
        "Stop-GpuVMAgentClient" => {
            person_only(ctx, "stop agent sessions")?;
            let target = s("Connection");
            let all = flag("All") || target == Some("*");
            if !all && target.is_none() {
                return err("bad_request", "Connection (an id or \"*\") is required.");
            }
            let stopped: Vec<String> = {
                let mut clients = lock(&broker().clients);
                clients.iter_mut().filter(|(id, _)| all || Some(id.as_str()) == target).map(|(id, c)| {
                    c.killed = true;
                    c.ended = Some("stopped");
                    id.clone()
                }).collect()
            };
            for id in &stopped {
                release_and_cancel(id, "killed", "The person stopped this agent session.");
                for r in lock(&broker().requests).iter_mut().filter(|r| &r.connection == id && r.state == "pending") {
                    r.state = "expired".into();
                }
            }
            Ok(json!({ "stopped": stopped }))
        }
        "New-GpuVMAgentRequest" => new_request(args, ctx),
        "Get-GpuVMAgentRequest" => {
            let mut list = lock(&broker().requests);
            expire(&mut list);
            let own = own_scope(ctx);
            Ok(Value::Array(list.iter().filter(|r| s("Id").is_none_or(|id| r.id == id) && own.as_ref().is_none_or(|o| o.contains(&r.connection)))
                .map(Request::to_json).collect()))
        }
        "Resolve-GpuVMAgentRequest" => {
            person_only(ctx, "answer what an agent asks for")?;
            let id = need(s("Id"), "Id")?;
            let allow = args.get("Allow").and_then(Value::as_bool).ok_or_else(|| CmdError { code: "bad_request".into(), message: "Allow (true or false) is required.".into() })?;
            let mut list = lock(&broker().requests);
            expire(&mut list);
            let r = list.iter_mut().find(|r| r.id == id).ok_or_else(|| CmdError { code: "not_found".into(), message: "No such request.".into() })?;
            if r.state != "pending" {
                return err("bad_request", format!("This request is already {}.", r.state));
            }
            r.state = if allow { "allowed" } else { "denied" }.into();
            // A send is always for that one copy: never "for the whole task".
            r.for_task = allow && flag("ForTask") && r.kind != "send";
            r.resolved = Some(now_ms());
            let out = r.to_json();
            let (vm, kind, state) = (r.vm_id.clone(), r.kind.clone(), r.state.clone());
            drop(list);
            if let Some(reg) = reg_by_id(&vm) {
                vm_log(&reg, json!({ "event": "request_resolved", "id": id, "kind": kind, "state": state, "via": ctx.label() }));
            }
            Ok(out)
        }
        "Revoke-GpuVMAgentRequest" => {
            // A session withdraws only what it asked for and is still waiting: its approval request, or its call for
            // a human (which then resumes the machine). Never the person's pause or take-control, nor another
            // session's request.
            let (id, conn) = (need(s("Id"), "Id")?, need(s("Connection"), "Connection")?);
            own_client(conn, ctx)?;
            {
                let mut list = lock(&broker().requests);
                expire(&mut list);
                if let Some(r) = list.iter_mut().find(|r| r.id == id) {
                    if r.connection != conn {
                        return err("denied", "Only the session that asked can withdraw a request.");
                    }
                    if r.state != "pending" {
                        return err("bad_request", format!("This request is already {}.", r.state));
                    }
                    r.state = "withdrawn".into();
                    r.resolved = Some(now_ms());
                    let (out, vm) = (r.to_json(), r.vm_id.clone());
                    drop(list);
                    if let Some(reg) = reg_by_id(&vm) {
                        vm_log(&reg, json!({ "event": "request_withdrawn", "id": id, "connection": conn }));
                    }
                    return Ok(out);
                }
            }
            let mut machines = lock(&broker().machines);
            let found = machines.iter_mut().find(|(_, m)| m.paused.as_ref().is_some_and(|p| p["requestId"].as_str() == Some(id)));
            let Some((vm, m)) = found else {
                return err("not_found", "No such request is waiting.");
            };
            let p = m.paused.as_ref().cloned().unwrap_or_default();
            if p["by"] != "agent" || p["reason"] != "human" || p["connection"].as_str() != Some(conn) {
                return err("denied", "Only the session that asked can withdraw a request.");
            }
            m.paused = None;
            m.resumed_at = Some(now_ms());
            let vm = vm.clone();
            drop(machines);
            if let Some(reg) = reg_by_id(&vm) {
                vm_log(&reg, json!({ "event": "resumed", "via": "request_withdrawn", "id": id, "connection": conn }));
            }
            Ok(json!({ "id": id, "state": "withdrawn", "resumed": true }))
        }
        "New-GpuVMAgentOffer" => {
            let (name, path) = (need(s("Name"), "Name")?, need(s("Path"), "Path")?);
            new_offer(name, path, s("Note").unwrap_or(""), s("Connection"), ctx)
        }
        "Get-GpuVMAgentOffer" => {
            let regs = registrations();
            let filter_vm = s("Name").map(|n| reg_by_name(n).map(|r| r.vm_id).unwrap_or_default());
            let mut offers = lock(&broker().offers);
            let now = now_ms();
            for o in offers.iter_mut().filter(|o| o.state == "pending" && o.expires <= now) {
                o.state = "expired".into();
            }
            let own = own_scope(ctx);
            let list: Vec<Value> = offers.iter()
                .filter(|o| s("Id").is_none_or(|id| o.id == id) && filter_vm.as_ref().is_none_or(|vm| &o.vm_id == vm)
                    && own.as_ref().is_none_or(|own| o.client.as_ref().is_some_and(|c| own.contains(c))))
                .map(|o| o.to_json(&regs.iter().find(|r| r.vm_id == o.vm_id).map(|r| r.name.clone()).unwrap_or_default()))
                .collect();
            Ok(Value::Array(list))
        }
        "Resolve-GpuVMAgentOffer" => {
            person_only(ctx, "approve files leaving a machine")?;
            let id = need(s("Id"), "Id")?;
            let accept = args.get("Accept").and_then(Value::as_bool).ok_or_else(|| CmdError { code: "bad_request".into(), message: "Accept (true or false) is required.".into() })?;
            crate::offer::resolve(id, accept, ctx)
        }
        "Get-GpuVMAgentSettings" => Ok(settings_json()),
        "Wait-GpuVMAgentActivity" => {
            person_only(ctx, "follow what agents do")?;
            let after = args.get("After").and_then(Value::as_u64).unwrap_or(0);
            let ms = args.get("TimeoutMs").and_then(Value::as_u64).unwrap_or(10_000).min(crate::agent_log::WAIT_MAX_MS);
            Ok(crate::agent_log::wait(after, Duration::from_millis(ms)))
        }
        "Get-GpuVMAgentHistory" => {
            person_only(ctx, "read the agents' history")?;
            // A bare list would come back one line per item: one object around it.
            Ok(json!({ "sessions": crate::agent_log::read(args.get("Limit").and_then(Value::as_u64).unwrap_or(200).clamp(1, 1000) as usize) }))
        }
        "Set-GpuVMAgentSecret" => {
            if !ctx.admin {
                return err("denied", "Only the GpuVM module stores agent secrets.");
            }
            let vm = need(s("VmId"), "VmId")?;
            let vm_id = hv::parse_guid(vm).map(hv::fmt_guid).ok_or_else(|| CmdError { code: "bad_request".into(), message: "VmId isn't a VM id.".into() })?;
            let mut secret = wire::unbase64(need(s("Secret"), "Secret")?).ok_or_else(|| CmdError { code: "bad_request".into(), message: "Secret must be base64.".into() })?;
            let stored = store_secret(&vm_id, &secret);
            secret.iter_mut().for_each(|b| *b = 0);
            stored.map_err(|e| CmdError { code: "internal".into(), message: format!("The agent's secret couldn't be stored: {e}") })?;
            Ok(json!({ "vmId": vm_id }))
        }
        "Remove-GpuVMAgentRegistration" => {
            if !ctx.admin {
                return err("denied", "Only the GpuVM module removes agent registrations.");
            }
            let vm = need(s("VmId"), "VmId")?;
            // Only a folder named by a VM id: never settings.json or a path the caller made up.
            let vm_id = hv::parse_guid(vm).map(hv::fmt_guid).ok_or_else(|| CmdError { code: "bad_request".into(), message: "VmId isn't a VM id.".into() })?;
            let removed = remove_registration(&vm_id).map_err(|e| CmdError { code: "internal".into(), message: format!("The agent's registration couldn't be removed: {e}") })?;
            Ok(json!({ "vmId": vm_id, "removed": removed }))
        }
        "Set-GpuVMAgentSettings" | "Set-GpuVMAgentClient" => {
            person_only(ctx, "change the agents' settings")?;
            let mut data = read_settings();
            if !data.is_object() {
                data = json!({});
            }
            if cmd == "Set-GpuVMAgentSettings" {
                // Steps and minutes: 0 = no limit.
                for (key, field, min, max) in [("MaxSteps", "maxSteps", 0, 100_000u64), ("MaxMinutes", "maxMinutes", 0, 24 * 60), ("ApprovalTimeoutSec", "approvalTimeoutSec", 10, 24 * 3600)] {
                    if let Some(v) = args.get(key) {
                        let n = v.as_u64().filter(|n| (min..=max).contains(n)).ok_or_else(|| CmdError { code: "bad_request".into(), message: format!("{key} must be {min} to {max}.") })?;
                        data[field] = json!(n);
                    }
                }
            } else {
                let name = clean(need(s("Name"), "Name")?, 64);
                let on = args.get("ClientApprovals").and_then(Value::as_bool).ok_or_else(|| CmdError { code: "bad_request".into(), message: "ClientApprovals (true or false) is required.".into() })?;
                if !data["clients"].is_object() {
                    data["clients"] = json!({});
                }
                data["clients"][name] = json!({ "clientApprovals": on });
            }
            write_settings(&data).map_err(|e| CmdError { code: "internal".into(), message: e })?;
            Ok(settings_json())
        }
        _ => err("bad_request", format!("Unknown command {cmd}")),
    }
}

/// Pending requests past their time are expired (and an allowed one-off is good for 10 minutes).
fn expire(list: &mut Vec<Request>) {
    let now = now_ms();
    for r in list.iter_mut() {
        if r.state == "pending" && r.expires <= now {
            r.state = "expired".into();
        }
    }
    if list.len() > 500 {
        let drop_n = list.len() - 500;
        list.drain(..drop_n);
    }
}

fn new_request(args: &Map<String, Value>, ctx: &Ctx) -> Result<Value, CmdError> {
    let s = |k: &str| args.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
    let (name, id) = (need(s("Name"), "Name")?, need(s("Connection"), "Connection")?);
    let kind = need(s("Kind"), "Kind")?;
    if !REQUEST_KINDS.contains(&kind) {
        return err("bad_request", format!("Kind is one of {}.", REQUEST_KINDS.join(", ")));
    }
    let reg = find_reg(name)?;
    let client_name = {
        let clients = lock(&broker().clients);
        let c = clients.get(id).filter(|c| c.pid == ctx.pid).ok_or_else(|| CmdError { code: "not_found".into(), message: "Unknown agent connection.".into() })?;
        if c.killed {
            return err("killed", "The person stopped this agent session.");
        }
        c.name.clone()
    };
    if lock(&broker().machines).get(&reg.vm_id).and_then(|m| m.taken_by.clone()).as_deref() != Some(id) {
        return err("not_taken", format!("Take '{}' first.", reg.name));
    }
    let timeout = args.get("TimeoutSec").and_then(seconds).unwrap_or(settings().2).clamp(10, 24 * 3600);
    let mut list = lock(&broker().requests);
    expire(&mut list);
    if list.iter().filter(|r| r.connection == id && r.state == "pending").count() >= 10 {
        return err("busy", "Too many requests are waiting for the person.");
    }
    let now = now_ms();
    // Sending files of this PC into the machine: the person sees the exact paths and what they hold, measured as the
    // session's own user (never as the service: a size must not reveal files that user can't read).
    let send = if kind == "send" {
        let paths = send_paths(args.get("Path"))?;
        let (files, bytes) = measure_as_client(ctx.pipe, &paths).map_err(|e| CmdError { code: "bad_request".into(), message: e })?;
        // What the session says it saw must be what is there.
        let said = |k: &str| args.get(k).filter(|v| !v.is_null()).map(|v| v.as_u64().ok_or(()));
        for (key, real) in [("SizeBytes", bytes), ("Files", files)] {
            match said(key) {
                None => {}
                Some(Ok(n)) if n == real => {}
                _ => return err("bad_request", format!("{key} doesn't match what is there now ({real}).")),
            }
        }
        Some(SendSet { paths, files, bytes })
    } else {
        if ["Path", "SizeBytes", "Files"].iter().any(|k| args.contains_key(*k)) {
            return err("bad_request", "Path, SizeBytes and Files are only for Kind send.");
        }
        None
    };
    let title = match &send {
        // Written by GpuVM, never by the session: what leaves this PC, exactly.
        Some(s) => format!("Send {} to '{}': {} file{}, {}", s.paths.join("; "), reg.name, s.files, if s.files == 1 { "" } else { "s" }, size_text(s.bytes)),
        None => clean(s("Title").unwrap_or(match kind {
            "admin" => "Do a step that needs an administrator",
            "network" => "Change the machine's network",
            "revert" => "Go back to a restore point",
            "delete" => "Delete a machine",
            _ => "Approve a step",
        }), 120),
    };
    // A send is answered within 10 minutes: what it covers may change, so it never waits longer.
    let timeout = if send.is_some() { timeout.min(600) } else { timeout };
    let r = Request { id: wire::hex(&wire::random::<8>()), connection: id.to_string(), client_name, vm_id: reg.vm_id.clone(), machine: reg.name.clone(),
        kind: kind.to_string(), title, reason: clean(s("Reason").unwrap_or(""), 1000), created: now, expires: now + timeout * 1000,
        state: "pending".into(), for_task: false, used: false, reserved: false, resolved: None, send };
    let out = json!({ "requestId": r.id, "expiresAt": r.expires });
    vm_log(&reg, json!({ "event": "request", "id": r.id, "kind": r.kind, "connection": id }));
    list.push(r);
    drop(list);
    if let Some(c) = lock(&broker().clients).get_mut(id) {
        c.approvals += 1;
    }
    Ok(out)
}

/// Seconds as the MCP may send them: a whole number, a whole float (600.0) or digits in a text.
fn seconds(v: &Value) -> Option<u64> {
    v.as_u64()
        .or_else(|| v.as_f64().filter(|f| f.is_finite() && *f >= 0.0 && f.fract() == 0.0).map(|f| f as u64))
        .or_else(|| v.as_str().and_then(|t| t.trim().parse().ok()))
}

const REQUEST_KINDS: &[&str] = &["admin", "network", "revert", "delete", "send", "other"];

/// The most a "send" request can cover, so the person can still read the title and the service can measure it.
const SEND_MAX_PATHS: usize = 20;
const SEND_MAX_ENTRIES: u64 = 100_000;

/// The paths of a send (a text or a list of texts): plain local paths of this PC, at most SEND_MAX_PATHS.
fn send_paths(v: Option<&Value>) -> Result<Vec<String>, CmdError> {
    let list: Vec<&Value> = match v {
        Some(Value::Array(a)) => a.iter().collect(),
        Some(x @ Value::String(_)) => vec![x],
        _ => return err("bad_request", "Path (a path of this PC, or a list of them) is required for Kind send."),
    };
    if list.is_empty() || list.len() > SEND_MAX_PATHS {
        return err("bad_request", format!("A send covers 1 to {SEND_MAX_PATHS} paths."));
    }
    let mut paths = Vec::new();
    for v in list {
        let p = v.as_str().unwrap_or("");
        if !crate::win::is_plain_local_path(p) || p.chars().any(hidden_char) || p.len() > 260 {
            return err("bad_request", format!("{} isn't a path on a disk of this PC.", clean(p, 100)));
        }
        paths.push(p.trim_end_matches('\\').to_string());
    }
    Ok(paths)
}

/// The same set of paths, whatever the order or the case.
fn same_paths(a: &[String], b: &[String]) -> bool {
    let norm = |l: &[String]| {
        let mut v: Vec<String> = l.iter().map(|p| p.trim_end_matches('\\').to_lowercase()).collect();
        v.sort();
        v.dedup();
        v
    };
    norm(a) == norm(b)
}

/// Files and bytes under the paths, without following any link: a link (junction, symbolic link) anywhere is refused,
/// so what was approved can't be pointed somewhere else later.
fn measure(paths: &[String]) -> Result<(u64, u64), String> {
    use std::os::windows::fs::MetadataExt;
    const REPARSE: u32 = 0x400;
    let (mut files, mut bytes, mut seen) = (0u64, 0u64, 0u64);
    let mut stack: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    while let Some(p) = stack.pop() {
        seen += 1;
        if seen > SEND_MAX_ENTRIES {
            return Err(format!("More than {SEND_MAX_ENTRIES} files and folders: send a smaller folder."));
        }
        let m = std::fs::symlink_metadata(&p).map_err(|e| format!("{}: {e}", p.display()))?;
        if m.file_attributes() & REPARSE != 0 {
            return Err(format!("{} is a link; GpuVM doesn't send through links.", p.display()));
        }
        if m.is_dir() {
            for entry in std::fs::read_dir(&p).map_err(|e| format!("{}: {e}", p.display()))? {
                stack.push(entry.map_err(|e| e.to_string())?.path());
            }
        } else {
            files += 1;
            bytes += m.len();
        }
    }
    Ok((files, bytes))
}

/// `measure` as the user on the other end of the pipe (the session's), then back to the service's identity.
fn measure_as_client(pipe: HANDLE, paths: &[String]) -> Result<(u64, u64), String> {
    #[cfg(test)]
    if pipe.is_null() {
        return measure(paths);
    }
    use windows_sys::Win32::Security::RevertToSelf;
    use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
    if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
        return Err(crate::win::last_error("ImpersonateNamedPipeClient"));
    }
    let result = measure(paths);
    if unsafe { RevertToSelf() } == 0 {
        // Never keep running as someone else.
        log("agent: RevertToSelf failed; the service stops");
        std::process::exit(1);
    }
    result
}

fn size_text(bytes: u64) -> String {
    match bytes {
        b if b >= 1 << 30 => format!("{:.1} GB", b as f64 / (1u64 << 30) as f64),
        b if b >= 1 << 20 => format!("{:.1} MB", b as f64 / (1u64 << 20) as f64),
        b if b >= 1 << 10 => format!("{:.1} KB", b as f64 / 1024.0),
        b => format!("{b} bytes"),
    }
}

/// Module commands an agent session (a process that registered as an agent client) may run through the service,
/// and the approval each needs. Everything else is refused for it; the person's own app is never limited here.
const AGENT_COMMANDS: &[(&str, Option<&str>)] = &[
    ("Get-GpuVM", None), ("Get-GpuVMOverview", None), ("Get-GpuVMTemplate", None), ("Get-GpuVMProfile", None),
    ("Get-GpuVMRestorePoint", None), ("New-GpuVMRestorePoint", None), ("New-GpuVM", None), ("Install-GpuVMAgent", None),
    ("Invoke-GpuVMPower", None), ("Send-GpuVMFile", Some("send")), ("Remove-GpuVMDisposable", None), ("Connect-GpuVM", None),
    ("Restore-GpuVMRestorePoint", Some("revert")), ("Remove-GpuVM", Some("delete")),
];

/// Checks a module command from the service pipe before it reaches PowerShell. For an agent session: only the
/// commands above, on machines it took (or a new disposable copy), with an allowed request of the right kind
/// (`Approval: <request id>`) where one is needed. The `Approval` argument is removed before the bridge sees it.
/// The arguments an agent session may pass to each module command, and their types: `s` text, `b` true/false,
/// `i` whole number, `a` a text or a list of texts, `o` an object (checked further below). Anything else, or another
/// type (a list where a name goes), is refused before PowerShell sees it (review 2, #4).
const AGENT_ARGS: &[(&str, &[(&str, char)])] = &[
    ("Get-GpuVM", &[("Name", 's')]),
    ("Get-GpuVMOverview", &[]),
    ("Get-GpuVMTemplate", &[]),
    ("Get-GpuVMProfile", &[("Name", 's')]),
    ("Get-GpuVMRestorePoint", &[("Name", 's')]),
    ("New-GpuVMRestorePoint", &[("Name", 's'), ("Label", 's'), ("ShutdownIfRunning", 'b')]),
    ("New-GpuVM", &[("Name", 's'), ("Template", 's'), ("Disposable", 'b'), ("Start", 'b'), ("Override", 'o')]),
    ("Install-GpuVMAgent", &[("Name", 's'), ("User", 's')]),
    ("Invoke-GpuVMPower", &[("Name", 's'), ("Action", 's')]),
    ("Send-GpuVMFile", &[("Name", 's'), ("Path", 'a'), ("Folder", 's'), ("TransferId", 's')]),
    ("Remove-GpuVMDisposable", &[("Name", 's')]),
    ("Connect-GpuVM", &[("Name", 's'), ("Viewer", 'b'), ("Resolution", 's'), ("Fps", 'i'), ("BitrateKbps", 'i'), ("Codec", 's')]),
    ("Restore-GpuVMRestorePoint", &[("Name", 's'), ("Id", 's'), ("SaveCurrent", 'b'), ("ShutdownIfRunning", 'b')]),
    ("Remove-GpuVM", &[("Name", 's'), ("DeleteDisk", 'b')]),
];

fn check_agent_args(cmd: &str, args: &Value) -> Result<(), CmdError> {
    let allowed = AGENT_ARGS.iter().find(|(c, _)| *c == cmd).map(|(_, a)| *a).unwrap_or(&[]);
    let empty = Map::new();
    let obj = match args {
        Value::Object(o) => o,
        Value::Null => &empty,
        _ => return err("bad_request", "Arguments must be an object."),
    };
    for (k, v) in obj {
        let Some((_, t)) = allowed.iter().find(|(a, _)| a == k) else {
            return err("denied", format!("An agent session can't pass {k} to {cmd}."));
        };
        let ok = match t {
            's' => v.is_string(),
            'b' => v.is_boolean(),
            'i' => v.is_i64() || v.is_u64(),
            'a' => v.is_string() || v.as_array().is_some_and(|a| a.iter().all(Value::is_string)),
            'o' => v.is_object(),
            _ => false,
        };
        if !ok {
            return err("bad_request", format!("{k} has the wrong type."));
        }
    }
    match cmd {
        // A copy for an agent keeps the agent's account: never the person's (review 2, #4).
        "Install-GpuVMAgent" if obj.get("User").is_some_and(|u| u != "agent") => return err("denied", "An agent session installs the agent with its own account only."),
        // Only processors and memory may differ from the template (review 2, #3): no network, GPU, use or profile.
        "New-GpuVM" => {
            if let Some(o) = obj.get("Override") {
                let vm = o.as_object().filter(|m| m.len() == 1).and_then(|m| m.get("vm")).and_then(Value::as_object);
                let ok = vm.is_some_and(|vm| vm.iter().all(|(k, v)| match k.as_str() {
                    "memoryGB" => v.is_u64(),
                    "cpu" => v.as_object().is_some_and(|c| c.iter().all(|(k, v)| k == "count" && v.is_u64())),
                    _ => false,
                }));
                if !ok {
                    return err("denied", "An agent session may only change a copy's processors (vm.cpu.count) and memory (vm.memoryGB).");
                }
            }
        }
        _ => {}
    }
    Ok(())
}

/// What the gate let through, followed to its end by the service: an approval is spent only when the command
/// succeeded (review 3, #17), and a new copy becomes its session's then. Dropped without success, the approval is free
/// again.
pub struct Gated {
    claim: Option<Claim>,
    approval: Option<String>,
    /// A machine this command removes or renames: what sessions made or claimed under that name is forgotten.
    forget: Option<String>,
}

impl Gated {
    fn none() -> Self {
        Gated { claim: None, approval: None, forget: None }
    }

    /// The command succeeded; `data` is its result (New-GpuVM's says the copy's vmId).
    pub fn succeeded(mut self, data: &Value) {
        if let Some(c) = self.claim.take() {
            let first = data.as_array().and_then(|a| a.first()).unwrap_or(data);
            match first["vmId"].as_str().and_then(hv::parse_guid) {
                Some(id) => claim(c, &hv::fmt_guid(id)),
                None => log(&format!("agent: New-GpuVM gave no vmId for {}; the copy isn't the session's", c.name)),
            }
        }
        if let Some(id) = self.approval.take() {
            if let Some(r) = lock(&broker().requests).iter_mut().find(|r| r.id == id) {
                r.reserved = false;
                if !r.for_task {
                    r.used = true;
                }
            }
        }
        if let Some(name) = self.forget.take() {
            forget_name(&name);
        }
    }
}

impl Drop for Gated {
    fn drop(&mut self) {
        if let Some(id) = self.approval.take() {
            if let Some(r) = lock(&broker().requests).iter_mut().find(|r| r.id == id) {
                r.reserved = false;
            }
        }
    }
}

/// A machine name that no longer means the machine a session made or claimed (deleted or renamed, by anyone): a later
/// machine with the same name is never that session's (review 2, #7).
pub fn forget_name(name: &str) {
    let key = name.to_lowercase();
    let mut ids: Vec<String> = lock(&broker().names).remove(&key).into_iter().collect();
    ids.extend(reg_by_name(name).map(|r| r.vm_id));
    for id in ids {
        lock(&broker().made).remove(&id);
        lock(&broker().claims).remove(&id);
    }
}

/// The VM id behind a machine name: its agent's registration, or the copy a session made under that name, but only
/// while Hyper-V still has that very VM under that name. A machine deleted outside GpuVM (Hyper-V Manager) and made
/// again with the same name has another id, and is nobody's.
fn id_of_name(name: &str) -> Option<String> {
    if let Some(r) = reg_by_name(name) {
        return Some(r.vm_id);
    }
    let made = lock(&broker().names).get(&name.to_lowercase()).cloned()?;
    match hyperv_id_of(name) {
        Some(Some(now)) if now == made => Some(made),
        Some(_) => {
            // Gone, or another VM now: forget it for good.
            forget_name(name);
            None
        }
        None => None,
    }
}

/// Forgets what sessions made or claimed for VMs Hyper-V no longer has (deleted outside GpuVM).
fn prune_made(existing: &[String]) {
    lock(&broker().made).retain(|id, _| existing.contains(id));
    lock(&broker().claims).retain(|id, _| existing.contains(id));
    lock(&broker().names).retain(|_, id| existing.contains(id));
}

/// Counts one step of an agent session through the service, like a guest request: a stopped session or one past its
/// budget does nothing more (review 3, #1).
fn charge(id: &str) -> Result<(), CmdError> {
    let mut clients = lock(&broker().clients);
    let Some(c) = clients.get_mut(id) else { return err("not_found", "Unknown agent connection.") };
    if c.killed {
        return err("killed", "The person stopped this agent session.");
    }
    if let Some(limit) = over_limit(c) {
        c.ended = Some("limit");
        return err("budget", limit);
    }
    c.steps += 1;
    c.last_activity = Instant::now();
    Ok(())
}

pub fn gate(request: &mut Value, pid: u32, agent_pipe: bool) -> Result<Gated, CmdError> {
    let (approval, connection) = match request["args"].as_object_mut() {
        Some(a) => (a.remove("Approval"), a.remove("Connection")),
        None => (None, None),
    };
    let cmd = request["cmd"].as_str().unwrap_or("").to_string();
    let mut gated = Gated::none();
    if matches!(cmd.as_str(), "Remove-GpuVM" | "Remove-GpuVMDisposable" | "Rename-GpuVM") {
        gated.forget = request["args"]["Name"].as_str().filter(|n| !n.is_empty()).map(str::to_string);
    }
    let mine: Vec<String> = lock(&broker().clients).iter().filter(|(_, c)| c.pid == pid).map(|(id, _)| id.clone()).collect();
    // The person's app (or the module) is never limited here. A process that ever registered as an agent stays one
    // until it ends, and a pipe connection that said it acts for a model is one, even with no session registered
    // (after a service restart, or a connection opened for a long job): the gate never fails open for them.
    if mine.is_empty() && !agent_pipe && !is_agent_pid(pid) {
        return Ok(gated);
    }
    let Some((_, kind)) = AGENT_COMMANDS.iter().find(|(c, _)| *c == cmd) else {
        return err("denied", format!("An agent session can't run {cmd}."));
    };
    check_agent_args(&cmd, &request["args"])?;
    if cmd == "New-GpuVM" {
        // The module then copies only a template made for agents, and the copy is an agent machine (isolated).
        if let Some(a) = request["args"].as_object_mut() {
            a.insert("ForAgent".into(), json!(true));
        }
    }
    let args = &request["args"];
    let name = args["Name"].as_str().unwrap_or("");
    // The session acting: the one named, or the process's only one.
    let acting = match connection.as_ref().and_then(Value::as_str) {
        Some(c) if mine.iter().any(|m| m == c) => Some(c.to_string()),
        Some(_) => return err("not_found", "Unknown agent connection."),
        None if mine.len() == 1 => Some(mine[0].clone()),
        None => None,
    };
    if cmd == "New-GpuVM" {
        if args["Disposable"] != json!(true) || args["Template"].as_str().is_none_or(str::is_empty) {
            return err("denied", "An agent session can only create disposable copies of a template.");
        }
        // The new copy belongs to the session that makes it from the moment it exists (create + take at once).
        let Some(id) = acting.clone() else { return err("bad_request", "Connection is required.") };
        if name.is_empty() {
            return err("bad_request", "Name is required.");
        }
        charge(&id)?;
        gated.claim = Some(Claim { name: name.to_string(), connection: id });
        return Ok(gated);
    }
    if cmd == "Remove-GpuVMDisposable" {
        // Deleting one disposable machine at once (no grace, no approval, no UAC): only a copy this very session made
        // (the module also checks it is disposable and off). The general sweep (no Name) stays allowed.
        if !name.is_empty() && !id_of_name(name).and_then(|id| lock(&broker().made).get(&id).cloned()).is_some_and(|c| mine.contains(&c)) {
            return err("denied", format!("An agent session can only delete the disposable machines it made, and '{name}' isn't one."));
        }
    } else if !cmd.starts_with("Get-") {
        if name.is_empty() {
            return err("bad_request", "Name is required.");
        }
        match owner_of_name(name) {
            Some(t) if mine.contains(&t) => {}
            Some(_) => return err("taken", format!("'{name}' is in use by another agent session.")),
            None => return err("not_taken", format!("Take '{name}' first.")),
        }
    }
    // A machine the person paused does nothing for the session, through the service either (review 3, #1).
    if !cmd.starts_with("Get-") && !name.is_empty() {
        if let Some(reg) = reg_by_name(name) {
            if lock(&broker().machines).get(&reg.vm_id).is_some_and(|m| m.paused.is_some()) {
                return err("paused", format!("'{}' is paused: the person has it.", reg.name));
            }
            let holder = lock(&broker().machines).get(&reg.vm_id).and_then(|m| m.taken_by.clone());
            if let Some(h) = holder {
                charge(&h)?;
            }
        } else if let Some(id) = &acting {
            charge(id)?;
        }
    } else if let Some(id) = &acting {
        charge(id)?;
    }
    if let Some(kind) = kind {
        let kind = *kind;
        let id = approval.as_ref().and_then(Value::as_str).unwrap_or("");
        let mut list = lock(&broker().requests);
        expire(&mut list);
        let now = now_ms();
        let clients = lock(&broker().clients);
        let r = list.iter_mut().find(|r| r.id == id && r.state == "allowed" && r.kind == kind && r.machine.eq_ignore_ascii_case(name)
            && clients.get(&r.connection).is_some_and(|c| c.pid == pid && !c.killed)
            && (r.for_task || (!r.used && !r.reserved && r.resolved.is_some_and(|t| now < t + 600_000))));
        let Some(r) = r else {
            return err("needs_approval", format!("{cmd} needs the person's approval: ask with New-GpuVMAgentRequest -Kind {kind}."));
        };
        if kind == "send" {
            // Exactly the approved paths, still holding what the person saw (a file added or swapped since, or a link
            // put in place, needs a new approval).
            let Some(approved) = r.send.clone() else { return err("needs_approval", "This approval isn't for sending files.") };
            let asked = send_paths(Some(&args["Path"]))?;
            if !same_paths(&asked, &approved.paths) {
                return err("needs_approval", "The person approved sending other paths: ask again with New-GpuVMAgentRequest -Kind send.");
            }
            match measure(&approved.paths) {
                Ok((f, b)) if f == approved.files && b == approved.bytes => {}
                Ok(_) => {
                    r.used = true;
                    return err("needs_approval", "The files changed since the person approved them: ask again.");
                }
                Err(e) => {
                    r.used = true;
                    return err("needs_approval", format!("{e} Ask again."));
                }
            }
        }
        // Held for this command; spent only if it succeeds (a declined UAC or a module error leaves it usable).
        if !r.for_task {
            r.reserved = true;
        }
        gated.approval = Some(r.id.clone());
    }
    Ok(gated)
}

/// A disposable copy an agent session is making: it is that session's from the moment New-GpuVM succeeds.
pub struct Claim {
    name: String,
    connection: String,
}

/// Called by the service once New-GpuVM succeeded for an agent session (only then: a failed one leaves nothing).
pub fn claim(c: Claim, vm_id: &str) {
    if lock(&broker().clients).contains_key(&c.connection) {
        lock(&broker().names).insert(c.name.to_lowercase(), vm_id.to_string());
        lock(&broker().made).insert(vm_id.to_string(), c.connection.clone());
        lock(&broker().claims).insert(vm_id.to_string(), c.connection);
    }
}

/// Who holds a machine: the session that took it, or the one that created it while its agent isn't registered yet
/// (the claim becomes the machine's taker as soon as it is).
fn owner_of_name(name: &str) -> Option<String> {
    match reg_by_name(name) {
        Some(reg) => {
            // The claim (by this VM's id) and whether its session still exists, before the machines' lock: clients
            // are always locked first.
            let claim = lock(&broker().claims).remove(&reg.vm_id).filter(|c| lock(&broker().clients).contains_key(c));
            let mut machines = lock(&broker().machines);
            let m = machines.entry(reg.vm_id.clone()).or_default();
            if let Some(c) = claim {
                if m.taken_by.is_none() {
                    m.taken_by = Some(c);
                }
            }
            m.taken_by.clone()
        }
        None => id_of_name(name).and_then(|id| lock(&broker().claims).get(&id).cloned()),
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
        // Signed in but no display: asked again (the agent may just be starting). Past 20 s, or as soon as the agent
        // says Windows gives it no display path (agent.info noDisplay, 0.4.5), the machine is turned off and on ONCE
        // (only a power cycle clears that state, agent-guest lab 051); it is "starting" meanwhile, and "no-display"
        // with the reason if it still has none afterwards.
        let mut state = state;
        let mut last_error = m.and_then(|m| m.last_error.clone());
        let repair = m.map(|m| m.display_repair).unwrap_or(0);
        let blank = conn.as_ref().and_then(|c| blank_for(&agent, &c.blank_since, now_ms()));
        if blank.is_some() {
            if let Some(c) = &conn {
                refresh_info(c.clone());
            }
        }
        let said = agent["noDisplay"].as_str().filter(|t| !t.is_empty()).map(|t| clean(t, 300));
        let verdict = display_verdict(conn.is_some(), blank, said.is_some(), agent["signedIn"] == json!(true), repair);
        match verdict {
            Verdict::Fine => {}
            Verdict::Repair | Verdict::Repairing => {
                state = "starting";
                last_error = Some("The agent saw no display: the machine is being turned off and on to bring it back.".into());
            }
            Verdict::NoDisplay(ms) => {
                state = "no-display";
                last_error = Some(format!("The agent is signed in but has seen no display for {} s, even after the machine was turned \
                    off and on: it can't take screenshots or use the mouse and keyboard. {}", ms / 1000, said.unwrap_or_default()));
            }
            Verdict::Recovered => {}
        }
        let (start_repair, repaired) = (verdict == Verdict::Repair, verdict == Verdict::Recovered);
        let desktop = match events["secure_desktop"]["data"]["on"].as_bool() {
            Some(true) => json!("secure"),
            Some(false) => json!("default"),
            None if conn.is_some() => json!("default"),
            None => Value::Null,
        };
        list.push(json!({
            "name": reg.name, "vmId": reg.vm_id, "state": state, "version": conn.as_ref().map(|c| c.agent.clone()),
            "agent": agent, "desktop": desktop, "events": events, "connectedSince": conn.as_ref().map(|c| c.since),
            "screen": conn.as_ref().map(|c| lock(&c.info)["screen"].clone()),
            "screenChangedAt": conn.as_ref().map(|c| c.screen_changed.load(Ordering::SeqCst)).filter(|t| *t > 0),
            "paused": m.and_then(|m| m.paused.clone()), "takenBy": taken,
            "lastError": last_error, "disposable": disposable, "template": template,
        }));
        drop(machines);
        if start_repair {
            lock(&broker().machines).entry(reg.vm_id.clone()).or_default().display_repair = 1;
            power_cycle(reg.clone());
        } else if repaired {
            lock(&broker().machines).entry(reg.vm_id.clone()).or_default().display_repair = 0;
        }
    }
    Value::Array(list)
}

/// The person's settings, in ProgramData\GpuVM\agents\settings.json (administrators only).
fn read_settings() -> Value {
    std::fs::read_to_string(agents_dir().join("settings.json")).ok()
        .and_then(|t| serde_json::from_str::<Value>(t.trim_start_matches('\u{feff}')).ok()).unwrap_or(Value::Null)
}

fn write_settings(data: &Value) -> Result<(), String> {
    let dir = agents_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join("settings.json.new");
    std::fs::write(&tmp, serde_json::to_string_pretty(data).unwrap_or_default()).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, dir.join("settings.json")).map_err(|e| e.to_string())
}

/// A session past the limit the person set (0 = none, the default since 2026-11-21: a fixed 500 steps cut long tasks
/// short and read like progress), and what to tell it.
fn over_limit(c: &Client) -> Option<String> {
    let steps = c.max_steps > 0 && c.steps >= c.max_steps;
    let minutes = c.max_minutes > 0 && c.started.elapsed() >= Duration::from_secs(c.max_minutes * 60);
    (steps || minutes).then(|| match (c.max_steps, c.max_minutes) {
        (0, m) => format!("This session reached the person's limit of {m} minutes."),
        (s, 0) => format!("This session reached the person's limit of {s} steps."),
        (s, m) => format!("This session reached the person's limit ({s} steps or {m} minutes)."),
    })
}

/// (steps, minutes) per session, 0 = no limit, and how long a request or an offer waits for the person (s).
fn settings() -> (u64, u64, u64) {
    let data = read_settings();
    (data["maxSteps"].as_u64().unwrap_or(0).min(100_000), data["maxMinutes"].as_u64().unwrap_or(0).min(24 * 60),
        data["approvalTimeoutSec"].as_u64().unwrap_or(600).clamp(10, 24 * 3600))
}

fn settings_json() -> Value {
    let (steps, minutes, approval) = settings();
    let clients = read_settings()["clients"].clone();
    json!({ "maxSteps": steps, "maxMinutes": minutes, "approvalTimeoutSec": approval, "clients": if clients.is_object() { clients } else { json!({}) } })
}

fn connect_client(client: &Value, ctx: &mut Ctx) -> Result<Value, CmdError> {
    if ctx.admin {
        return err("denied", "Agent clients connect through the GpuVM app's pipe.");
    }
    let name = clean(client["name"].as_str().unwrap_or("unknown"), 64);
    let version = clean(client["version"].as_str().unwrap_or(""), 32);
    let (max_steps, max_minutes, approval) = settings();
    // MCP elicitation (approving low-risk steps in the client) only where the person turned it on for that client.
    let elicitation = read_settings()["clients"][&name]["clientApprovals"].as_bool().unwrap_or(false);
    let id = wire::hex(&wire::random::<16>());
    lock(&broker().clients).insert(id.clone(), Client {
        name: name.clone(), version, pid: ctx.pid, started: Instant::now(), started_ms: now_ms(), steps: 0, killed: false, max_steps, max_minutes,
        task: None, actions: VecDeque::new(), captures: VecDeque::new(), last_activity: Instant::now(),
        machines: Vec::new(), runs: 0, approvals: 0, offers: 0, controls: 0, ended: None,
    });
    ctx.owned.push(id.clone());
    log(&format!("agent: client {name} connected (pid {})", ctx.pid));
    Ok(json!({ "connection": id, "settings": { "elicitation": elicitation, "maxSteps": max_steps, "maxMinutes": max_minutes, "approvalTimeoutSec": approval } }))
}

/// The agent sessions as the app shows them: who, which machine, doing what, how far into its budget, last steps.
fn get_clients(only: Option<&str>) -> Value {
    let regs = registrations();
    let machines = lock(&broker().machines);
    let requests = lock(&broker().requests);
    let clients = lock(&broker().clients);
    let now = now_ms();
    let list = clients.iter().filter(|(id, _)| only.is_none_or(|o| o == id.as_str())).map(|(id, c)| {
        let taken = machines.iter().find(|(_, m)| m.taken_by.as_deref() == Some(id.as_str()));
        let machine = taken.and_then(|(vm, _)| regs.iter().find(|r| &r.vm_id == vm)).map(|r| r.name.clone());
        let paused = taken.and_then(|(_, m)| m.paused.clone());
        let waiting = requests.iter().any(|r| &r.connection == id && r.state == "pending" && r.expires > now);
        let (state, reason) = if c.killed {
            ("stopped", Value::Null)
        } else if let Some(p) = &paused {
            (match p["reason"].as_str() { Some("human") => "human", Some("control") => "control", _ => "paused" }, p["message"].clone())
        } else if waiting {
            ("waiting", Value::Null)
        } else if c.last_activity.elapsed() > Duration::from_secs(15) {
            ("idle", Value::Null)
        } else {
            ("working", Value::Null)
        };
        json!({
            "id": id, "name": c.name, "version": c.version, "connectedAt": c.started_ms, "machine": machine, "task": c.task,
            "state": state, "reason": reason, "steps": c.steps, "maxSteps": c.max_steps,
            "minutes": c.started.elapsed().as_secs() / 60, "maxMinutes": c.max_minutes,
            "resumedAt": taken.and_then(|(_, m)| m.resumed_at),
            "actions": c.actions.iter().rev().cloned().collect::<Vec<_>>(),
        })
    }).collect();
    Value::Array(list)
}

/// Keeps one step of a session for the app (and the image of a capture, the last 10).
fn record_action(id: &str, method: &str, note: Option<&str>, ok: bool, code: &str, ms: f64, capture: Option<(&str, &[u8])>) {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let mut clients = lock(&broker().clients);
    let Some(c) = clients.get_mut(id) else { return };
    let action = NEXT.fetch_add(1, Ordering::SeqCst);
    c.last_activity = Instant::now();
    c.actions.push_back(json!({ "id": action, "at": now_ms(), "method": method, "text": note.map(|n| clean(n, 200)), "ok": ok, "code": code,
        "ms": (ms * 100.0).round() / 100.0, "capture": capture.is_some() }));
    while c.actions.len() > MAX_ACTIONS {
        c.actions.pop_front();
    }
    if let Some((format, data)) = capture {
        c.captures.push_back((action, format.to_string(), data.to_vec()));
        while c.captures.len() > MAX_CAPTURES {
            c.captures.pop_front();
        }
    }
}

/// A connection id is only usable from the process that registered it.
fn own_client(id: &str, ctx: &Ctx) -> Result<(), CmdError> {
    match lock(&broker().clients).get(id) {
        Some(c) if c.pid == ctx.pid => Ok(()),
        _ => err("not_found", "Unknown agent connection."),
    }
}

fn release_and_cancel(id: &str, code: &str, message: &str) {
    lock(&broker().claims).retain(|_, c| c != id);
    lock(&broker().made).retain(|_, c| c != id);
    for m in lock(&broker().machines).values_mut() {
        if m.taken_by.as_deref() == Some(id) {
            m.taken_by = None;
        }
        // Its own call for a human goes with it (review 3, #2); a pause by the person stays.
        if m.paused.as_ref().is_some_and(|p| p["by"] == "agent" && p["connection"].as_str() == Some(id)) {
            m.paused = None;
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
        // A session that never took a machine left nothing worth keeping.
        if !c.machines.is_empty() {
            crate::agent_log::append(&json!({ "id": id, "client": c.name, "version": c.version, "task": c.task, "machines": c.machines,
                "start": c.started_ms, "end": now_ms(), "steps": c.steps, "runs": c.runs, "approvals": c.approvals, "offers": c.offers,
                "controls": c.controls, "ended": c.ended.unwrap_or("done") }));
        }
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
        if let Some(limit) = over_limit(c) {
            c.ended = Some("limit");
            return err("budget", limit);
        }
        c.steps += 1;
    }
    let _ = owner_of_name(name);
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
    bounded(&redacted(v), 4)
}

/// What a model types or runs never reaches the log, at any depth (input.act's actions[].text, a field's value, a
/// command line, a file's data): only its length.
fn redacted(v: &Value) -> Value {
    const SECRET: &[&str] = &["data", "blob", "stdin", "text", "value", "command", "args", "password"];
    match v {
        Value::Object(o) => Value::Object(o.iter().map(|(k, x)| {
            let hidden = SECRET.contains(&k.to_ascii_lowercase().as_str());
            let x = if hidden {
                let n = match x { Value::String(s) => s.chars().count(), Value::Null => 0, other => other.to_string().len() };
                json!(format!("<{n} chars>"))
            } else {
                redacted(x)
            };
            (k.clone(), x)
        }).collect()),
        Value::Array(a) => Value::Array(a.iter().map(redacted).collect()),
        other => other.clone(),
    }
}

/// Ids of steps in the live view (a start and its end share one).
static NEXT_STEP: AtomicU64 = AtomicU64::new(1);

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
    // screen.refresh with repeatMs: the desktop repainted every 250 ms for that long, in the background, and the answer
    // comes at once. With ddx a still desktop sends no frame, and a single repaint is lost while Sunshine restarts its
    // capture (lab 052: one refresh 2 of 10 opens with a picture, a 10 s burst 9 of 10, median 0.84 s).
    if method == "screen.refresh" && params.get("repeatMs").is_some() {
        let ms = params["repeatMs"].as_u64().filter(|m| *m > 0).ok_or_else(|| CmdError { code: "bad_request".into(), message: "repeatMs must be a number of ms.".into() })?
            .min(REFRESH_BURST_MAX_MS);
        let conn = conn_of(&reg.vm_id).ok_or_else(|| CmdError { code: "off".into(), message: format!("The agent on '{}' isn't connected.", reg.name) })?;
        refresh_burst(conn, ms, client.map(str::to_string));
        vm_log(&reg, json!({ "method": method, "params": { "repeatMs": ms }, "client": client.unwrap_or(ctx.label()), "code": "ok" }));
        return Ok(json!({ "ok": true, "result": { "repeating": ms } }));
    }
    // The live view (agent_log.rs): this step starts, with its shape and the screen it is drawn on.
    let live = client.map(|id| {
        let name = lock(&broker().clients).get_mut(id).map(|c| {
            if method == "exec.run" {
                c.runs += 1;
            }
            c.name.clone()
        });
        let screen = conn_of(&reg.vm_id).map(|c| lock(&c.info)["screen"].clone()).unwrap_or(Value::Null);
        let step = NEXT_STEP.fetch_add(1, Ordering::SeqCst);
        crate::agent_log::push(json!({ "phase": "start", "step": step, "client": id, "clientName": name, "machine": reg.name, "at": now_ms(),
            "method": method, "intent": s("Intent").map(|i| clean(i, 120)), "shapes": crate::agent_log::shapes(method, &params), "screen": screen }));
        step
    });
    let started = Instant::now();
    let reply = match conn_of(&reg.vm_id) {
        Some(c) => c.request(method, &params, blob.as_deref(), Duration::from_secs(timeout), client),
        None => Err(("off".into(), format!("The agent on '{}' isn't connected.", reg.name))),
    };
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let code = match &reply { Ok(_) => "ok".to_string(), Err((c, _)) => c.clone() };
    let blob_len = reply.as_ref().ok().and_then(|(_, b)| b.as_ref().map(Vec::len));
    vm_log(&reg, json!({ "method": method, "params": loggable(&params), "client": client.unwrap_or(ctx.label()), "code": code,
        "ms": (ms * 100.0).round() / 100.0, "blobIn": blob.as_ref().map(Vec::len), "blobOut": blob_len, "note": s("Note").map(|n| clean(n, 200)) }));
    if let Some(id) = client {
        let capture = match &reply {
            Ok((r, Some(b))) if method == "screen.capture" => Some((r["format"].as_str().unwrap_or("webp"), b.as_slice())),
            _ => None,
        };
        record_action(id, method, s("Note"), reply.is_ok(), &code, ms, capture);
    }
    if let (Some(id), Some(step)) = (client, live) {
        crate::agent_log::push(json!({ "phase": "end", "step": step, "client": id, "machine": reg.name, "at": now_ms(), "method": method,
            "ok": reply.is_ok(), "code": code }));
    }
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
    // Every answer says when the agent's screen last changed size, so a client recaptures before acting on old pixels.
    if let Some(c) = conn_of(&reg.vm_id) {
        let changed = c.screen_changed.load(Ordering::SeqCst);
        if changed > 0 {
            out["screenChangedAt"] = json!(changed);
            out["screen"] = lock(&c.info)["screen"].clone();
        }
    }
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
    let stem = cleaned.split('.').next().unwrap_or("").trim_end().to_uppercase();
    // COM0-9 / LPT0-9, and the superscript ¹ ² ³ Windows also reserves (review 2, #10).
    let device_digit = |c: char| c.is_ascii_digit() || matches!(c, '\u{b9}' | '\u{b2}' | '\u{b3}');
    let chars: Vec<char> = stem.chars().collect();
    let reserved = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&stem.as_str())
        || ((stem.starts_with("COM") || stem.starts_with("LPT")) && chars.len() == 4 && device_digit(chars[3]));
    (!cleaned.is_empty() && !reserved && cleaned != "." && cleaned != "..").then_some(cleaned)
}

/// Files that act just by being looked at in Explorer (an icon or a target on a network path makes Windows send the
/// person's NTLM hash to the guest's server): never offered (review 2, #10).
pub fn offer_kind_allowed(file_name: &str) -> bool {
    let lower = file_name.to_lowercase();
    let blocked_ext = [".url", ".lnk", ".scf", ".library-ms", ".searchconnector-ms", ".website", ".appref-ms"];
    lower != "desktop.ini" && !blocked_ext.iter().any(|e| lower.ends_with(e))
}

/// Only a file directly inside the agent's Outbox: no subfolders, links are the guest's problem (it reads as
/// `agent` and the host only receives bytes).
/// `path` is relative to the agent's home (`Desktop\Outbox\x`) or absolute under it; `home` is what the agent
/// reported (agent.info), `C:\Users\agent` when it hasn't yet. Returns the file's name.
pub fn outbox_file(path: &str, home: Option<&str>) -> Option<String> {
    if path.contains('/') {
        return None;
    }
    let home = home.filter(|h| !h.is_empty()).unwrap_or(DEFAULT_HOME).trim_end_matches('\\');
    let absolute = format!("{home}\\{OUTBOX}");
    let lower = path.to_lowercase();
    let prefix = if lower.starts_with(&OUTBOX.to_lowercase()) {
        OUTBOX.len()
    } else if lower.starts_with(&absolute.to_lowercase()) {
        absolute.len()
    } else {
        return None;
    };
    let rest = &path[prefix..];
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
    let conn = conn_of(&reg.vm_id);
    let home = conn.as_ref().and_then(|c| lock(&c.info)["home"].as_str().map(str::to_string));
    let Some(guest_name) = outbox_file(path, home.as_deref()) else {
        return err("denied", format!("Only files directly inside the agent's {OUTBOX} can leave the machine."));
    };
    let conn = conn.ok_or_else(|| CmdError { code: "off".into(), message: format!("The agent on '{}' isn't connected.", reg.name) })?;
    let Some(file_name) = safe_file_name(&guest_name) else { return err("bad_request", "That file name can't be saved on this PC.") };
    if !offer_kind_allowed(&file_name) {
        return err("denied", "Shortcuts and folder settings files (.url, .lnk, .scf, .library-ms, .searchConnector-ms, desktop.ini) can't leave the machine.");
    }
    // Kept relative to the agent's home: what the guest's files.read takes, whatever its profile folder is called.
    let path = &format!("{OUTBOX}{guest_name}");
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
    let client_name = client.and_then(|c| lock(&broker().clients).get(c).map(|c| c.name.clone()));
    let now = now_ms();
    offers.push(Offer { id: id.clone(), vm_id: reg.vm_id.clone(), path: path.to_string(), file_name: file_name.clone(), size, note: note.clone(),
        state: "pending".into(), created: now, expires: now + settings().2 * 1000, host_path: None, error: None,
        client: client.map(str::to_string), client_name });
    drop(offers);
    if let Some(c) = client {
        if let Some(c) = lock(&broker().clients).get_mut(c) {
            c.offers += 1;
        }
    }
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
        if o.state == "pending" && o.expires <= now_ms() {
            o.state = "expired".into();
        }
        if o.state != "pending" {
            return err("bad_request", format!("This offer is already {}.", o.state));
        }
        if !approve {
            o.state = "refused".into();
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
pub(crate) mod tests {
    use super::*;

    pub static TEST_AGENTS: OnceLock<PathBuf> = OnceLock::new();
    /// Power cycles asked in tests (machine names).
    pub static TEST_CYCLES: Mutex<Vec<String>> = Mutex::new(Vec::new());
    /// What "Hyper-V" has in tests: machine name (lowercase) → VM id.
    pub static TEST_HV: Mutex<std::collections::BTreeMap<String, String>> = Mutex::new(std::collections::BTreeMap::new());

    fn code(r: Result<Value, CmdError>) -> String {
        match r {
            Ok(v) if v["ok"] == json!(false) => v["error"]["code"].as_str().unwrap_or("?").to_string(),
            Ok(_) => "ok".into(),
            Err(e) => e.code,
        }
    }

    /// The policy the MCP server can't bypass: one client per machine, pause, kill switch, budget, and only the
    /// person approves. No agent is connected, so an admitted request ends in "off".
    #[test]
    fn agent_session_policy() {
        let dir = std::env::temp_dir().join(format!("gpuvm-agent-test-{}", std::process::id()));
        let vm = "0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b";
        std::fs::create_dir_all(dir.join(vm)).unwrap();
        std::fs::write(dir.join(vm).join("agent.json"), json!({ "vmId": vm, "name": "Test1", "folder": dir.display().to_string() }).to_string()).unwrap();
        std::fs::write(dir.join("settings.json"), r#"{"maxSteps": 6}"#).unwrap();
        TEST_AGENTS.set(dir.clone()).unwrap();
        let null = std::ptr::null_mut();
        let mut mcp = Ctx::new(null, 100, false);
        let mut other = Ctx::new(null, 200, false);
        let mut app = Ctx::new(null, 300, false);
        let invoke = |ctx: &mut Ctx, conn: Option<&str>| {
            let mut a = json!({ "Name": "test1", "Method": "agent.info" });
            if let Some(c) = conn {
                a["Connection"] = json!(c);
            }
            code(command("Invoke-GpuVMAgent", &a, ctx))
        };
        let c = command("Connect-GpuVMAgentClient", &json!({ "Client": { "name": "claude-code", "version": "1" } }), &mut mcp).unwrap();
        assert_eq!(c["settings"]["maxSteps"], 6);
        assert_eq!(c["settings"]["elicitation"], false);
        let id = c["connection"].as_str().unwrap().to_string();
        let id2 = command("Connect-GpuVMAgentClient", &json!({ "Client": { "name": "other" } }), &mut other).unwrap()["connection"].as_str().unwrap().to_string();
        // Exact argument names; unknown ones are refused.
        assert_eq!(code(command("Invoke-GpuVMAgent", &json!({ "name": "Test1", "Method": "agent.info" }), &mut app)), "bad_request");
        assert_eq!(code(command("Invoke-GpuVMAgent", &json!({ "Name": "Test1", "Method": "rm" }), &mut app)), "bad_request");
        // screen.refresh (agent 0.3.8) is a guest method: it reaches the machine (here "off": no agent connected).
        assert_eq!(code(command("Invoke-GpuVMAgent", &json!({ "Name": "Test1", "Method": "screen.refresh" }), &mut app)), "off");
        assert_eq!(code(command("Invoke-GpuVMAgent", &json!({ "Name": "Test1", "Method": "screen.repaint" }), &mut app)), "bad_request");
        // A repaint burst needs a number of ms and a connected agent (here none: "off").
        let mut burst = |p: Value| code(command("Invoke-GpuVMAgent", &json!({ "Name": "Test1", "Method": "screen.refresh", "Params": p }), &mut app));
        assert_eq!(burst(json!({ "repeatMs": "lots" })), "bad_request");
        assert_eq!(burst(json!({ "repeatMs": 0 })), "bad_request");
        assert_eq!(burst(json!({ "repeatMs": 10_000 })), "off");
        // The MCP side must name its connection and take the machine first.
        assert_eq!(invoke(&mut mcp, None), "not_taken");
        assert_eq!(invoke(&mut mcp, Some(&id)), "not_taken"); // step 1
        // A connection id only works from the process that registered it.
        assert_eq!(code(command("Lock-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id }), &mut other)), "not_found");
        assert_eq!(code(command("Lock-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id }), &mut mcp)), "ok");
        assert_eq!(code(command("Lock-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id2 }), &mut other)), "taken");
        assert_eq!(invoke(&mut other, Some(&id2)), "taken");
        assert_eq!(invoke(&mut mcp, Some(&id)), "off"); // admitted (step 2), no agent connected
        // The person (app) may use the machine without a connection.
        assert_eq!(invoke(&mut app, None), "off");
        // Only the person pauses, resumes, stops and approves.
        assert_eq!(code(command("Suspend-GpuVMAgent", &json!({ "Name": "Test1" }), &mut mcp)), "denied");
        assert_eq!(code(command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut mcp)), "denied");
        assert_eq!(code(command("Stop-GpuVMAgentClient", &json!({ "All": true }), &mut mcp)), "denied");
        assert_eq!(code(command("Resolve-GpuVMAgentOffer", &json!({ "Id": "x", "Accept": true }), &mut mcp)), "denied");
        assert_eq!(code(command("Set-GpuVMAgentSettings", &json!({ "MaxSteps": 99999 }), &mut mcp)), "denied");
        // What an agent session may run through the service: its machine only, deletions and reverts with approval.
        // Each command counts as a step: a larger budget for this part, the step count put back afterwards.
        for c in lock(&broker().clients).values_mut() {
            c.max_steps = 10_000;
        }
        let gate_code = |cmd: &str, args: Value, pid: u32| {
            let mut r = json!({ "cmd": cmd, "args": args });
            match gate(&mut r, pid, false) { Ok(_) => "ok".to_string(), Err(e) => e.code }
        };
        let pipe_code = |cmd: &str, args: Value, pid: u32| {
            let mut r = json!({ "cmd": cmd, "args": args });
            match gate(&mut r, pid, true) { Ok(_) => "ok".to_string(), Err(e) => e.code }
        };
        // A pipe connection that said it acts for a model is limited even with no session (pid 900 has none): the
        // gate never fails open for it.
        assert_eq!(pipe_code("Remove-GpuVM", json!({ "Name": "Test1" }), 900), "taken"); // held by another session
        assert_eq!(pipe_code("Remove-GpuVMDisk", json!({ "Name": "Test1" }), 900), "denied");
        assert_eq!(pipe_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": r"C:\Users" }), 900), "taken");
        assert_eq!(pipe_code("Get-GpuVM", json!({}), 900), "ok");
        assert_eq!(gate_code("Remove-GpuVMDisk", json!({ "Name": "Test1" }), 900), "ok"); // the person's app
        let mut piped = Ctx::new(std::ptr::null_mut(), 900, false);
        assert_eq!(code(command("Register-GpuVMAgentPipe", &json!({}), &mut piped)), "ok");
        assert!(piped.is_agent_pipe());
        assert_eq!(code(command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut piped)), "denied");
        assert_eq!(code(command("Invoke-GpuVMAgent", &json!({ "Name": "Test1", "Method": "agent.info" }), &mut piped)), "not_taken");
        let mut module = Ctx::new(std::ptr::null_mut(), 901, true);
        assert_eq!(code(command("Register-GpuVMAgentPipe", &json!({}), &mut module)), "denied");
        // A disposable copy an agent session makes is its own at once: only it may install the agent there and take it.
        let mut r = json!({ "cmd": "New-GpuVM", "args": { "Name": "Copy1", "Template": "t", "Disposable": true, "Connection": id } });
        let c = gate(&mut r, 100, false).unwrap();
        assert!(r["args"].get("Connection").is_none());
        assert_eq!(r["args"]["ForAgent"], true); // the module copies only an agent template, as an agent machine
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Copy1" }), 100), "not_taken"); // New-GpuVM didn't finish yet
        TEST_HV.lock().unwrap().insert("copy1".into(), "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d".into());
        c.succeeded(&json!([{ "name": "Copy1", "vmId": "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d" }]));
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Copy1" }), 100), "ok");
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Copy1" }), 200), "taken");
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Test1" }), 200), "taken");
        // Deleting a disposable at once: only the copy this session made; another session's copy, a machine it only
        // took, or any other name is refused. The general sweep (no Name) stays allowed.
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy1" }), 100), "ok");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "copy1" }), 100), "ok");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy1" }), 200), "denied");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Test1" }), 100), "denied");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "win-gpu" }), 100), "denied");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({}), 200), "ok");
        assert_eq!(gate_code("Remove-GpuVMDisk", json!({ "Name": "Test1" }), 100), "denied");
        assert_eq!(gate_code("Get-GpuVMTemplate", json!({}), 100), "ok");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x" }), 100), "denied");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true }), 100), "ok");
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({ "Name": "Test1" }), 100), "ok");
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({ "Name": "Test1" }), 200), "taken");
        assert_eq!(gate_code("Remove-GpuVM", json!({ "Name": "Test1" }), 300), "ok"); // the person's app: not limited here
        assert_eq!(gate_code("Restore-GpuVMRestorePoint", json!({ "Name": "Test1" }), 100), "needs_approval");
        let req = command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "revert", "Reason": "undo my test" }), &mut mcp).unwrap();
        let rid = req["requestId"].as_str().unwrap().to_string();
        assert_eq!(get_clients(Some(&id))[0]["state"], "waiting");
        assert_eq!(gate_code("Restore-GpuVMRestorePoint", json!({ "Name": "Test1", "Approval": rid }), 100), "needs_approval"); // pending
        assert_eq!(code(command("Resolve-GpuVMAgentRequest", &json!({ "Id": rid, "Allow": true }), &mut mcp)), "denied");
        assert_eq!(code(command("Resolve-GpuVMAgentRequest", &json!({ "Id": rid, "Allow": true }), &mut app)), "ok");
        assert_eq!(gate_code("Remove-GpuVM", json!({ "Name": "Test1", "Approval": rid }), 100), "needs_approval"); // other kind
        assert_eq!(gate_code("Restore-GpuVMRestorePoint", json!({ "Name": "Test1", "Approval": rid }), 200), "taken");
        let mut r = json!({ "cmd": "Restore-GpuVMRestorePoint", "args": { "Name": "Test1", "Approval": rid } });
        // Held while the command runs: a failed run (a declined UAC, a module error) leaves it usable; a success spends it.
        drop(gate(&mut r, 100, false).unwrap());
        let mut r = json!({ "cmd": "Restore-GpuVMRestorePoint", "args": { "Name": "Test1", "Approval": rid } });
        let held = gate(&mut r, 100, false).unwrap();
        assert_eq!(gate_code("Restore-GpuVMRestorePoint", json!({ "Name": "Test1", "Approval": rid }), 100), "needs_approval"); // in use
        held.succeeded(&Value::Null);
        assert!(r["args"].get("Approval").is_none()); // the bridge never sees it
        assert_eq!(gate_code("Restore-GpuVMRestorePoint", json!({ "Name": "Test1", "Approval": rid }), 100), "needs_approval"); // used once
        let src = dir.join("to-send");
        std::fs::create_dir_all(src.join("sub")).unwrap();
        std::fs::write(src.join("a.txt"), b"hello").unwrap();
        std::fs::write(src.join("sub").join("b.txt"), b"world!").unwrap();
        let path = src.display().to_string();
        let send = |rid: &str, p: &str| gate_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": [p], "Approval": rid }), 100);
        assert_eq!(gate_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": [path] }), 100), "needs_approval");
        assert_eq!(code(command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "send" }), &mut mcp)), "bad_request");
        assert_eq!(code(command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "send", "Path": "relative\\x" }), &mut mcp)), "bad_request");
        assert_eq!(code(command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "revert", "Path": path }), &mut mcp)), "bad_request");
        let ask = |mcp: &mut Ctx| {
            let r = command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "send", "Path": path, "Title": "harmless", "TimeoutSec": 86400 }), mcp).unwrap();
            r["requestId"].as_str().unwrap().to_string()
        };
        // The TimeoutSec the MCP sends is kept (up to 10 minutes for a send), as a number, a float or a text.
        for t in [json!(300), json!(300.0), json!("300")] {
            let r = command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "send", "Path": path, "TimeoutSec": t }), &mut mcp).unwrap();
            let shown = command("Get-GpuVMAgentRequest", &json!({ "Id": r["requestId"] }), &mut app).unwrap()[0].clone();
            assert_eq!(shown["expiresAt"].as_u64().unwrap() - shown["createdAt"].as_u64().unwrap(), 300_000);
            command("Revoke-GpuVMAgentRequest", &json!({ "Id": r["requestId"], "Connection": id }), &mut mcp).unwrap();
        }
        let sid = ask(&mut mcp);
        let shown = command("Get-GpuVMAgentRequest", &json!({ "Id": sid }), &mut app).unwrap()[0].clone();
        assert!(shown["title"].as_str().unwrap().contains(&path)); // GpuVM's words with the exact path, not the session's
        assert!(shown["title"].as_str().unwrap().contains("2 files"));
        assert_eq!(shown["files"], 2);
        assert_eq!(shown["bytes"], 11);
        assert!(shown["expiresAt"].as_u64().unwrap() <= shown["createdAt"].as_u64().unwrap() + 600_000); // 10 minutes at most
        assert_eq!(send(&sid, &path), "needs_approval"); // pending
        command("Resolve-GpuVMAgentRequest", &json!({ "Id": sid, "Allow": true, "ForTask": true }), &mut app).unwrap();
        assert_eq!(send(&sid, &format!("{path}\\sub")), "needs_approval"); // other paths, and the approval is spent
        let sid = ask(&mut mcp);
        command("Resolve-GpuVMAgentRequest", &json!({ "Id": sid, "Allow": true, "ForTask": true }), &mut app).unwrap();
        assert_eq!(gate_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": [path], "Approval": sid }), 200), "taken");
        let mut r = json!({ "cmd": "Send-GpuVMFile", "args": { "Name": "Test1", "Path": [path.to_uppercase()], "Approval": sid } });
        gate(&mut r, 100, false).unwrap().succeeded(&Value::Null);
        assert_eq!(send(&sid, &path), "needs_approval"); // once, even when asked "for the task"
        let sid = ask(&mut mcp);
        command("Resolve-GpuVMAgentRequest", &json!({ "Id": sid, "Allow": true }), &mut app).unwrap();
        std::fs::write(src.join("sub").join("c.txt"), b"added later").unwrap(); // the folder changed after the approval
        assert_eq!(send(&sid, &path), "needs_approval");
        // Copying from a machine: only from one the session took, and that moves nothing off this PC.
        assert_eq!(gate_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": ["C:\\x"], "FromVM": "win-gpu" }), 100), "denied");
        // A folder with a link inside (a junction to somewhere else) is never measured nor sent.
        let linked = dir.join("linked");
        std::fs::create_dir_all(&linked).unwrap();
        let made = std::process::Command::new("cmd").args(["/c", "mklink", "/J"]).arg(linked.join("j")).arg(&src).output().unwrap();
        assert!(made.status.success());
        let r = command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "send", "Path": linked.display().to_string() }), &mut mcp);
        assert_eq!(code(r), "bad_request");
        // Arguments and their types: only those listed for each command (a list where a name goes is refused, and so
        // are the person's account, copying from another machine, and a copy's network or GPU).
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({ "Name": ["Test1"] }), 100), "bad_request");
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({ "Name": "Test1", "Force": true }), 100), "denied");
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Test1", "User": "own" }), 100), "denied");
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Test1", "User": "agent" }), 100), "ok");
        assert_eq!(gate_code("Send-GpuVMFile", json!({ "Name": "Test1", "Path": ["C:\\x"], "FromVM": "Test1" }), 100), "denied");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true, "Override": { "vm": { "memoryGB": 4, "cpu": { "count": 2 } } } }), 100), "ok");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true, "Override": { "vm": { "network": { "isolation": false } } } }), 100), "denied");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true, "Override": { "gpu": { "allocationPercent": 100 } } }), 100), "denied");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true, "Use": "none" }), 100), "denied");
        assert_eq!(gate_code("New-GpuVM", json!({ "Name": "x", "Template": "t", "Disposable": true, "Profile": "max-performance" }), 100), "denied");
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({}), 100), "bad_request"); // a command on a machine names it
        // A machine the person paused does nothing for the session through the service either.
        command("Suspend-GpuVMAgent", &json!({ "Name": "Test1" }), &mut app).unwrap();
        assert_eq!(gate_code("Invoke-GpuVMPower", json!({ "Name": "Test1" }), 100), "paused");
        assert_eq!(gate_code("Get-GpuVM", json!({ "Name": "Test1" }), 100), "ok");
        command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut app).unwrap();
        // A process that registered as an agent stays one: without its session it still isn't the person.
        // (this test's own process: a live one, whose handle is held.)
        let me = std::process::id();
        mark_agent_pid(me);
        assert!(is_agent_pid(me));
        assert_eq!(gate_code("Remove-GpuVMDisk", json!({ "Name": "Test1" }), me), "denied");
        let mut was_agent = Ctx::new(std::ptr::null_mut(), me, false);
        assert_eq!(code(command("Set-GpuVMAgentSettings", &json!({ "MaxSteps": 5 }), &mut was_agent)), "denied");
        assert_eq!(code(command("Resolve-GpuVMAgentRequest", &json!({ "Id": "x", "Allow": true }), &mut was_agent)), "denied");
        // A deleted (or renamed) machine's name is no longer what a session made.
        // A copy made under another name with no vmId in the result is nobody's.
        let mut r = json!({ "cmd": "New-GpuVM", "args": { "Name": "Copy2", "Template": "t", "Disposable": true, "Connection": id } });
        gate(&mut r, 100, false).unwrap().succeeded(&json!([{ "name": "Copy2" }]));
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy2" }), 100), "denied");
        // What a session made is known by the VM's id: once the name is gone, a new machine with it isn't the session's.
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "copy1" }), 100), "ok");
        // Deleted outside GpuVM and made again with the same name (another VM id): not the session's any more.
        TEST_HV.lock().unwrap().insert("copy1".into(), "99999999-7e8f-4a1b-9c2d-3e4f5a6b7c8d".into());
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy1" }), 100), "denied");
        assert_eq!(gate_code("Install-GpuVMAgent", json!({ "Name": "Copy1" }), 100), "not_taken");
        TEST_HV.lock().unwrap().insert("copy1".into(), "3a4b5c6d-7e8f-4a1b-9c2d-3e4f5a6b7c8d".into());
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy1" }), 100), "denied"); // forgotten for good
        forget_name("Copy1");
        assert_eq!(gate_code("Remove-GpuVMDisposable", json!({ "Name": "Copy1" }), 100), "denied");
        for c in lock(&broker().clients).values_mut() {
            c.max_steps = 6;
            c.steps = 2;
        }
        assert_eq!(get_clients(Some(&id))[0]["machine"], "Test1");
        assert_eq!(code(command("Suspend-GpuVMAgent", &json!({ "Name": "Test1", "Message": "mine" }), &mut app)), "ok");
        assert_eq!(invoke(&mut mcp, Some(&id)), "paused"); // step 3
        let agents = get_agents(Some("Test1"));
        assert_eq!(agents[0]["paused"]["by"], "person");
        assert_eq!(agents[0]["takenBy"]["connection"], json!(id));
        assert_eq!(code(command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut app)), "ok");
        // The agent asks for a human: paused until the person resumes.
        let r = command("Request-GpuVMHuman", &json!({ "Name": "Test1", "Connection": id, "Message": "Please sign in" }), &mut mcp).unwrap();
        assert!(r["requestId"].is_string());
        assert_eq!(get_agents(Some("Test1"))[0]["paused"]["by"], "agent");
        assert_eq!(invoke(&mut mcp, Some(&id)), "paused"); // step 4
        command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut app).unwrap();
        // A session withdraws only its own waiting request; withdrawing a call for a human resumes the machine.
        let revoke = |ctx: &mut Ctx, rid: &str, conn: &str| code(command("Revoke-GpuVMAgentRequest", &json!({ "Id": rid, "Connection": conn }), ctx));
        let human = command("Request-GpuVMHuman", &json!({ "Name": "Test1", "Connection": id, "Message": "help" }), &mut mcp).unwrap()["requestId"].as_str().unwrap().to_string();
        assert_eq!(revoke(&mut other, &human, &id2), "denied"); // another session's call
        assert_eq!(revoke(&mut mcp, &human, &id2), "not_found"); // a connection that isn't the caller's
        assert_eq!(revoke(&mut mcp, &human, &id), "ok");
        assert!(get_agents(Some("Test1"))[0]["paused"].is_null());
        assert_eq!(revoke(&mut mcp, &human, &id), "not_found"); // already withdrawn
        // The person's pause is never withdrawn, not even when it replaced the session's call for a human.
        let human = command("Request-GpuVMHuman", &json!({ "Name": "Test1", "Connection": id, "Message": "help" }), &mut mcp).unwrap()["requestId"].as_str().unwrap().to_string();
        command("Suspend-GpuVMAgent", &json!({ "Name": "Test1", "Reason": "control" }), &mut app).unwrap();
        assert_eq!(revoke(&mut mcp, &human, &id), "not_found");
        assert_eq!(get_agents(Some("Test1"))[0]["paused"]["by"], "person");
        command("Resume-GpuVMAgent", &json!({ "Name": "Test1" }), &mut app).unwrap();
        // An approval request: only its session withdraws it, once, and the person can't answer it afterwards.
        let ask = command("New-GpuVMAgentRequest", &json!({ "Name": "Test1", "Connection": id, "Kind": "network" }), &mut mcp).unwrap()["requestId"].as_str().unwrap().to_string();
        assert_eq!(revoke(&mut other, &ask, &id2), "denied");
        assert_eq!(revoke(&mut mcp, &ask, &id), "ok");
        assert_eq!(revoke(&mut mcp, &ask, &id), "bad_request");
        assert_eq!(code(command("Resolve-GpuVMAgentRequest", &json!({ "Id": ask, "Allow": true }), &mut app)), "bad_request");
        assert_eq!(invoke(&mut mcp, Some(&id)), "off"); // step 5
        assert_eq!(invoke(&mut mcp, Some(&id)), "off"); // step 6
        assert_eq!(invoke(&mut mcp, Some(&id)), "budget");
        // The app's view of the session: newest step first, the machine, the budget.
        let c = &get_clients(Some(&id))[0];
        assert_eq!(c["steps"], 6);
        assert_eq!(c["maxSteps"], 6);
        assert_eq!(c["actions"][0]["code"], "off");
        assert!(c["actions"][0]["id"].as_u64().unwrap() > c["actions"][1]["id"].as_u64().unwrap());
        // Suspend by session, "*" = every session's machine.
        assert_eq!(command("Suspend-GpuVMAgent", &json!({ "Connection": "*", "Reason": "control" }), &mut app).unwrap()[0]["name"], "Test1");
        assert_eq!(get_clients(Some(&id))[0]["state"], "control");
        assert_eq!(command("Resume-GpuVMAgent", &json!({ "Connection": id }), &mut app).unwrap(), json!([]));
        assert_eq!(get_clients(Some(&id))[0]["state"], "control");
        assert_eq!(code(command("Resume-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id2 }), &mut app)), "not_found");
        assert_eq!(command("Resume-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id }), &mut app).unwrap()[0]["name"], "Test1");
        assert!(get_clients(Some(&id))[0]["resumedAt"].is_u64());
        // A call for a human is the session's own pause: resuming the session lifts it.
        command("Request-GpuVMHuman", &json!({ "Name": "Test1", "Connection": id, "Message": "help" }), &mut mcp).unwrap();
        assert_eq!(command("Resume-GpuVMAgent", &json!({ "Connection": id }), &mut app).unwrap()[0]["name"], "Test1");
        assert!(get_agents(Some("Test1"))[0]["paused"].is_null());
        // Outbox offers are checked before anything reaches the guest.
        assert_eq!(code(command("New-GpuVMAgentOffer", &json!({ "Name": "Test1", "Path": r"C:\Windows\win.ini" }), &mut app)), "denied");
        // Kill switch: everything of that session stops and its machines are freed.
        let r = command("Stop-GpuVMAgentClient", &json!({ "Connection": id2 }), &mut app).unwrap();
        assert_eq!(r["stopped"][0], json!(id2));
        assert_eq!(invoke(&mut other, Some(&id2)), "killed");
        assert_eq!(code(command("Lock-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id2 }), &mut other)), "killed");
        // A session reads only its own: not another session's steps, screenshots or requests.
        assert_eq!(code(command("Get-GpuVMAgentClient", &json!({ "Connection": id }), &mut other)), "not_found");
        assert!(command("Get-GpuVMAgentClient", &json!({}), &mut other).unwrap().as_array().unwrap().iter().all(|c| c["id"] == json!(id2)));
        assert_eq!(code(command("Get-GpuVMAgentCapture", &json!({ "Connection": id, "Action": 1 }), &mut other)), "not_found");
        assert!(command("Get-GpuVMAgentRequest", &json!({}), &mut other).unwrap().as_array().unwrap().iter().all(|r| r["connection"] == json!(id2)));
        assert!(command("Get-GpuVMAgentRequest", &json!({}), &mut app).unwrap().as_array().unwrap().iter().any(|r| r["connection"] == json!(id)));
        assert!(command("Get-GpuVMAgentClient", &json!({}), &mut app).unwrap().as_array().unwrap().len() >= 2);
        // A call for a human ends with its session: closing the MCP pipe connection frees the machine and its pause.
        command("Request-GpuVMHuman", &json!({ "Name": "Test1", "Connection": id, "Message": "help" }), &mut mcp).unwrap();
        assert_eq!(get_agents(Some("Test1"))[0]["paused"]["by"], "agent");
        drop(mcp);
        assert!(get_agents(Some("Test1"))[0]["takenBy"].is_null());
        assert!(get_agents(Some("Test1"))[0]["paused"].is_null());
        assert_eq!(code(command("Lock-GpuVMAgent", &json!({ "Name": "Test1", "Connection": id }), &mut app)), "not_found");
        assert_eq!(get_agents(Some("Nope"))[0]["state"], "no-agent");
        // A deleted machine's registration and SYSTEM-only secret go through the service, for the module only.
        let gone = "1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f";
        std::fs::create_dir_all(dir.join(gone)).unwrap();
        std::fs::write(dir.join(gone).join("secret"), b"x").unwrap();
        std::fs::write(dir.join(gone).join("agent.json"), "{}").unwrap();
        let remove = |ctx: &mut Ctx, id: &str| command("Remove-GpuVMAgentRegistration", &json!({ "VmId": id }), ctx);
        assert_eq!(code(remove(&mut app, gone)), "denied");
        assert!(dir.join(gone).join("secret").exists());
        let mut module = Ctx::new(std::ptr::null_mut(), 400, true);
        assert_eq!(code(remove(&mut module, "..\\Test1")), "bad_request");
        assert_eq!(code(remove(&mut module, "settings.json")), "bad_request");
        assert_eq!(remove(&mut module, &gone.to_uppercase()).unwrap()["removed"], json!(true));
        assert!(!dir.join(gone).exists());
        assert_eq!(remove(&mut module, gone).unwrap()["removed"], json!(false));
        assert!(dir.join("settings.json").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn outbox_paths() {
        let o = |p: &str| outbox_file(p, None);
        assert_eq!(o(r"C:\Users\agent\Desktop\Outbox\report.html").as_deref(), Some("report.html"));
        assert_eq!(o(r"c:\users\AGENT\desktop\outbox\a.png").as_deref(), Some("a.png"));
        assert_eq!(o(r"Desktop\Outbox\x.txt").as_deref(), Some("x.txt"));
        assert!(o(r"C:\Users\agent\Desktop\Outbox\..\secret").is_none());
        assert!(o(r"Desktop\Outbox\..\..\secret").is_none());
        assert!(o(r"C:\Users\agent\Desktop\Outbox\sub\a.txt").is_none());
        assert!(o(r"C:\Users\agent\Desktop\Outbox\a.txt:stream").is_none());
        assert!(o(r"C:\Users\agent\Desktop\Outbox\").is_none());
        assert!(o(r"C:\Users\agent\Desktop\Outboxx\a").is_none());
        assert!(o(r"C:\Windows\a.txt").is_none());
        assert!(o("C:/Users/agent/Desktop/Outbox/a.txt").is_none());
        // The home the agent reports (a profile folder named otherwise).
        let home = Some(r"C:\Users\agent.AGENT051");
        assert_eq!(outbox_file(r"C:\Users\agent.AGENT051\Desktop\Outbox\r.txt", home).as_deref(), Some("r.txt"));
        assert!(outbox_file(r"C:\Users\agent\Desktop\Outbox\r.txt", home).is_none());
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
    fn screen_event() {
        assert!(EVENTS.contains(&"screen"));
        let info = Mutex::new(json!({ "version": "0.3.5", "screen": { "w": 1024, "h": 768 } }));
        let changed = AtomicU64::new(0);
        assert!(note_screen(&info, &changed, &json!({ "w": 1280, "h": 800 })));
        assert_eq!(lock(&info)["screen"], json!({ "w": 1280, "h": 800 }));
        assert_eq!(lock(&info)["version"], "0.3.5");
        assert!(changed.load(Ordering::SeqCst) > 0);
        // A hostile or broken size changes nothing.
        let before = changed.load(Ordering::SeqCst);
        assert!(!note_screen(&info, &changed, &json!({ "w": 0, "h": 800 })));
        assert!(!note_screen(&info, &changed, &json!({ "w": 99999, "h": 800 })));
        assert!(!note_screen(&info, &changed, &json!({ "w": "1280", "h": 800 })));
        assert_eq!(lock(&info)["screen"]["w"], 1280);
        assert_eq!(changed.load(Ordering::SeqCst), before);
    }

    #[test]
    fn sweep_choices() {
        let a = "0b5d1f53-1e33-4b7e-9f0a-2c4d6e8f0a1b";
        let b = "4e9fa79e-58b4-4638-a98b-c7a0e3e78256";
        assert_eq!(parse_vm_ids("WARNING: x\nOK:0B5D1F53-1E33-4B7E-9F0A-2C4D6E8F0A1B\n"), Some(vec![a.to_string()]));
        assert_eq!(parse_vm_ids("OK:"), Some(vec![]));
        // Anything but a clean list means "don't know": nothing may be deleted then.
        assert_eq!(parse_vm_ids(""), None);
        assert_eq!(parse_vm_ids("Get-VM: access denied"), None);
        assert_eq!(parse_vm_ids("OK:not-a-guid"), None);
        let old = Duration::from_secs(3600);
        let folders = vec![(a.to_string(), old), (b.to_string(), old), (b.to_uppercase(), Duration::from_secs(5)), ("blobs".to_string(), old)];
        // The VM that exists stays; a young folder stays (an install may be writing it); other folders stay.
        assert_eq!(orphans(&folders, &[a.to_string()]), vec![b.to_string()]);
    }

    #[test]
    fn a_machine_without_display_is_power_cycled_once() {
        assert_eq!(display_verdict(true, Some(5_000), false, true, 0), Verdict::Fine); // may just be starting
        assert_eq!(display_verdict(true, Some(21_000), false, true, 0), Verdict::Repair);
        assert_eq!(display_verdict(true, Some(1_000), true, true, 0), Verdict::Repair); // the agent says so: at once
        assert_eq!(display_verdict(false, None, false, false, 1), Verdict::Repairing); // off and on: no agent meanwhile
        assert_eq!(display_verdict(true, Some(21_000), true, true, 1), Verdict::Repairing);
        assert_eq!(display_verdict(true, Some(25_000), true, true, 2), Verdict::NoDisplay(25_000)); // never twice
        assert_eq!(display_verdict(true, None, false, true, 2), Verdict::Recovered);
        assert_eq!(display_verdict(true, None, false, true, 0), Verdict::Fine);
    }

    #[test]
    fn no_display_after_twenty_seconds() {
        let since = AtomicU64::new(0);
        let blank = json!({ "signedIn": true, "displays": [] });
        assert_eq!(blank_for(&blank, &since, 1_000), Some(0));
        assert_eq!(blank_for(&blank, &since, 15_000), Some(14_000));
        assert!(blank_for(&blank, &since, 22_000).unwrap() > NO_DISPLAY_AFTER_MS);
        // A display, or nobody signed in, isn't "no display": the count starts again.
        assert_eq!(blank_for(&json!({ "signedIn": true, "displays": [{ "device": "x" }] }), &since, 23_000), None);
        assert_eq!(blank_for(&blank, &since, 24_000), Some(0));
        assert_eq!(blank_for(&json!({ "signedIn": false, "displays": [] }), &since, 25_000), None);
        assert_eq!(blank_for(&Value::Null, &since, 26_000), None);
    }

    #[test]
    fn signed_in_shows_at_once() {
        let info = Mutex::new(json!({ "signedIn": false, "user": null, "displays": [] }));
        note_signed_in(&info, &json!({ "user": "AGENT-BASE\\agent" }));
        assert_eq!(lock(&info)["signedIn"], true);
        assert_eq!(lock(&info)["user"], "AGENT-BASE\\agent");
        note_signed_in(&info, &json!({ "user": null }));
        assert_eq!(lock(&info)["signedIn"], false);
        assert!(lock(&info)["user"].is_null());
        assert_eq!(seconds(&json!(600)), Some(600));
        assert_eq!(seconds(&json!(600.0)), Some(600));
        assert_eq!(seconds(&json!("90")), Some(90));
        assert_eq!(seconds(&json!(-1)), None);
        assert_eq!(seconds(&json!(1.5)), None);
    }

    #[test]
    fn dangerous_names_never_land() {
        for bad in ["COM1.txt", "lpt9", "COM\u{b9}.txt", "LPT\u{b3}", "con", "AUX.log"] {
            assert!(safe_file_name(bad).is_none(), "{bad}");
        }
        assert_eq!(safe_file_name("COMET.txt").as_deref(), Some("COMET.txt"));
        for bad in ["x.url", "Report.LNK", "a.scf", "b.library-ms", "c.searchConnector-ms", "desktop.ini", "Desktop.INI"] {
            assert!(!offer_kind_allowed(bad), "{bad}");
        }
        assert!(offer_kind_allowed("report.pdf"));
    }

    #[test]
    fn log_redacts_typed_text() {
        let params = json!({ "actions": [{ "type": "type", "text": "my password" }, { "type": "key", "value": "secret" }],
            "command": "curl x", "stdin": "abc", "nested": { "args": ["a", "b"] }, "x": 5 });
        let logged = loggable(&params).to_string();
        for secret in ["my password", "secret", "curl x", "abc", "\"a\""] {
            assert!(!logged.contains(secret), "{secret} reached the log: {logged}");
        }
        assert!(logged.contains("<11 chars>"));
        assert_eq!(loggable(&params)["x"], 5);
    }

    #[test]
    fn bounded_values() {
        let long = "a".repeat(1000);
        let v = bounded(&json!({ "s": long, "deep": {"a": {"b": {"c": {"d": 1}}}} }), 3);
        assert_eq!(v["s"].as_str().unwrap().len(), 300);
        assert!(v["deep"]["a"]["b"].is_null());
    }
}
