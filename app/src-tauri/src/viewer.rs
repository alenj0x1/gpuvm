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

const MAX_LINE: usize = 16 * 1024;
const PANEL_GAP: Duration = Duration::from_millis(250);
const FROM_VIEWER: &[&str] = &["hello", "stage", "stage-failed", "connected", "error", "app-running", "window", "first-frame", "stats", "panel", "home", "ended", "drag",
    "agent-resume",
    "capture", "capture-error", "recording",
    "input",
    "notice"];
const TO_VIEWER: &[&str] = &["inset", "capture", "fullscreen", "stats", "quit", "focus", "screenshot", "record", "replay-save", "agent-watch"];

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
    child: crate::lowbox::LowChild,
    raise_until: Mutex<Option<Instant>>,
    write: Mutex<()>,
    hwnd: AtomicIsize,
    embed: bool,
    visible: std::sync::atomic::AtomicBool,
    revealed: std::sync::atomic::AtomicBool,
    first_frame: std::sync::atomic::AtomicBool,
    full_now: std::sync::atomic::AtomicBool,
    last_toggle: Mutex<Option<Instant>>,
    last_drag: Mutex<Option<Instant>>,
    full_screen: bool,
    replaced: std::sync::atomic::AtomicBool,
}

const TITLEBAR: f64 = 40.0;

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

static FOLLOW: Mutex<Option<(i32, i32, i32, i32)>> = Mutex::new(None);
static FOLLOWING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

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

fn window_of(hwnd: isize, pid: u32) -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetWindowThreadProcessId, IsWindow};
    if hwnd == 0 {
        return false;
    }
    let mut owner = 0u32;
    // SAFETY: plain queries on a window handle; a stale or foreign handle only makes them fail or differ.
    unsafe { IsWindow(hwnd as _) != 0 && GetWindowThreadProcessId(hwnd as _, &mut owner) != 0 && owner == pid }
}

fn bring_forward(hwnd: isize, pid: u32) {
    use windows_sys::Win32::UI::WindowsAndMessaging::SetForegroundWindow;
    if !window_of(hwnd, pid) {
        return;
    }
    raise_without_focus(hwnd, false);
    // SAFETY: a window of the viewer's own process, checked just above.
    unsafe { SetForegroundWindow(hwnd as _) };
}

// HWND_TOP is ignored for a program that isn't in front; the topmost round trip isn't.
pub(crate) fn raise_without_focus(hwnd: isize, restore: bool) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{IsIconic, SetWindowPos, ShowWindow, HWND_NOTOPMOST, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_SHOWWINDOW, SW_SHOWNA, SW_SHOWNOACTIVATE};
    // SAFETY: plain Win32 calls on a window handle this app holds.
    unsafe {
        if restore {
            ShowWindow(hwnd as _, if IsIconic(hwnd as _) != 0 { SW_SHOWNOACTIVATE } else { SW_SHOWNA });
        }
        let flags = SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW;
        let topmost = windows_sys::Win32::UI::WindowsAndMessaging::GetWindowLongPtrW(hwnd as _, windows_sys::Win32::UI::WindowsAndMessaging::GWL_EXSTYLE) as u32 & windows_sys::Win32::UI::WindowsAndMessaging::WS_EX_TOPMOST != 0;
        SetWindowPos(hwnd as _, HWND_TOPMOST, 0, 0, 0, 0, flags);
        if !topmost {
            SetWindowPos(hwnd as _, HWND_NOTOPMOST, 0, 0, 0, 0, flags);
        }
    }
}

// At Low integrity its own request to go there can be ignored, so the app places it.
fn keep_below_app(app: &AppHandle, viewer: &Viewer) {
    use tauri::Manager;
    use windows_sys::Win32::UI::WindowsAndMessaging::{IsWindowVisible, SetWindowPos, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOOWNERZORDER, SWP_NOSIZE};
    if !viewer.embed || viewer.visible.load(Ordering::Relaxed) {
        return;
    }
    let hwnd = viewer.hwnd.load(Ordering::Relaxed);
    let Some(main) = app.get_webview_window("main").and_then(|w| w.hwnd().ok()) else { return };
    if hwnd == 0 || !window_of(hwnd, viewer.child.pid) {
        return;
    }
    // SAFETY: a window of the viewer's own process (checked above) placed after this app's main window.
    unsafe {
        if IsWindowVisible(hwnd as _) != 0 {
            SetWindowPos(hwnd as _, main.0 as _, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_NOOWNERZORDER);
        }
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

static WAITERS: Mutex<Option<HashMap<String, std::sync::mpsc::Sender<Value>>>> = Mutex::new(None);

static VIEWERS: Mutex<Option<HashMap<String, Arc<Viewer>>>> = Mutex::new(None);

fn viewers() -> std::sync::MutexGuard<'static, Option<HashMap<String, Arc<Viewer>>>> {
    VIEWERS.lock().unwrap_or_else(|e| e.into_inner())
}

static APP: std::sync::OnceLock<AppHandle> = std::sync::OnceLock::new();
static COVERED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

// The VMs share this PC's GPU: animations behind the stream slow the stream.
fn announce_cover() {
    let covered = viewers().as_ref().is_some_and(|v| v.values().any(|x| x.visible.load(Ordering::Relaxed)));
    if COVERED.swap(covered, Ordering::AcqRel) != covered {
        if let Some(app) = APP.get() {
            let _ = app.emit("viewer-cover", json!({ "covered": covered }));
        }
    }
}

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
    // SAFETY: the OVERLAPPED, its event and the buffer live until the operation completes or is cancelled and waited for.
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
    // This user only; the Low label lets the Low viewer open it.
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
    let _ = APP.set(app.clone());
    let child = crate::lowbox::spawn_low(&exe, &all, &[(TOKEN_VAR, token.as_str())])?;
    let pid = child.pid;

    let refuse = |message: &str| -> Result<u32, String> {
        child.kill();
        Err(message.to_string())
    };
    if !wait_connect(pipe.0, child.handle(), Duration::from_secs(20)) {
        // Say how a viewer that ended before connecting failed (0xC0000142: a DLL or the console failed at Low or in its job).
        if let Some(code) = child.exit_code() {
            eprintln!("viewer {vm}: ended before connecting, exit code {code:#010x}");
            return refuse(&format!("The viewer closed as it started (code {code:#010x})."));
        }
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

    let viewer = Arc::new(Viewer { pipe, child, raise_until: Mutex::new(None), write: Mutex::new(()), hwnd: AtomicIsize::new(0), embed, visible: std::sync::atomic::AtomicBool::new(!embed), revealed: std::sync::atomic::AtomicBool::new(!embed), first_frame: std::sync::atomic::AtomicBool::new(false), full_now: std::sync::atomic::AtomicBool::new(false), last_toggle: Mutex::new(None), last_drag: Mutex::new(None), full_screen, replaced: std::sync::atomic::AtomicBool::new(false) });
    viewers().get_or_insert_with(HashMap::new).insert(vm.clone(), viewer.clone());
    let _ = app.emit("viewer", json!({ "vm": vm, "msg": { "type": "opened", "pid": pid } }));
    send_raw(&viewer, &crate::capture::setup_message());

    std::thread::spawn(move || {
        while let Some(line) = read_line(viewer.pipe.0, &mut pending, None) {
            let Ok(mut msg) = serde_json::from_slice::<Value>(&line) else { continue };
            let kind = msg["type"].as_str().unwrap_or("").to_string();
            if !FROM_VIEWER.contains(&kind.as_str()) || kind == "hello" {
                continue;
            }
            if viewer.replaced.load(Ordering::Relaxed) {
                continue;
            }
            if kind == "window" {
                let hwnd = msg["hwnd"].as_f64().unwrap_or(0.0) as isize;
                // Only a window of the viewer's own process: another program's handle would put GpuVM's panel and focus there.
                viewer.hwnd.store(if window_of(hwnd, viewer.child.pid) { hwnd } else { 0 }, Ordering::Relaxed);
                let full = msg["fullScreen"].as_bool().unwrap_or(false);
                viewer.full_now.store(full, Ordering::Relaxed);
                // At Low integrity the viewer can't come in front of this app: raised once, only right after the app asked for the picture.
                let shown = viewer.hwnd.load(Ordering::Relaxed);
                if full && shown != 0 && viewer.visible.load(Ordering::Relaxed) && take_raise(&viewer) {
                    bring_forward(shown, viewer.child.pid);
                }
                keep_below_app(&app, &viewer);
                if let Some(o) = msg.as_object_mut() {
                    o.remove("hwnd");
                }
            }
            if kind == "drag" {
                let mut last = viewer.last_drag.lock().unwrap_or_else(|e| e.into_inner());
                if !last.is_some_and(|t| t.elapsed() < PANEL_GAP) && viewer.visible.load(Ordering::Relaxed) {
                    *last = Some(Instant::now());
                    crate::dropzone::on_drag(&app, &vm);
                }
                continue;
            }
            if kind == "input" {
                crate::agent::on_input(&app, &vm);
                continue;
            }
            if kind == "recording" {
                crate::capture::on_recording(&vm, msg["on"].as_bool().unwrap_or(false));
            }
            if kind == "capture" {
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
            crate::agent::on_viewer(&app, &vm, &msg);
            crate::status::on_viewer(&app, &vm, &msg);
            crate::live::on_viewer(&app, &vm, &msg);
            if kind == "first-frame" && !background(&vm) {
                publish_state(&vm, "picture");
            }
            if kind == "first-frame" && background(&vm) && !viewer.first_frame.swap(true, Ordering::AcqRel) {
                viewer.visible.store(false, Ordering::Relaxed);
                send_raw(&viewer, &json!({ "type": "hide" }));
            }
            if kind == "first-frame" && viewer.embed && !viewer.first_frame.swap(true, Ordering::AcqRel) {
                let late = viewer.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(2000));
                    if !late.revealed.load(Ordering::Relaxed) {
                        reveal(&late);
                    }
                });
            }
            if matches!(kind.as_str(), "connected" | "first-frame") {
                keep_below_app(&app, &viewer);
            }
            if kind == "connected" {
                let (app, viewer) = (app.clone(), viewer.clone());
                std::thread::spawn(move || {
                    for _ in 0..60 {
                        std::thread::sleep(Duration::from_millis(100));
                        if viewer.visible.load(Ordering::Relaxed) || !viewer.child.running() {
                            break;
                        }
                        keep_below_app(&app, &viewer);
                    }
                });
            }
            if kind == "connected" && !viewer.replaced.load(Ordering::Relaxed) {
                if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|w| w.get(&vm)) {
                    let _ = waiter.send(msg.clone());
                }
            }
            if matches!(kind.as_str(), "error" | "stage-failed") && !viewer.first_frame.load(Ordering::Relaxed) {
                publish_state(&vm, "failed");
            }
            if matches!(kind.as_str(), "first-frame" | "error" | "app-running" | "stage-failed" | "ended") && !viewer.replaced.load(Ordering::Relaxed) {
                if let Some(waiter) = WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|w| w.remove(&vm)) {
                    let _ = waiter.send(msg.clone());
                }
            }
        }
        if viewer.replaced.load(Ordering::Relaxed) {
            let mut all = viewers();
            if all.as_ref().and_then(|v| v.get(&vm)).is_some_and(|v| Arc::ptr_eq(v, &viewer)) {
                all.as_mut().map(|v| v.remove(&vm));
            }
            return;
        }
        set_background(&vm, false);
        let mut all = viewers();
        if all.as_ref().and_then(|v| v.get(&vm)).is_some_and(|v| Arc::ptr_eq(v, &viewer)) {
            all.as_mut().map(|v| v.remove(&vm));
        }
        let none_left = all.as_ref().is_none_or(|v| v.is_empty());
        drop(all);
        if none_left {
            crate::clipboard::clear();
        }
        announce_cover();
        crate::capture::on_recording(&vm, false);
        publish_state(&vm, "closed");
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

pub fn launch_in(data: &Value) -> Option<Value> {
    let items: Vec<&Value> = match data {
        Value::Array(a) => a.iter().collect(),
        other => vec![other],
    };
    items.into_iter().rev().find_map(|v| v.get("viewerLaunch").filter(|l| l.is_object()).cloned())
}

// One opening per machine at a time: two Connects on a new copy left a pure black picture.
pub fn opening_lock(vm: &str) -> Arc<Mutex<()>> {
    static LOCKS: Mutex<Option<HashMap<String, Arc<Mutex<()>>>>> = Mutex::new(None);
    let mut all = LOCKS.lock().unwrap_or_else(|e| e.into_inner());
    all.get_or_insert_with(HashMap::new).entry(vm.to_lowercase()).or_insert_with(|| Arc::new(Mutex::new(()))).clone()
}

fn with_embed(app: &AppHandle, mut arguments: Vec<String>) -> Vec<String> {
    if let (Some(i), Some((hwnd, x, y, w, h))) = (arguments.iter().position(|a| a == "--gpuvm-embed"), content_rect(app)) {
        if let Some(value) = arguments.get_mut(i + 1) {
            *value = format!("{hwnd},{x},{y},{w},{h}");
        }
    }
    arguments
}

pub fn viewer_state_path() -> Option<PathBuf> {
    std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("GpuVM").join("viewer-state.json"))
}

pub fn read_viewer_states() -> Value {
    viewer_state_path().and_then(|p| std::fs::read_to_string(p).ok()).and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| json!({}))
}

static STATE_FILE: Mutex<()> = Mutex::new(());

pub(crate) fn publish_state(vm: &str, state: &str) {
    let Some(path) = viewer_state_path() else { return };
    let _guard = STATE_FILE.lock().unwrap_or_else(|e| e.into_inner());
    let mut all = read_viewer_states();
    if !all.is_object() {
        all = json!({});
    }
    let at = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0);
    all[vm.to_lowercase()] = json!({ "state": state, "at": at });
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("json.tmp");
    if std::fs::write(&tmp, all.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, &path);
    }
}

pub fn open_and_wait(app: &AppHandle, vm: &str, launch: &Value) -> Result<(), String> {
    publish_state(vm, "opening");
    crate::agent::picture_shown(vm);
    let arguments: Vec<String> = launch["arguments"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    if arguments.first().map(String::as_str) != Some("stream") {
        return Err("The module didn't say how to open the machine.".into());
    }
    // The module quotes the name for a command line; passed as its own argument, the quotes would become part of it.
    let mut arguments: Vec<String> = arguments.into_iter()
        .map(|a| if a.len() >= 2 && a.starts_with('"') && a.ends_with('"') { a[1..a.len() - 1].to_string() } else { a })
        .collect();
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
        let mut waiters = WAITERS.lock().unwrap_or_else(|e| e.into_inner());
        let waiters = waiters.get_or_insert_with(HashMap::new);
        if waiters.contains_key(vm) {
            return Err("This machine is already opening.".into());
        }
        waiters.insert(vm.to_string(), tx);
    }
    let full_screen = match arguments.iter().position(|a| a == "--display-mode") {
        Some(i) => arguments.get(i + 1).map(String::as_str) != Some("windowed"),
        None => true,
    };
    if let Some(i) = arguments.iter().position(|a| a == "--display-mode") {
        arguments.drain(i..(i + 2).min(arguments.len()));
    }
    arguments.push("--display-mode".into());
    arguments.push("windowed".into());
    // Recordings keep the stream's codec: HEVC files don't open in Windows' players without the Store extension, so auto picks H.264 there.
    if !arguments.iter().any(|a| a == "--video-codec") && !crate::capture::windows_decodes(b"HEVC") {
        arguments.push("--video-codec".into());
        arguments.push("H.264".into());
    }
    if let Some((hwnd, x, y, w, h)) = content_rect(app) {
        arguments.push("--gpuvm-embed".into());
        arguments.push(format!("{hwnd},{x},{y},{w},{h}"));
    }
    let embed = arguments.iter().any(|a| a == "--gpuvm-embed");
    if let Err(e) = open_blocking(app.clone(), vm.to_string(), exe.clone(), arguments.clone(), embed, full_screen) {
        WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(|w| w.remove(vm));
        return Err(e);
    }
    // A first session after Sunshine restarts or changes the display mode can stay black: no picture within FIRST_PICTURE reopens the viewer once.
    const FIRST_PICTURE: Duration = Duration::from_secs(6);
    let started = Instant::now();
    let mut connected_at: Option<Instant> = None;
    let mut retried = false;
    let msg = loop {
        let left = Duration::from_secs(90).saturating_sub(started.elapsed());
        let wait = match connected_at {
            Some(t) if !retried => FIRST_PICTURE.saturating_sub(t.elapsed()).min(left),
            _ => left,
        };
        match rx.recv_timeout(wait) {
            Ok(m) if m["type"] == "connected" => {
                connected_at.get_or_insert_with(Instant::now);
            }
            Ok(m) => break m,
            Err(_) if connected_at.is_some() && !retried && !left.is_zero() => {
                retried = true;
                connected_at = None;
                eprintln!("viewer {vm}: no picture {}s after connecting; opening it once more", FIRST_PICTURE.as_secs());
                if let Some(old) = viewers().as_ref().and_then(|v| v.get(vm).cloned()) {
                    old.replaced.store(true, Ordering::Relaxed);
                    old.child.kill();
                }
                viewers().as_mut().map(|v| v.remove(vm));
                crate::capture::on_recording(vm, false);
                crate::agent::viewer_replaced(vm);
                let args = with_embed(app, arguments.clone());
                if let Err(e) = open_blocking(app.clone(), vm.to_string(), exe.clone(), args, embed, full_screen) {
                    break json!({ "type": "error", "message": e });
                }
            }
            Err(_) => break json!({ "type": "timeout" }),
        }
    };
    WAITERS.lock().unwrap_or_else(|e| e.into_inner()).as_mut().map(|w| w.remove(vm));
    match msg["type"].as_str().unwrap_or("") {
        "first-frame" => Ok(()),
        "error" => Err(msg["message"].as_str().unwrap_or("The viewer couldn't connect.").chars().take(200).collect()),
        "app-running" => Err("The machine has another session open. Close it and try again.".into()),
        "stage-failed" => Err(format!("Couldn't connect ({}).", msg["stage"].as_str().unwrap_or("?"))),
        "closed" | "ended" => Err("The viewer closed before showing the picture.".into()),
        _ => Ok(()),
    }
}

fn send_raw(viewer: &Viewer, msg: &Value) -> bool {
    let mut line = msg.to_string().into_bytes();
    line.push(b'\n');
    let _guard = viewer.write.lock().unwrap_or_else(|e| e.into_inner());
    overlapped_io(viewer.pipe.0, Some(&line), None, Some(Duration::from_secs(2))).is_ok()
}

#[tauri::command]
pub async fn viewer_send(vm: String, msg: Value) -> Result<(), String> {
    send_to(&vm, &msg)
}

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

pub fn broadcast(msg: &Value) {
    let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
    for viewer in list {
        send_raw(&viewer, msg);
    }
}

pub fn viewer_full_screen(vm: &str) -> bool {
    viewers().as_ref().and_then(|v| v.get(vm)).is_some_and(|v| v.full_now.load(Ordering::Relaxed))
}

pub fn any_open() -> bool {
    viewers().as_ref().is_some_and(|v| !v.is_empty())
}

pub fn viewer_hwnd(vm: &str) -> Option<isize> {
    let viewer = viewers().as_ref()?.get(vm).cloned()?;
    let hwnd = viewer.hwnd.load(Ordering::Relaxed);
    // Checked again on use: a closed window's handle can be reused by another program.
    window_of(hwnd, viewer.child.pid).then_some(hwnd)
}

pub fn allow_viewer_foreground(vm: &str) {
    if let Some(pid) = viewers().as_ref().and_then(|v| v.get(vm)).map(|v| v.child.pid) {
        allow_foreground(pid);
    }
}

const RAISE_WINDOW: Duration = Duration::from_secs(3);

fn allow_raise(viewer: &Viewer) {
    *viewer.raise_until.lock().unwrap_or_else(|e| e.into_inner()) = Some(Instant::now() + RAISE_WINDOW);
}

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

#[tauri::command]
pub async fn viewer_reveal(app: AppHandle, vm: String) -> Result<(), String> {
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    set_background(&vm, false);
    crate::agent::picture_shown(&vm);
    if !viewer.visible.load(Ordering::Relaxed) {
        reveal(&viewer);
    }
    if viewer.first_frame.load(Ordering::Relaxed) {
        publish_state(&vm, "picture");
    }
    crate::status::refresh(&app);
    Ok(())
}

#[tauri::command]
pub async fn viewer_home(app: AppHandle, vm: String, keep: bool) -> Result<(), String> {
    crate::overlay::close(&app);
    crate::overlay::hide_all(&app, &vm);
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    viewer.visible.store(false, Ordering::Relaxed);
    crate::status::refresh(&app);
    announce_cover();
    let msg = if keep { json!({ "type": "hide" }) } else { json!({ "type": "quit" }) };
    if send_raw(&viewer, &msg) { Ok(()) } else { Err("The viewer didn't respond.".into()) }
}

#[tauri::command]
pub async fn viewer_show(app: AppHandle, vm: String) -> Result<(), String> {
    let viewer = viewers().as_ref().and_then(|v| v.get(&vm).cloned()).ok_or("This machine's viewer isn't open.")?;
    set_background(&vm, false);
    crate::agent::picture_shown(&vm);
    if viewer.first_frame.load(Ordering::Relaxed) {
        publish_state(&vm, "picture");
    }
    if viewer.embed {
        if let Some((_, x, y, w, h)) = content_rect(&app) {
            send_raw(&viewer, &json!({ "type": "place", "x": x, "y": y, "w": w, "h": h }));
        }
    }
    allow_foreground(viewer.child.pid);
    allow_raise(&viewer);
    viewer.visible.store(true, Ordering::Relaxed);
    viewer.revealed.store(true, Ordering::Relaxed);
    if !send_raw(&viewer, &json!({ "type": "show" })) {
        return Err("The viewer didn't respond.".into());
    }
    let hwnd = viewer.hwnd.load(Ordering::Relaxed);
    if viewer.full_now.load(Ordering::Relaxed) && hwnd != 0 && take_raise(&viewer) {
        bring_forward(hwnd, viewer.child.pid);
    }
    viewer.visible.store(true, Ordering::Relaxed);
    viewer.revealed.store(true, Ordering::Relaxed);
    announce_cover();
    crate::status::refresh(&app);
    Ok(())
}

static BACKGROUND: Mutex<Option<std::collections::HashSet<String>>> = Mutex::new(None);

pub fn background(vm: &str) -> bool {
    BACKGROUND.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|s| s.contains(vm))
}

pub fn set_background(vm: &str, on: bool) {
    let mut s = BACKGROUND.lock().unwrap_or_else(|e| e.into_inner());
    let s = s.get_or_insert_with(Default::default);
    if on { s.insert(vm.to_string()); } else { s.remove(vm); }
}

pub fn open_background(app: &AppHandle, vm: &str, launch: &Value) -> Result<(), String> {
    set_background(vm, true);
    let result = open_and_wait(app, vm, launch);
    if result.is_err() {
        set_background(vm, false);
    }
    result
}

pub fn viewer_visible(vm: &str) -> bool {
    viewers().as_ref().and_then(|v| v.get(vm)).is_some_and(|v| v.visible.load(Ordering::Relaxed))
}

#[tauri::command]
pub fn viewer_gone(vm: String) {
    let Some(viewer) = viewers().as_ref().and_then(|v| v.get(&vm).cloned()) else { return };
    send_raw(&viewer, &json!({ "type": "quit" }));
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(5));
        if viewer.child.running() {
            eprintln!("viewer {vm}: the machine is gone and the viewer didn't quit; ended");
            viewer.child.kill();
        }
    });
}

pub fn quit_all() {
    let list: Vec<Arc<Viewer>> = viewers().as_ref().map(|v| v.values().cloned().collect()).unwrap_or_default();
    for viewer in list {
        send_raw(&viewer, &json!({ "type": "quit" }));
    }
}

pub fn foreground_vm() -> Option<String> {
    use windows_sys::Win32::UI::WindowsAndMessaging::GetForegroundWindow;
    // SAFETY: reading the foreground window has no preconditions.
    let foreground = unsafe { GetForegroundWindow() } as isize;
    let all = viewers();
    all.as_ref()?.iter().find(|(_, v)| v.hwnd.load(Ordering::Relaxed) == foreground && window_of(foreground, v.child.pid)).map(|(name, _)| name.clone())
}

#[tauri::command]
pub fn viewer_list() -> Vec<Value> {
    viewers().as_ref().map(|v| v.iter().map(|(name, x)| json!({ "vm": name, "embed": x.embed, "visible": x.visible.load(Ordering::Relaxed) })).collect()).unwrap_or_default()
}

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
