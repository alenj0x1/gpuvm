//! What GpuVM draws over its viewer: the side panel. It opens with Ctrl+Alt+Shift+G inside the viewer (or from the
//! app) and pushes the picture aside instead of covering it: the viewer shrinks the picture to the left while the
//! panel slides in on the right, both with the same duration and curve.
//!
//! The panel is a window owned by the viewer's window (always just above it, minimized and moved with it) and is
//! hidden, not just transparent, while closed: nothing is drawn over the stream, so Windows keeps presenting the
//! picture directly (no extra latency).

use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::{HWND, POINT, RECT};
use windows_sys::Win32::Graphics::Gdi::ClientToScreen;
use windows_sys::Win32::UI::HiDpi::GetDpiForWindow;
use windows_sys::Win32::UI::WindowsAndMessaging::{GetClientRect, IsIconic, IsWindow, SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "viewer-panel";
/// Panel width in logical pixels (scaled with the viewer's monitor); the person can drag its edge between the limits.
static WIDTH: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(340);
const MIN_WIDTH: u32 = 300;
const MAX_WIDTH: u32 = 560;
/// Same as the page's slide (styles.css, .viewer-panel).
const SLIDE_MS: u64 = 320;

#[derive(Default)]
struct Panel {
    /// Machine whose viewer the panel is on.
    vm: Option<String>,
    open: bool,
}

static PANEL: Mutex<Panel> = Mutex::new(Panel { vm: None, open: false });

fn panel() -> std::sync::MutexGuard<'static, Panel> {
    PANEL.lock().unwrap_or_else(|e| e.into_inner())
}

/// The viewer's client area on screen, in physical pixels, and its DPI scale.
fn client_rect(hwnd: isize) -> Option<(i32, i32, i32, i32, f64)> {
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
    WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
        .title("GpuVM")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .visible(false)
        .build()
        .ok()
}

/// Puts the panel over the right edge of the viewer's picture area.
fn place(window: &tauri::WebviewWindow, viewer: isize) -> Option<(i32, i32)> {
    let (x, y, w, h, scale) = client_rect(viewer)?;
    let logical = WIDTH.load(std::sync::atomic::Ordering::Relaxed) as f64;
    let width = ((logical * scale).round() as i32).min(w / 2);
    let _ = window.set_size(PhysicalSize::new(width as u32, h as u32));
    let _ = window.set_position(PhysicalPosition::new(x + w - width, y));
    if let Ok(own) = window.hwnd() {
        // SAFETY: makes the viewer the panel's owner window, so the panel stays just above it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
    }
    Some((width, w))
}

fn bring_to_front(hwnd: isize) {
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
    let Some((width, total)) = place(&window, viewer) else { return };
    {
        let mut p = panel();
        p.vm = Some(vm.to_string());
        p.open = true;
    }
    let _ = crate::viewer::viewer_send(vm.to_string(), json!({ "type": "capture", "on": false }));
    let _ = crate::viewer::viewer_send(vm.to_string(), json!({ "type": "inset", "fraction": width as f64 / total as f64, "durationMs": SLIDE_MS }));
    let _ = window.show();
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
    let _ = crate::viewer::viewer_send(vm.clone(), json!({ "type": "inset", "fraction": 0.0, "durationMs": SLIDE_MS }));
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.emit("viewer-panel", json!({ "open": false, "vm": vm }));
        let app = app.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(SLIDE_MS));
            // Opened again meanwhile: keep it.
            if panel().open {
                return;
            }
            if let Some(w) = app.get_webview_window(LABEL) {
                let _ = w.hide();
            }
        });
    }
    if let Some(viewer) = crate::viewer::viewer_hwnd(&vm) {
        crate::viewer::allow_viewer_foreground(&vm);
        let _ = crate::viewer::viewer_send(vm.clone(), json!({ "type": "focus" }));
        bring_to_front(viewer);
    }
    let _ = crate::viewer::viewer_send(vm, json!({ "type": "capture", "on": true }));
}

/// Messages from a viewer that concern the panel.
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
                if let (Some(viewer), Some(window)) = (crate::viewer::viewer_hwnd(vm), app.get_webview_window(LABEL)) {
                    if let Some((width, total)) = place(&window, viewer) {
                        let _ = crate::viewer::viewer_send(vm.to_string(), json!({ "type": "inset", "fraction": width as f64 / total as f64, "durationMs": 0 }));
                    }
                }
            }
        }
        "closed" => {
            let mut p = panel();
            if p.vm.as_deref() == Some(vm) {
                p.open = false;
                p.vm = None;
                drop(p);
                if let Some(w) = app.get_webview_window(LABEL) {
                    let _ = w.hide();
                }
            }
        }
        _ => {}
    }
}

/// The panel's edge was dragged (or its page loaded with the saved width): new width in logical pixels.
#[tauri::command]
pub fn viewer_panel_resize(app: AppHandle, width: u32) -> u32 {
    let width = width.clamp(MIN_WIDTH, MAX_WIDTH);
    WIDTH.store(width, std::sync::atomic::Ordering::Relaxed);
    let vm = { let p = panel(); if p.open { p.vm.clone() } else { None } };
    if let Some(vm) = vm {
        if let (Some(viewer), Some(window)) = (crate::viewer::viewer_hwnd(&vm), app.get_webview_window(LABEL)) {
            if let Some((w, total)) = place(&window, viewer) {
                let _ = crate::viewer::viewer_send(vm, json!({ "type": "inset", "fraction": w as f64 / total as f64, "durationMs": 0 }));
            }
        }
    }
    width
}

/// The panel's close button and Escape.
#[tauri::command]
pub fn viewer_panel_close(app: AppHandle) {
    close(&app);
}

/// The machine the panel is on, for its page when it loads.
#[tauri::command]
pub fn viewer_panel_vm() -> Option<String> {
    panel().vm.clone()
}
