//! What an agent is doing, live over its machine's picture (2026-11-21, chosen by the person): the agent's cursor with
//! its name, a ring on each click, the stroke of a drag, and in the status notch what it is doing ("Claude Code ·
//! Drawing the moon", from the step's `intent`, or a plain text from the step itself).
//!
//! - The service tells what each step is as it starts and ends (agent_log.rs in app/host): this module waits for it on
//!   a pipe connection of its own (`Wait-GpuVMAgentActivity`, a long poll), so the app's other calls never wait
//!   behind it and nothing polls fast.
//! - The overlay is one window of this app over the picture in view, owned by the viewer, transparent and
//!   click-through: the person's clicks always reach the picture. Only while an agent acts on the machine whose picture
//!   is on screen (never over a hidden viewer, one opened only to record) and gone as soon as the person takes control,
//!   so watching costs nothing the rest of the time (an overlay takes the stream off Windows' direct path to the screen
//!   while it is shown).
//! - Shapes only: where a click or a drag went, which keys, how many characters were typed; never the text typed or
//!   a command line.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Listener, Manager, WebviewUrl, WebviewWindowBuilder};

pub const LABEL: &str = "agent-live";
/// With no step for this long, the notch says the agent is thinking.
const THINKING: Duration = Duration::from_millis(1800);
/// With no step for this long, the overlay and the notch go (the agent stopped or waits for something long).
const GONE: Duration = Duration::from_secs(25);
/// A step whose end never came (the pipe dropped, the service restarted) stops counting as running after this long:
/// longer than any step may take (a command's 580 s).
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
    /// Steps started and not ended yet (the newest one is shown).
    running: Vec<Step>,
    last: Instant,
    thinking: bool,
}

static LIVE: Mutex<Option<HashMap<String, Live>>> = Mutex::new(None);

/// The overlay window: the machine it is over, whether its page listens yet, and what came before it did.
struct Over {
    vm: String,
    ready: bool,
    pending: Vec<Value>,
}
static OVER: Mutex<Option<Over>> = Mutex::new(None);

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
    // The overlay's page listens now: what came while it loaded is sent (the first step of a session used to be lost).
    let handle = app.clone();
    app.listen_any("agent-live-ready", move |_| {
        let pending = {
            let mut over = lock(&OVER);
            let Some(o) = over.as_mut() else { return };
            o.ready = true;
            std::mem::take(&mut o.pending)
        };
        if let Some(w) = handle.get_webview_window(LABEL) {
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
            // A service that doesn't know the command (an older one) answers at once: don't spin on it.
            let Some(last) = data["last"].as_u64() else { break };
            // A restarted service counts from 1 again: what it has is from before the app looked, as at the start.
            if last < after {
                primed = false;
            }
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
        // The connection broke: steps whose end may have been lost don't stay "running".
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
    // Only the picture on screen, and never once the person has the machine.
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
            // A drag of several strokes is drawing; the first shape names what an input step does.
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

/// The status notch line for the machine: the newest running step, or "thinking" between steps.
fn notch(app: &AppHandle, vm: &str) {
    let item = lock(&LIVE).as_ref().and_then(|m| m.get(vm)).map(|l| {
        let now = l.running.last();
        json!({ "kind": "live", "client": l.client, "clientName": l.client_name, "method": now.map(|s| s.method.clone()),
            "intent": now.and_then(|s| s.intent.clone()), "shape": now.and_then(|s| s.shape.clone()),
            "thinking": l.thinking && l.running.is_empty() })
    });
    crate::status::set(app, vm, "live", item);
}

/// Sends an event to the overlay over this machine's picture, making or moving it there as needed. One overlay: a
/// second machine's picture on screen at the same time keeps only its notch line while the first one has it.
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
                let _ = w.destroy();
            }
            let Ok(w) = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
                .title("GpuVM").decorations(false).transparent(true).shadow(false).resizable(false)
                .skip_taskbar(true).focused(false).visible(false).build() else { return };
            // Click-through: every click and the wheel go to the picture underneath.
            let _ = w.set_ignore_cursor_events(true);
            *lock(&OVER) = Some(Over { vm: vm.to_string(), ready: false, pending: Vec::new() });
            w
        }
    };
    if !crate::agent::place_over_picture(app, &window, vm) {
        return;
    }
    if !window.is_visible().unwrap_or(false) {
        let _ = window.show();
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

/// Everything about a machine goes: its viewer closed or hid, the person took control, or the agent went quiet.
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
    // An overlay left without its machine (it hid before any step was tracked).
    let orphan = lock(&OVER).as_ref().map(|o| o.vm.clone()).filter(|vm| !crate::dock::wants(vm));
    if let Some(vm) = orphan {
        close_overlay(app, &vm);
    }
}

/// The viewer moved, resized or opened its side panel: the overlay follows the picture.
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
