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
// Not GENERIC_WRITE: on a pipe it includes FILE_CREATE_PIPE_INSTANCE, letting any user program serve its own instances.
const CLIENT_ACCESS: u32 = 0x0010_0083;
const NEEDS_CONSENT: &[&str] = &["Remove-GpuVM", "Remove-GpuVMDisk", "Remove-GpuVMSharedDisk", "Remove-GpuVMTemplate", "Remove-GpuVMBase",
    "Remove-GpuVMRestorePoint", "Uninstall-GpuVMAgent"];
const CONSENT_TTL: Duration = Duration::from_secs(120);

pub static BUSY: AtomicUsize = AtomicUsize::new(0);
pub static QUICK: AtomicUsize = AtomicUsize::new(0);
pub static STOPPING: AtomicBool = AtomicBool::new(false);
static CONNECTIONS: AtomicUsize = AtomicUsize::new(0);
static STOP_WHEN_IDLE: AtomicBool = AtomicBool::new(false);

pub fn install_dir() -> PathBuf {
    std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)).unwrap_or_default()
}

pub fn log(line: &str) {
    if cfg!(test) {
        return;
    }
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

struct Pending {
    client_pid: u32,
    sid: String,
    request: String,
    created: Instant,
    approved: bool,
}

static PENDING: Mutex<Option<HashMap<String, Pending>>> = Mutex::new(None);

// Canonical text of a request (command and arguments), so a confirmation only covers exactly what was shown.
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

fn host_paths(request: &Value) -> Vec<(String, PathAccess)> {
    let args = &request["args"];
    let mut paths = Vec::new();
    let mut add = |v: &Value, kind: PathAccess| {
        if let Some(s) = v.as_str().filter(|s| !s.is_empty()) {
            paths.push((s.to_string(), kind));
        }
    };
    match request["cmd"].as_str().unwrap_or("") {
        "New-GpuVM" => add(&args["IsoPath"], PathAccess::ReadFile),
        "Add-GpuVMIso" => add(&args["Path"], PathAccess::ReadFile),
        "Import-GpuVMSharedDisk" => add(&args["Path"], PathAccess::ListFolder),
        "Save-GpuVMProfile" => add(&args["Settings"]["iso"], PathAccess::ReadFile),
        "Import-GpuVM" | "Get-GpuVMImportInfo" => add(&args["Path"], PathAccess::ReadFile),
        "Export-GpuVM" => {
            if let Some((folder, _)) = args["Path"].as_str().and_then(|p| p.rsplit_once('\\')) {
                let folder = if folder.len() == 2 { format!("{folder}\\") } else { folder.to_string() };
                add(&json!(folder), PathAccess::WriteFolder);
            } else {
                add(&args["Path"], PathAccess::WriteFolder);
            }
        }
        // A non-text value is kept as an invalid path, so it is refused instead of skipping the check.
        "Send-GpuVMClipboard" if !args["Files"].is_null() => {
            let list = match &args["Files"] { Value::Array(list) => list.clone(), other => vec![other.clone()] };
            for v in list {
                paths.push((v.as_str().unwrap_or("?").to_string(), PathAccess::ListFolder));
            }
        }
        "Send-GpuVMFile" if args["FromVM"].as_str().unwrap_or("").is_empty() => {
            let list = match &args["Path"] { Value::Array(list) => list.clone(), other => vec![other.clone()] };
            for v in list {
                paths.push((v.as_str().unwrap_or("?").to_string(), PathAccess::ListFolder));
            }
        }
        _ => {}
    }
    paths
}

fn needs_consent(request: &Value) -> bool {
    let cmd = request["cmd"].as_str().unwrap_or("");
    NEEDS_CONSENT.contains(&cmd) || (cmd == "Restore-GpuVMRestorePoint" && request["args"]["SaveCurrent"] != json!(true))
        || (cmd == "Set-GpuVMUse" && request["args"]["Use"].as_str().is_some_and(|u| u.trim().eq_ignore_ascii_case("none")))
}

fn check_paths_as_client(pipe: HANDLE, request: &Value) -> Result<(), String> {
    for (path, kind) in host_paths(request) {
        if !is_plain_local_path(&path) {
            return Err(format!("{path} isn't a path on a disk of this PC."));
        }
        if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
            return Err(last_error("ImpersonateNamedPipeClient"));
        }
        let result = check_access(&path, kind);
        if unsafe { RevertToSelf() } == 0 {
            // Never keep running as someone else: stop the service rather than continue impersonating.
            log("RevertToSelf failed; the service stops");
            std::process::exit(1);
        }
        result?;
    }
    Ok(())
}

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
        return Err("Some GpuVM files are missing. Install it again.".into());
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

pub struct Busy(bool);
impl Busy {
    pub fn start() -> Self {
        BUSY.fetch_add(1, Ordering::SeqCst);
        Busy(true)
    }
    pub fn quick() -> Self {
        QUICK.fetch_add(1, Ordering::SeqCst);
        Busy(false)
    }
    pub fn for_command(cmd: &str) -> Self {
        if cmd.starts_with("Get-") || cmd.starts_with("Test-") { Busy::quick() } else { Busy::start() }
    }
}
impl Drop for Busy {
    fn drop(&mut self) {
        if self.0 { BUSY.fetch_sub(1, Ordering::SeqCst) } else { QUICK.fetch_sub(1, Ordering::SeqCst) };
    }
}

struct Client {
    pid: u32,
    sid: String,
    session: u32,
    elevated: bool,
}

fn identify(pipe: HANDLE) -> Result<Client, String> {
    let mut pid = 0;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
        return Err(last_error("GetNamedPipeClientProcessId"));
    }
    let process = open_process(pid)?;
    let image = process_image(process.0)?;
    let allowed = install_dir().join("gpuvm.exe");
    if !image.as_os_str().eq_ignore_ascii_case(allowed.as_os_str()) {
        return Err(format!("program not allowed: {}", image.display()));
    }
    let token = process_token(process.0)?;
    Ok(Client { pid, sid: token_sid(token.0)?, session: session_of(pid), elevated: token_elevated(token.0)? })
}

fn send(out: &mut &File, value: &Value) -> bool {
    writeln!(out, "{value}").and_then(|_| out.flush()).is_ok()
}

const MAX_REQUEST_LINE: u64 = 24 << 20;

fn handle(pipe: HANDLE) {
    let client = match identify(pipe) {
        Ok(c) => c,
        Err(reason) => {
            log(&format!("rejected: {reason}"));
            return;
        }
    };
    let file = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(pipe) });
    let mut out: &File = &file;
    let mut reader = BufReader::new(&*file);
    let mut bridge: Option<Bridge> = None;
    let mut agent_ctx = crate::agent::Ctx::new(pipe, client.pid, false);
    let mut line = String::new();
    // One request at a time, as the app sends them: the synchronous pipe is never read and written at once.
    loop {
        line.clear();
        let n = std::io::Read::take(&mut reader, MAX_REQUEST_LINE).read_line(&mut line).unwrap_or(0);
        if n == 0 {
            return;
        }
        if !line.ends_with('\n') && n as u64 >= MAX_REQUEST_LINE {
            log("rejected: a request line over the limit");
            send(&mut out, &json!({ "type": "result", "ok": false, "error": "The request is too large." }));
            return;
        }
        let Ok(request) = serde_json::from_str::<Value>(&line) else {
            send(&mut out, &json!({ "type": "result", "ok": false, "error": "Invalid request." }));
            continue;
        };
        let id = request["id"].clone();
        let fail = |out: &mut &File, error: String| send(out, &json!({ "id": id, "type": "result", "ok": false, "error": error }));

        if let Some(nonce) = request["consent"].as_str().filter(|_| request["cmd"].is_null()) {
            let ok = client.elevated && approve_consent(nonce, &client.sid);
            log(&format!("confirmation {}", if ok { "accepted" } else { "rejected" }));
            send(&mut out, &json!({ "type": "consent", "ok": ok }));
            continue;
        }
        if request["control"] == "stop-when-idle" {
            STOP_WHEN_IDLE.store(true, Ordering::SeqCst);
            send(&mut out, &json!({ "type": "control", "ok": true }));
            continue;
        }
        if STOPPING.load(Ordering::SeqCst) {
            fail(&mut out, "The GpuVM service is stopping.".into());
            return;
        }
        let Some(cmd) = request["cmd"].as_str().map(str::to_string) else {
            fail(&mut out, "Invalid request.".into());
            continue;
        };
        if crate::agent::is_command(&cmd) {
            let _busy = Busy::quick();
            let reply = crate::agent::result_line(&id, crate::agent::command(&cmd, &request["args"], &mut agent_ctx));
            if !send(&mut out, &reply) {
                return;
            }
            continue;
        }
        let mut request = request;
        let mut gated = match crate::agent::gate(&mut request, client.pid, agent_ctx.is_agent_pipe()) {
            Ok(g) => Some(g),
            Err(e) => {
                send(&mut out, &json!({ "id": id, "type": "result", "ok": false, "error": e.message, "code": e.code }));
                continue;
            }
        };
        if needs_consent(&request) {
            let confirmed = request["consent"].as_str().is_some_and(|n| take_consent(n, client.pid, &request));
            if !confirmed {
                let nonce = new_consent(client.pid, &client.sid, &request);
                send(&mut out, &json!({ "id": id, "type": "result", "ok": false, "error": "This needs your confirmation as administrator.", "consent": nonce }));
                continue;
            }
            log(&format!("{cmd} confirmed"));
        }
        if let Err(e) = check_paths_as_client(pipe, &request) {
            fail(&mut out, e);
            continue;
        }
        if bridge.is_none() {
            match elevated_user_token(client.session, &client.sid).and_then(|t| spawn_bridge(&t)) {
                Ok(b) => bridge = Some(b),
                Err(e) => {
                    log(&format!("bridge: {e}"));
                    fail(&mut out, e);
                    return;
                }
            }
        }
        let b = bridge.as_mut().unwrap();
        let _busy = Busy::for_command(&cmd);
        let forward = json!({ "id": id, "cmd": cmd, "args": request["args"] }).to_string();
        if writeln!(b.stdin, "{forward}").and_then(|_| b.stdin.flush()).is_err() {
            fail(&mut out, "PowerShell stopped responding.".into());
            return;
        }
        // The request still finishes if the app goes away meanwhile: never stop halfway.
        let mut client_gone = false;
        let mut event = String::new();
        loop {
            event.clear();
            if b.stdout.read_line(&mut event).unwrap_or(0) == 0 {
                if !client_gone {
                    fail(&mut out, "PowerShell stopped responding.".into());
                }
                return;
            }
            if !client_gone {
                client_gone = out.write_all(event.as_bytes()).and_then(|_| out.flush()).is_err();
            }
            let parsed = serde_json::from_str::<Value>(&event).unwrap_or(Value::Null);
            if parsed["type"] == "result" && parsed["id"] == id {
                if parsed["ok"] == json!(true) {
                    if let Some(g) = gated.take() {
                        g.succeeded(&parsed["data"]);
                    }
                }
                break;
            }
        }
        if client_gone {
            return;
        }
    }
}

pub fn serve() {
    crate::agent::start();
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
        // Counted in order: a connection opened before the app's "stop when idle" keeps the service up; one opened after cancels the stop.
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
                log("stopped when GpuVM quit");
                crate::stop_now();
            }
        });
    }
}
