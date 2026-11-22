//! The administrator-prompt dock (lab 042): while a machine's picture is shown (inside the app or full screen) and
//! Windows in it asks for administrator permission, the prompt drops from the top center of the picture as part of the
//! screen, instead of the corner card (prompt.rs keeps the card for machines whose picture isn't shown).
//!
//! Security: the dock is a window of this app (Medium integrity), owned by the viewer's window so it stays just above
//! the picture, and Permitir / Rechazar are decided there. The viewer (Low integrity, it draws what the guest sends)
//! only gets the usual "capture off / focus / capture on" commands; Windows' UIPI keeps it from sending clicks or keys
//! to this window, so a viewer taken over by the guest can't approve a prompt in its own machine.
//!
//! The window is hidden (destroyed) when no prompt is open: nothing is drawn over the picture then, and a full-screen
//! viewer goes back to presenting directly (independent flip, lab 041).

use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "prompt-dock";
/// Same as the page's drop and lift (styles.css, .dock).
const SLIDE_MS: u64 = 320;

struct Dock {
    vm: String,
    prompt: Value,
    /// When it came down: a click in its first moments (meant for the picture) never answers it.
    shown: std::time::Instant,
}

static DOCK: Mutex<Option<Dock>> = Mutex::new(None);

fn dock() -> std::sync::MutexGuard<'static, Option<Dock>> {
    DOCK.lock().unwrap_or_else(|e| e.into_inner())
}

/// Whether a machine's prompt goes to the dock: its picture is shown now.
pub fn wants(vm: &str) -> bool {
    crate::viewer::viewer_visible(vm) && crate::viewer::viewer_hwnd(vm).is_some()
}

/// The machine the dock is on now.
pub fn current_vm() -> Option<String> {
    dock().as_ref().map(|d| d.vm.clone())
}

/// Puts the dock over the viewer's picture (leaving the side panel uncovered when it is open there).
fn place(app: &AppHandle, window: &tauri::WebviewWindow, vm: &str) -> bool {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return false };
    let Some((x, y, w, h, _)) = crate::overlay::client_rect(viewer) else { return false };
    let w = w - crate::overlay::open_width(app, vm).unwrap_or(0).min(w / 2);
    let _ = window.set_size(PhysicalSize::new(w.max(1) as u32, h.max(1) as u32));
    crate::overlay::borderless(window);
    let _ = window.set_position(PhysicalPosition::new(x, y));
    if let Ok(own) = window.hwnd() {
        // SAFETY: makes the viewer the dock's owner window, so the dock stays just above it and moves with it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
    }
    true
}

/// Shows (or updates) the dock with this prompt over its machine's picture.
pub fn show(app: &AppHandle, prompt: Value) {
    let vm = prompt["name"].as_str().unwrap_or("").to_string();
    let same = {
        let mut d = dock();
        let same = d.as_ref().is_some_and(|d| d.vm == vm);
        let shown = d.as_ref().filter(|d| d.vm == vm && d.prompt["id"] == prompt["id"]).map(|d| d.shown).unwrap_or_else(std::time::Instant::now);
        *d = Some(Dock { vm: vm.clone(), prompt: prompt.clone(), shown });
        same
    };
    if let Some(window) = app.get_webview_window(LABEL) {
        if same {
            let _ = window.emit("prompt-dock", json!({ "prompt": prompt }));
            return;
        }
        let _ = window.destroy();
    }
    let built = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS)
        .title("GpuVM")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build();
    let Ok(window) = built else { return };
    if !place(app, &window, &vm) {
        let _ = window.destroy();
        *dock() = None;
        return;
    }
    // The viewer lets go of the mouse (as for the side panel) so the pointer can reach the dock.
    let _ = crate::viewer::send_to(&vm, &json!({ "type": "capture", "on": false }));
    let _ = window.show();
    crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(&vm));
    crate::status::dock_changed(app);
    if let Ok(own) = window.hwnd() {
        // The keyboard comes to the dock too: nothing typed meanwhile goes on into the machine (and there is no key
        // that answers, so a stray Enter approves nothing).
        crate::overlay::bring_to_front(own.0 as isize);
    }
}

/// The dock goes away: it lifts (page) and closes, and the picture gets the mouse and keyboard back.
pub fn hide(app: &AppHandle) {
    let Some(d) = dock().take() else { return };
    crate::status::dock_changed(app);
    if let Some(window) = app.get_webview_window(LABEL) {
        let _ = window.emit("prompt-dock", json!({ "prompt": Value::Null }));
        let had_focus = window.is_focused().unwrap_or(false);
        let app = app.clone();
        let vm = d.vm.clone();
        std::thread::spawn(move || {
            std::thread::sleep(std::time::Duration::from_millis(SLIDE_MS));
            // Shown again meanwhile (another prompt in the same machine): keep it.
            if dock().is_some() {
                return;
            }
            if let Some(w) = app.get_webview_window(LABEL) {
                let _ = w.destroy();
            }
            if had_focus {
                if let Some(viewer) = crate::viewer::viewer_hwnd(&vm) {
                    crate::viewer::allow_viewer_foreground(&vm);
                    let _ = crate::viewer::send_to(&vm, &json!({ "type": "focus" }));
                    crate::overlay::bring_to_front(viewer);
                }
            }
            if !crate::overlay::open_width(&app, &vm).is_some() {
                let _ = crate::viewer::send_to(&vm, &json!({ "type": "capture", "on": true }));
            }
        });
    }
}

/// Messages from a viewer that concern the dock: it follows the picture, and goes when the viewer closes.
pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    if current_vm().as_deref() != Some(vm) {
        return;
    }
    match msg["type"].as_str().unwrap_or("") {
        "window" => {
            if let Some(window) = app.get_webview_window(LABEL) {
                place(app, &window, vm);
                crate::overlay::mark_taskbar(&window, msg["fullScreen"].as_bool().unwrap_or(false));
            }
        }
        "closed" => {
            *dock() = None;
            if let Some(window) = app.get_webview_window(LABEL) {
                let _ = window.destroy();
            }
        }
        _ => {}
    }
}

/// Least time between the dock coming down and an answer (its drop plus the page's own guard, PromptDock.tsx).
const ARM: std::time::Duration = std::time::Duration::from_millis(700);

/// Allow / Deny in the dock. The page only says which button: the machine and the prompt are the ones this
/// app put in the dock, so the dock's page can't answer anything else (its capability has no other command).
#[tauri::command]
pub async fn dock_answer(app: AppHandle, allow: bool) -> Result<(), String> {
    let (vm, id) = {
        let d = dock();
        let d = d.as_ref().ok_or("The prompt already closed.")?;
        if d.prompt["reading"].as_bool() == Some(true) {
            return Err("The prompt is still being read.".into());
        }
        if d.shown.elapsed() < ARM {
            return Err("The prompt just appeared.".into());
        }
        (d.vm.clone(), d.prompt["id"].as_i64().ok_or("The prompt isn't valid.")?)
    };
    let state = app.state::<crate::AppState>();
    let request = json!({ "id": crate::next_id(&state), "cmd": "Resolve-GpuVMAdminPrompt",
        "args": { "Name": vm, "Answer": if allow { "Allow" } else { "Deny" }, "PromptId": id } });
    crate::query(&state, request).await.and_then(crate::into_data)?;
    crate::prompt::admin_prompt_answered(app.clone(), vm, id);
    Ok(())
}

/// The prompt the dock shows, for its page when it loads.
#[tauri::command]
pub fn dock_prompt() -> Value {
    dock().as_ref().map(|d| d.prompt.clone()).unwrap_or(Value::Null)
}
