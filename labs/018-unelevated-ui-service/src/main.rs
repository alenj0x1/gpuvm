//! Lab 018: GpuVM's window without administrator; the Hyper-V work in an elevated service behind a named pipe.
//!
//! One binary, several roles:
//!   service ...            the Windows service (started by the Service Control Manager)
//!   bench-direct N ...     baseline: spawns bridge.ps1 directly, as the app does today (run elevated)
//!   client bench N         N Get-GpuVMOverview through the service (run unelevated)
//!   client identity        who the bridge runs as, according to the service
//!   client squat           tries to create the service's pipe from an unelevated process (must fail)
//!
//! Client commands take --mode user|system too (default user).
//! Service options: --mode user|system  --allow <exe>  --user-sid <SID>  --code-root <dir>  --pwsh <exe>
//!   user:   the bridge runs with the signed-in user's elevated token (same profile, DPAPI and paths as today)
//!   system: the bridge runs as LocalSystem

use std::ffi::c_void;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::FromRawHandle;
use std::path::PathBuf;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use windows_sys::core::PWSTR;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Environment::*;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Pipes::*;
use windows_sys::Win32::System::RemoteDesktop::*;
use windows_sys::Win32::System::Services::*;
use windows_sys::Win32::System::Threading::*;

// One service and one pipe per mode, so both can be measured side by side (GpuVMLab018-user, gpuvm-lab-018-user...).
static MODE_NAME: OnceLock<String> = OnceLock::new();

fn mode_name() -> &'static str {
    MODE_NAME.get().map(String::as_str).unwrap_or("user")
}

fn pipe_name() -> String {
    format!(r"\\.\pipe\gpuvm-lab-018-{}", mode_name())
}

fn service_name() -> String {
    format!("GpuVMLab018-{}", mode_name())
}
// What the user may do on the pipe: read, write, read attributes, synchronize. Not GENERIC_WRITE: for a pipe it
// includes FILE_CREATE_PIPE_INSTANCE, which would let any user program open its own instances of the name.
const CLIENT_ACCESS: u32 = 0x0010_0083;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn last_error(what: &str) -> String {
    format!("{what} falló (error {})", unsafe { GetLastError() })
}

fn json_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

// ---------------------------------------------------------------- configuration

#[derive(Clone, Copy, PartialEq)]
enum Mode {
    User,
    System,
}

struct Config {
    mode: Mode,
    allow: Vec<String>,
    user_sid: String,
    code_root: PathBuf,
    pwsh: PathBuf,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

fn parse_config(args: &[String]) -> Result<Config, String> {
    let need = |n: &str| arg(args, n).ok_or(format!("falta {n}"));
    Ok(Config {
        mode: if need("--mode")? == "system" { Mode::System } else { Mode::User },
        allow: args
            .iter()
            .enumerate()
            .filter(|(_, a)| *a == "--allow")
            .filter_map(|(i, _)| args.get(i + 1))
            .map(|p| p.to_lowercase())
            .collect(),
        user_sid: need("--user-sid")?,
        code_root: PathBuf::from(need("--code-root")?),
        pwsh: PathBuf::from(need("--pwsh")?),
    })
}

fn log(line: &str) {
    let dir = PathBuf::from(std::env::var("ProgramData").unwrap_or(r"C:\ProgramData".into())).join("GpuVM-lab");
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("host.log")) {
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
        let _ = writeln!(f, "{t} {line}");
    }
}

// ---------------------------------------------------------------- process and token helpers

struct Handle(HANDLE);
unsafe impl Sync for Handle {}
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe { CloseHandle(self.0) };
        }
    }
}

fn open_process(pid: u32) -> Result<Handle, String> {
    let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if h.is_null() { Err(last_error("OpenProcess")) } else { Ok(Handle(h)) }
}

fn process_image(process: HANDLE) -> Result<String, String> {
    let mut buf = [0u16; 1024];
    let mut len = buf.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process, 0, buf.as_mut_ptr(), &mut len) } == 0 {
        return Err(last_error("QueryFullProcessImageNameW"));
    }
    Ok(String::from_utf16_lossy(&buf[..len as usize]))
}

fn token_info(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> Result<Vec<u8>, String> {
    let mut len = 0u32;
    unsafe { GetTokenInformation(token, class, std::ptr::null_mut(), 0, &mut len) };
    let mut buf = vec![0u8; len.max(8) as usize];
    if unsafe { GetTokenInformation(token, class, buf.as_mut_ptr().cast(), len, &mut len) } == 0 {
        return Err(last_error("GetTokenInformation"));
    }
    Ok(buf)
}

fn process_token(process: HANDLE) -> Result<Handle, String> {
    let mut token = std::ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err(last_error("OpenProcessToken"));
    }
    Ok(Handle(token))
}

fn token_sid(token: HANDLE) -> Result<String, String> {
    let buf = token_info(token, TokenUser)?;
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let mut text: *mut u16 = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) } == 0 {
        return Err(last_error("ConvertSidToStringSidW"));
    }
    let len = (0..).take_while(|&i| unsafe { *text.add(i) } != 0).count();
    let sid = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) });
    unsafe { LocalFree(text.cast()) };
    Ok(sid)
}

fn token_account(token: HANDLE) -> Result<String, String> {
    let buf = token_info(token, TokenUser)?;
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let (mut name, mut domain) = ([0u16; 256], [0u16; 256]);
    let (mut nl, mut dl, mut use_) = (256u32, 256u32, 0);
    if unsafe {
        LookupAccountSidW(std::ptr::null(), user.User.Sid, name.as_mut_ptr(), &mut nl, domain.as_mut_ptr(), &mut dl, &mut use_)
    } == 0
    {
        return Err(last_error("LookupAccountSidW"));
    }
    Ok(format!("{}\\{}", String::from_utf16_lossy(&domain[..dl as usize]), String::from_utf16_lossy(&name[..nl as usize])))
}

fn token_elevated(token: HANDLE) -> Result<bool, String> {
    let buf = token_info(token, TokenElevation)?;
    Ok(unsafe { (*(buf.as_ptr() as *const TOKEN_ELEVATION)).TokenIsElevated } != 0)
}

/// The elevated token of the user signed in to `session` (the linked token of their filtered token).
fn elevated_user_token(session: u32, expected_sid: &str) -> Result<Handle, String> {
    let mut raw = std::ptr::null_mut();
    if unsafe { WTSQueryUserToken(session, &mut raw) } == 0 {
        return Err(last_error("WTSQueryUserToken"));
    }
    let token = Handle(raw);
    if token_sid(token.0)? != expected_sid {
        return Err("la sesión pertenece a otro usuario".into());
    }
    let kind = i32::from_ne_bytes(token_info(token.0, TokenElevationType)?[..4].try_into().unwrap());
    let source = if kind == TokenElevationTypeLimited {
        let buf = token_info(token.0, TokenLinkedToken)?;
        Handle(unsafe { (*(buf.as_ptr() as *const TOKEN_LINKED_TOKEN)).LinkedToken })
    } else if token_elevated(token.0)? {
        token
    } else {
        return Err("el usuario no es administrador".into());
    };
    let mut primary = std::ptr::null_mut();
    if unsafe { DuplicateTokenEx(source.0, TOKEN_ALL_ACCESS, std::ptr::null(), SecurityImpersonation, TokenPrimary, &mut primary) } == 0 {
        return Err(last_error("DuplicateTokenEx"));
    }
    Ok(Handle(primary))
}

// ---------------------------------------------------------------- the bridge (pwsh + bridge.ps1)

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
        // Bridges die with the service: the job is closed when the service process exits.
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &info as *const _ as *const c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32);
        Handle(job)
    })
    .0
}

fn spawn_bridge(cfg: &Config, session: u32) -> Result<Bridge, String> {
    let _guard = SPAWN.lock().unwrap();
    let token = match cfg.mode {
        Mode::User => Some(elevated_user_token(session, &cfg.user_sid)?),
        Mode::System => None,
    };
    unsafe {
        let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: std::ptr::null_mut(), bInheritHandle: 1 };
        let (mut in_r, mut in_w, mut out_r, mut out_w) = (std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut());
        if CreatePipe(&mut in_r, &mut in_w, &sa, 0) == 0 || CreatePipe(&mut out_r, &mut out_w, &sa, 0) == 0 {
            return Err(last_error("CreatePipe"));
        }
        SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
        SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
        // The bridge's errors go to the (admin-only) log folder, to diagnose the lab.
        let err_path = PathBuf::from(std::env::var("ProgramData").unwrap_or(r"C:\ProgramData".into()))
            .join("GpuVM-lab").join(format!("bridge-{}.err", mode_name()));
        let nul = Handle(CreateFileW(wide(&err_path.to_string_lossy()).as_ptr(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_ALWAYS, 0, std::ptr::null_mut()));
        let (in_r, out_w) = (Handle(in_r), Handle(out_w));

        let mut desktop = wide("winsta0\\default");
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = in_r.0;
        si.hStdOutput = out_w.0;
        si.hStdError = nul.0;
        si.lpDesktop = desktop.as_mut_ptr();
        let script = cfg.code_root.join("src").join("bridge.ps1");
        let mut cmd = wide(&format!("\"{}\" -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{}\"", cfg.pwsh.display(), script.display()));
        let app = wide(&cfg.pwsh.to_string_lossy());
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        let flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT;
        let ok = match &token {
            Some(t) => {
                let mut env = std::ptr::null_mut();
                CreateEnvironmentBlock(&mut env, t.0, 0);
                let ok = CreateProcessAsUserW(t.0, app.as_ptr(), cmd.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 1, flags, env, std::ptr::null(), &si, &mut pi);
                DestroyEnvironmentBlock(env);
                ok
            }
            None => CreateProcessW(app.as_ptr(), cmd.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 1, flags, std::ptr::null(), std::ptr::null(), &si, &mut pi),
        };
        if ok == 0 {
            CloseHandle(in_w);
            CloseHandle(out_r);
            return Err(last_error("CreateProcess"));
        }
        AssignProcessToJobObject(job(), pi.hProcess);
        ResumeThread(pi.hThread);
        CloseHandle(pi.hThread);
        Ok(Bridge { process: Handle(pi.hProcess), stdin: File::from_raw_handle(in_w), stdout: BufReader::new(File::from_raw_handle(out_r)) })
    }
}

// ---------------------------------------------------------------- service: pipe server

/// Checks who is on the other end of the pipe: the allowed executable, run by the allowed user.
fn verify_client(pipe: HANDLE, cfg: &Config) -> Result<(u32, String), String> {
    let mut pid = 0;
    if unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) } == 0 {
        return Err(last_error("GetNamedPipeClientProcessId"));
    }
    let process = open_process(pid)?;
    let image = process_image(process.0)?;
    if !cfg.allow.contains(&image.to_lowercase()) {
        return Err(format!("programa no permitido: {image}"));
    }
    let sid = token_sid(process_token(process.0)?.0)?;
    if sid != cfg.user_sid {
        return Err(format!("usuario no permitido: {sid}"));
    }
    let mut session = 0;
    unsafe { ProcessIdToSessionId(pid, &mut session) };
    Ok((session, image))
}

fn handle_client(pipe: HANDLE, cfg: &Config) {
    let (session, image) = match verify_client(pipe, cfg) {
        Ok(v) => v,
        Err(reason) => {
            log(&format!("rechazado: {reason}"));
            let mut f = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(pipe) });
            let _ = writeln!(f, "{{\"type\":\"rejected\",\"reason\":\"{}\"}}", json_escape(&reason));
            return;
        }
    };
    log(&format!("aceptado: {image} (sesión {session})"));
    let mut bridge = match spawn_bridge(cfg, session) {
        Ok(b) => b,
        Err(e) => {
            log(&format!("puente: {e}"));
            return;
        }
    };
    let file = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(pipe) });
    let mut out = &*file;
    let mut reader = BufReader::new(&*file);
    // One request at a time, like the app's quick queries: never read and write the synchronous pipe at once.
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            break;
        }
        if line.contains("\"lab\":\"identity\"") {
            let token = process_token(bridge.process.0);
            let answer = match token {
                Ok(t) => format!(
                    "{{\"type\":\"identity\",\"user\":\"{}\",\"elevated\":{},\"session\":{},\"client\":\"{}\"}}",
                    json_escape(&token_account(t.0).unwrap_or_default()),
                    token_elevated(t.0).unwrap_or(false),
                    session,
                    json_escape(&image)
                ),
                Err(e) => format!("{{\"type\":\"identity\",\"error\":\"{}\"}}", json_escape(&e)),
            };
            if writeln!(out, "{answer}").is_err() {
                break;
            }
            continue;
        }
        let id = line.split("\"id\":\"").nth(1).and_then(|r| r.split('"').next()).unwrap_or("").to_string();
        if bridge.stdin.write_all(line.as_bytes()).is_err() || bridge.stdin.flush().is_err() {
            break;
        }
        // Relay every event (progress, warnings) until the result of this request.
        let mut event = String::new();
        loop {
            event.clear();
            if bridge.stdout.read_line(&mut event).unwrap_or(0) == 0 {
                let mut code = 0u32;
                unsafe { WaitForSingleObject(bridge.process.0, 2000) };
                unsafe { GetExitCodeProcess(bridge.process.0, &mut code) };
                log(&format!("el puente terminó (código 0x{code:08x})"));
                return;
            }
            if out.write_all(event.as_bytes()).is_err() {
                return;
            }
            if event.contains("\"type\":\"result\"") && event.contains(&format!("\"id\":\"{id}\"")) {
                break;
            }
        }
    }
}

fn serve() {
    let cfg = CONFIG.get().unwrap();
    // Administrators and SYSTEM: full access. The allowed user: read/write only. Network logons: denied.
    let sddl = format!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x{CLIENT_ACCESS:08x};;;{})(D;;GA;;;NU)", cfg.user_sid);
    let mut sd = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(&sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        log(&last_error("SDDL"));
        std::process::exit(1);
    }
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    let name = wide(&pipe_name());
    let mut first = true;
    loop {
        // The first instance claims the name: if another program created it before, the service does not start.
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
            std::thread::sleep(std::time::Duration::from_millis(500));
            continue;
        }
        first = false;
        let connected = unsafe { ConnectNamedPipe(pipe, std::ptr::null_mut()) } != 0 || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        let pipe = Handle(pipe);
        if !connected {
            continue;
        }
        std::thread::spawn(move || {
            let pipe = pipe;
            handle_client(pipe.0, CONFIG.get().unwrap());
            unsafe {
                FlushFileBuffers(pipe.0);
                DisconnectNamedPipe(pipe.0);
            }
        });
    }
}

// ---------------------------------------------------------------- service: SCM plumbing

static STATUS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

fn set_state(state: SERVICE_STATUS_CURRENT_STATE) {
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING { SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN } else { 0 },
        dwWin32ExitCode: 0,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: 0,
        dwWaitHint: 0,
    };
    unsafe { SetServiceStatus(STATUS.load(Ordering::SeqCst), &status) };
}

unsafe extern "system" fn control(code: u32, _: u32, _: *mut c_void, _: *mut c_void) -> u32 {
    if code == SERVICE_CONTROL_STOP || code == SERVICE_CONTROL_SHUTDOWN {
        // Answer the SCM first; the process ends right after (the job object takes the bridges with it).
        log("detenido");
        std::thread::spawn(|| {
            set_state(SERVICE_STOPPED);
            std::thread::sleep(std::time::Duration::from_millis(100));
            std::process::exit(0);
        });
    }
    NO_ERROR
}

unsafe extern "system" fn service_main(_: u32, _: *mut PWSTR) {
    let name = wide(&service_name());
    STATUS.store(RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(control), std::ptr::null()), Ordering::SeqCst);
    set_state(SERVICE_RUNNING);
    log("iniciado");
    std::thread::spawn(serve);
}

// ---------------------------------------------------------------- client side

/// PID of the running service, from the Service Control Manager (a user program cannot fake it).
fn service_pid() -> Result<u32, String> {
    unsafe {
        let scm = OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT);
        if scm.is_null() {
            return Err(last_error("OpenSCManagerW"));
        }
        let svc = OpenServiceW(scm, wide(&service_name()).as_ptr(), SERVICE_QUERY_STATUS);
        let mut status: SERVICE_STATUS_PROCESS = std::mem::zeroed();
        let mut needed = 0;
        let ok = !svc.is_null()
            && QueryServiceStatusEx(svc, SC_STATUS_PROCESS_INFO, &mut status as *mut _ as *mut u8,
                std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32, &mut needed) != 0;
        if !svc.is_null() {
            CloseServiceHandle(svc);
        }
        CloseServiceHandle(scm);
        if !ok || status.dwProcessId == 0 {
            return Err("el servicio no está en ejecución".into());
        }
        Ok(status.dwProcessId)
    }
}

/// Opens the pipe and checks the server is the service, not a program that took the name first.
fn connect() -> Result<File, String> {
    let pipe = unsafe {
        CreateFileW(wide(&pipe_name()).as_ptr(), CLIENT_ACCESS, 0, std::ptr::null(), OPEN_EXISTING,
            SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, std::ptr::null_mut())
    };
    if pipe == INVALID_HANDLE_VALUE {
        return Err(last_error("CreateFileW(pipe)"));
    }
    let file = unsafe { File::from_raw_handle(pipe) };
    let mut server = 0;
    if unsafe { GetNamedPipeServerProcessId(pipe, &mut server) } == 0 {
        return Err(last_error("GetNamedPipeServerProcessId"));
    }
    let expected = service_pid()?;
    if server != expected {
        return Err(format!("el pipe lo abrió otro proceso ({server}), no el servicio ({expected})"));
    }
    Ok(file)
}

fn stats(label: &str, times: &mut Vec<f64>) {
    let first = times[0];
    let mut rest: Vec<f64> = times[1..].to_vec();
    rest.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let pick = |q: f64| rest[((rest.len() - 1) as f64 * q).round() as usize];
    println!(
        "{{\"run\":\"{label}\",\"n\":{},\"first_ms\":{first:.1},\"median_ms\":{:.1},\"p95_ms\":{:.1},\"min_ms\":{:.1},\"max_ms\":{:.1}}}",
        times.len(), pick(0.5), pick(0.95), rest[0], rest[rest.len() - 1]
    );
}

/// Sends `n` Get-GpuVMOverview requests, one after another, and times each until its result.
fn bench(label: &str, n: usize, mut write: impl Write, mut read: impl BufRead) -> Result<(), String> {
    let mut times = Vec::with_capacity(n);
    let mut line = String::new();
    for i in 0..n {
        let id = format!("b{i}");
        let start = Instant::now();
        writeln!(write, "{{\"id\":\"{id}\",\"cmd\":\"Get-GpuVMOverview\",\"args\":{{}}}}").map_err(|e| e.to_string())?;
        write.flush().map_err(|e| e.to_string())?;
        loop {
            line.clear();
            if read.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                return Err("conexión cerrada".into());
            }
            if line.contains("\"type\":\"rejected\"") {
                return Err(line.trim().to_string());
            }
            if line.contains("\"type\":\"result\"") && line.contains(&format!("\"id\":\"{id}\"")) {
                if !line.contains("\"ok\":true") {
                    return Err(line.trim().to_string());
                }
                break;
            }
        }
        times.push(start.elapsed().as_secs_f64() * 1000.0);
    }
    stats(label, &mut times);
    Ok(())
}

fn client(args: &[String]) -> Result<(), String> {
    match args.first().map(String::as_str) {
        Some("bench") => {
            let n = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
            let start = Instant::now();
            let file = connect()?;
            println!("{{\"run\":\"connect\",\"ms\":{:.2}}}", start.elapsed().as_secs_f64() * 1000.0);
            bench("service", n, &file, BufReader::new(&file))
        }
        Some("identity") => {
            let file = connect()?;
            writeln!(&file, "{{\"lab\":\"identity\"}}").map_err(|e| e.to_string())?;
            let mut line = String::new();
            BufReader::new(&file).read_line(&mut line).map_err(|e| e.to_string())?;
            println!("{}", line.trim());
            Ok(())
        }
        Some("call") => {
            // client call <command> [<args as JSON>]: prints the result line.
            let cmd = args.get(1).ok_or("falta el comando")?;
            let call_args = args.get(2).filter(|a| !a.starts_with("--")).map(String::as_str).unwrap_or("{}");
            let file = connect()?;
            writeln!(&file, "{{\"id\":\"c1\",\"cmd\":\"{cmd}\",\"args\":{call_args}}}").map_err(|e| e.to_string())?;
            let mut reader = BufReader::new(&file);
            let mut line = String::new();
            loop {
                line.clear();
                if reader.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
                    return Err("conexión cerrada".into());
                }
                if line.contains("\"type\":\"result\"") || line.contains("\"type\":\"rejected\"") {
                    println!("{}", line.trim());
                    return Ok(());
                }
            }
        }
        Some("squat") => {
            let pipe = unsafe {
                CreateNamedPipeW(wide(&pipe_name()).as_ptr(), PIPE_ACCESS_DUPLEX, PIPE_TYPE_BYTE | PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 4096, 4096, 0, std::ptr::null())
            };
            if pipe == INVALID_HANDLE_VALUE {
                println!("{{\"run\":\"squat\",\"created\":false,\"error\":{}}}", unsafe { GetLastError() });
            } else {
                unsafe { CloseHandle(pipe) };
                println!("{{\"run\":\"squat\",\"created\":true}}");
            }
            Ok(())
        }
        _ => Err("uso: client bench N | client identity | client squat".into()),
    }
}

fn bench_direct(args: &[String]) -> Result<(), String> {
    let n = args.first().and_then(|s| s.parse().ok()).unwrap_or(30);
    let code_root = PathBuf::from(arg(args, "--code-root").ok_or("falta --code-root")?);
    let pwsh = arg(args, "--pwsh").ok_or("falta --pwsh")?;
    use std::os::windows::process::CommandExt;
    let mut child = std::process::Command::new(pwsh)
        .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(code_root.join("src").join("bridge.ps1"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
    let stdin = child.stdin.take().unwrap();
    let stdout = BufReader::new(child.stdout.take().unwrap());
    let result = bench("direct", n, stdin, stdout);
    let _ = child.kill();
    result
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let _ = MODE_NAME.set(if arg(&args, "--mode").as_deref() == Some("system") { "system".into() } else { "user".into() });
    let result = match args.first().map(String::as_str) {
        Some("service") => match parse_config(&args) {
            Ok(cfg) => {
                let _ = CONFIG.set(cfg);
                let mut name = wide(&service_name());
                let table = [
                    SERVICE_TABLE_ENTRYW { lpServiceName: name.as_mut_ptr(), lpServiceProc: Some(service_main) },
                    SERVICE_TABLE_ENTRYW { lpServiceName: std::ptr::null_mut(), lpServiceProc: None },
                ];
                if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 { Err(last_error("StartServiceCtrlDispatcherW")) } else { Ok(()) }
            }
            Err(e) => Err(e),
        },
        Some("client") => client(&args[1..]),
        Some("bench-direct") => bench_direct(&args[1..]),
        _ => Err("uso: service ... | client ... | bench-direct N --code-root DIR --pwsh EXE".into()),
    };
    if let Err(e) = result {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
