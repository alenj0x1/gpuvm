//! The GpuVM viewer: our fork of Moonlight (repo gpuvm-viewer) that only streams. This app starts it, talks to it
//! over a private pipe and draws what goes around the picture (waiting screen, side panel, admin-prompt notch).
//!
//! Security (the viewer talks to a server the guest controls, so it is treated as untrusted too):
//! - The pipe has a random name, is created before the viewer starts (first instance, so nobody can take the name),
//!   only this user can open it and remote clients are refused.
//! - Only the process this app started may connect (its PID is checked) and it must present the one-time token
//!   it got through its environment, never the command line.
//! - Messages are JSON lines from a fixed list, with a size limit; anything else is dropped.
//! - The viewer runs at Low integrity with a restricted token, inside a job (lowbox.rs).
//! - This app raises the viewer's window only right after it asked for the picture (reveal, show, full screen),
//!   never because the viewer says so on its own.

use serde_json::{json, Value};
use std::collections::HashMap;
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
use windows_sys::Win32::System::Threading::{CreateEventW, GetCurrentProcess, OpenProcessToken, WaitForMultipleObjects, WaitForSingleObject};
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};

/// Longest line either side sends; the viewer's own limit is the same.
const MAX_LINE: usize = 16 * 1024;
/// Shortest time between two panel or Home requests from a viewer (a key held down, or a viewer that loops).
const PANEL_GAP: Duration = Duration::from_millis(250);
/// Messages the viewer may send.
const FROM_VIEWER: &[&str] = &["hello", "stage", "stage-failed", "connected", "error", "app-running", "window", "first-frame", "stats", "panel", "home", "ended", "drag",
    // Screenshots and recordings (capture.rs).
    "capture", "capture-error", "recording"];
/// Commands this app may send.
const TO_VIEWER: &[&str] = &["inset", "capture", "fullscreen", "stats", "quit", "focus", "screenshot", "record", "replay-save"];

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
    /// Its process (handle and job): what is killed, checked and given the foreground is always this one.
    child: crate::lowbox::LowChild,
    /// Until when a full-screen report raises its window: set when this app asks for the picture.
    raise_until: Mutex<Option<Instant>>,
    write: Mutex<()>,
    hwnd: AtomicIsize,
    /// Inside the app's window (not full screen): placed over the content area and following it.
    embed: bool,
    /// Shown over the app (false while waiting for the first picture or while the person is in Home).
    visible: std::sync::atomic::AtomicBool,
    /// Its picture was revealed once: the late reveal after the first picture must not bring back a viewer the
    /// person already left for Home.
    revealed: std::sync::atomic::AtomicBool,
    /// The first picture arrived (a viewer that repeats it gets one late reveal, not one thread per message).
    first_frame: std::sync::atomic::AtomicBool,
    /// Its window is full screen now (its last "window" report).
    full_now: std::sync::atomic::AtomicBool,
    /// When the viewer last asked for the panel or Home: repeated asks closer than PANEL_GAP are dropped.
    last_toggle: Mutex<Option<Instant>>,
    /// When the viewer last reported a drag (same limit as the panel).
    last_drag: Mutex<Option<Instant>>,
    /// The machine opens full screen (its "Full screen" option): it still starts inside the app, hidden, and
    /// goes full screen when revealed.
    full_screen: bool,
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

/// Latest place for the viewers inside the app, and whether a thread is sending it.
static FOLLOW: Mutex<Option<(i32, i32, i32, i32)>> = Mutex::new(None);
static FOLLOWING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The app's window moved or changed size: the viewers shown inside it follow. Called on the UI thread for every
/// move, so the pipe writes happen on a worker that always sends the latest place (a busy viewer never freezes
/// the window's drag).
pub fn follow_main(app: &AppHandle) {
    let Some((_, x, y, w, h)) = content_rect(app) else { return };
    *FOLLOW.lock().unwrap_or_else(|e| e.into_inner()) = Some((x, y, w, h));
    if FOLLOWING.swap(true, Ordering::AcqRel) {
        return;
    }
    std::thread::spawn(|| loop {
        let next = FOLLOW.lock().unwrap_or_else(|e| e.into_inner()).take();
        let Some((x, y, w, h)) = next else {
            FOLLOWING.store(false, Ordering::Release);
            // A place stored between the take and the flag: send it too.
            if FOLLOW.lock().unwrap_or_else(|e| e.into_inner()).is_some() && !FOLLOWING.swap(true, Ordering::AcqRel) {
                continue;
            }
            return;
        };
        let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
        for viewer in list.iter().filter(|v| v.embed) {
            send_raw(viewer, &json!({ "type": "place", "x": x, "y": y, "w": w, "h": h }));
        }
    });
}

/// Whether a window belongs to a process.
fn window_of(hwnd: isize, pid: u32) -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow};
    if hwnd == 0 {
        return false;
    }
    let mut owner = 0u32;
    // SAFETY: plain queries on a window handle; a stale or foreign handle only makes them fail or differ.
    unsafe { IsWindow(hwnd as _) != 0 && GetWindowThreadProcessId(hwnd as _, &mut owner) != 0 && owner == pid }
}

/// Puts a viewer's window in front and gives it the keyboard (it can't do it itself at Low integrity).
fn bring_forward(hwnd: isize, pid: u32) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetForegroundWindow, SetWindowPos, HWND_TOP, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW};
    if !window_of(hwnd, pid) {
        return;
    }
    // SAFETY: a window of the viewer's own process, checked just above.
    unsafe {
        SetWindowPos(hwnd as _, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        SetForegroundWindow(hwnd as _);
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

/// Who waits for a viewer's first picture (the "Open" job), by machine name.
static WAITERS: Mutex<Option<HashMap<String, std::sync::mpsc::Sender<Value>>>> = Mutex::new(None);

/// Open viewers by machine name.
static VIEWERS: Mutex<Option<HashMap<String, Arc<Viewer>>>> = Mutex::new(None);

fn viewers() -> std::sync::MutexGuard<'static, Option<HashMap<String, Arc<Viewer>>>> {
    VIEWERS.lock().unwrap_or_else(|e| e.into_inner())
}

/// The app, for telling its pages when a picture covers them.
static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();
/// What the pages were last told.
static COVERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Tells the pages whether any machine's picture is shown now ("viewer-cover"): while one is, they stop their
/// animations. The VMs share this PC's GPU, and a hologram drawn behind the stream took time from the stream itself
/// (lab 041).
fn announce_cover() {
    let covered = viewers().as_ref().is_some_and(|v| v.values().any(|x| x.visible.load(Ordering::Relaxed)));
    if COVERED.swap(covered, Ordering::AcqRel) != covered {
        if let Some(app) = APP.get() {
            let _ = app.emit("viewer-cover", json!({ "covered": covered }));
        }
    }
}

/// Whether a machine's picture is shown now (asked by a page when it starts).
#[tauri::command]
pub fn viewer_covered() -> bool {
    COVERED.load(Ordering::Relaxed)
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn random_hex(bytes: usize) -> Result<String, String> {
    let mut buffer = vec![0u8; bytes];
    // SAFETY: the buffer is valid for its length; the system RNG needs no algorithm handle.
    let status = unsafe { BCryptGenRandom(std::ptr::null_mut(), buffer.as_mut_ptr(), buffer.len() as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    if status != 0 {
        return Err("Couldn't create a key for the viewer.".into());
    }
    Ok(buffer.iter().map(|b| format!("{b:02x}")).collect())
}

/// This user's SID as text, for the pipe's access list.
fn current_user_sid() -> Result<String, String> {
    // SAFETY: standard token query; buffers are sized from the first call and freed below.
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err("Couldn't read the current user.".into());
        }
        let mut size = 0u32;
        GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size);
        let mut buffer = vec![0u8; size as usize];
        let ok = GetTokenInformation(token, TokenUser, buffer.as_mut_ptr().cast(), size, &mut size);
        CloseHandle(token);
        if ok == 0 {
            return Err("Couldn't read the current user.".into());
        }
        let user = &*(buffer.as_ptr() as *const TOKEN_USER);
        let mut text: *mut u16 = std::ptr::null_mut();
        if ConvertSidToStringSidW(user.User.Sid, &mut text) == 0 {
            return Err("Couldn't read the current user.".into());
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
fn wait_connect(pipe: HANDLE, process: HANDLE, timeout: Duration) -> bool {
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
                    // A viewer that exits before connecting fails the open at once.
                    if WaitForMultipleObjects(2, [event, process].as_ptr(), 0, timeout.as_millis() as u32) != WAIT_OBJECT_0 {
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

fn open_blocking(app: AppHandle, vm: String, exe: PathBuf, arguments: Vec<String>, embed: bool, full_screen: bool) -> Result<u32, String> {
    let pipe_name = format!(r"\\.\pipe\gpuvm-viewer-{}", random_hex(16)?);
    let token = random_hex(32)?;
    // This user only, full access; everyone else (including the network) gets nothing.
    // The Low label lets the viewer (Low integrity) open it; the access list still allows only this user.
    let sddl = format!("D:P(A;;GA;;;{})S:(ML;;NW;;;LW)", current_user_sid()?);
    let mut sd = std::ptr::null_mut();
    // SAFETY: valid NUL-terminated SDDL; the descriptor is freed after the pipe is created.
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(&sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        return Err("Couldn't prepare the connection with the viewer.".into());
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
        return Err("Couldn't prepare the connection with the viewer.".into());
    }
    let pipe = Pipe(handle);

    const TOKEN_VAR: &str = "GPUVM_VIEWER_TOKEN";
    let mut all = arguments.clone();
    all.extend(["--gpuvm-pipe".into(), pipe_name.clone(), "--gpuvm-token-env".into(), TOKEN_VAR.into()]);
    // At Low integrity (lowbox.rs): the viewer handles what the machine sends.
    let _ = APP.set(app.clone());
    let child = crate::lowbox::spawn_low(&exe, &all, &[(TOKEN_VAR, token.as_str())])?;
    let pid = child.pid;

    let refuse = |message: &str| -> Result<u32, String> {
        child.kill();
        Err(message.to_string())
    };
    if !wait_connect(pipe.0, child.handle(), Duration::from_secs(20)) {
        return refuse("The viewer didn't respond.");
    }
    let mut client = 0u32;
    // SAFETY: connected pipe handle.
    if unsafe { GetNamedPipeClientProcessId(pipe.0, &mut client) } == 0 || client != pid {
        return refuse("Another program tried to connect instead of the viewer.");
    }
    let mut pending = Vec::new();
    let hello = read_line(pipe.0, &mut pending, Some(Duration::from_secs(10)))
        .and_then(|l| serde_json::from_slice::<Value>(&l).ok())
        .unwrap_or(Value::Null);
    if hello["type"] != "hello" || !same_token(hello["token"].as_str().unwrap_or(""), &token) {
        return refuse("The viewer didn't identify itself.");
    }
    drop(token);

    let viewer = Arc::new(Viewer { pipe, child, raise_until: Mutex::new(None), write: Mutex::new(()), hwnd: AtomicIsize::new(0), embed, visible: std::sync::atomic::AtomicBool::new(!embed), revealed: std::sync::atomic::AtomicBool::new(!embed), first_frame: std::sync::atomic::AtomicBool::new(false), full_now: std::sync::atomic::AtomicBool::new(false), last_toggle: Mutex::new(None), last_drag: Mutex::new(None), full_screen });
    viewers().get_or_insert_with(HashMap::new).insert(vm.clone(), viewer.clone());
    let _ = app.emit("viewer", json!({ "vm": vm, "msg": { "type": "opened", "pid": pid } }));
    // The capture settings (the last 30 s on or off, the notices' language): kept by the viewer until its stream starts.
    send_raw(&viewer, &crate::capture::setup_message());

    std::thread::spawn(move || {
        while let Some(line) = read_line(viewer.pipe.0, &mut pending, None) {
            let Ok(mut msg) = serde_json::from_slice::<Value>(&line) else { continue };
            let kind = msg["type"].as_str().unwrap_or("").to_string();
            if !FROM_VIEWER.contains(&kind.as_str()) || kind == "hello" {
                continue;
            }
            if kind == "window" {
                let hwnd = msg["hwnd"].as_f64().unwrap_or(0.0) as isize;
                // Only a window of the viewer's own process: the panel is owned by it and placed over it, so a
                // handle of another program's window would put GpuVM's panel (and the focus) there.
                viewer.hwnd.store(if window_of(hwnd, viewer.child.pid) { hwnd } else { 0 }, Ordering::Relaxed);
                let full = msg["fullScreen"].as_bool().unwrap_or(false);
                viewer.full_now.store(full, Ordering::Relaxed);
                // At Low integrity the viewer can't put its window in front of this app's: it went full screen but
                // stayed behind it until something raised it. This app may, but only once and only right after it
                // asked for the picture (a viewer can't take the keyboard whenever it likes).
                let shown = viewer.hwnd.load(Ordering::Relaxed);
                if full && shown != 0 && viewer.visible.load(Ordering::Relaxed) && take_raise(&viewer) {
                    bring_forward(shown, viewer.child.pid);
                }
                // The handle stays here: pages only need to know that it changed.
                if let Some(o) = msg.as_object_mut() {
                    o.remove("hwnd");
                }
            }
            // Something is dragged over the picture: this app shows its own drop area (dropzone.rs). Nothing else
            // sees it, and a viewer that repeats it is held to one every PANEL_GAP.
            if kind == "drag" {
                let mut last = viewer.last_drag.lock().unwrap_or_else(|e| e.into_inner());
                if !last.is_some_and(|t| t.elapsed() < PANEL_GAP) && viewer.visible.load(Ordering::Relaxed) {
                    *last = Some(Instant::now());
                    crate::dropzone::on_drag(&app, &vm);
                }
                continue;
            }
            if kind == "recording" {
                crate::capture::on_recording(&vm, msg["on"].as_bool().unwrap_or(false));
            }
            if kind == "capture" {
                // A finished file: this app moves it out of the viewer's folder (capture.rs); the pages hear
                // "capture-saved" with where it went, never the viewer's own name for it.
                crate::capture::on_file(&app, &vm, &msg);
                continue;
            }
            if matches!(kind.as_str(), "panel" | "home") {
                let mut last = viewer.last_toggle.lock().unwrap_or_else(|e| e.into_inner());
                if last.is_some_and(|t| t.elapsed() < PANEL_GAP) {
                    continue;
                }
                *last = Some(Instant::now());
            }
            let _ = app.emit("viewer", json!({ "vm": vm, "msg": msg }));
            crate::overlay::on_viewer(&app, &vm, &msg);
            crate::dock::on_viewer(&app, &vm, &msg);
            // The first picture: the app zooms into the machine and then reveals the viewer (viewer_reveal). If the
            // page doesn't (hidden, busy), the viewer comes out on its own a moment later.
            if kind == "first-frame" && viewer.embed && !viewer.first_frame.swap(true, Ordering::AcqRel) {
                let late = viewer.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(2000));
                    if !late.revealed.load(Ordering::Relaxed) {
                        reveal(&late);
                    }
                });
            }
            if matches!(kind.as_str(), "first-frame" | "error" | "app-running" | "stage-failed" | "ended") {
                if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|w| w.remove(&vm)) {
                    let _ = waiter.send(msg.clone());
                }
            }
        }
        let mut all = viewers();
        if all.as_ref().and_then(|v| v.get(&vm)).is_some_and(|v| Arc::ptr_eq(v, &viewer)) {
            all.as_mut().map(|v| v.remove(&vm));
        }
        // The last machine closed: the clipboard copies kept for it are forgotten.
        let none_left = all.as_ref().is_none_or(|v| v.is_empty());
        drop(all);
        if none_left {
            crate::clipboard::clear();
        }
        announce_cover();
        crate::capture::on_recording(&vm, false);
        let closed = json!({ "type": "closed" });
        if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|w| w.remove(&vm)) {
            let _ = waiter.send(closed.clone());
        }
        let _ = app.emit("viewer", json!({ "vm": vm, "msg": closed }));
        crate::overlay::on_viewer(&app, &vm, &closed);
        crate::dock::on_viewer(&app, &vm, &closed);
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

/// The end of "Open": opens the viewer with the module's arguments and returns once the first picture is decoded
/// (the button shows "Connecting the picture" until then), or with the viewer's error in plain words.
pub fn open_and_wait(app: &AppHandle, vm: &str, launch: &Value) -> Result<(), String> {
    let arguments: Vec<String> = launch["arguments"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    if arguments.first().map(String::as_str) != Some("stream") {
        return Err("The module didn't say how to open the machine.".into());
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
    let exe = viewer_path().ok_or("GpuVM's viewer isn't installed.")?;
    let (tx, rx) = std::sync::mpsc::channel();
    {
        // One opening per machine at a time (a double click, or a switch from the panel while it connects): a
        // second viewer would replace the first in the list and leave it streaming out of reach.
        let mut waiters = WAITERS.lock().unwrap_or_else(|e| e.into_inner());
        let waiters = waiters.get_or_insert_with(HashMap::new);
        if waiters.contains_key(vm) {
            return Err("This machine is already opening.".into());
        }
        waiters.insert(vm.to_string(), tx);
    }
    // The picture always starts inside the app's window, hidden behind it; a machine set to full screen goes full
    // screen when it is revealed, and coming out of full screen brings it back inside the app.
    let full_screen = match arguments.iter().position(|a| a == "--display-mode") {
        Some(i) => arguments.get(i + 1).map(String::as_str) != Some("windowed"),
        None => true,
    };
    if let Some(i) = arguments.iter().position(|a| a == "--display-mode") {
        arguments.drain(i..(i + 2).min(arguments.len()));
    }
    arguments.push("--display-mode".into());
    arguments.push("windowed".into());
    if let Some((hwnd, x, y, w, h)) = content_rect(app) {
        arguments.push("--gpuvm-embed".into());
        arguments.push(format!("{hwnd},{x},{y},{w},{h}"));
    }
    let embed = arguments.iter().any(|a| a == "--gpuvm-embed");
    if let Err(e) = open_blocking(app.clone(), vm.to_string(), exe, arguments, embed, full_screen) {
        WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(|w| w.remove(vm));
        return Err(e);
    }
    // Cold start: Sunshine tests its encoders on the first session after boot (up to ~20 s, labs 019 and 023).
    let msg = rx.recv_timeout(Duration::from_secs(90)).unwrap_or_else(|_| json!({ "type": "timeout" }));
    match msg["type"].as_str().unwrap_or("") {
        "first-frame" => Ok(()),
        // Text from the streaming host (untrusted): kept short.
        "error" => Err(msg["message"].as_str().unwrap_or("The viewer couldn't connect.").chars().take(200).collect()),
        "app-running" => Err("The machine has another session open. Close it and try again.".into()),
        "stage-failed" => Err(format!("Couldn't connect ({}).", msg["stage"].as_str().unwrap_or("?"))),
        // The viewer's last message on every exit ("ended"), or its pipe closing.
        "closed" | "ended" => Err("The viewer closed before showing the picture.".into()),
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
pub async fn viewer_send(vm: String, msg: Value) -> Result<(), String> {
    send_to(&vm, &msg)
}

/// A command for a machine's viewer, from this app's own code (the panel's placement).
pub fn send_to(vm: &str, msg: &Value) -> Result<(), String> {
    let kind = msg["type"].as_str().unwrap_or("");
    if !TO_VIEWER.contains(&kind) {
        return Err("Invalid command for the viewer.".into());
    }
    let viewer = viewers().as_ref().and_then(|v| v.get(vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    if kind == "fullscreen" {
        allow_raise(&viewer);
    }
    if send_raw(&viewer, msg) { Ok(()) } else { Err("The viewer didn't respond.".into()) }
}

/// The same message to every open viewer (settings that apply to all of them).
pub fn broadcast(msg: &Value) {
    let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
    for viewer in list {
        send_raw(&viewer, msg);
    }
}

/// The viewer's window, for placing the panel over it.
/// Whether a machine's viewer is full screen now.
pub fn viewer_full_screen(vm: &str) -> bool {
    viewers().as_ref().and_then(|v| v.get(vm)).is_some_and(|v| v.full_now.load(Ordering::Relaxed))
}

/// A machine is open in a viewer (the clipboard widget only keeps copies meanwhile).
pub fn any_open() -> bool {
    viewers().as_ref().is_some_and(|v| !v.is_empty())
}

pub fn viewer_hwnd(vm: &str) -> Option<isize> {
    let viewer = viewers().as_ref()?.get(vm).cloned()?;
    let hwnd = viewer.hwnd.load(Ordering::Relaxed);
    // Checked again on use: a closed window's handle can be reused by another program.
    window_of(hwnd, viewer.child.pid).then_some(hwnd)
}

/// Lets the viewer take the foreground back from this app (when the panel closes).
pub fn allow_viewer_foreground(vm: &str) {
    if let Some(pid) = viewers().as_ref().and_then(|v| v.get(vm)).map(|v| v.child.pid) {
        allow_foreground(pid);
    }
}

/// How long after this app asks for the picture a full-screen report may raise the viewer.
const RAISE_WINDOW: Duration = Duration::from_secs(3);

fn allow_raise(viewer: &Viewer) {
    *viewer.raise_until.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now() + RAISE_WINDOW);
}

/// Uses up the raise this app granted, if it is still current.
fn take_raise(viewer: &Viewer) -> bool {
    viewer.raise_until.lock().unwrap_or_else(|e| e.into_inner()).take().is_some_and(|until| Instant::now() < until)
}

fn reveal(viewer: &Viewer) {
    allow_raise(viewer);
    viewer.visible.store(true, Ordering::Relaxed);
    announce_cover();
    viewer.revealed.store(true, Ordering::Relaxed);
    allow_foreground(viewer.child.pid);
    send_raw(viewer, &json!({ "type": "reveal", "fullscreen": viewer.full_screen }));
}

/// The app finished zooming into the machine: the picture comes out from behind it.
#[tauri::command]
pub async fn viewer_reveal(vm: String) -> Result<(), String> {
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    if !viewer.visible.load(Ordering::Relaxed) {
        reveal(&viewer);
    }
    Ok(())
}

/// Back to Home: the viewer hides and its session stays connected (keep), or it disconnects.
#[tauri::command]
pub async fn viewer_home(app: AppHandle, vm: String, keep: bool) -> Result<(), String> {
    crate::overlay::close(&app);
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    viewer.visible.store(false, Ordering::Relaxed);
    announce_cover();
    let msg = if keep { json!({ "type": "hide" }) } else { json!({ "type": "quit" }) };
    if send_raw(&viewer, &msg) { Ok(()) } else { Err("The viewer didn't respond.".into()) }
}

/// Back to a machine still connected: its picture shows again over the app (or full screen).
#[tauri::command]
pub async fn viewer_show(app: AppHandle, vm: String) -> Result<(), String> {
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    if viewer.embed {
        if let Some((_, x, y, w, h)) = content_rect(&app) {
            send_raw(&viewer, &json!({ "type": "place", "x": x, "y": y, "w": w, "h": h }));
        }
    }
    allow_foreground(viewer.child.pid);
    // Coming back to a full-screen picture: its next full-screen report raises it.
    allow_raise(&viewer);
    if !send_raw(&viewer, &json!({ "type": "show" })) {
        return Err("The viewer didn't respond.".into());
    }
    viewer.visible.store(true, Ordering::Relaxed);
    viewer.revealed.store(true, Ordering::Relaxed);
    announce_cover();
    Ok(())
}

/// Whether a machine's viewer is open and its picture shown (not hidden while the person is in Home).
pub fn viewer_visible(vm: &str) -> bool {
    viewers().as_ref().and_then(|v| v.get(vm)).is_some_and(|v| v.visible.load(Ordering::Relaxed))
}

/// Closes every viewer (GpuVM is going to its notices-only mode: no windows left).
pub fn quit_all() {
    let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
    for viewer in list {
        send_raw(&viewer, &json!({ "type": "quit" }));
    }
}

/// The machine whose viewer window has the keyboard now, if any (what an admin prompt is about to interrupt).
pub fn foreground_vm() -> Option<String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    // SAFETY: reading the foreground window has no preconditions.
    let foreground = unsafe { GetForegroundWindow() } as isize;
    let all = viewers();
    all.as_ref()?.iter().find(|(_, v)| v.hwnd.load(Ordering::Relaxed) == foreground && window_of(foreground, v.child.pid)).map(|(name, _)| name.clone())
}

/// Machines whose viewer is open (connected), and whether each is inside the app's window.
#[tauri::command]
pub fn viewer_list() -> Vec<Value> {
    viewers().as_ref().map(|v| v.iter().map(|(name, x)| json!({ "vm": name, "embed": x.embed, "visible": x.visible.load(Ordering::Relaxed) })).collect()).unwrap_or_default()
}

/// Whether a machine's viewer is open and its process still running (asked right before zooming into it, so the
/// app never zooms into a picture that is gone). A dead one is forgotten here.
#[tauri::command]
pub fn viewer_is_open(vm: String) -> bool {
    let Some(viewer) = viewers().as_ref().and_then(|v| v.get(&vm).cloned()) else { return false };
    if viewer.child.running() {
        return true;
    }
    let mut all = viewers();
    if all.as_ref().and_then(|v| v.get(&vm)).is_some_and(|v| Arc::ptr_eq(v, &viewer)) {
        all.as_mut().map(|v| v.remove(&vm));
    }
    false
}
