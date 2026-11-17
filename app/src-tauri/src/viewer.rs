//! The GpuVM viewer: our fork of Moonlight (repo gpuvm-viewer) that only streams. This app starts it, talks to it
//! over a private pipe and draws what goes around the picture (waiting screen, side panel, admin-prompt notch).
//!
//! Security (the viewer talks to a server the guest controls, so it is treated as untrusted too):
//! - The pipe has a random name, is created before the viewer starts (first instance, so nobody can take the name),
//!   only this user can open it and remote clients are refused.
//! - Only the process this app started may connect (its PID is checked) and it must present the one-time token
//!   it got through its environment, never the command line.
//! - Messages are JSON lines from a fixed list, with a size limit; anything else is dropped.
//! - The viewer runs unelevated, as this app does.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicIsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter};
use windows_sys::Win32::Foundation::{CloseHandle, GetLastError, LocalFree, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, HANDLE, INVALID_HANDLE_VALUE, WAIT_OBJECT_0};
use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows_sys::Win32::Security::Cryptography::{BCryptGenRandom, BCRYPT_USE_SYSTEM_PREFERRED_RNG};
use windows_sys::Win32::Security::{GetTokenInformation, TokenUser, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER};
use windows_sys::Win32::Storage::FileSystem::{ReadFile, WriteFile, FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX};
use windows_sys::Win32::System::Pipes::{ConnectNamedPipe, CreateNamedPipeW, GetNamedPipeClientProcessId, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT};
use windows_sys::Win32::System::Threading::{CreateEventW, GetCurrentProcess, OpenProcessToken, WaitForSingleObject};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

/// Longest line either side sends; the viewer's own limit is the same.
const MAX_LINE: usize = 16 * 1024;
/// Messages the viewer may send.
const FROM_VIEWER: &[&str] = &["hello", "stage", "stage-failed", "connected", "error", "app-running", "window", "first-frame", "stats", "panel", "ended"];
/// Commands this app may send.
const TO_VIEWER: &[&str] = &["inset", "capture", "fullscreen", "stats", "quit", "focus"];

struct Pipe(HANDLE);
// SAFETY: a pipe handle can be used from any thread; reads and writes are overlapped, each with its own event.
unsafe impl Send for Pipe {}
unsafe impl Sync for Pipe {}
impl Drop for Pipe {
    fn drop(&mut self) {
        // SAFETY: the handle is owned by this value and closed once.
        unsafe { CloseHandle(self.0) };
    }
}

struct Viewer {
    pipe: Pipe,
    pid: u32,
    write: Mutex<()>,
    hwnd: AtomicIsize,
    /// Inside the app's window (not full screen): placed over the content area and following it.
    embed: bool,
    /// Shown over the app (false while waiting for the first picture or while the person is in Home).
    visible: std::sync::atomic::AtomicBool,
}

/// Height of the app's title bar in logical pixels (styles.css, --titlebar): the viewer covers what is below it.
const TITLEBAR: f64 = 40.0;

/// The main window's content area on screen (physical pixels), and the window's handle.
fn content_rect(app: &AppHandle) -> Option<(isize, i32, i32, i32, i32)> {
    use tauri::Manager;
    let main = app.get_webview_window("main")?;
    if main.is_minimized().unwrap_or(false) {
        return None;
    }
    let hwnd = main.hwnd().ok()?.0 as isize;
    let pos = main.inner_position().ok()?;
    let size = main.inner_size().ok()?;
    let top = (TITLEBAR * main.scale_factor().unwrap_or(1.0)).round() as i32;
    let height = size.height as i32 - top;
    if size.width == 0 || height <= 0 {
        return None;
    }
    Some((hwnd, pos.x, pos.y + top, size.width as i32, height))
}

/// The app's window moved or changed size: the viewers shown inside it follow.
pub fn follow_main(app: &AppHandle) {
    let Some((_, x, y, w, h)) = content_rect(app) else { return };
    let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
    for viewer in list.iter().filter(|v| v.embed) {
        send_raw(viewer, &json!({ "type": "place", "x": x, "y": y, "w": w, "h": h }));
    }
}

fn allow_foreground(pid: u32) {
    #[link(name = "user32")]
    extern "system" {
        fn AllowSetForegroundWindow(pid: u32) -> i32;
    }
    // SAFETY: plain Win32 call with a process id.
    unsafe { AllowSetForegroundWindow(pid) };
}

/// Who waits for a viewer's first picture (the "Abrir" job), by machine name.
static WAITERS: Mutex<Option<HashMap<String, std::sync::mpsc::Sender<Value>>>> = Mutex::new(None);

/// Open viewers by machine name.
static VIEWERS: Mutex<Option<HashMap<String, Arc<Viewer>>>> = Mutex::new(None);

fn viewers() -> std::sync::MutexGuard<'static, Option<HashMap<String, Arc<Viewer>>>> {
    VIEWERS.lock().unwrap_or_else(|e| e.into_inner())
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buffer = vec![0u8; bytes];
    // SAFETY: the buffer is valid for its length; the system RNG needs no algorithm handle.
    let status = unsafe { BCryptGenRandom(std::ptr::null_mut(), buffer.as_mut_ptr(), buffer.len() as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status != 0 {
        return Err("No se pudo generar una clave para el visor.".into());
    }
    Ok(buffer.iter().map(|b| format!("{b:02x}")).collect())
}

/// This user's SID as text, for the pipe's access list.
fn current_user_sid() -> Result<String, String> {
    // SAFETY: standard token query; buffers are sized from the first call and freed below.
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err("No se pudo leer el usuario actual.".into());
        }
        let mut size = 0u32;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size);
        let mut buffer = vec![0u8; size as usize];
        let ok = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), size, &mut size);
        CloseHandle(token);
        if ok == 0 {
            return Err("No se pudo leer el usuario actual.".into());
        }
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut text: *mut u16 = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            return Err("No se pudo leer el usuario actual.".into());
        }
        let len = (0..).take_while(|&i| *text.add(i) != 0).count();
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, len));
        LocalFree(text.cast());
        Ok(sid)
    }
}

/// Where the viewer is: installed with GpuVM's module (Program Files, only admins can change it), the same place
/// the module looks (Get-GpuVMViewerPath). In development, the repository's viewer folder.
pub fn viewer_path() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let installed = exe.parent()?.join("gpuvm").join("viewer").join("GpuVMViewer.exe");
    if installed.is_file() {
        return Some(installed);
    }
    #[cfg(debug_assertions)]
    {
        let dev = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(r"..\..\viewer\GpuVMViewer.exe");
        if dev.is_file() {
            return Some(dev);
        }
    }
    None
}

fn overlapped_io(pipe: HANDLE, write: Option<&[u8]>, read: Option<&mut [u8]>, timeout: Option<Duration>) -> Result<usize, ()> {
    // SAFETY: the OVERLAPPED and its event live until the operation completes (we wait for it or cancel it and
    // then wait), and the buffer outlives the call.
    unsafe {
        let event = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
        if event.is_null() {
            return Err(());
        }
        let mut ov: OVERLAPPED = std::mem::zeroed();
        ov.hEvent = event;
        let started = match (write, read) {
            (Some(data), _) => WriteFile(pipe, data.as_ptr(), data.len() as u32, std::ptr::null_mut(), &mut ov),
            (None, Some(buf)) => ReadFile(pipe, buf.as_mut_ptr(), buf.len() as u32, std::ptr::null_mut(), &mut ov),
            _ => 0,
        };
        if started == 0 && GetLastError() != ERROR_IO_PENDING {
            CloseHandle(event);
            return Err(());
        }
        if let Some(t) = timeout {
            if WaitForSingleObject(event, t.as_millis() as u32) != WAIT_OBJECT_0 {
                CancelIoEx(pipe, &ov);
            }
        }
        let mut done = 0u32;
        let ok = GetOverlappedResult(pipe, &ov, &mut done, 1);
        CloseHandle(event);
        if ok == 0 { Err(()) } else { Ok(done as usize) }
    }
}

/// Waits up to `timeout` for the viewer to connect.
fn wait_connect(pipe: HANDLE, timeout: Duration) -> bool {
    // SAFETY: as in overlapped_io.
    unsafe {
        let event = CreateEventW(std::ptr::null(), 1, 0, std::ptr::null());
        let mut ov: OVERLAPPED = std::mem::zeroed();
        ov.hEvent = event;
        let connected = if ConnectNamedPipe(pipe, &mut ov) != 0 {
            true
        } else {
            match GetLastError() {
                ERROR_PIPE_CONNECTED => true,
                ERROR_IO_PENDING => {
                    if WaitForSingleObject(event, timeout.as_millis() as u32) != WAIT_OBJECT_0 {
                        CancelIoEx(pipe, &ov);
                    }
                    let mut done = 0u32;
                    GetOverlappedResult(pipe, &ov, &mut done, 1) != 0
                }
                _ => false,
            }
        };
        CloseHandle(event);
        connected
    }
}

/// Reads one line; None when the pipe closed, the line is too long or the time ran out.
fn read_line(pipe: HANDLE, pending: &mut Vec<u8>, timeout: Option<Duration>) -> Option<Vec<u8>> {
    let deadline = timeout.map(|t| Instant::now() + t);
    loop {
        if let Some(pos) = pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = pending.drain(..=pos).collect();
            return Some(line[..line.len() - 1].to_vec());
        }
        if pending.len() > MAX_LINE {
            return None;
        }
        let left = match deadline {
            Some(d) => Some(d.checked_duration_since(Instant::now())?),
            None => None,
        };
        let mut chunk = [0u8; 4096];
        let n = overlapped_io(pipe, None, Some(&mut chunk), left).ok()?;
        if n == 0 {
            return None;
        }
        pending.extend_from_slice(&chunk[..n]);
    }
}

fn same_token(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

fn open_blocking(app: AppHandle, vm: String, exe: PathBuf, arguments: Vec<String>, embed: bool) -> Result<u32, String> {
    let pipe_name = format!(r"\\.\pipe\gpuvm-viewer-{}", random_hex(16)?);
    let token = random_hex(32)?;
    // This user only, full access; everyone else (including the network) gets nothing.
    let sddl = format!("D:P(A;;GA;;;{})", current_user_sid()?);
    let mut sd = std::ptr::null_mut();
    // SAFETY: valid NUL-terminated SDDL; the descriptor is freed after the pipe is created.
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(&sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        return Err("No se pudo preparar la conexión con el visor.".into());
    }
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    // SAFETY: valid name and attributes; the handle is owned by Pipe from here on.
    let handle = unsafe {
        CreateNamedPipeW(wide(&pipe_name).as_ptr(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, &sa)
    };
    // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
    unsafe { LocalFree(sd) };
    if handle == INVALID_HANDLE_VALUE {
        return Err("No se pudo preparar la conexión con el visor.".into());
    }
    let pipe = Pipe(handle);

    const TOKEN_VAR: &str = "GPUVM_VIEWER_TOKEN";
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let child = std::process::Command::new(&exe)
        .args(&arguments)
        .arg("--gpuvm-pipe").arg(&pipe_name)
        .arg("--gpuvm-token-env").arg(TOKEN_VAR)
        .env(TOKEN_VAR, &token)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("No se pudo abrir el visor: {e}"))?;
    let pid = child.id();

    let refuse = |message: &str| -> Result<u32, String> {
        let _ = std::process::Command::new(crate::system32("taskkill.exe")).args(["/PID", &pid.to_string(), "/F"]).creation_flags(CREATE_NO_WINDOW).status();
        Err(message.to_string())
    };
    if !wait_connect(pipe.0, Duration::from_secs(20)) {
        return refuse("El visor no respondió.");
    }
    let mut client = 0u32;
    // SAFETY: connected pipe handle.
    if unsafe { GetNamedPipeClientProcessId(pipe.0, &mut client) } == 0 || client != pid {
        return refuse("Otro programa intentó conectarse en lugar del visor.");
    }
    let mut pending = Vec::new();
    let hello = read_line(pipe.0, &mut pending, Some(Duration::from_secs(10)))
        .and_then(|l| serde_json::from_slice::<Value>(&l).ok())
        .unwrap_or(Value::Null);
    if hello["type"] != "hello" || !same_token(hello["token"].as_str().unwrap_or(""), &token) {
        return refuse("El visor no se identificó.");
    }
    drop(token);

    let viewer = Arc::new(Viewer { pipe, pid, write: Mutex::new(()), hwnd: AtomicIsize::new(0), embed, visible: std::sync::atomic::AtomicBool::new(!embed) });
    viewers().get_or_insert_with(HashMap::new).insert(vm.clone(), viewer.clone());
    let _ = app.emit("viewer", json!({ "vm": vm, "msg": { "type": "opened", "pid": pid } }));

    std::thread::spawn(move || {
        while let Some(line) = read_line(viewer.pipe.0, &mut pending, None) {
            let Ok(mut msg) = serde_json::from_slice::<Value>(&line) else { continue };
            let kind = msg["type"].as_str().unwrap_or("").to_string();
            if !FROM_VIEWER.contains(&kind.as_str()) || kind == "hello" {
                continue;
            }
            if kind == "window" {
                let hwnd = msg["hwnd"].as_f64().unwrap_or(0.0) as isize;
                viewer.hwnd.store(hwnd, Ordering::Relaxed);
                // The handle stays here: pages only need to know that it changed.
                if let Some(o) = msg.as_object_mut() {
                    o.remove("hwnd");
                }
            }
            let _ = app.emit("viewer", json!({ "vm": vm, "msg": msg }));
            crate::overlay::on_viewer(&app, &vm, &msg);
            // The first picture: the viewer comes out from behind the app, over its content area.
            if kind == "first-frame" && viewer.embed {
                allow_foreground(viewer.pid);
                send_raw(&viewer, &json!({ "type": "reveal" }));
                viewer.visible.store(true, Ordering::Relaxed);
            }
            if matches!(kind.as_str(), "first-frame" | "error" | "app-running" | "stage-failed") {
                if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|w| w.remove(&vm)) {
                    let _ = waiter.send(msg.clone());
                }
            }
        }
        let mut all = viewers();
        if all.as_ref().and_then(|v| v.get(&vm)).is_some_and(|v| Arc::ptr_eq(v, &viewer)) {
            all.as_mut().map(|v| v.remove(&vm));
        }
        drop(all);
        let closed = json!({ "type": "closed" });
        if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|w| w.remove(&vm)) {
            let _ = waiter.send(closed.clone());
        }
        let _ = app.emit("viewer", json!({ "vm": vm, "msg": closed }));
        crate::overlay::on_viewer(&app, &vm, &closed);
    });
    Ok(pid)
}

/// The viewer launch in a job's data: the module returns every object the command wrote, as a list.
pub fn launch_in(data: &Value) -> Option<Value> {
    let items: Vec<&Value> = match data {
        Value::Array(a) => a.iter().collect(),
        other => vec![other],
    };
    items.into_iter().rev().find_map(|v| v.get("viewerLaunch").filter(|l| l.is_object()).cloned())
}

/// The end of "Abrir": opens the viewer with the module's arguments and returns once the first picture is decoded
/// (the button shows "Conectando la imagen" until then), or with the viewer's error in plain words.
pub fn open_and_wait(app: &AppHandle, vm: &str, launch: &Value) -> Result<(), String> {
    let arguments: Vec<String> = launch["arguments"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    if arguments.first().map(String::as_str) != Some("stream") {
        return Err("El módulo no devolvió cómo abrir la máquina.".into());
    }
    // The module quotes the app's name for a command line ("Desktop"); here each argument goes on its own, so the
    // quotes would become part of the name.
    let mut arguments: Vec<String> = arguments.into_iter()
        .map(|a| if a.len() >= 2 && a.starts_with('"') && a.ends_with('"') { a[1..a.len() - 1].to_string() } else { a })
        .collect();
    // The machine's monitor: the viewer opens on the display that holds its center.
    let monitor = &launch["monitor"];
    if let (Some(x), Some(y), Some(w), Some(h)) = (monitor["x"].as_i64(), monitor["y"].as_i64(), monitor["width"].as_i64(), monitor["height"].as_i64()) {
        arguments.push("--gpuvm-display".into());
        arguments.push(format!("{},{}", x + w / 2, y + h / 2));
    }
    let already = viewers().as_ref().and_then(|v| v.get(vm).cloned());
    if let Some(existing) = already {
        send_raw(&existing, &json!({ "type": "focus" }));
        return Ok(());
    }
    let exe = viewer_path().ok_or("El visor de GpuVM no está instalado.")?;
    let (tx, rx) = std::sync::mpsc::channel();
    WAITERS.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).insert(vm.to_string(), tx);
    // "Ventana" means inside GpuVM's own window now: the picture takes the app's content area.
    let embed = arguments.windows(2).any(|w| w[0] == "--display-mode" && w[1] == "windowed");
    if embed {
        if let Some((hwnd, x, y, w, h)) = content_rect(app) {
            arguments.push("--gpuvm-embed".into());
            arguments.push(format!("{hwnd},{x},{y},{w},{h}"));
        }
    }
    let embed = arguments.iter().any(|a| a == "--gpuvm-embed");
    if let Err(e) = open_blocking(app.clone(), vm.to_string(), exe, arguments, embed) {
        WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(|w| w.remove(vm));
        return Err(e);
    }
    // Cold start: Sunshine tests its encoders on the first session after boot (up to ~20 s, labs 019 and 023).
    let msg = rx.recv_timeout(Duration::from_secs(90)).unwrap_or_else(|_| json!({ "type": "timeout" }));
    match msg["type"].as_str().unwrap_or("") {
        "first-frame" => Ok(()),
        "error" => Err(msg["message"].as_str().unwrap_or("El visor no pudo conectarse.").to_string()),
        "app-running" => Err("La máquina tiene otra sesión abierta. Ciérrala e inténtalo de nuevo.".into()),
        "stage-failed" => Err(format!("No se pudo conectar ({}).", msg["stage"].as_str().unwrap_or("?"))),
        "closed" => Err("El visor se cerró antes de mostrar la imagen.".into()),
        // Still connecting: the viewer stays open and shows the picture when it comes.
        _ => Ok(()),
    }
}

fn send_raw(viewer: &Viewer, msg: &Value) -> bool {
    let mut line = msg.to_string().into_bytes();
    line.push(b'\n');
    let _guard = viewer.write.lock().unwrap_or_else(|e| e.into_inner());
    overlapped_io(viewer.pipe.0, Some(&line), None, Some(Duration::from_secs(2))).is_ok()
}

/// A command for a machine's viewer (from the panel).
#[tauri::command]
pub fn viewer_send(vm: String, msg: Value) -> Result<(), String> {
    let kind = msg["type"].as_str().unwrap_or("");
    if !TO_VIEWER.contains(&kind) {
        return Err("Orden no válida para el visor.".into());
    }
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("El visor de esta máquina no está abierto.")?;
    if send_raw(&viewer, &msg) { Ok(()) } else { Err("El visor no respondió.".into()) }
}

/// The viewer's window, for placing the panel over it.
pub fn viewer_hwnd(vm: &str) -> Option<isize> {
    viewers().as_ref()?.get(vm).map(|v| v.hwnd.load(Ordering::Relaxed)).filter(|&h| h != 0)
}

/// Lets the viewer take the foreground back from this app (when the panel closes).
pub fn allow_viewer_foreground(vm: &str) {
    if let Some(pid) = viewers().as_ref().and_then(|v| v.get(vm)).map(|v| v.pid) {
        allow_foreground(pid);
    }
}

/// Back to Home: the viewer hides and its session stays connected (keep), or it disconnects.
#[tauri::command]
pub fn viewer_home(app: AppHandle, vm: String, keep: bool) -> Result<(), String> {
    crate::overlay::close(&app);
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("El visor de esta máquina no está abierto.")?;
    viewer.visible.store(false, Ordering::Relaxed);
    let msg = if keep && viewer.embed { json!({ "type": "hide" }) } else { json!({ "type": "quit" }) };
    if send_raw(&viewer, &msg) { Ok(()) } else { Err("El visor no respondió.".into()) }
}

/// Back to a machine still connected: its picture shows again over the app (or full screen).
#[tauri::command]
pub fn viewer_show(app: AppHandle, vm: String) -> Result<(), String> {
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("El visor de esta máquina no está abierto.")?;
    if viewer.embed {
        if let Some((_, x, y, w, h)) = content_rect(&app) {
            send_raw(&viewer, &json!({ "type": "place", "x": x, "y": y, "w": w, "h": h }));
        }
    }
    allow_foreground(viewer.pid);
    viewer.visible.store(true, Ordering::Relaxed);
    if send_raw(&viewer, &json!({ "type": "show" })) { Ok(()) } else { Err("El visor no respondió.".into()) }
}

/// Machines whose viewer is open (connected), and whether each is inside the app's window.
#[tauri::command]
pub fn viewer_list() -> Vec<Value> {
    viewers().as_ref().map(|v| v.iter().map(|(name, x)| json!({ "vm": name, "embed": x.embed, "visible": x.visible.load(Ordering::Relaxed) })).collect()).unwrap_or_default()
}

/// Whether a machine's viewer is open.
#[tauri::command]
pub fn viewer_is_open(vm: String) -> bool {
    viewers().as_ref().is_some_and(|v| v.contains_key(&vm))
}
