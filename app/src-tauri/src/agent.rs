//! Agents in the app (docs/agents/protocol.md): the broker in the GpuVM service decides everything; this shows it over
//! the machine's picture and passes on the person's answers.
//!
//! - Requests an agent makes (deliver a file, install as administrator, open the network, revert or delete the machine)
//!   drop as the agent dock over the picture of their machine, like the administrator dock (dock B). With the picture
//!   out of view they show in the main window, and a Windows notification says one is waiting: its only button opens
//!   GpuVM. Nothing is ever approved from a notification, from the viewer or from the guest.
//! - Take control: while an agent works, the viewer reports that the person moved the mouse or pressed a key over the
//!   picture ("input", nothing else: no keys, no positions). With the take-control preference on "input", GpuVM pauses
//!   that machine's agent and shows the notch "You took control · Return to agent" at the bottom of the picture.
//!
//! Security: the dock and the notch are windows of this app (Medium integrity); the viewer (Low, it draws what the guest
//! sends) can't click them (UIPI). Their pages only say which button: the request and the machine are the ones this
//! app put there. The viewer is told to report input only while it matters ("agent-watch"), and a viewer that sends it
//! anyway can at most pause an agent, never approve or resume anything.

use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const DOCK: &str = "agent-dock";
pub const BANNER: &str = "agent-banner";
/// Same as the pages' drop and lift (styles.css, .dock and .ag-banner).
const SLIDE_MS: u64 = 320;
/// Least time between the dock coming down and an answer (its drop plus the page's own guard).
const ARM: Duration = Duration::from_millis(700);
/// The notch's size, in logical pixels (its page centers it at the bottom).
const BANNER_W: f64 = 520.0;
const BANNER_H: f64 = 56.0;

/// Take control with the mouse or keyboard (true) or only with the button (false).
static TAKE_ON_INPUT: AtomicBool = AtomicBool::new(true);
static TIMEOUT_S: AtomicU32 = AtomicU32::new(120);

struct Docked {
    vm: String,
    request: Value,
    shown: Instant,
}
static DOCKED: Mutex<Option<Docked>> = Mutex::new(None);
/// The machine and client whose notch is shown.
static BANNERED: Mutex<Option<Value>> = Mutex::new(None);
/// The machines whose viewer reports input now.
static WATCHING: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// When each machine's agent was last paused from input: one pause per press, not one per mouse move.
static PAUSED_AT: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);
/// What the last poll saw: the clients (machine -> client) and every request waiting.
static CLIENTS: Mutex<Vec<Value>> = Mutex::new(Vec::new());
/// Requests a notification was already shown for.
static NOTIFIED: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// Answered here: hidden at once, before the next poll stops listing them.
static ANSWERED: Mutex<Vec<String>> = Mutex::new(Vec::new());

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn english() -> bool {
    crate::ENGLISH.load(Ordering::Relaxed)
}
fn tr(en: &str, es: &str) -> String {
    if english() { en.to_string() } else { es.to_string() }
}

async fn call(app: &AppHandle, cmd: &str, args: Value) -> Result<Value, String> {
    let state = app.state::<crate::AppState>();
    let request = json!({ "id": crate::next_id(&state), "cmd": cmd, "args": args });
    crate::query(&state, request).await.and_then(crate::into_data)
}

fn list(v: Result<Value, String>) -> Option<Vec<Value>> {
    match v {
        Ok(Value::Array(a)) => Some(a),
        Ok(Value::Null) => Some(vec![]),
        Ok(other) => Some(vec![other]),
        Err(_) => None,
    }
}

/// The agent poll: once a second while a machine's picture is open, every few seconds otherwise. A module without
/// the agent commands (before the broker is installed) is asked again only every half minute.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let (mut round, mut settings, mut broker) = (0u64, Value::Null, Value::Null);
        loop {
            let viewing = crate::viewer::any_open();
            // The broker answers these itself, in-process (agent-broker.md): cheap enough to ask every second.
            let clients = list(call(&app, "Get-GpuVMAgentClient", json!({})).await);
            let Some(clients) = clients else {
                tokio::time::sleep(Duration::from_secs(30)).await;
                continue;
            };
            let requests = list(call(&app, "Get-GpuVMAgentRequest", json!({})).await).unwrap_or_default();
            let offers = list(call(&app, "Get-GpuVMAgentOffer", json!({})).await).unwrap_or_default();
            // The settings (per-client approvals) and the channel's state change rarely: every tenth round.
            if round % 10 == 0 {
                settings = call(&app, "Get-GpuVMAgentSettings", json!({})).await.ok().and_then(|v| v.get(0).cloned()).unwrap_or(Value::Null);
                broker = call(&app, "Get-GpuVMAgentBroker", json!({})).await.ok().and_then(|v| v.get(0).cloned()).unwrap_or(Value::Null);
            }
            round += 1;
            update(&app, clients, requests, offers, &settings, &broker);
            let busy = lock(&CLIENTS).iter().any(|c| c["state"].as_str().is_some_and(|s| s != "idle"));
            tokio::time::sleep(Duration::from_millis(if viewing && busy { 1000 } else if busy { 2000 } else { 5000 })).await;
        }
    });
}

/// A pending delivery, shown in the dock like any other request.
fn offer_request(o: &Value) -> Value {
    let name = o["name"].as_str().unwrap_or("");
    let created = o["createdAt"].clone();
    json!({
        "id": format!("offer:{}", o["id"].as_str().unwrap_or("")), "offerId": o["id"], "client": o["connection"], "clientName": o["clientName"],
        "machine": o["machine"], "kind": "deliver", "title": format!("Deliver {name}"), "reason": o["note"], "createdAt": created,
        "expiresAt": o["expiresAt"],
        "file": { "name": name, "sizeBytes": o["sizeBytes"] },
    })
}

fn update(app: &AppHandle, clients: Vec<Value>, requests: Vec<Value>, offers: Vec<Value>, settings: &Value, broker: &Value) {
    // Every page that shows agents takes this instead of asking the service again (agentStore.ts turns it into the
    // app's shapes).
    let _ = app.emit("agents-state", json!({ "clients": clients, "requests": requests, "offers": offers, "settings": settings, "broker": broker }));
    *lock(&CLIENTS) = clients.clone();
    let answered = lock(&ANSWERED).clone();
    // What only the person can do (a password, UAC) is the agent's state, not a request: shown without buttons.
    let human = clients.iter().filter(|c| c["state"] == "human" && c["machine"].is_string()).map(|c| json!({
        "id": format!("human:{}", c["id"].as_str().unwrap_or("")), "client": c["id"], "clientName": c["name"], "machine": c["machine"],
        "kind": "admin", "title": c["reason"].as_str().filter(|s| !s.is_empty()).unwrap_or("Windows needs you"), "human": true,
        "createdAt": 0, "expiresAt": Value::Null,
    }));
    let pending = requests.into_iter().filter(|r| r["state"].as_str().unwrap_or("pending") == "pending")
        .map(|mut r| { r["client"] = r["connection"].clone(); r });
    let mut waiting: Vec<Value> = pending.chain(human).chain(offers.iter().filter(|o| o["state"] == "pending").map(offer_request))
        .filter(|r| !answered.iter().any(|a| Some(a.as_str()) == r["id"].as_str()))
        .collect();
    waiting.sort_by(|a, b| a["createdAt"].as_f64().unwrap_or(0.0).total_cmp(&b["createdAt"].as_f64().unwrap_or(0.0)));

    // Which viewers report input: those whose machine has an agent working, with take control on input.
    let on_input = TAKE_ON_INPUT.load(Ordering::Relaxed);
    let working: HashSet<String> = clients.iter()
        .filter(|c| c["state"] == "working")
        .filter_map(|c| c["machine"].as_str().map(str::to_string))
        .filter(|vm| on_input && crate::viewer::viewer_is_open(vm.clone()))
        .collect();
    {
        let mut watching = lock(&WATCHING);
        let watching = watching.get_or_insert_with(HashSet::new);
        for vm in working.difference(watching).cloned().collect::<Vec<_>>() {
            if crate::viewer::send_to(&vm, &json!({ "type": "agent-watch", "on": true })).is_ok() {
                watching.insert(vm);
            }
        }
        for vm in watching.difference(&working).cloned().collect::<Vec<_>>() {
            let _ = crate::viewer::send_to(&vm, &json!({ "type": "agent-watch", "on": false }));
            watching.remove(&vm);
        }
    }

    // The notch: a machine in view whose agent the person has.
    let banner = clients.iter()
        .find(|c| c["state"] == "control" && c["machine"].as_str().is_some_and(crate::dock::wants))
        .map(|c| json!({ "vm": c["machine"], "clientName": c["name"], "client": c["id"] }));
    show_banner(app, banner);

    // The dock: the oldest request of a machine in view, unless its administrator dock is down already.
    let docked = waiting.iter().find(|r| {
        let vm = r["machine"].as_str().unwrap_or("");
        crate::dock::wants(vm) && crate::dock::current_vm().as_deref() != Some(vm)
    }).cloned();
    match docked {
        Some(r) => show_dock(app, r),
        None => hide_dock(app),
    }

    // A notification for each new request whose machine isn't in view (once each; not for the docked one).
    let shown_id = lock(&DOCKED).as_ref().map(|d| d.request["id"].clone());
    let mut notified = lock(&NOTIFIED);
    let notified = notified.get_or_insert_with(HashSet::new);
    for r in &waiting {
        let id = r["id"].as_str().unwrap_or("").to_string();
        if id.is_empty() || notified.contains(&id) || Some(&r["id"]) == shown_id.as_ref() {
            continue;
        }
        notified.insert(id);
        if !main_in_front(app) {
            notify(app, r);
        }
    }
    let live: HashSet<String> = waiting.iter().filter_map(|r| r["id"].as_str().map(str::to_string)).collect();
    notified.retain(|id| live.contains(id));
    lock(&ANSWERED).retain(|id| live.contains(id));
}

fn main_in_front(app: &AppHandle) -> bool {
    app.get_webview_window("main").is_some_and(|w| w.is_focused().unwrap_or(false) && w.is_visible().unwrap_or(false))
}

/* ---------- the dock ---------- */

/// A window over the viewer's picture: all of it (the dock's veil), or only its top center for what only the person
/// can do (no veil, the picture stays usable).
fn place(app: &AppHandle, window: &tauri::WebviewWindow, vm: &str, rect: Rect) -> bool {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return false };
    let Some((x, y, w, h, scale)) = crate::overlay::client_rect(viewer) else { return false };
    let w = w - crate::overlay::open_width(app, vm).unwrap_or(0).min(w / 2);
    let (px, py, pw, ph) = match rect {
        Rect::Picture => (x, y, w, h),
        Rect::Top => {
            let bw = ((440.0 * scale) as i32).min(w);
            (x + (w - bw) / 2, y, bw, (72.0 * scale) as i32)
        }
        Rect::Bottom => {
            let bw = ((BANNER_W * scale) as i32).min(w);
            let bh = (BANNER_H * scale) as i32;
            (x + (w - bw) / 2, y + h - bh, bw, bh)
        }
    };
    let _ = window.set_size(PhysicalSize::new(pw.max(1) as u32, ph.max(1) as u32));
    let _ = window.set_position(PhysicalPosition::new(px, py));
    if let Ok(own) = window.hwnd() {
        // SAFETY: the viewer becomes the window's owner, so it stays just above the picture and moves with it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
    }
    true
}

#[derive(Clone, Copy)]
enum Rect {
    Picture,
    Top,
    Bottom,
}

fn build(app: &AppHandle, label: &str) -> Option<tauri::WebviewWindow> {
    WebviewWindowBuilder::new(app, label, WebviewUrl::App("index.html".into()))
        .title("GpuVM")
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .build()
        .ok()
}

fn show_dock(app: &AppHandle, request: Value) {
    let vm = request["machine"].as_str().unwrap_or("").to_string();
    let human = request["human"].as_bool() == Some(true);
    let same_vm = {
        let mut d = lock(&DOCKED);
        let same = d.as_ref().is_some_and(|d| d.vm == vm && (d.request["human"].as_bool() == Some(true)) == human);
        if d.as_ref().is_some_and(|d| d.request["id"] == request["id"]) {
            return;
        }
        *d = Some(Docked { vm: vm.clone(), request: request.clone(), shown: Instant::now() });
        same
    };
    if let Some(window) = app.get_webview_window(DOCK) {
        if same_vm {
            let _ = window.emit("agent-dock", json!({ "request": request }));
            return;
        }
        let _ = window.destroy();
    }
    let Some(window) = build(app, DOCK) else { return };
    if !place(app, &window, &vm, if human { Rect::Top } else { Rect::Picture }) {
        let _ = window.destroy();
        *lock(&DOCKED) = None;
        return;
    }
    let _ = window.show();
    crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(&vm));
    if !human {
        // Like the administrator dock: the viewer lets go of the mouse and the keyboard comes here, so nothing typed
        // meanwhile goes on into the machine (and no key answers it).
        let _ = crate::viewer::send_to(&vm, &json!({ "type": "capture", "on": false }));
        if let Ok(own) = window.hwnd() {
            crate::overlay::bring_to_front(own.0 as isize);
        }
    }
}

fn hide_dock(app: &AppHandle) {
    let Some(d) = lock(&DOCKED).take() else { return };
    let Some(window) = app.get_webview_window(DOCK) else { return };
    let _ = window.emit("agent-dock", json!({ "request": Value::Null }));
    let had_focus = window.is_focused().unwrap_or(false);
    let human = d.request["human"].as_bool() == Some(true);
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(SLIDE_MS));
        if lock(&DOCKED).is_some() {
            return;
        }
        if let Some(w) = app.get_webview_window(DOCK) {
            let _ = w.destroy();
        }
        if human {
            return;
        }
        if had_focus {
            if let Some(viewer) = crate::viewer::viewer_hwnd(&d.vm) {
                crate::viewer::allow_viewer_foreground(&d.vm);
                let _ = crate::viewer::send_to(&d.vm, &json!({ "type": "focus" }));
                crate::overlay::bring_to_front(viewer);
            }
        }
        if crate::overlay::open_width(&app, &d.vm).is_none() {
            let _ = crate::viewer::send_to(&d.vm, &json!({ "type": "capture", "on": true }));
        }
    });
}

/// Allow / Refuse (and, from its right click, Allow for this task) in the dock. Only which button: the request is
/// the one this app put there.
#[tauri::command]
pub async fn agent_dock_answer(app: AppHandle, allow: bool, for_task: bool) -> Result<(), String> {
    let request = {
        let d = lock(&DOCKED);
        let d = d.as_ref().ok_or("The request already closed.")?;
        if d.request["human"].as_bool() == Some(true) {
            return Err("Only you can do this, in the machine.".into());
        }
        if d.shown.elapsed() < ARM {
            return Err("The request just appeared.".into());
        }
        d.request.clone()
    };
    answer(&app, &request, allow, for_task).await?;
    lock(&ANSWERED).push(request["id"].as_str().unwrap_or("").to_string());
    hide_dock(&app);
    let _ = app.emit("agents-changed", json!({}));
    Ok(())
}

async fn answer(app: &AppHandle, request: &Value, allow: bool, for_task: bool) -> Result<(), String> {
    if let Some(offer) = request["offerId"].as_str() {
        call(app, "Resolve-GpuVMAgentOffer", json!({ "Id": offer, "Accept": allow })).await.map(|_| ())
    } else {
        let id = request["id"].as_str().ok_or("The request isn't valid.")?;
        let mut args = json!({ "Id": id, "Allow": allow });
        if allow && for_task {
            args["ForTask"] = json!(true);
        }
        call(app, "Resolve-GpuVMAgentRequest", args).await.map(|_| ())
    }
}

/// The request the dock shows, for its page when it loads.
#[tauri::command]
pub fn agent_dock_request() -> Value {
    lock(&DOCKED).as_ref().map(|d| d.request.clone()).unwrap_or(Value::Null)
}

/* ---------- take control ---------- */

fn show_banner(app: &AppHandle, info: Option<Value>) {
    let previous = lock(&BANNERED).clone();
    if previous == info {
        // Still the same: it follows the picture if it moved (window messages re-place it too).
        return;
    }
    *lock(&BANNERED) = info.clone();
    let Some(info) = info else {
        if let Some(w) = app.get_webview_window(BANNER) {
            let _ = w.emit("agent-banner", json!({ "info": Value::Null }));
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(SLIDE_MS));
                if lock(&BANNERED).is_none() {
                    if let Some(w) = app.get_webview_window(BANNER) {
                        let _ = w.destroy();
                    }
                }
            });
        }
        return;
    };
    let vm = info["vm"].as_str().unwrap_or("").to_string();
    if let Some(w) = app.get_webview_window(BANNER) {
        if previous.as_ref().is_some_and(|p| p["vm"] == info["vm"]) {
            let _ = w.emit("agent-banner", json!({ "info": info }));
            return;
        }
        let _ = w.destroy();
    }
    let Some(window) = build(app, BANNER) else { return };
    if !place(app, &window, &vm, Rect::Bottom) {
        let _ = window.destroy();
        *lock(&BANNERED) = None;
        return;
    }
    // Shown without taking the keyboard: the person keeps typing into the machine.
    let _ = window.show();
    crate::overlay::mark_taskbar(&window, crate::viewer::viewer_full_screen(&vm));
}

/// The notch's machine and client, for its page when it loads.
#[tauri::command]
pub fn agent_banner_info() -> Value {
    lock(&BANNERED).clone().unwrap_or(Value::Null)
}

/// Return to agent: the broker resumes it with a fresh screenshot and a note that the person had control.
#[tauri::command]
pub async fn agent_banner_return(app: AppHandle) -> Result<(), String> {
    let info = lock(&BANNERED).clone().ok_or("The agent already has the machine.")?;
    let id = info["client"].as_str().ok_or("The agent isn't valid.")?.to_string();
    call(&app, "Resume-GpuVMAgent", json!({ "Connection": id })).await?;
    show_banner(&app, None);
    let _ = app.emit("agents-changed", json!({}));
    Ok(())
}

/// The viewer saw the person's input over the picture: the agent working there pauses (take control).
pub fn on_input(app: &AppHandle, vm: &str) {
    if !TAKE_ON_INPUT.load(Ordering::Relaxed) || !lock(&WATCHING).as_ref().is_some_and(|w| w.contains(vm)) {
        return;
    }
    {
        let mut at = lock(&PAUSED_AT);
        let at = at.get_or_insert_with(HashMap::new);
        if at.get(vm).is_some_and(|t| t.elapsed() < Duration::from_millis(1500)) {
            return;
        }
        at.insert(vm.to_string(), Instant::now());
    }
    let Some(client) = lock(&CLIENTS).iter().find(|c| c["machine"].as_str() == Some(vm) && c["state"] == "working").cloned() else { return };
    // The viewer stops reporting at once (nothing to pause until it is given back).
    let _ = crate::viewer::send_to(vm, &json!({ "type": "agent-watch", "on": false }));
    lock(&WATCHING).as_mut().map(|w| w.remove(vm));
    let started = Instant::now();
    let app = app.clone();
    let vm = vm.to_string();
    tauri::async_runtime::spawn(async move {
        let id = client["id"].as_str().unwrap_or("").to_string();
        let result = call(&app, "Suspend-GpuVMAgent", json!({ "Connection": id, "Reason": "control", "Message": "You took control" })).await;
        // Lab 054 reads this line: the time from the viewer's report to the broker's answer.
        eprintln!("agent take-control {vm} paused in {} ms ({})", started.elapsed().as_millis(), if result.is_ok() { "ok" } else { "failed" });
        if result.is_ok() {
            let info = json!({ "vm": vm, "clientName": client["name"], "client": id });
            if crate::dock::wants(&vm) {
                show_banner(&app, Some(info));
            }
            let _ = app.emit("agents-changed", json!({}));
        }
    });
}

/// The viewer's window moved or closed: the agent's windows follow it.
pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    match msg["type"].as_str().unwrap_or("") {
        "window" => {
            let docked = lock(&DOCKED).as_ref().filter(|d| d.vm == vm).map(|d| d.request["human"].as_bool() == Some(true));
            if let (Some(human), Some(w)) = (docked, app.get_webview_window(DOCK)) {
                place(app, &w, vm, if human { Rect::Top } else { Rect::Picture });
            }
            let bannered = lock(&BANNERED).as_ref().is_some_and(|b| b["vm"].as_str() == Some(vm));
            if let (true, Some(w)) = (bannered, app.get_webview_window(BANNER)) {
                place(app, &w, vm, Rect::Bottom);
            }
        }
        "closed" | "ended" => {
            if lock(&DOCKED).as_ref().is_some_and(|d| d.vm == vm) {
                *lock(&DOCKED) = None;
                if let Some(w) = app.get_webview_window(DOCK) {
                    let _ = w.destroy();
                }
            }
            if lock(&BANNERED).as_ref().is_some_and(|b| b["vm"].as_str() == Some(vm)) {
                *lock(&BANNERED) = None;
                if let Some(w) = app.get_webview_window(BANNER) {
                    let _ = w.destroy();
                }
            }
            lock(&WATCHING).as_mut().map(|w| w.remove(vm));
        }
        _ => {}
    }
}

/* ---------- preferences ---------- */

/// Settings › Agents: how the person takes control, and how long a request waits (the broker refuses it after).
#[tauri::command]
pub async fn set_agent_prefs(app: AppHandle, take_control: String, approval_timeout: u32) -> Result<(), String> {
    TAKE_ON_INPUT.store(take_control != "button", Ordering::Relaxed);
    let timeout = approval_timeout.clamp(15, 3600);
    if TIMEOUT_S.swap(timeout, Ordering::Relaxed) != timeout {
        // A module without the broker yet just doesn't know it; the app keeps working.
        let _ = call(&app, "Set-GpuVMAgentSettings", json!({ "ApprovalTimeoutSec": timeout })).await;
    }
    if take_control == "button" {
        // Nothing to report any more.
        if let Some(w) = lock(&WATCHING).take() {
            for vm in w {
                let _ = crate::viewer::send_to(&vm, &json!({ "type": "agent-watch", "on": false }));
            }
        }
    }
    Ok(())
}

/// This PC's gpuvm.exe, for the `claude mcp add` command the Agents page shows.
#[tauri::command]
pub fn mcp_exe_path() -> Result<String, String> {
    std::env::current_exe().map(|p| p.display().to_string()).map_err(|e| e.to_string())
}

/* ---------- Windows notifications ---------- */

/// A Windows notification that a request waits. Its only action opens GpuVM's main window on Agents: answering is
/// done there (a GpuVM window), never from the notification.
fn notify(app: &AppHandle, request: &Value) {
    let who = request["clientName"].as_str().unwrap_or("An agent");
    let what = request["title"].as_str().unwrap_or("");
    let vm = request["machine"].as_str().unwrap_or("");
    let title = if english() { format!("{who} asks: {what}") } else { format!("{who} pide: {}", spanish_title(what)) };
    let body = format!("{vm} · {}", tr("Waiting for your answer", "Espera tu respuesta"));
    let review = tr("Review", "Revisar");
    let app2 = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Err(e) = toast::show(&title, &body, &review, move || open_agents(&app2)) {
            eprintln!("agent notification: {e}");
        }
    });
}

/// The broker's titles are English ("Connect to github.com"); the notification is drawn here, so its common shapes
/// are said in Spanish.
fn spanish_title(en: &str) -> String {
    let pairs = [("Deliver ", "Entregar "), ("Connect to ", "Conectarse a "), ("Install ", "Instalar "), ("Go back to the restore point ", "Volver al punto "), ("Delete ", "Eliminar ")];
    for (a, b) in pairs {
        if let Some(rest) = en.strip_prefix(a) {
            return format!("{b}{rest}");
        }
    }
    en.to_string()
}

fn open_agents(app: &AppHandle) {
    crate::show_main(app);
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.emit("open-route", ":agents");
    }
}

mod toast {
    use windows::core::{Interface, HSTRING};
    use windows::Data::Xml::Dom::XmlDocument;
    use windows::Foundation::TypedEventHandler;
    use windows::UI::Notifications::{ToastNotification, ToastNotificationManager};

    /// The app's id as the installer registers it (tauri.conf.json identifier).
    const AUMID: &str = "dev.alejandro.gpuvm";

    fn escape(s: &str) -> String {
        s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
    }

    pub fn show(title: &str, body: &str, action: &str, on_open: impl Fn() + Send + Sync + 'static) -> windows::core::Result<()> {
        let xml = format!(
            "<toast activationType=\"foreground\" launch=\"agents\"><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text></binding></visual>\
             <actions><action content=\"{}\" arguments=\"agents\" activationType=\"foreground\"/></actions></toast>",
            escape(title), escape(body), escape(action));
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml))?;
        let toast = ToastNotification::CreateToastNotification(&doc)?;
        // Clicking the notification or its button: GpuVM opens on Agents (in this running process).
        toast.Activated(&TypedEventHandler::<ToastNotification, windows::core::IInspectable>::new(move |_, _| {
            on_open();
            Ok(())
        }))?;
        let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?;
        notifier.Show(&toast)?;
        // Kept alive until it goes, so its click still reaches the handler.
        let _ = toast.cast::<windows::core::IInspectable>();
        KEEP.with(|k| {
            let mut k = k.borrow_mut();
            k.push(toast);
            if k.len() > 8 {
                k.remove(0);
            }
        });
        Ok(())
    }

    thread_local! {
        static KEEP: std::cell::RefCell<Vec<ToastNotification>> = const { std::cell::RefCell::new(Vec::new()) };
    }
}
