// Shown only while needed: an overlay takes the stream off Windows' direct path to the screen.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Listener, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "agent-live";
const THINKING: Duration = Duration::from_millis(1800);
const GONE: Duration = Duration::from_secs(25);
const STEP_MAX: Duration = Duration::from_secs(620);

struct Step {
    id: u64,
    method: String,
    intent: Option<String>,
    shape: Option<String>,
    since: Instant,
}

struct Live {
    client: String,
    client_name: String,
    running: Vec<Step>,
    last: Instant,
    thinking: bool,
}

static LIVE: Mutex<Option<HashMap<String, Live>>> = Mutex::new(None);

struct Over {
    vm: String,
    ready: bool,
    pending: Vec<Value>,
}
static OVER: Mutex<Option<Over>> = Mutex::new(None);

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

pub fn start(app: &AppHandle) {
    let handle = app.clone();
    std::thread::spawn(move || follow(handle));
    let handle = app.clone();
    std::thread::spawn(move || loop {
        std::thread::sleep(Duration::from_millis(400));
        tidy(&handle);
    });
    let handle = app.clone();
    app.listen_any("agent-live-ready", move |_| {
        let (pending, vm) = {
            let mut over = lock(&OVER);
            let Some(o) = over.as_mut() else { return };
            o.ready = true;
            (std::mem::take(&mut o.pending), o.vm.clone())
        };
        if let Some(w) = handle.get_webview_window(LABEL) {
            if !w.is_visible().unwrap_or(false) && crate::agent::place_over_picture(&handle, &w, &vm) {
                crate::overlay::show_quiet(&w);
                crate::overlay::mark_taskbar(&w, crate::viewer::viewer_full_screen(&vm));
            }
            for event in pending {
                let _ = w.emit("agent-live", event);
            }
        }
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
            let Some(last) = data["last"].as_u64() else { break };
            // A restarted service counts from 1 again: what it has is from before the app looked, as at the start.
            if last < after {
                primed = false;
            }
            after = last;
            if !primed {
                primed = true;
                continue;
            }
            for event in data["events"].as_array().into_iter().flatten() {
                on_event(&app, event);
            }
        }
        if let Some(map) = lock(&LIVE).as_mut() {
            for l in map.values_mut() {
                l.running.clear();
            }
        }
        std::thread::sleep(Duration::from_secs(3));
    }
}

fn on_event(app: &AppHandle, event: &Value) {
    let Some(vm) = event["machine"].as_str().map(str::to_string) else { return };
    if !crate::dock::wants(&vm) || crate::agent::person_has(&vm) {
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
            let first = &event["shapes"][0];
            let shape = match first["type"].as_str() {
                Some("drag") if first["strokes"].as_array().is_some_and(|s| s.len() > 1) => Some("draw".to_string()),
                k => k.map(str::to_string),
            };
            entry.running.push(Step { id: step, method: event["method"].as_str().unwrap_or("").to_string(),
                intent: event["intent"].as_str().map(str::to_string), shape, since: Instant::now() });
        } else {
            entry.running.retain(|s| s.id != step);
        }
        entry.last = Instant::now();
        entry.thinking = false;
    }
    notch(app, &vm);
    overlay_send(app, &vm, event);
}

fn notch(app: &AppHandle, vm: &str) {
    let item = lock(&LIVE).as_ref().and_then(|m| m.get(vm)).map(|l| {
        let now = l.running.last();
        json!({ "kind": "live", "client": l.client, "clientName": l.client_name, "method": now.map(|s| s.method.clone()),
            "intent": now.and_then(|s| s.intent.clone()), "shape": now.and_then(|s| s.shape.clone()),
            "thinking": l.thinking && l.running.is_empty() })
    });
    crate::status::set(app, vm, "live", item);
}

fn overlay_send(app: &AppHandle, vm: &str, event: &Value) {
    let current = lock(&OVER).as_ref().map(|o| o.vm.clone());
    if let Some(other) = current.as_deref().filter(|o| *o != vm) {
        if crate::dock::wants(other) && lock(&LIVE).as_ref().is_some_and(|m| m.contains_key(other)) {
            return;
        }
    }
    let window = match app.get_webview_window(LABEL) {
        Some(w) if current.as_deref() == Some(vm) => w,
        existing => {
            if let Some(w) = existing {
                crate::overlay::destroy_and_wait(app, w);
            }
            let Ok(w) = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS).general_autofill_enabled(false)
                .title("GpuVM").decorations(false).transparent(true).no_redirection_bitmap(true).shadow(false).resizable(false)
                .skip_taskbar(true).focused(false).visible(false).build() else { return };
            let _ = w.set_ignore_cursor_events(true);
            *lock(&OVER) = Some(Over { vm: vm.to_string(), ready: false, pending: Vec::new() });
            w
        }
    };
    if !crate::agent::place_over_picture(app, &window, vm) {
        return;
    }
    let ready = lock(&OVER).as_ref().is_some_and(|o| o.ready);
    if ready && !window.is_visible().unwrap_or(false) {
        crate::overlay::show_quiet(&window);
        crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(vm));
    }
    let mut over = lock(&OVER);
    match over.as_mut() {
        Some(o) if o.ready => {
            drop(over);
            let _ = window.emit("agent-live", event);
        }
        Some(o) => {
            o.pending.push(event.clone());
            if o.pending.len() > 20 {
                o.pending.remove(0);
            }
        }
        None => {}
    }
}

fn close_overlay(app: &AppHandle, vm: &str) {
    let mine = lock(&OVER).as_ref().is_some_and(|o| o.vm == vm);
    if mine {
        *lock(&OVER) = None;
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.destroy();
        }
    }
}

pub fn clear(app: &AppHandle, vm: &str) {
    let had = lock(&LIVE).as_mut().and_then(|m| m.remove(vm)).is_some();
    if had {
        crate::status::set(app, vm, "live", None);
    }
    close_overlay(app, vm);
}

fn tidy(app: &AppHandle) {
    let vms: Vec<(String, bool, bool)> = lock(&LIVE).as_mut().map(|m| m.iter_mut().map(|(vm, l)| {
        l.running.retain(|s| s.since.elapsed() < STEP_MAX);
        let idle = l.running.is_empty();
        let think = idle && !l.thinking && l.last.elapsed() > THINKING;
        if think {
            l.thinking = true;
        }
        (vm.clone(), think, idle && l.last.elapsed() > GONE)
    }).collect()).unwrap_or_default();
    for (vm, think, gone) in vms {
        if gone || !crate::dock::wants(&vm) || crate::agent::person_has(&vm) {
            clear(app, &vm);
        } else if think {
            notch(app, &vm);
        }
    }
    let orphan = lock(&OVER).as_ref().map(|o| o.vm.clone()).filter(|vm| !crate::dock::wants(vm));
    if let Some(vm) = orphan {
        close_overlay(app, &vm);
    }
}

pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    match msg["type"].as_str().unwrap_or("") {
        "window" | "panel" => {
            if lock(&OVER).as_ref().is_some_and(|o| o.vm == vm) {
                if let Some(w) = app.get_webview_window(LABEL) {
                    crate::agent::place_over_picture(app, &w, vm);
                }
            }
        }
        "closed" | "ended" => clear(app, vm),
        _ => {}
    }
}
