// Hidden, not just transparent, while closed: then Windows keeps presenting the stream directly.

use serde_json::{json, Value};
use std::sync::atomic::Ordering;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::{HWND, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::ClientToScreen;
use windows_sys::Win32::UI::HiDpi::GetDpiForWindow;
use windows_sys::Win32::UI::WindowsAndMessaging::{GetClientRect, IsIconic, IsWindow, SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "viewer-panel";
static WIDTH: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(340);
const MIN_WIDTH: u32 = 300;
const MAX_WIDTH: u32 = 560;
const SLIDE_MS: u64 = 320;

#[derive(Default)]
struct Panel {
    vm: Option<String>,
    open: bool,
}

static PANEL: Mutex<Panel> = Mutex::new(Panel { vm: None, open: false });

fn panel() -> std::sync::MutexGuard<'static, Panel> {
    PANEL.lock().unwrap_or_else(|e| e.into_inner())
}

pub(crate) fn client_rect(hwnd: isize) -> Option<(i32, i32, i32, i32, f64)> {
    // SAFETY: plain queries on a window handle; a stale handle only makes them fail.
    unsafe {
        let hwnd = hwnd as HWND;
        if IsWindow(hwnd) == 0 || IsIconic(hwnd) != 0 {
            return None;
        }
        let mut rect: RECT = std::mem::zeroed();
        if GetClientRect(hwnd, &mut rect) == 0 {
            return None;
        }
        let mut origin = POINT { x: 0, y: 0 };
        ClientToScreen(hwnd, &mut origin);
        let dpi = GetDpiForWindow(hwnd).max(96);
        Some((origin.x, origin.y, rect.right - rect.left, rect.bottom - rect.top, dpi as f64 / 96.0))
    }
}

fn panel_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS).general_autofill_enabled(false)
        .title("GpuVM")
        .decorations(false)
        .transparent(true).no_redirection_bitmap(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .visible(false)
        .build()
        .ok()
}

pub fn picture_rect(viewer: isize, vm: &str) -> Option<(i32, i32, i32, i32)> {
    let (x, y, w, h, scale) = client_rect(viewer)?;
    let open_here = { let p = panel(); p.open && p.vm.as_deref() == Some(vm) };
    let panel_w = if open_here { ((WIDTH.load(Ordering::Relaxed) as f64 * scale).round() as i32).min(w / 2) } else { 0 };
    Some((x, y, w - panel_w, h))
}

fn place(window: &tauri::WebviewWindow, viewer: isize) -> Option<(i32, i32, f64)> {
    let (x, y, w, h, scale) = client_rect(viewer)?;
    let logical = WIDTH.load(std::sync::atomic::Ordering::Relaxed) as f64;
    let width = ((logical * scale).round() as i32).min(w / 2);
    let _ = window.set_size(PhysicalSize::new(width as u32, h as u32));
    borderless(window);
    let _ = window.set_position(PhysicalPosition::new(x + w - width, y));
    if let Ok(own) = window.hwnd() {
        // SAFETY: makes the viewer the panel's owner window, so the panel stays just above it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
    }
    Some((width, w, scale))
}

static MARKED: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

// Marked full-screen so the taskbar stays hidden while the panel has the focus.
fn mark_full_screen(window: &tauri::WebviewWindow, on: bool) {
    MARKED.store(if on { 2 } else { 1 }, Ordering::Relaxed);
    mark_taskbar(window, on);
}

// Tauri's undecorated windows keep WS_CAPTION, drawn by Windows 10 as a 1px grey frame: only WS_POPUP, reapplied on every show.
pub(crate) fn borderless(window: &tauri::WebviewWindow) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowPos, GWL_STYLE, SWP_FRAMECHANGED, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER,
        WS_CAPTION, WS_MAXIMIZEBOX, WS_MINIMIZEBOX, WS_POPUP, WS_SYSMENU, WS_THICKFRAME,
    };
    let Ok(own) = window.hwnd() else { return };
    let hwnd = own.0 as HWND;
    // SAFETY: reads and rewrites this app's own window's style, then asks Windows to recompute its frame.
    unsafe {
        // Windows' show/hide animation draws a captioned ghost of the window ("GpuVM") for a moment.
        let off: i32 = 1;
        windows_sys::Win32::Graphics::Dwm::DwmSetWindowAttribute(hwnd, windows_sys::Win32::Graphics::Dwm::DWMWA_TRANSITIONS_FORCEDISABLED as u32, (&off as *const i32).cast(), 4);
        let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
        let frame = WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
        if style & frame == 0 && style & WS_POPUP != 0 {
            return;
        }
        SetWindowLongPtrW(hwnd, GWL_STYLE, ((style & !frame) | WS_POPUP) as isize);
        SetWindowPos(hwnd, std::ptr::null_mut(), 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }
}

// tao re-applies its own style, caption included, whenever it shows or hides a window, and Windows draws that caption
// for a frame: done off screen.
const AWAY: i32 = -32000;

fn move_raw(window: &tauri::WebviewWindow, x: i32, y: i32) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowPos, SWP_NOACTIVATE, SWP_NOSIZE, SWP_NOZORDER};
    if let Ok(own) = window.hwnd() {
        // SAFETY: moves this app's own window.
        unsafe { SetWindowPos(own.0 as HWND, std::ptr::null_mut(), x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE) };
    }
}

/// Runs on the main thread, where tao acts at once: called elsewhere, its show/hide would land after our moves.
fn on_main(window: &tauri::WebviewWindow, f: impl FnOnce(&tauri::WebviewWindow) + Send + 'static) {
    if MAIN.get().is_some_and(|id| *id == std::thread::current().id()) {
        return f(window);
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let w = window.clone();
    if window.run_on_main_thread(move || { f(&w); let _ = tx.send(()); }).is_ok() {
        let _ = rx.recv_timeout(std::time::Duration::from_millis(800));
    }
}

static MAIN: std::sync::OnceLock<std::thread::ThreadId> = std::sync::OnceLock::new();

pub fn mark_main_thread() {
    let _ = MAIN.set(std::thread::current().id());
}

/// Called off the main thread, destroy() only queues: a window built under the same label before it lands fails.
pub(crate) fn destroy_and_wait(app: &AppHandle, window: tauri::WebviewWindow) {
    let label = window.label().to_string();
    let _ = window.destroy();
    for _ in 0..50 {
        if app.get_webview_window(&label).is_none() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

// tao re-applies its frame each time it shows a window, so it shows each one once; after that it still takes the
// window for shown, and hiding and showing again go through Win32 alone.
static SHOWN: Mutex<Vec<isize>> = Mutex::new(Vec::new());

pub(crate) fn show_quiet(window: &tauri::WebviewWindow) {
    on_main(window, |window| {
        use windows_sys::Win32::UI::WindowsAndMessaging::{IsWindow, ShowWindow, SW_SHOWNOACTIVATE};
        let Ok(own) = window.hwnd() else { return };
        let h = own.0 as isize;
        let at = window.outer_position().ok();
        move_raw(window, AWAY, AWAY);
        let first = {
            let mut shown = SHOWN.lock().unwrap_or_else(|e| e.into_inner());
            // SAFETY: only checks whether each remembered handle is still a window.
            shown.retain(|w| unsafe { IsWindow(*w as HWND) } != 0);
            let first = !shown.contains(&h);
            if first {
                shown.push(h);
            }
            first
        };
        if first {
            use windows_sys::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, SetForegroundWindow};
            // SAFETY: reads the foreground window and gives it back if this app's overlay took it.
            let before = unsafe { GetForegroundWindow() };
            let _ = window.show();
            unsafe {
                if !before.is_null() && before as isize != h && GetForegroundWindow() as isize == h {
                    SetForegroundWindow(before);
                }
            }
        } else {
            // SAFETY: shows this app's own window without activating it.
            unsafe { ShowWindow(h as HWND, SW_SHOWNOACTIVATE) };
        }
        borderless(window);
        if let Some(at) = at {
            move_raw(window, at.x, at.y);
        }
    });
}

pub(crate) fn hide_quiet(window: &tauri::WebviewWindow) {
    on_main(window, |window| {
        use windows_sys::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_HIDE};
        let Ok(own) = window.hwnd() else { return };
        move_raw(window, AWAY, AWAY);
        // SAFETY: this app's own window loses its owner (one that closes would redraw it with its frame) and hides.
        unsafe {
            SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, 0);
            ShowWindow(own.0 as HWND, SW_HIDE);
        }
    });
}

/// Everything over a machine's picture goes at once (its viewer is about to close or hide).
pub fn hide_all(app: &AppHandle, vm: &str) {
    {
        let mut p = panel();
        if p.vm.as_deref() == Some(vm) {
            p.open = false;
        }
    }
    for label in [LABEL, "status-notch", "agent-live", "agent-dock"] {
        if let Some(w) = app.get_webview_window(label) {
            hide_quiet(&w);
        }
    }
}

pub(crate) fn mark_taskbar(window: &tauri::WebviewWindow, on: bool) {
    borderless(window);
    use windows_sys::core::GUID;
    use windows_sys::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED};
    #[repr(C)]
    struct TaskbarList2Vtbl {
        _query_interface: usize,
        _add_ref: usize,
        release: unsafe extern "system" fn(*mut std::ffi::c_void) -> u32,
        hr_init: unsafe extern "system" fn(*mut std::ffi::c_void) -> i32,
        _add_tab: usize,
        _delete_tab: usize,
        _activate_tab: usize,
        _set_active_alt: usize,
        mark_fullscreen_window: unsafe extern "system" fn(*mut std::ffi::c_void, HWND, i32) -> i32,
    }
    const CLSID_TASKBAR_LIST: GUID = GUID::from_u128(0x56FDF344_FD6D_11d0_958A_006097C9A090);
    const IID_ITASKBAR_LIST2: GUID = GUID::from_u128(0x602D4995_B13A_429b_A66E_1935E44F4317);
    let Ok(own) = window.hwnd() else { return };
    // SAFETY: COM set up for this call; ITaskbarList2 used through its documented vtable order and released once.
    unsafe {
        let init = CoInitializeEx(std::ptr::null(), COINIT_APARTMENTTHREADED as u32);
        let mut list: *mut std::ffi::c_void = std::ptr::null_mut();
        if CoCreateInstance(&CLSID_TASKBAR_LIST, std::ptr::null_mut(), CLSCTX_INPROC_SERVER, &IID_ITASKBAR_LIST2, &mut list) == 0 && !list.is_null() {
            let vtbl = &**(list as *mut *const TaskbarList2Vtbl);
            if (vtbl.hr_init)(list) == 0 {
                (vtbl.mark_fullscreen_window)(list, own.0 as HWND, on as i32);
            }
            (vtbl.release)(list);
        }
        if init >= 0 {
            CoUninitialize();
        }
    }
}

pub(crate) fn bring_to_front(hwnd: isize) {
    #[link(name = "user32")]
    extern "system" {
        fn SetForegroundWindow(hwnd: isize) -> i32;
    }
    // SAFETY: plain Win32 call; the viewer allowed this process to take the foreground (AllowSetForegroundWindow).
    unsafe { SetForegroundWindow(hwnd) };
}

pub fn open(app: &AppHandle, vm: &str) {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return };
    let Some(window) = panel_window(app) else { return };
    let Some((width, total, _)) = place(&window, viewer) else { return };
    {
        let mut p = panel();
        p.vm = Some(vm.to_string());
        p.open = true;
    }
    let _ = crate::viewer::send_to(vm, &json!({ "type": "capture", "on": false }));
    let _ = crate::viewer::send_to(vm, &json!({ "type": "inset", "fraction": width as f64 / total as f64, "durationMs": SLIDE_MS }));
    show_quiet(&window);
    mark_full_screen(&window, crate::viewer::viewer_full_screen(vm));
    let _ = window.emit("viewer-panel", json!({ "open": true, "vm": vm }));
    if let Ok(own) = window.hwnd() {
        bring_to_front(own.0 as isize);
    }
}

pub fn close(app: &AppHandle) {
    let vm = {
        let mut p = panel();
        if !p.open {
            return;
        }
        p.open = false;
        p.vm.clone()
    };
    let Some(vm) = vm else { return };
    let _ = crate::viewer::send_to(&vm, &json!({ "type": "inset", "fraction": 0.0, "durationMs": SLIDE_MS }));
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.emit("viewer-panel", json!({ "open": false, "vm": vm }));
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(SLIDE_MS));
            if panel().open {
                return;
            }
            if let Some(w) = app.get_webview_window(LABEL) {
                hide_quiet(&w);
            }
        });
    }
    if let Some(viewer) = crate::viewer::viewer_hwnd(&vm) {
        crate::viewer::allow_viewer_foreground(&vm);
        let _ = crate::viewer::send_to(&vm, &json!({ "type": "focus" }));
        bring_to_front(viewer);
    }
    let _ = crate::viewer::send_to(&vm, &json!({ "type": "capture", "on": true }));
}

pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    match msg["type"].as_str().unwrap_or("") {
        "panel" => {
            let open_here = { let p = panel(); p.open && p.vm.as_deref() == Some(vm) };
            if open_here { close(app) } else { open(app, vm) }
        }
        "window" => {
            let p = panel();
            if p.open && p.vm.as_deref() == Some(vm) {
                drop(p);
                let full = msg["fullScreen"].as_bool().unwrap_or(false);
                if let (Some(viewer), Some(window)) = (crate::viewer::viewer_hwnd(vm), app.get_webview_window(LABEL)) {
                    if MARKED.load(Ordering::Relaxed) != if full { 2 } else { 1 } {
                        mark_full_screen(&window, full);
                    }
                    if let Some((width, total, _)) = place(&window, viewer) {
                        let _ = crate::viewer::send_to(vm, &json!({ "type": "inset", "fraction": width as f64 / total as f64, "durationMs": 0 }));
                    }
                }
            }
        }
        "ended" | "closed" => {
            hide_all(app, vm);
            let mut p = panel();
            if p.vm.as_deref() == Some(vm) {
                p.vm = None;
            }
        }
        _ => {}
    }
}

#[tauri::command]
pub async fn viewer_panel_resize(app: AppHandle, width: u32) -> u32 {
    let width = width.clamp(MIN_WIDTH, MAX_WIDTH);
    WIDTH.store(width, std::sync::atomic::Ordering::Relaxed);
    let vm = { let p = panel(); if p.open { p.vm.clone() } else { None } };
    if let Some(vm) = vm {
        if let (Some(viewer), Some(window)) = (crate::viewer::viewer_hwnd(&vm), app.get_webview_window(LABEL)) {
            if let Some((w, total, scale)) = place(&window, viewer) {
                let _ = crate::viewer::send_to(&vm, &json!({ "type": "inset", "fraction": w as f64 / total as f64, "durationMs": 0 }));
                return ((w as f64 / scale).round() as u32).min(width);
            }
        }
    }
    width
}

#[tauri::command]
pub async fn viewer_panel_close(app: AppHandle) {
    close(&app);
}

pub fn open_width(app: &AppHandle, vm: &str) -> Option<i32> {
    let p = panel();
    if !p.open || p.vm.as_deref() != Some(vm) {
        return None;
    }
    drop(p);
    let size = app.get_webview_window(LABEL)?.outer_size().ok()?;
    Some(size.width as i32)
}

/// Right above its viewer, never above other apps: an owner set through GWLP_HWNDPARENT doesn't always bring the
/// window up with it when the viewer comes forward.
pub(crate) fn raise_over(window: &tauri::WebviewWindow, viewer: isize) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetWindow, SetWindowPos, GW_HWNDPREV, HWND_TOP, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE};
    let Ok(own) = window.hwnd() else { return };
    let own = own.0 as HWND;
    // SAFETY: reads the window just above the viewer and moves this app's own window into that place.
    unsafe {
        let above = GetWindow(viewer as HWND, GW_HWNDPREV);
        if above == own {
            return;
        }
        let after = if above.is_null() { HWND_TOP } else { above };
        SetWindowPos(own, after, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
}

/// Pieces placed over the picture keep their place when the side panel opens; only one it would cover moves left.
pub fn clear_of_panel(app: &AppHandle, vm: &str, x: i32, w: i32, px: i32, bw: i32) -> i32 {
    match open_width(app, vm) {
        Some(pw) => px.min(x + w - pw.min(w / 2) - bw).max(x),
        None => px,
    }
}

#[tauri::command]
pub fn viewer_panel_vm() -> Option<String> {
    panel().vm.clone()
}
