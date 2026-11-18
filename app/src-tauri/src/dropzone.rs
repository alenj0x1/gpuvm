//! Files dropped on the viewer's picture, and the copies into machines (lab 043).
//!
//! The viewer runs at Low integrity and talks to a host the guest controls, so it never names files: when something
//! is dragged over its window it only sends "drag". This app then shows its own window over the picture (owned by
//! the viewer, so it stays just above it, and shown without taking the focus: activating a window mid-drag makes
//! Windows cancel the drag). That window takes the drop, and the paths come from Windows itself. A viewer that
//! sends "drag" on its own only makes the drop area appear for a moment.
//!
//! The copies run in the GpuVM service (Send-GpuVMFile), which first opens every path as this user, unelevated.
//! Their state lives here, so the drop window, the side panel and the app all show the same list.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{
    GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, GWLP_HWNDPARENT, GWL_EXSTYLE, HWND_TOP, SWP_NOACTIVATE,
    SWP_SHOWWINDOW, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
};

pub const LABEL: &str = "viewer-drop";
/// A "drag" the drop window never confirms (no files came over it) hides it again after this long.
const UNCONFIRMED: Duration = Duration::from_millis(1500);
/// Copies kept in the list after they end.
const KEEP: usize = 20;

struct Zone {
    vm: Option<String>,
    shown_at: Option<Instant>,
}
static ZONE: Mutex<Zone> = Mutex::new(Zone { vm: None, shown_at: None });
/// Files are over the drop window right now (its own drag events).
static HOVER: AtomicBool = AtomicBool::new(false);

fn zone() -> std::sync::MutexGuard<'static, Zone> {
    ZONE.lock().unwrap_or_else(|e| e.into_inner())
}

fn drop_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    let w = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
        .title("GpuVM")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()
        .ok()?;
    if let Ok(h) = w.hwnd() {
        // SAFETY: style bits on our own window: never activated by a click or by being shown.
        unsafe {
            let ex = GetWindowLongPtrW(h.0 as HWND, GWL_EXSTYLE);
            SetWindowLongPtrW(h.0 as HWND, GWL_EXSTYLE, ex | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) as isize);
        }
    }
    Some(w)
}

/// The viewer reported a drag over its picture: cover the picture (not the side panel) with the drop window.
pub fn on_drag(app: &AppHandle, vm: &str) {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return };
    let Some((x, y, w, h)) = crate::overlay::picture_rect(viewer, vm) else { return };
    let Some(window) = drop_window(app) else { return };
    {
        let mut z = zone();
        z.vm = Some(vm.to_string());
        z.shown_at = Some(Instant::now());
    }
    HOVER.store(false, Ordering::Relaxed);
    let _ = window.emit("viewer-drop", json!({ "vm": vm, "state": "drag" }));
    if let Ok(own) = window.hwnd() {
        // SAFETY: our window, owned by the viewer's (kept just above it), shown without activation.
        unsafe {
            SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer);
            SetWindowPos(own.0 as HWND, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
        }
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(UNCONFIRMED);
        let stale = zone().shown_at.is_some_and(|t| t.elapsed() >= UNCONFIRMED);
        if stale && !HOVER.load(Ordering::Relaxed) {
            hide(&app);
        }
    });
}

/// The card in the bottom right corner of the picture (logical size, scaled with the viewer's monitor).
const CARD: (f64, f64) = (300.0, 76.0);
const CARD_MARGIN: f64 = 16.0;

fn show_card(app: &AppHandle, vm: &str, id: &str) {
    zone().shown_at = None;
    HOVER.store(false, Ordering::Relaxed);
    let (Some(window), Some(viewer)) = (app.get_webview_window(LABEL), crate::viewer::viewer_hwnd(vm)) else { return hide(app) };
    let Some((x, y, w, h)) = crate::overlay::picture_rect(viewer, vm) else { return hide(app) };
    // SAFETY: plain query on the viewer's window.
    let scale = unsafe { windows_sys::Win32::UI::HiDpi::GetDpiForWindow(viewer as HWND).max(96) } as f64 / 96.0;
    let (cw, ch, m) = ((CARD.0 * scale) as i32, (CARD.1 * scale) as i32, (CARD_MARGIN * scale) as i32);
    let _ = window.emit("viewer-drop", json!({ "vm": vm, "state": "card", "id": id }));
    if let Ok(own) = window.hwnd() {
        // SAFETY: our window, still owned by the viewer, moved without activation.
        unsafe { SetWindowPos(own.0 as HWND, HWND_TOP, x + w - cw - m, y + h - ch - m, cw, ch, SWP_SHOWWINDOW | SWP_NOACTIVATE) };
    }
}

pub fn hide(app: &AppHandle) {
    zone().shown_at = None;
    HOVER.store(false, Ordering::Relaxed);
    if let Some(w) = app.get_webview_window(LABEL) {
        let _ = w.hide();
    }
}

/// The drop window's own drag events (Windows' OLE drop target on its web view).
pub fn on_window_event(app: &AppHandle, event: &tauri::WindowEvent) {
    let tauri::WindowEvent::DragDrop(drag) = event else { return };
    match drag {
        tauri::DragDropEvent::Enter { .. } | tauri::DragDropEvent::Over { .. } => HOVER.store(true, Ordering::Relaxed),
        tauri::DragDropEvent::Leave => hide(app),
        tauri::DragDropEvent::Drop { paths, .. } => {
            let vm = zone().vm.clone();
            let paths: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
            let (Some(vm), false) = (vm, paths.is_empty()) else { return hide(app) };
            let folder = if crate::ENGLISH.load(Ordering::Relaxed) { "Received" } else { "Recibidos" };
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                match start(&app, vm.clone(), paths, None, folder.to_string()).await {
                    // The drop area becomes a small card in the picture's corner with the copy's progress.
                    Ok(id) => show_card(&app, &vm, &id),
                    Err(_) => hide(&app),
                }
            });
        }
        _ => {}
    }
}

// ---------------------------------------------------------------- the copies

static TRANSFERS: Mutex<Vec<Value>> = Mutex::new(Vec::new());

fn update(app: &AppHandle, id: &str, change: impl FnOnce(&mut Value)) {
    let snapshot = {
        let mut list = TRANSFERS.lock().unwrap_or_else(|e| e.into_inner());
        let Some(t) = list.iter_mut().find(|t| t["id"] == id) else { return };
        change(t);
        t.clone()
    };
    let _ = app.emit("transfer", snapshot);
}

fn new_id() -> String {
    let mut bytes = [0u8; 16];
    // SAFETY: fills the buffer with random bytes.
    unsafe {
        windows_sys::Win32::Security::Cryptography::BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), 16,
            windows_sys::Win32::Security::Cryptography::BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// "Enviando 42 % · 1.2 de 2.9 GB" -> 42.
fn percent_of(message: &str) -> Option<u32> {
    let rest = message.strip_prefix("Enviando ")?;
    rest.split_whitespace().next()?.parse().ok()
}

/// Copies files into `vm`: from this PC (paths of this PC) or from the machine `from` (paths inside it).
#[tauri::command]
pub async fn transfer_start(app: AppHandle, vm: String, paths: Vec<String>, from: Option<String>, folder: String) -> Result<String, String> {
    start(&app, vm, paths, from, folder).await
}

async fn start(app: &AppHandle, vm: String, paths: Vec<String>, from: Option<String>, folder: String) -> Result<String, String> {
    if paths.is_empty() || paths.len() > 1000 {
        return Err("Elige entre 1 y 1000 elementos.".into());
    }
    let from = from.filter(|f| !f.is_empty());
    let id = new_id();
    let names: Vec<String> = paths.iter().map(|p| p.rsplit(['\\', '/']).next().unwrap_or(p).to_string()).collect();
    let entry = json!({ "id": id, "vm": vm, "from": from, "names": names, "state": "running", "percent": 0, "message": "", "error": null, "items": [] });
    {
        let mut list = TRANSFERS.lock().unwrap_or_else(|e| e.into_inner());
        list.push(entry.clone());
        let ended = list.iter().filter(|t| t["state"] != "running").count();
        if ended > KEEP {
            let mut drop_n = ended - KEEP;
            list.retain(|t| if drop_n > 0 && t["state"] != "running" { drop_n -= 1; false } else { true });
        }
    }
    let _ = app.emit("transfer", entry);
    let mut args = json!({ "Name": vm, "Path": paths, "Folder": folder, "TransferId": id });
    if let Some(f) = &from {
        args["FromVM"] = json!(f);
    }
    let request = json!({ "id": id, "cmd": "Send-GpuVMFile", "args": args });
    let mut conn = tauri::async_runtime::spawn_blocking(crate::backend::connect).await.map_err(|e| e.to_string())??;
    let (app2, id2) = (app.clone(), id.clone());
    std::thread::spawn(move || {
        let result = conn.call(&request, |event| {
            if event["type"] == "progress" {
                let message = event["message"].as_str().unwrap_or("").to_string();
                update(&app2, &id2, |t| {
                    if let Some(p) = percent_of(&message) {
                        t["percent"] = json!(p);
                    }
                    t["message"] = json!(message);
                });
            }
        });
        update(&app2, &id2, |t| match result {
            Ok(r) if r["ok"] == true => {
                t["state"] = json!("done");
                t["percent"] = json!(100);
                t["items"] = r["data"][0]["items"].clone();
                t["folder"] = r["data"][0]["folder"].clone();
            }
            Ok(r) => {
                let error = r["error"].as_str().unwrap_or("No se pudo copiar.").to_string();
                t["state"] = json!(if error == "Envío cancelado." { "cancelled" } else { "error" });
                t["error"] = json!(error);
            }
            Err(e) => {
                t["state"] = json!("error");
                t["error"] = json!(e);
            }
        });
    });
    Ok(id)
}

#[tauri::command]
pub async fn transfer_cancel(state: tauri::State<'_, crate::AppState>, id: String) -> Result<(), String> {
    if !id.chars().all(|c| c.is_ascii_hexdigit()) || id.len() != 32 {
        return Err("Copia desconocida.".into());
    }
    let request = json!({ "id": crate::next_id(&state), "cmd": "Stop-GpuVMTransfer", "args": { "TransferId": id } });
    crate::into_data(crate::query(&state, request).await?).map(|_| ())
}

#[tauri::command]
pub fn transfer_list() -> Vec<Value> {
    TRANSFERS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

/// Hides the drop window (Escape, or the page saw the drag leave).
#[tauri::command]
pub fn viewer_drop_hide(app: AppHandle) {
    hide(&app);
}
