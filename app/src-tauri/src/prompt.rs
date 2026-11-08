//! Windows administrator prompts in a VM captured with WGC (labs 025-026): Moonlight can't show them, so GpuVM asks
//! the module every 2 s (light: Hyper-V data exchange) and, while one is open, shows a small card over everything
//! with Permitir / Rechazar. Polling lives here, not in the page: the page stops polling when Moonlight covers it.
//! The card takes the focus when it appears: Moonlight keeps the mouse inside its window while it has the focus, and
//! gets it back once the prompt is answered.

use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

const LABEL: &str = "prompt";
const WIDTH: f64 = 400.0;
const HEIGHT: f64 = 168.0;

/// Last list sent to the card, for the card to read when its page loads (an event could arrive before it listens).
static CURRENT: Mutex<Option<Value>> = Mutex::new(None);
/// Prompts already answered: the guest's data exchange reports a closed prompt a few seconds late, and the card must
/// not come back for it.
static ANSWERED: Mutex<Vec<i64>> = Mutex::new(Vec::new());
/// The window that had the focus before the card (Moonlight), to give it back.
static PREVIOUS: Mutex<isize> = Mutex::new(0);

#[link(name = "user32")]
extern "system" {
    fn GetForegroundWindow() -> isize;
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn IsWindow(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
}

/// Windows only lets the process with the last input change the foreground window; an Alt tap from this process
/// lifts that lock (the same trick the latency labs use).
fn bring_to_front(hwnd: isize) {
    // SAFETY: plain Win32 calls on a window handle; a stale handle only makes them fail.
    unsafe {
        if hwnd == 0 || IsWindow(hwnd) == 0 {
            return;
        }
        keybd_event(0x12, 0, 0, 0);
        keybd_event(0x12, 0, 2, 0);
        SetForegroundWindow(hwnd);
    }
}

/// Gives the focus back to the window that had it before the card, if the card still has it (the person may have
/// gone elsewhere meanwhile).
fn restore_previous(card: Option<isize>) {
    let previous = std::mem::take(&mut *PREVIOUS.lock().unwrap_or_else(|e| e.into_inner()));
    // SAFETY: reading the foreground window has no preconditions.
    let foreground = unsafe { GetForegroundWindow() };
    if card.is_none_or(|c| c == foreground) {
        bring_to_front(previous);
    }
}

fn card_hwnd(w: &tauri::WebviewWindow) -> Option<isize> {
    w.hwnd().ok().map(|h| h.0 as isize)
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut last = String::new();
        loop {
            let prompts = {
                let state = app.state::<crate::AppState>();
                let request = json!({ "id": crate::next_id(&state), "cmd": "Get-GpuVMAdminPrompt", "args": {} });
                crate::query(&state, request).await.and_then(crate::into_data).unwrap_or(json!([]))
            };
            let prompts = if prompts.is_array() { prompts } else { json!([prompts]) };
            let prompts = {
                let answered = ANSWERED.lock().unwrap_or_else(|e| e.into_inner());
                Value::Array(prompts.as_array().into_iter().flatten().filter(|p| !answered.contains(&p["id"].as_i64().unwrap_or(0))).cloned().collect())
            };
            let text = prompts.to_string();
            if text != last {
                last = text;
                show(&app, prompts);
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    });
}

fn show(app: &AppHandle, prompts: Value) {
    let open = prompts.as_array().is_some_and(|p| !p.is_empty());
    *CURRENT.lock().unwrap_or_else(|e| e.into_inner()) = Some(prompts.clone());
    let existing = app.get_webview_window(LABEL);
    if !open {
        if let Some(w) = existing {
            let card = card_hwnd(&w);
            let _ = w.close();
            restore_previous(card);
        }
        return;
    }
    if let Some(w) = existing {
        let _ = w.emit("admin-prompt", prompts);
        return;
    }
    // A new window each time, top right of the main monitor; it takes the focus (and Moonlight releases the mouse).
    // SAFETY: reading the foreground window has no preconditions.
    *PREVIOUS.lock().unwrap_or_else(|e| e.into_inner()) = unsafe { GetForegroundWindow() };
    let built = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
        .title("GpuVM")
        .inner_size(WIDTH, HEIGHT)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(true)
        .visible(false)
        .build();
    let Ok(window) = built else { return };
    if let Ok(Some(monitor)) = window.primary_monitor() {
        let scale = monitor.scale_factor();
        let x = monitor.position().x + monitor.size().width as i32 - ((WIDTH + 24.0) * scale) as i32;
        let y = monitor.position().y + (24.0 * scale) as i32;
        let _ = window.set_position(PhysicalPosition::new(x, y));
    }
    let _ = window.show();
    if let Some(hwnd) = card_hwnd(&window) {
        bring_to_front(hwnd);
    }
}

/// The card answered this prompt: forget it and close the card now (the next poll would still list it for a moment).
#[tauri::command]
pub fn admin_prompt_answered(app: AppHandle, id: i64) {
    let mut answered = ANSWERED.lock().unwrap_or_else(|e| e.into_inner());
    answered.push(id);
    if answered.len() > 32 {
        answered.remove(0);
    }
    drop(answered);
    if let Some(w) = app.get_webview_window(LABEL) {
        let card = card_hwnd(&w);
        let _ = w.close();
        restore_previous(card);
    }
}

/// The open prompts, for the card's page when it loads.
#[tauri::command]
pub fn admin_prompts() -> Value {
    CURRENT.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or(json!([]))
}
