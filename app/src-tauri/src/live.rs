//! What an agent is doing, live over its machine's picture (2026-11-21, chosen by the person): the agent's cursor with
//! its name, a ring on each click, the stroke of a drag, and in the status notch what it is doing ("Claude Code ·
//! Drawing the moon", from the step's `intent`, or a plain text from the step itself).
//!
//! - The service tells what each step is as it starts and ends (agent_log.rs in app/host): this module waits for it on
//!   a pipe connection of its own (`Wait-GpuVMAgentActivity`, a long poll), so the app's other calls never wait
//!   behind it and nothing polls fast.
//! - The overlay is one window of this app over the picture, owned by the viewer, transparent and click-through: the
//!   person's clicks always reach the picture. It only exists while an agent acts on the machine in view and goes as
//!   soon as the person takes control, so watching costs nothing the rest of the time (an overlay takes the stream
//!   off Windows' direct path to the screen while it is shown).
//! - Shapes only: where a click or a drag went, which keys, how many characters were typed; never the text typed or
//!   a command line.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "agent-live";
/// With no step for this long, the notch says the agent is thinking.
const THINKING: Duration = Duration::from_millis(1800);
/// With no step for this long, the overlay and the notch go (the agent stopped or waits for something long).
const GONE: Duration = Duration::from_secs(25);

struct Live {
    client: String,
    client_name: String,
    /// Steps started and not ended yet: their method, intent and first input shape (the newest one is shown).
    running: Vec<(u64, String, Option<String>, Option<String>)>,
    last: Instant,
    thinking: bool,
}

static LIVE: Mutex<Option<HashMap<String, Live>>> = Mutex::new(None);
/// The machine the overlay window is over now.
static OVER: Mutex<Option<String>> = Mutex::new(None);

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// Starts following the service (a thread of its own) and tidying what went quiet.
pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || follow(handle));
    let handle = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(400));
        tidy(&handle);
    });
}

fn follow(app: AppHandle) {
    let mut after = 0u64;
    let mut primed = false;
    let mut id = 0u64;
    loop {
        let mut conn = match crate::backend::connect() {
            Ok(c) => c,
            Err(_) => {
                std::thread::sleep(Duration::from_secs(5));
                continue;
            }
        };
        loop {
            id += 1;
            let request = json!({ "id": format!("live-{id}"), "cmd": "Wait-GpuVMAgentActivity", "args": { "After": after, "TimeoutMs": 10_000 } });
            if conn.send(&request).is_err() {
                break;
            }
            let Ok(data) = crate::recv_result(&mut conn, &request).and_then(crate::into_data) else { break };
            let data = match data { Value::Array(mut a) if !a.is_empty() => a.remove(0), other => other };
            // A service that doesn't know the command (an older one) answers at once: don't spin on it.
            let Some(last) = data["last"].as_u64() else { break };
            after = last;
            // What happened before the app was looking isn't replayed.
            if !primed {
                primed = true;
                continue;
            }
            for event in data["events"].as_array().into_iter().flatten() {
                on_event(&app, event);
            }
        }
        std::thread::sleep(Duration::from_secs(3));
    }
}

fn on_event(app: &AppHandle, event: &Value) {
    let Some(vm) = event["machine"].as_str().map(str::to_string) else { return };
    if crate::viewer::viewer_hwnd(&vm).is_none() || crate::agent::person_has(&vm) {
        return;
    }
    let step = event["step"].as_u64().unwrap_or(0);
    let start = event["phase"] == "start";
    {
        let mut live = lock(&LIVE);
        let map = live.get_or_insert_with(HashMap::new);
        let entry = map.entry(vm.clone()).or_insert_with(|| Live {
            client: String::new(), client_name: String::new(), running: Vec::new(), last: Instant::now(), thinking: false,
        });
        if let Some(c) = event["client"].as_str() {
            entry.client = c.to_string();
        }
        if let Some(n) = event["clientName"].as_str() {
            entry.client_name = n.to_string();
        }
        if start {
            // A drag of several strokes is drawing; the first shape names what an input step does.
            let first = &event["shapes"][0];
            let kind = match first["type"].as_str() {
                Some("drag") if first["strokes"].as_array().is_some_and(|s| s.len() > 1) => Some("draw".to_string()),
                k => k.map(str::to_string),
            };
            entry.running.push((step, event["method"].as_str().unwrap_or("").to_string(), event["intent"].as_str().map(str::to_string), kind));
        } else {
            entry.running.retain(|(s, _, _, _)| *s != step);
        }
        entry.last = Instant::now();
        entry.thinking = false;
    }
    notch(app, &vm);
    if let Some(window) = overlay(app, &vm) {
        let _ = window.emit("agent-live", event);
    }
}

/// The status notch line for the machine: the newest running step, or "thinking" between steps.
fn notch(app: &AppHandle, vm: &str) {
    let item = lock(&LIVE).as_ref().and_then(|m| m.get(vm)).map(|l| {
        let (method, intent, shape) = l.running.last().map(|(_, m, i, k)| (json!(m), json!(i), json!(k))).unwrap_or((Value::Null, Value::Null, Value::Null));
        json!({ "kind": "live", "client": l.client, "clientName": l.client_name, "method": method, "intent": intent, "shape": shape,
            "thinking": l.thinking && l.running.is_empty() })
    });
    crate::status::set(app, vm, "live", item);
}

/// The overlay window over this machine's picture, made or moved there as needed.
fn overlay(app: &AppHandle, vm: &str) -> Option<tauri::WebviewWindow> {
    let same = lock(&OVER).as_deref() == Some(vm);
    let window = match app.get_webview_window(LABEL) {
        Some(w) if same => w,
        existing => {
            if let Some(w) = existing {
                let _ = w.destroy();
            }
            let w = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
                .title("GpuVM").decorations(false).transparent(true).shadow(false).resizable(false)
                .skip_taskbar(true).focused(false).visible(false).build().ok()?;
            // Click-through: every click and the wheel go to the picture underneath.
            let _ = w.set_ignore_cursor_events(true);
            *lock(&OVER) = Some(vm.to_string());
            w
        }
    };
    if !crate::agent::place_over_picture(app, &window, vm) {
        return None;
    }
    if !window.is_visible().unwrap_or(false) {
        let _ = window.show();
        crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(vm));
    }
    Some(window)
}

fn close_overlay(app: &AppHandle, vm: &str) {
    if lock(&OVER).as_deref() == Some(vm) {
        *lock(&OVER) = None;
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.destroy();
        }
    }
}

/// Everything about a machine goes: its viewer closed, the person took control, or the agent went quiet.
pub fn clear(app: &AppHandle, vm: &str) {
    let had = lock(&LIVE).as_mut().and_then(|m| m.remove(vm)).is_some();
    if had {
        crate::status::set(app, vm, "live", None);
    }
    close_overlay(app, vm);
}

fn tidy(app: &AppHandle) {
    let vms: Vec<(String, bool, bool)> = lock(&LIVE).as_mut().map(|m| m.iter_mut().map(|(vm, l)| {
        let idle = l.running.is_empty();
        let think = idle && !l.thinking && l.last.elapsed() > THINKING;
        if think {
            l.thinking = true;
        }
        (vm.clone(), think, idle && l.last.elapsed() > GONE)
    }).collect()).unwrap_or_default();
    for (vm, think, gone) in vms {
        if gone || crate::viewer::viewer_hwnd(&vm).is_none() || crate::agent::person_has(&vm) {
            clear(app, &vm);
        } else if think {
            notch(app, &vm);
        }
    }
}

/// The viewer moved, resized or opened its side panel: the overlay follows the picture.
pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    match msg["type"].as_str().unwrap_or("") {
        "window" | "panel" => {
            if lock(&OVER).as_deref() == Some(vm) {
                if let Some(w) = app.get_webview_window(LABEL) {
                    crate::agent::place_over_picture(app, &w, vm);
                }
            }
        }
        "closed" | "ended" => clear(app, vm),
        _ => {}
    }
}
