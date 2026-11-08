//! The pipe the GpuVM window talks to, and the PowerShell bridge behind it.
//!
//! Who may connect: GpuVM's own `gpuvm.exe` (next to this service, in an administrators-only folder), run by the
//! user signed in to that session, whose account is an administrator. Each connection gets its own bridge
//! (`bridge.ps1` in GpuVM's PowerShell 7) running with that user's elevated token: the same profile, saved
//! passwords and folders as when the app itself ran elevated. The protocol is the bridge's own: one JSON request
//! per line, events back until the request's result.
//!
//! What the service adds on top:
//! - Paths of this PC in a request (ISO, folder to import) are opened first as the user, unelevated: the service
//!   never reads for them a file they could not read themselves.
//! - Deleting machines or disks needs the user to confirm it in a UAC prompt (an elevated `gpuvm.exe --consent`).

use std::collections::HashMap;
use std::ffi::c_void;
use std::fs::File;
use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::FromRawHandle;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Environment::*;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::*;
use windows_sys::Win32::System::Threading::*;

use crate::win::*;

pub const PIPE: &str = r"\\.\pipe\gpuvm";
// What a user may do on the pipe: read, write, read attributes, synchronize. Not GENERIC_WRITE: on a pipe it
// includes FILE_CREATE_PIPE_INSTANCE, which would let any user program serve its own instances of the name.
const CLIENT_ACCESS: u32 = 0x0010_0083;
/// Commands that destroy data: they run only after a UAC confirmation.
const NEEDS_CONSENT: &[&str] = &["Remove-GpuVM", "Remove-GpuVMDisk", "Remove-GpuVMSharedDisk", "Remove-GpuVMTemplate"];
const CONSENT_TTL: Duration = Duration::from_secs(120);

/// Requests running right now: a stop waits for them.
pub static BUSY: AtomicUsize = AtomicUsize::new(0);
/// Set while the service stops: new requests are refused.
pub static STOPPING: AtomicBool = AtomicBool::new(false);
/// Open connections, and whether the app asked the service to stop once none is left (when it quits).
static CONNECTIONS: AtomicUsize = AtomicUsize::new(0);
static STOP_WHEN_IDLE: AtomicBool = AtomicBool::new(false);

/// Install folder (where this service lives): only administrators can change it.
pub fn install_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default()
}

pub fn log(line: &str) {
    // Next to the module's data (ProgramData\GpuVM, administrators only), and only once the module created it.
    let dir = PathBuf::from(std::env::var("ProgramData").unwrap_or(r"C:\ProgramData".into())).join("GpuVM");
    if !dir.is_dir() {
        return;
    }
    let path = dir.join("host.log");
    if std::fs::metadata(&path).map(|m| m.len() > 1 << 20).unwrap_or(false) {
        let _ = std::fs::rename(&path, dir.join("host.old.log"));
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let _ = writeln!(f, "{t} {line}");
    }
}

// ---------------------------------------------------------------- consent for destructive commands

struct Pending {
    client_pid: u32,
    sid: String,
    request: String,
    created: Instant,
    approved: bool,
}

static PENDING: Mutex<Option<HashMap<String, Pending>>> = Mutex::new(None);

/// Canonical text of a request (command and arguments), so a confirmation only covers exactly what was shown.
fn request_key(request: &Value) -> String {
    json!({ "cmd": request["cmd"], "args": request["args"] }).to_string()
}

fn new_consent(client_pid: u32, sid: &str, request: &Value) -> String {
    let nonce = random_hex();
    let mut guard = PENDING.lock().unwrap();
    let map = guard.get_or_insert_with(HashMap::new);
    map.retain(|_, p| p.created.elapsed() < CONSENT_TTL);
    map.insert(nonce.clone(), Pending { client_pid, sid: sid.into(), request: request_key(request), created: Instant::now(), approved: false });
    nonce
}

fn approve_consent(nonce: &str, sid: &str) -> bool {
    let mut guard = PENDING.lock().unwrap();
    match guard.as_mut().and_then(|m| m.get_mut(nonce)) {
        Some(p) if p.sid == sid && p.created.elapsed() < CONSENT_TTL => {
            p.approved = true;
            true
        }
        _ => false,
    }
}

/// Uses up an approved confirmation: same program instance, same command and arguments, still fresh.
fn take_consent(nonce: &str, client_pid: u32, request: &Value) -> bool {
    let mut guard = PENDING.lock().unwrap();
    let Some(map) = guard.as_mut() else { return false };
    let ok = matches!(map.get(nonce), Some(p) if p.approved && p.client_pid == client_pid
        && p.created.elapsed() < CONSENT_TTL && p.request == request_key(request));
    if ok {
        map.remove(nonce);
    }
    ok
}

// ---------------------------------------------------------------- paths of this PC in requests

/// Arguments that name a file or folder of this PC, by command: (path, is a folder).
fn host_paths(request: &Value) -> Vec<(String, bool)> {
    let args = &request["args"];
    let mut paths = Vec::new();
    let mut add = |v: &Value, folder: bool| {
        if let Some(s) = v.as_str().filter(|s| !s.is_empty()) {
            paths.push((s.to_string(), folder));
        }
    };
    match request["cmd"].as_str().unwrap_or("") {
        "New-GpuVM" => add(&args["IsoPath"], false),
        "Add-GpuVMIso" => add(&args["Path"], false),
        "Import-GpuVMSharedDisk" => add(&args["Path"], true),
        "Save-GpuVMProfile" => add(&args["Settings"]["iso"], false),
        _ => {}
    }
    paths
}

/// Checks each path as the user on the other end of the pipe (unelevated), then goes back to the service's identity.
fn check_paths_as_client(pipe: HANDLE, request: &Value) -> Result<(), String> {
    for (path, folder) in host_paths(request) {
        if !is_plain_local_path(&path) {
            return Err(format!("{path} no es una ruta de un disco de este equipo."));
        }
        if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
            return Err(last_error("ImpersonateNamedPipeClient"));
        }
        let result = check_access(&path, folder);
        if unsafe { RevertToSelf() } == 0 {
            // Never keep running as someone else: stop the service rather than continue impersonating.
            log("RevertToSelf falló; el servicio se detiene");
            std::process::exit(1);
        }
        result?;
    }
    Ok(())
}

// ---------------------------------------------------------------- the bridge

struct Bridge {
    process: Handle,
    stdin: File,
    stdout: BufReader<File>,
}

impl Drop for Bridge {
    fn drop(&mut self) {
        unsafe { TerminateProcess(self.process.0, 0) };
    }
}

static JOB: OnceLock<Handle> = OnceLock::new();
// Inheritable handles exist only while one bridge is being created, so no bridge inherits another's pipes.
static SPAWN: Mutex<()> = Mutex::new(());

fn job() -> HANDLE {
    JOB.get_or_init(|| unsafe {
        // Bridges die with the service, even if it crashes: the job closes when its process exits.
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as *const c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32);
        Handle(job)
    })
    .0
}

fn spawn_bridge(token: &Handle) -> Result<Bridge, String> {
    let dir = install_dir();
    let pwsh = dir.join("pwsh").join("pwsh.exe");
    let code = dir.join("gpuvm");
    let script = code.join("src").join("bridge.ps1");
    if !pwsh.exists() || !script.exists() {
        return Err("Faltan archivos de GpuVM. Vuelve a instalarlo.".into());
    }
    let _guard = SPAWN.lock().unwrap();
    unsafe {
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: std::ptr::null_mut(), bInheritHandle: 1 };
        let (mut in_r, mut in_w, mut out_r, mut out_w) = (std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
        if CreatePipe(&mut in_r, &mut in_w, &sa, 0) == 0 {
            return Err(last_error("CreatePipe"));
        }
        let (in_r, in_w) = (Handle(in_r), Handle(in_w));
        if CreatePipe(&mut out_r, &mut out_w, &sa, 0) == 0 {
            return Err(last_error("CreatePipe"));
        }
        let (out_r, out_w) = (Handle(out_r), Handle(out_w));
        SetHandleInformation(in_w.0, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(out_r.0, HANDLE_FLAG_INHERIT, 0);
        let nul = Handle(CreateFileW(wide("NUL").as_ptr(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, std::ptr::null_mut()));

        // The user's interactive desktop: the bridge reads the clipboard and starts Moonlight in their session.
        let mut desktop = wide("winsta0\\default");
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = in_r.0;
        si.hStdOutput = out_w.0;
        si.hStdError = nul.0;
        si.lpDesktop = desktop.as_mut_ptr();
        let mut cmd = wide(&format!("\"{}\" -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{}\"", pwsh.display(), script.display()));
        let mut env = std::ptr::null_mut();
        if CreateEnvironmentBlock(&mut env, token.0, 0) == 0 {
            return Err(last_error("CreateEnvironmentBlock"));
        }
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let ok = CreateProcessAsUserW(token.0, wide_path(&pwsh).as_ptr(), cmd.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 1,
            CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT, env, wide_path(&code).as_ptr(), &si, &mut pi);
        DestroyEnvironmentBlock(env);
        if ok == 0 {
            return Err(last_error("CreateProcessAsUserW"));
        }
        AssignProcessToJobObject(job(), pi.hProcess);
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        let stdin = File::from_raw_handle(in_w.0);
        let stdout = BufReader::new(File::from_raw_handle(out_r.0));
        std::mem::forget(in_w);
        std::mem::forget(out_r);
        Ok(Bridge { process: Handle(pi.hProcess), stdin, stdout })
    }
}

// ---------------------------------------------------------------- one connection

/// Counts a request as running while it lives.
struct Busy;
impl Busy {
    fn start() -> Self {
        BUSY.fetch_add(1, Ordering::SeqCst);
        Busy
    }
}
impl Drop for Busy {
    fn drop(&mut self) {
        BUSY.fetch_sub(1, Ordering::SeqCst);
    }
}

struct Client {
    pid: u32,
    sid: String,
    session: u32,
    elevated: bool,
}

/// Who is on the other end: GpuVM's own program, run by a user signed in to this PC.
fn identify(pipe: HANDLE) -> Result<Client, String> {
    let mut pid = 0;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
        return Err(last_error("GetNamedPipeClientProcessId"));
    }
    let process = open_process(pid)?;
    let image = process_image(process.0)?;
    let allowed = install_dir().join("gpuvm.exe");
    if !image.as_os_str().eq_ignore_ascii_case(allowed.as_os_str()) {
        return Err(format!("programa no permitido: {}", image.display()));
    }
    let token = process_token(process.0)?;
    Ok(Client { pid, sid: token_sid(token.0)?, session: session_of(pid), elevated: token_elevated(token.0)? })
}

fn send(out: &mut &File, value: &Value) -> bool {
    writeln!(out, "{value}").and_then(|_| out.flush()).is_ok()
}

fn handle(pipe: HANDLE) {
    let client = match identify(pipe) {
        Ok(c) => c,
        Err(reason) => {
            log(&format!("rechazado: {reason}"));
            return;
        }
    };
    let file = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(pipe) });
    let mut out: &File = &file;
    let mut reader = BufReader::new(&*file);
    let mut bridge: Option<Bridge> = None;
    let mut line = String::new();
    // One request at a time, as the app sends them: the synchronous pipe is never read and written at once.
    loop {
        line.clear();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            send(&mut out, &json!({ "type": "result", "ok": false, "error": "Petición no válida." }));
            continue;
        };
        let id = request["id"].clone();
        let fail = |out: &mut &File, error: String| send(out, &json!({ "id": id, "type": "result", "ok": false, "error": error }));

        // An elevated gpuvm.exe (after the user said yes in UAC) confirms a pending deletion.
        if let Some(nonce) = request["consent"].as_str().filter(|_| request["cmd"].is_null()) {
            let ok = client.elevated && approve_consent(nonce, &client.sid);
            log(&format!("confirmación {}", if ok { "aceptada" } else { "rechazada" }));
            send(&mut out, &json!({ "type": "consent", "ok": ok }));
            continue;
        }
        // The app quits: stop once every connection is closed (requests still running finish first).
        if request["control"] == "stop-when-idle" {
            STOP_WHEN_IDLE.store(true, Ordering::SeqCst);
            send(&mut out, &json!({ "type": "control", "ok": true }));
            continue;
        }
        if STOPPING.load(Ordering::SeqCst) {
            fail(&mut out, "El servicio de GpuVM se está deteniendo.".into());
            return;
        }
        let Some(cmd) = request["cmd"].as_str() else {
            fail(&mut out, "Petición no válida.".into());
            continue;
        };
        if NEEDS_CONSENT.contains(&cmd) {
            let confirmed = request["consent"].as_str().is_some_and(|n| take_consent(n, client.pid, &request));
            if !confirmed {
                let nonce = new_consent(client.pid, &client.sid, &request);
                send(&mut out, &json!({ "id": id, "type": "result", "ok": false, "error": "Hace falta confirmarlo como administrador.", "consent": nonce }));
                continue;
            }
            log(&format!("{cmd} confirmado"));
        }
        if let Err(e) = check_paths_as_client(pipe, &request) {
            fail(&mut out, e);
            continue;
        }
        if bridge.is_none() {
            match elevated_user_token(client.session, &client.sid).and_then(|t| spawn_bridge(&t)) {
                Ok(b) => bridge = Some(b),
                Err(e) => {
                    log(&format!("puente: {e}"));
                    fail(&mut out, e);
                    return;
                }
            }
        }
        let b = bridge.as_mut().unwrap();
        let _busy = Busy::start();
        let forward = json!({ "id": id, "cmd": cmd, "args": request["args"] }).to_string();
        if writeln!(b.stdin, "{forward}").and_then(|_| b.stdin.flush()).is_err() {
            fail(&mut out, "PowerShell dejó de responder.".into());
            return;
        }
        // Relay every event (progress, warnings) until this request's result. If the app goes away meanwhile
        // (it quit, or "apagar al salir" sent its last request) the request still finishes: never stop halfway.
        let mut client_gone = false;
        let mut event = String::new();
        loop {
            event.clear();
            if b.stdout.read_line(&mut event).unwrap_or(0) == 0 {
                if !client_gone {
                    fail(&mut out, "PowerShell dejó de responder.".into());
                }
                return;
            }
            if !client_gone {
                client_gone = out.write_all(event.as_bytes()).and_then(|_| out.flush()).is_err();
            }
            let parsed = serde_json::from_str::<Value>(&event).unwrap_or(Value::Null);
            if parsed["type"] == "result" && parsed["id"] == id {
                break;
            }
        }
        if client_gone {
            return;
        }
    }
}

pub fn serve() {
    // SYSTEM and Administrators: full access. Users signed in at this PC: read and write only. Network: denied.
    let sddl = format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x{CLIENT_ACCESS:08x};;;IU)(D;;GA;;;NU)");
    let mut sd = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(&sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        log(&last_error("SDDL"));
        std::process::exit(1);
    }
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    let name = wide(PIPE);
    let mut first = true;
    loop {
        // The first instance claims the name: if another program took it first, the service stops instead.
        let open = PIPE_ACCESS_DUPLEX | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        let pipe = unsafe {
            CreateNamedPipeW(name.as_ptr(), open, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, &sa)
        };
        if pipe == INVALID_HANDLE_VALUE {
            log(&last_error("CreateNamedPipeW"));
            if first {
                std::process::exit(1);
            }
            std::thread::sleep(Duration::from_millis(500));
            continue;
        }
        first = false;
        let connected = unsafe { ConnectNamedPipe(pipe, std::ptr::null_mut()) } != 0 || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        let pipe = Handle(pipe);
        if !connected {
            continue;
        }
        // Counted here, in order: a connection opened before the app's "stop when idle" keeps the service up
        // until it ends; one opened after it (GpuVM opened again) cancels that stop.
        CONNECTIONS.fetch_add(1, Ordering::SeqCst);
        STOP_WHEN_IDLE.store(false, Ordering::SeqCst);
        std::thread::spawn(move || {
            let pipe = pipe;
            handle(pipe.0);
            unsafe {
                FlushFileBuffers(pipe.0);
                DisconnectNamedPipe(pipe.0);
            }
            if CONNECTIONS.fetch_sub(1, Ordering::SeqCst) == 1 && STOP_WHEN_IDLE.load(Ordering::SeqCst) {
                log("detenido al salir de GpuVM");
                crate::stop_now();
            }
        });
    }
}
