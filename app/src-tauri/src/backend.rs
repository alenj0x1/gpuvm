use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::sync::atomic::AtomicBool;
#[cfg(not(debug_assertions))]
use std::sync::atomic::Ordering;

use windows_sys::Win32::Foundation::*;

#[cfg_attr(debug_assertions, allow(dead_code))]
pub const SERVICE_MISSING: &str = "The GpuVM service isn't installed.";
#[cfg_attr(debug_assertions, allow(dead_code))]
pub const SERVICE_STOPPED: &str = "The GpuVM service is stopped.";

pub static AUTO_START: AtomicBool = AtomicBool::new(true);

pub struct Conn {
    reader: BufReader<Box<dyn Read + Send>>,
    writer: Box<dyn Write + Send>,
    abort: Aborter,
    child: Option<std::process::Child>,
}

#[derive(Clone, Copy)]
pub struct Aborter(usize);

impl Aborter {
    pub fn abort(self) {
        // SAFETY: the handle belongs to a connection that is still open (the caller holds it while it waits).
        unsafe {
            if cfg!(debug_assertions) {
                windows_sys::Win32::System::Threading::TerminateProcess(self.0 as HANDLE, 1);
            } else {
                windows_sys::Win32::System::IO::CancelIoEx(self.0 as HANDLE, std::ptr::null());
            }
        }
    }
}

impl Drop for Conn {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
        }
    }
}

impl Conn {
    pub fn send(&mut self, request: &Value) -> Result<(), String> {
        writeln!(self.writer, "{request}").and_then(|_| self.writer.flush()).map_err(|_| "GpuVM stopped responding.".to_string())
    }

    pub fn next_event(&mut self) -> Option<Value> {
        let mut line = String::new();
        loop {
            line.clear();
            if self.reader.read_line(&mut line).ok()? == 0 {
                return None;
            }
            if let Ok(event) = serde_json::from_str(&line) {
                return Some(event);
            }
        }
    }

    pub fn aborter(&self) -> Aborter {
        self.abort
    }

    pub fn detach(mut self) {
        std::mem::forget(self.child.take());
    }

    pub fn call(&mut self, request: &Value, mut on_event: impl FnMut(&Value)) -> Result<Value, String> {
        self.send(request)?;
        loop {
            let event = self.next_event().ok_or("GpuVM stopped responding.")?;
            if event["type"] == "result" && event["id"] == request["id"] {
                return Ok(event);
            }
            on_event(&event);
        }
    }
}

#[cfg(debug_assertions)]
pub fn connect() -> Result<Conn, String> {
    use std::os::windows::io::AsRawHandle;
    let mut child = crate::direct::spawn_bridge()?;
    let stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let abort = Aborter(child.as_raw_handle() as usize);
    Ok(Conn { reader: BufReader::new(Box::new(stdout)), writer: Box::new(stdin), abort, child: Some(child) })
}

#[cfg(not(debug_assertions))]
pub fn connect() -> Result<Conn, String> {
    if let Some(conn) = open_pipe() {
        return Ok(conn);
    }
    match crate::service::status().state {
        "missing" => return Err(SERVICE_MISSING.into()),
        "stopped" | "stopping" if !AUTO_START.load(Ordering::Relaxed) => return Err(SERVICE_STOPPED.into()),
        "stopped" => crate::service::start()?,
        _ => {}
    }
    for _ in 0..150 {
        std::thread::sleep(std::time::Duration::from_millis(200));
        if let Some(conn) = open_pipe() {
            return Ok(conn);
        }
        if crate::service::status().state == "stopped" {
            crate::service::start()?;
        }
    }
    Err(SERVICE_STOPPED.into())
}

#[cfg(not(debug_assertions))]
pub fn connect_existing() -> Option<Conn> {
    open_pipe()
}

#[cfg(debug_assertions)]
pub fn connect_existing() -> Option<Conn> {
    None
}

#[cfg(not(debug_assertions))]
fn open_pipe() -> Option<Conn> {
    use std::os::windows::io::{AsRawHandle, FromRawHandle};
    use windows_sys::Win32::Storage::FileSystem::*;
    use windows_sys::Win32::System::Pipes::*;

    let name: Vec<u16> = r"\\.\pipe\gpuvm".encode_utf16().chain(Some(0)).collect();
    let mut handle = INVALID_HANDLE_VALUE;
    for _ in 0..3 {
        // Exactly what the pipe grants users; impersonation lets the service open request paths as this user, unelevated.
        handle = unsafe {
            CreateFileW(name.as_ptr(), 0x0010_0083, 0, std::ptr::null(), OPEN_EXISTING,
                SECURITY_SQOS_PRESENT | SECURITY_IMPERSONATION, std::ptr::null_mut())
        };
        if handle != INVALID_HANDLE_VALUE || unsafe { GetLastError() } != ERROR_PIPE_BUSY {
            break;
        }
        unsafe { WaitNamedPipeW(name.as_ptr(), 2000) };
    }
    if handle == INVALID_HANDLE_VALUE {
        return None;
    }
    let file = unsafe { std::fs::File::from_raw_handle(handle) };
    // The other end must be the service itself (PID from the service manager), not a program that took the pipe's name.
    let mut server = 0;
    unsafe { GetNamedPipeServerProcessId(handle, &mut server) };
    if server == 0 || server != crate::service::status().pid {
        return None;
    }
    let writer = file.try_clone().ok()?;
    let abort = Aborter(file.as_raw_handle() as usize);
    Some(Conn { reader: BufReader::new(Box::new(file)), writer: Box::new(writer), abort, child: None })
}

pub fn run_elevated(file: &std::path::Path, parameters: &str, cancelled: &str) -> Result<u32, String> {
    use windows_sys::Win32::System::Threading::{GetExitCodeProcess, WaitForSingleObject, INFINITE};
    use windows_sys::Win32::UI::Shell::*;
    let verb: Vec<u16> = "runas\0".encode_utf16().collect();
    let path: Vec<u16> = file.as_os_str().to_string_lossy().encode_utf16().chain(Some(0)).collect();
    let params: Vec<u16> = parameters.encode_utf16().chain(Some(0)).collect();
    let mut info: SHELLEXECUTEINFOW = unsafe { std::mem::zeroed() };
    info.cbSize = std::mem::size_of::<SHELLEXECUTEINFOW>() as u32;
    info.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
    info.lpVerb = verb.as_ptr();
    info.lpFile = path.as_ptr();
    info.lpParameters = params.as_ptr();
    info.nShow = 0;
    if unsafe { ShellExecuteExW(&mut info) } == 0 {
        return Err(if unsafe { GetLastError() } == ERROR_CANCELLED { cancelled.to_string() } else { "Couldn't ask for administrator permission.".into() });
    }
    let mut code = 1;
    unsafe {
        WaitForSingleObject(info.hProcess, INFINITE);
        GetExitCodeProcess(info.hProcess, &mut code);
        CloseHandle(info.hProcess);
    }
    Ok(code)
}

pub fn consent(code: &str) -> i32 {
    let Ok(mut conn) = connect() else { return 1 };
    if conn.send(&json!({ "consent": code })).is_err() {
        return 1;
    }
    match conn.next_event() {
        Some(reply) if reply["type"] == "consent" && reply["ok"] == true => 0,
        _ => 1,
    }
}
