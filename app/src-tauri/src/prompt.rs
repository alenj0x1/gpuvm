use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "prompt";
const WIDTH: f64 = 400.0;
const HEIGHT: f64 = 168.0;

static CURRENT: Mutex<Option<Value>> = Mutex::new(None);
// Data exchange reports a closed prompt a few seconds late: the card must not come back for it.
static ANSWERED: Mutex<Vec<(String, i64)>> = Mutex::new(Vec::new());
const POLL_MS: u64 = 1000;

fn key(p: &Value) -> (String, i64) {
    (p["name"].as_str().unwrap_or("").to_string(), p["id"].as_i64().unwrap_or(0))
}
static PREVIOUS: Mutex<isize> = Mutex::new(0);

#[link(name = "user32")]
extern "system" {
    fn GetForegroundWindow() -> isize;
    fn SetForegroundWindow(hwnd: isize) -> i32;
    fn IsWindow(hwnd: isize) -> i32;
    fn keybd_event(vk: u8, scan: u8, flags: u32, extra: usize);
}

// Only the process with the last input may change the foreground; an Alt tap from this process lifts that lock.
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
            let reply = crate::notices::poll(&app).await;
            // Notices-only mode ends once no watched machine is on (a failed query is not "none").
            if crate::notices::active() && reply.as_ref().is_some_and(|r| r["watched"].as_u64() == Some(0)) {
                crate::notices::finish(&app);
            }
            let prompts = reply.map(|r| r["prompts"].clone()).unwrap_or(json!([]));
            let prompts = if prompts.is_array() { prompts } else if prompts.is_null() { json!([]) } else { json!([prompts]) };
            let prompts: Vec<Value> = {
                let answered = ANSWERED.lock().unwrap_or_else(|e| e.into_inner());
                prompts.as_array().into_iter().flatten().filter(|p| !answered.contains(&key(p))).cloned().collect()
            };
            let docked = prompts.iter().find(|p| crate::dock::wants(p["name"].as_str().unwrap_or(""))).cloned();
            let cards: Vec<Value> = prompts.into_iter().filter(|p| docked.as_ref() != Some(p)).collect();
            let text = format!("{}|{}", Value::Array(cards.clone()), docked.clone().unwrap_or(Value::Null));
            if text != last {
                last = text;
                match docked {
                    Some(p) => crate::dock::show(&app, p),
                    None => crate::dock::hide(&app),
                }
                show(&app, Value::Array(cards));
            }
            tokio::time::sleep(Duration::from_millis(POLL_MS)).await;
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
    let take_focus = crate::viewer::foreground_vm().is_some();
    // SAFETY: reading the foreground window has no preconditions.
    *PREVIOUS.lock().unwrap_or_else(|e| e.into_inner()) = if take_focus { unsafe { GetForegroundWindow() } } else { 0 };
    let built = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS)
        .title("GpuVM")
        .inner_size(WIDTH, HEIGHT)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .focused(take_focus)
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
    crate::overlay::borderless(&window);
    if take_focus {
        if let Some(hwnd) = card_hwnd(&window) {
            bring_to_front(hwnd);
        }
    }
}

// Only a prompt this app put on the card can be answered (its window has no generic command).
#[tauri::command]
pub async fn card_answer(app: AppHandle, name: String, id: i64, allow: bool) -> Result<(), String> {
    let shown = CURRENT.lock().unwrap_or_else(|e| e.into_inner()).as_ref()
        .and_then(|v| v.as_array().map(|list| list.iter().any(|p| key(p) == (name.clone(), id))))
        .unwrap_or(false);
    if !shown {
        return Err("The prompt changed or closed. Check the new one before answering.".into());
    }
    let state = app.state::<crate::AppState>();
    let request = json!({ "id": crate::next_id(&state), "cmd": "Resolve-GpuVMAdminPrompt",
        "args": { "Name": name, "Answer": if allow { "Allow" } else { "Deny" }, "PromptId": id } });
    crate::query(&state, request).await.and_then(crate::into_data)?;
    admin_prompt_answered(app.clone(), name, id);
    Ok(())
}

pub fn admin_prompt_answered(app: AppHandle, name: String, id: i64) {
    let mut answered = ANSWERED.lock().unwrap_or_else(|e| e.into_inner());
    answered.push((name.clone(), id));
    if answered.len() > 32 {
        answered.remove(0);
    }
    drop(answered);
    if crate::dock::current_vm().as_deref() == Some(name.as_str()) {
        crate::dock::hide(&app);
        return;
    }
    if let Some(w) = app.get_webview_window(LABEL) {
        let card = card_hwnd(&w);
        let _ = w.close();
        restore_previous(card);
    }
}

#[tauri::command]
pub fn admin_prompts() -> Value {
    CURRENT.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or(json!([]))
}
