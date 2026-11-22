// The dock is a Medium-integrity window: UIPI keeps the Low viewer (drawing what the guest sends) from clicking or typing into it.

use serde_json::{json, Value};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "prompt-dock";
const SLIDE_MS: u64 = 320;

struct Dock {
    vm: String,
    prompt: Value,
    shown: std::time::Instant,
}

static DOCK: Mutex<Option<Dock>> = Mutex::new(None);

fn dock() -> std::sync::MutexGuard<'static, Option<Dock>> {
    DOCK.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn wants(vm: &str) -> bool {
    crate::viewer::viewer_visible(vm) && crate::viewer::viewer_hwnd(vm).is_some()
}

pub fn current_vm() -> Option<String> {
    dock().as_ref().map(|d| d.vm.clone())
}

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
    let _ = crate::viewer::send_to(&vm, &json!({ "type": "capture", "on": false }));
    crate::overlay::show_quiet(&window);
    crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(&vm));
    crate::status::dock_changed(app);
    if let Ok(own) = window.hwnd() {
        // The keyboard comes to the dock too: nothing typed goes into the machine, and no key answers it.
        crate::overlay::bring_to_front(own.0 as isize);
    }
}

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

const ARM: std::time::Duration = std::time::Duration::from_millis(700);

// The page only says which button: the machine and prompt are the ones this app put in the dock.
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

#[tauri::command]
pub fn dock_prompt() -> Value {
    dock().as_ref().map(|d| d.prompt.clone()).unwrap_or(Value::Null)
}
