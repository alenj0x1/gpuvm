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
/// Same as the pages' drop and lift (styles.css, .dock and .ag-banner).
const SLIDE_MS: u64 = 320;
/// Least time between the dock coming down and an answer (its drop plus the page's own guard).
const ARM: Duration = Duration::from_millis(700);

/// Take control with the mouse or keyboard (true) or only with the button (false).
static TAKE_ON_INPUT: AtomicBool = AtomicBool::new(true);

struct Docked {
    vm: String,
    request: Value,
    shown: Instant,
}
static DOCKED: Mutex<Option<Docked>> = Mutex::new(None);
/// What each machine's status notch says about its agent now (machine -> "control"/"paused" and client).
static STATUS: Mutex<Option<HashMap<String, (String, String)>>> = Mutex::new(None);
/// The machines whose viewer reports input now.
static WATCHING: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// When each machine's agent was last paused from input: one pause per press, not one per mouse move.
static PAUSED_AT: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);
/// When each machine's picture last came on screen (refresh_burst): input reported in the next VIEWER_SETTLE is the
/// viewer itself settling, not the person (2026-11-21: every open paused the agent ~4 s in, "You took control").
static SHOWN_AT: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);
const VIEWER_SETTLE: Duration = Duration::from_secs(4);
/// What the last poll saw: the clients (machine -> client) and every request waiting.
static CLIENTS: Mutex<Vec<Value>> = Mutex::new(Vec::new());
/// Requests a notification was already shown for.
static NOTIFIED: Mutex<Option<HashSet<String>>> = Mutex::new(None);
/// Answered here: hidden at once, before the next poll stops listing them.
static ANSWERED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// `gpuvm.exe --view <name>` from an agent (the MCP server's open_viewer): waits here until that machine is held by
/// a live agent session, for up to VIEW_WAIT (an agent that just made it isn't listed yet). Never anything else: the
/// person's own machines don't open (or power on) because some process ran `--view` (security review, 2026-11-19).
static AGENT_VIEW: Mutex<Option<(String, Instant)>> = Mutex::new(None);
/// Released: the page opens it when it is running (pending_agent_view, for a page that isn't loaded yet).
static AGENT_VIEW_READY: Mutex<Option<String>> = Mutex::new(None);
const VIEW_WAIT: Duration = Duration::from_secs(180);

/// A `--view` arrived: checked against the sessions now and on each poll.
pub fn request_view(app: &AppHandle, name: &str) {
    *lock(&AGENT_VIEW) = Some((name.to_string(), Instant::now()));
    let clients = lock(&CLIENTS).clone();
    release_view(app, &clients);
}

/// Whether a live agent session holds that machine (any state but stopped).
fn held_by_agent(clients: &[Value], name: &str) -> bool {
    clients.iter().any(|c| c["machine"].as_str().is_some_and(|m| m.eq_ignore_ascii_case(name)) && c["state"].as_str().is_some_and(|s| s != "stopped"))
}

fn release_view(app: &AppHandle, clients: &[Value]) {
    let name = {
        let mut pending = lock(&AGENT_VIEW);
        match pending.as_ref() {
            Some((_, at)) if at.elapsed() > VIEW_WAIT => { *pending = None; return; }
            Some((name, _)) if held_by_agent(clients, name) => { let n = name.clone(); *pending = None; n }
            _ => return,
        }
    };
    *lock(&AGENT_VIEW_READY) = Some(name.clone());
    if let Some(w) = app.get_webview_window("main") {
        // No focus taken: the taskbar button flashes, the person looks when they want.
        let _ = w.request_user_attention(Some(tauri::UserAttentionType::Informational));
        let _ = w.emit("agent-view", name);
    }
}

/// The page, once it can open machines: an agent's `--view` released before it loaded.
#[tauri::command]
pub fn pending_agent_view() -> Option<String> {
    lock(&AGENT_VIEW_READY).take()
}

/// The page took the released name (it opens it or decides not to).
#[tauri::command]
pub fn agent_view_taken() {
    *lock(&AGENT_VIEW_READY) = None;
}

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
            // Each machine's agent: ready, no-display (signed in but sees no screen), starting, off or no-agent. Only
            // what the pages show is kept (not the agent's whole info).
            let machines: Vec<Value> = list(call(&app, "Get-GpuVMAgent", json!({})).await).unwrap_or_default().iter()
                .map(|m| json!({ "name": m["name"], "state": m["state"], "lastError": m["lastError"] })).collect();
            // The settings (per-client approvals) and the channel's state change rarely: every tenth round.
            if round % 10 == 0 {
                settings = call(&app, "Get-GpuVMAgentSettings", json!({})).await.ok().and_then(|v| v.get(0).cloned()).unwrap_or(Value::Null);
                broker = call(&app, "Get-GpuVMAgentBroker", json!({})).await.ok().and_then(|v| v.get(0).cloned()).unwrap_or(Value::Null);
            }
            round += 1;
            update(&app, clients, requests, offers, machines, &settings, &broker);
            // An agent holding a machine counts even while idle (thinking): its viewer must be watched without lag.
            let busy = lock(&CLIENTS).iter().any(|c| c["state"].as_str().is_some_and(|s| s != "idle" && s != "stopped") || holds(c))
                // A delivery still copying: its result shows without waiting for the slow poll.
                || lock(&COPIES).as_ref().is_some_and(|c| c.values().any(|x| x.state == "copying" || x.state == "pending"));
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

fn update(app: &AppHandle, clients: Vec<Value>, requests: Vec<Value>, offers: Vec<Value>, machines: Vec<Value>, settings: &Value, broker: &Value) {
    // Every page that shows agents takes this instead of asking the service again (agentStore.ts turns it into the
    // app's shapes).
    let _ = app.emit("agents-state", json!({ "clients": clients, "requests": requests, "offers": offers, "machines": machines, "settings": settings, "broker": broker, "recordings": recordings() }));
    *lock(&CLIENTS) = clients.clone();
    release_view(app, &clients);
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

    // Which viewers report input: those whose machine an agent holds and may act on (working, or idle between two
    // actions), with take control on input. Only "working" missed the person's first move after the agent had been
    // idle 15 s (lab 054: round 1 missed in every run).
    let on_input = TAKE_ON_INPUT.load(Ordering::Relaxed);
    let working: HashSet<String> = clients.iter()
        .filter(|c| holds(c))
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

    // The status notch: "You took control" or "<client> paused" on the machine's picture.
    sync_status(app, &clients);
    // Recording while an agent works on a machine.
    sync_recordings(app, &clients);
    // A delivery the person accepted: "Copying…" on the machine's notch, then where it went or why it failed.
    sync_copies(app, &offers);

    // The dock: the oldest request of a machine in view, unless its administrator dock is down already.
    let docked = waiting.iter().find(|r| {
        let vm = r["machine"].as_str().unwrap_or("");
        crate::dock::wants(vm) && crate::dock::current_vm().as_deref() != Some(vm)
    }).cloned();
    match docked {
        Some(r) => show_dock(app, r),
        None => hide_dock(app),
    }

    // A Windows notification for every new request (once each), wherever GpuVM is: in front, minimized, in the tray or
    // in notices-only mode. Only the one dropping as the dock over the picture the person looks at goes without.
    // (agent-mcp, 2026-11-19: a request that came while GpuVM was in front was marked as announced without a
    // notification, and with GpuVM then in the tray the person never learned of it.)
    let shown_id = lock(&DOCKED).as_ref().map(|d| d.request["id"].clone());
    {
        let mut notified = lock(&NOTIFIED);
        let notified = notified.get_or_insert_with(HashSet::new);
        for r in &waiting {
            let id = r["id"].as_str().unwrap_or("").to_string();
            if id.is_empty() || notified.contains(&id) || Some(&r["id"]) == shown_id.as_ref() {
                continue;
            }
            notified.insert(id);
            notify(app, r);
        }
        let live: HashSet<String> = waiting.iter().filter_map(|r| r["id"].as_str().map(str::to_string)).collect();
        notified.retain(|id| live.contains(id));
        lock(&ANSWERED).retain(|id| live.contains(id));
    }
    // The mark: the tray icon (a dot and the count in its tooltip) and, with the window out of front, its taskbar
    // button flashing once per new request.
    mark_waiting(app, waiting.len());
}

/// How many requests waited at the last poll (the tray's mark changes only when it changes).
static WAITING: AtomicU32 = AtomicU32::new(0);

fn mark_waiting(app: &AppHandle, count: usize) {
    let count = count as u32;
    let before = WAITING.swap(count, Ordering::Relaxed);
    if before == count {
        return;
    }
    crate::set_tray_waiting(app, count);
    if count > before && !main_in_front(app) {
        if let Some(w) = app.get_webview_window("main") {
            let _ = w.request_user_attention(Some(tauri::UserAttentionType::Informational));
        }
    }
}

/// The agent holds a machine and may act on it now or at any moment (working, thinking between steps, or waiting for
/// an answer): the person's input there takes control, so its next click never fights theirs (code review).
fn holds(c: &Value) -> bool {
    c["machine"].is_string() && matches!(c["state"].as_str(), Some("working") | Some("idle") | Some("waiting"))
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
            let bw = ((560.0 * scale) as i32).min(w);
            (x + (w - bw) / 2, y, bw, (72.0 * scale) as i32)
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

/// The live overlay (live.rs) over a machine's whole picture.
pub(crate) fn place_over_picture(app: &AppHandle, window: &tauri::WebviewWindow, vm: &str) -> bool {
    place(app, window, vm, Rect::Picture)
}

/// The person has this machine now (took control, or paused its agent): nothing of the agent's is drawn over it.
pub(crate) fn person_has(vm: &str) -> bool {
    lock(&STATUS).as_ref().is_some_and(|s| s.contains_key(vm))
}

/// "Take control" from the live line in the status notch: like a click on the picture, without the click.
pub async fn take_control(app: &AppHandle, vm: &str) -> Result<(), String> {
    let client = lock(&CLIENTS).iter().find(|c| c["machine"].as_str() == Some(vm) && holds(c)).cloned().ok_or("No agent is working on this machine.")?;
    lock(&WATCHING).as_mut().map(|w| w.remove(vm));
    let _ = crate::viewer::send_to(vm, &json!({ "type": "agent-watch", "on": false }));
    pause_for_control(app, vm, &client).await
}

async fn pause_for_control(app: &AppHandle, vm: &str, client: &Value) -> Result<(), String> {
    let id = client["id"].as_str().unwrap_or("").to_string();
    call(app, "Suspend-GpuVMAgent", json!({ "Connection": id, "Reason": "control", "Message": "You took control" })).await?;
    crate::status::set(app, vm, "agent", Some(json!({ "kind": "control", "client": id, "clientName": client["name"] })));
    lock(&STATUS).get_or_insert_with(HashMap::new).insert(vm.to_string(), ("control".into(), id));
    crate::live::clear(app, vm);
    let _ = app.emit("agents-changed", json!({}));
    Ok(())
}

#[derive(Clone, Copy)]
enum Rect {
    Picture,
    Top,
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
    crate::status::dock_changed(app);
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
    crate::status::dock_changed(app);
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

/// The dock's answer is for the request its page shows (`id`), which must still be the one docked: a newer request
/// that replaced it between the page's draw and the click is never answered by that click (security review).
fn docked_request(id: &str) -> Result<(Value, String, Instant), String> {
    let d = lock(&DOCKED);
    let d = d.as_ref().ok_or("The request already closed.")?;
    if id.is_empty() || d.request["id"].as_str() != Some(id) {
        return Err("That request changed. Look again before answering.".into());
    }
    Ok((d.request.clone(), d.vm.clone(), d.shown))
}

/// Allow for this task covers later requests of the same kind; a copy from the PC names one exact path, so it is
/// answered one at a time.
fn task_allowed(request: &Value) -> bool {
    request["kind"].as_str() != Some("send")
}

/// A copy from the PC is allowed only when its exact path was there to show (the page shows it, the person reads it).
fn send_shown(request: &Value) -> bool {
    if request["kind"].as_str() != Some("send") {
        return true;
    }
    send_paths(request).next().is_some()
}

/// The exact paths of a "send" request (Get-GpuVMAgentRequest: `paths`), blank ones left out.
fn send_paths(request: &Value) -> impl Iterator<Item = &str> {
    request["paths"].as_array().into_iter().flatten().filter_map(Value::as_str).filter(|p| !p.trim().is_empty())
}

/// Allow / Refuse (and, from its right click, Allow for this task) in the dock. Only which button, for the request
/// whose id the page shows: the request is the one this app put there.
#[tauri::command]
pub async fn agent_dock_answer(app: AppHandle, id: String, allow: bool, for_task: bool) -> Result<(), String> {
    let request = {
        let (request, _, shown) = docked_request(&id)?;
        if request["human"].as_bool() == Some(true) {
            return Err("Only you can do this, in the machine.".into());
        }
        if shown.elapsed() < ARM {
            return Err("The request just appeared.".into());
        }
        if for_task && !task_allowed(&request) {
            return Err("This one is answered on its own.".into());
        }
        if allow && !send_shown(&request) {
            return Err("It doesn't say what it would copy.".into());
        }
        request
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

/// Return to agent, from the dock of what only the person could do (request_human): they did it in the machine, the
/// agent goes on.
#[tauri::command]
pub async fn agent_dock_resume(app: AppHandle, id: String) -> Result<(), String> {
    let (client, vm) = {
        let (request, vm, _) = docked_request(&id)?;
        if request["human"].as_bool() != Some(true) {
            return Err("Answer it with its buttons.".into());
        }
        (request["client"].as_str().unwrap_or("").to_string(), vm)
    };
    resume(&app, &client, &vm).await?;
    hide_dock(&app);
    Ok(())
}

/// The request the dock shows, for its page when it loads.
#[tauri::command]
pub fn agent_dock_request() -> Value {
    lock(&DOCKED).as_ref().map(|d| d.request.clone()).unwrap_or(Value::Null)
}

/* ---------- take control ---------- */

/// What the status notch says about each machine's agent: the person has it, or it's paused. Changed only when it
/// changes, so the notch isn't redrawn every poll.
fn sync_status(app: &AppHandle, clients: &[Value]) {
    let now: HashMap<String, (String, String, Value)> = clients.iter()
        .filter(|c| c["state"] == "control" || c["state"] == "paused")
        .filter_map(|c| Some((c["machine"].as_str()?.to_string(), (c["state"].as_str()?.to_string(), c["id"].as_str().unwrap_or("").to_string(), c["name"].clone()))))
        .collect();
    let mut last = lock(&STATUS);
    let last = last.get_or_insert_with(HashMap::new);
    for vm in last.keys().filter(|vm| !now.contains_key(*vm)).cloned().collect::<Vec<_>>() {
        crate::status::set(app, &vm, "agent", None);
        last.remove(&vm);
    }
    for (vm, (state, id, name)) in now {
        if last.get(&vm) == Some(&(state.clone(), id.clone())) {
            continue;
        }
        crate::status::set(app, &vm, "agent", Some(json!({ "kind": state, "client": id, "clientName": name })));
        last.insert(vm, (state, id));
    }
}

/// The machine whose agent dock is down now (a top-center status notch sits under it).
pub fn docked_vm() -> Option<String> {
    lock(&DOCKED).as_ref().map(|d| d.vm.clone())
}

/// Return to agent / Resume, from the status notch or the dock: the broker gives that one machine back (Name and
/// Connection: a session holding several machines gets back only this one, never the one the person still has), with
/// a fresh screenshot and a note that the person had control.
pub async fn resume(app: &AppHandle, client: &str, vm: &str) -> Result<(), String> {
    // A pause whose session is gone (the service clears orphans) resumes by Name alone.
    if vm.is_empty() {
        return Err("The agent isn't valid.".into());
    }
    call(app, "Resume-GpuVMAgent", resume_args(client, vm)).await?;
    lock(&STATUS).as_mut().map(|s| s.remove(vm));
    crate::status::set(app, vm, "agent", None);
    let _ = app.emit("agents-changed", json!({}));
    Ok(())
}

fn resume_args(client: &str, vm: &str) -> Value {
    if client.is_empty() { json!({ "Name": vm }) } else { json!({ "Name": vm, "Connection": client }) }
}

/// The viewer saw the person's input over the picture: the agent working there pauses (take control).
pub fn on_input(app: &AppHandle, vm: &str) {
    // The viewer stopped watching when it reported (its next input reaches the machine): forgotten here too, so the
    // next poll turns it back on if the agent isn't paused below (the viewer still settling, a second press).
    if !TAKE_ON_INPUT.load(Ordering::Relaxed) || !lock(&WATCHING).as_mut().is_some_and(|w| w.remove(vm)) {
        return;
    }
    if lock(&SHOWN_AT).as_ref().and_then(|s| s.get(vm)).is_some_and(|t| t.elapsed() < VIEWER_SETTLE) {
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
    let Some(client) = lock(&CLIENTS).iter().find(|c| c["machine"].as_str() == Some(vm) && holds(c)).cloned() else { return };
    let started = Instant::now();
    let app = app.clone();
    let vm = vm.to_string();
    tauri::async_runtime::spawn(async move {
        let result = pause_for_control(&app, &vm, &client).await;
        // The time from the viewer's report to the broker's answer (the app's log).
        eprintln!("agent take-control {vm} paused in {} ms ({})", started.elapsed().as_millis(), if result.is_ok() { "ok" } else { "failed" });
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
        }
        "closed" | "ended" => {
            if lock(&DOCKED).as_ref().is_some_and(|d| d.vm == vm) {
                *lock(&DOCKED) = None;
                if let Some(w) = app.get_webview_window(DOCK) {
                    let _ = w.destroy();
                }
            }
            lock(&STATUS).as_mut().map(|s| s.remove(vm));
            lock(&WATCHING).as_mut().map(|w| w.remove(vm));
        }
        _ => {}
    }
}

/* ---------- the guest's repaint (ddx) ---------- */

/// When each machine's last burst was asked for: one at a time (a burst lasts 10 s).
static BURSTS: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);

/// screen.refresh as a burst (every 250 ms for 10 s, agent 0.4.5+) on an agent machine, as its viewer starts or comes
/// out: with ddx a still desktop sends no frame, and a single repaint got lost while Sunshine restarted capture
/// (agent-broker, labs/052: picture on opening 9/10, median 0.84 s; asked late, at "connected", it did worse). Any
/// machine is asked: one without the agent says so and nothing happens. Lab 054's switch
/// (GPUVM_LAB_NO_SCREEN_REFRESH=1) leaves it out, to measure it.
pub fn refresh_burst(app: &AppHandle, vm: &str) {
    // The picture is showing now (open, reveal, back to it): its viewer settles first (it takes the mouse and moves the
    // pointer as its window appears), which isn't the person taking control.
    lock(&SHOWN_AT).get_or_insert_with(HashMap::new).insert(vm.to_string(), Instant::now());
    if vm.is_empty() || std::env::var("GPUVM_LAB_NO_SCREEN_REFRESH").is_ok_and(|v| v == "1") {
        return;
    }
    {
        let mut b = lock(&BURSTS);
        let b = b.get_or_insert_with(HashMap::new);
        if b.get(vm).is_some_and(|t| t.elapsed() < Duration::from_secs(5)) {
            return;
        }
        b.insert(vm.to_string(), Instant::now());
    }
    let app = app.clone();
    let vm = vm.to_string();
    tauri::async_runtime::spawn(async move {
        let _ = call(&app, "Invoke-GpuVMAgent", json!({ "Name": vm, "Method": "screen.refresh", "Params": { "repeatMs": 10000 }, "TimeoutSec": 15 })).await;
    });
}

/* ---------- deliveries being copied ---------- */

/// Deliveries followed (offer id -> machine, the state the last poll saw, and when its result went up): Resolve-
/// GpuVMAgentOffer answers "copying" and the copy ends in the background, accepted or failed (Get-GpuVMAgentOffer).
/// A small file is often done before the next poll (lab 054: pending, then accepted), so the result shows for any
/// offer that leaves pending or copying, not only for one seen copying.
static COPIES: Mutex<Option<HashMap<String, Delivery>>> = Mutex::new(None);

struct Delivery {
    vm: String,
    state: String,
    shown_at: Option<Instant>,
}
/// How long the result stays on the notch.
const COPY_RESULT: Duration = Duration::from_secs(6);

/// What the notch says about one delivery, from its offer: None once there is nothing to say.
fn copy_notice(offer: &Value) -> Option<Value> {
    let state = offer["state"].as_str()?;
    if !matches!(state, "copying" | "accepted" | "failed") {
        return None;
    }
    Some(json!({ "kind": "copy", "state": state, "name": offer["name"], "error": offer["error"] }))
}

/// What the notch does about one delivery between two polls: show "copying", show its result, or nothing.
fn copy_step(before: Option<&str>, now: &str) -> Option<&'static str> {
    match (before, now) {
        (Some("copying"), "copying") => None,
        (_, "copying") => Some("copying"),
        (Some("pending" | "copying"), "accepted" | "failed") => Some("result"),
        _ => None,
    }
}

fn sync_copies(app: &AppHandle, offers: &[Value]) {
    let mut copies = lock(&COPIES);
    let copies = copies.get_or_insert_with(HashMap::new);
    for o in offers {
        let (Some(id), Some(vm)) = (o["id"].as_str(), o["machine"].as_str().filter(|m| !m.is_empty())) else { continue };
        let state = o["state"].as_str().unwrap_or("");
        let before = copies.get(id).map(|c| c.state.clone());
        let key = format!("copy:{id}");
        match copy_step(before.as_deref(), state) {
            Some("copying") => crate::status::set(app, vm, &key, copy_notice(o)),
            Some(_) => {
                crate::status::set(app, vm, &key, copy_notice(o));
                copies.insert(id.to_string(), Delivery { vm: vm.to_string(), state: state.to_string(), shown_at: Some(Instant::now()) });
                continue;
            }
            None => {}
        }
        let shown_at = copies.get(id).and_then(|c| c.shown_at);
        copies.insert(id.to_string(), Delivery { vm: vm.to_string(), state: state.to_string(), shown_at });
    }
    // Results shown long enough, and deliveries no longer listed, leave the notch.
    let live: HashSet<&str> = offers.iter().filter_map(|o| o["id"].as_str()).collect();
    let gone: Vec<(String, String, bool)> = copies.iter()
        .filter(|(id, c)| !live.contains(id.as_str()) || c.shown_at.is_some_and(|t| t.elapsed() > COPY_RESULT))
        .map(|(id, c)| (id.clone(), c.vm.clone(), live.contains(id.as_str()))).collect();
    for (id, vm, still_listed) in gone {
        crate::status::set(app, &vm, &format!("copy:{id}"), None);
        if still_listed {
            // Done showing; remembered as finished so it never shows again.
            if let Some(c) = copies.get_mut(&id) { c.shown_at = None; c.state = "done".into(); }
        } else {
            copies.remove(&id);
        }
    }
}

/* ---------- recording an agent's work ---------- */

/// A machine an agent works on is recorded from when it takes it until it lets it go (The person's option B): with the
/// person's viewer if it is open, else a viewer GpuVM opens hidden (viewer::open_background). The file goes to the
/// usual Videos\GpuVM\<machine> and is linked from the agent's session.
struct Rec {
    client: String,
    client_name: Value,
    /// GpuVM opened that viewer for this: it closes it afterwards if the person never opened the machine.
    ours: bool,
    /// The agent let go: waiting for the file, then (ours, still hidden) the viewer closes.
    stopping: Option<Instant>,
    opening: bool,
    /// The viewer said it records. Until then "record" is sent again each round: a viewer just opened has no picture
    /// yet and refuses it ("no-stream"), which left the hidden viewer recording nothing (lab 054, 2026-11-19).
    confirmed: bool,
}
static RECS: Mutex<Option<HashMap<String, Rec>>> = Mutex::new(None);
/// Recordings of agents' work, newest last: what the Agents page and the machine's Agent section link to.
static RECORDINGS: Mutex<Vec<Value>> = Mutex::new(Vec::new());

fn sync_recordings(app: &AppHandle, clients: &[Value]) {
    // Held, idle included: an agent thinking for 15 s used to cut the recording and close the hidden viewer, which
    // then took minutes to open again (lab 054: three files per run).
    let taken: HashMap<String, (String, Value)> = clients.iter()
        .filter(|c| !matches!(c["state"].as_str(), Some("stopped") | None))
        .filter_map(|c| Some((c["machine"].as_str()?.to_string(), (c["id"].as_str().unwrap_or("").to_string(), c["name"].clone()))))
        .collect();
    let mut recs = lock(&RECS);
    let recs = recs.get_or_insert_with(HashMap::new);
    // The agent let go (or its session ended): recording stops; the file links when it arrives (on_capture_saved).
    for (vm, rec) in recs.iter_mut().filter(|(vm, r)| !taken.contains_key(*vm) && r.stopping.is_none() && !r.opening) {
        let _ = crate::viewer::send_to(vm, &json!({ "type": "record", "on": false }));
        rec.stopping = Some(Instant::now());
    }
    // A stopping one whose file never came (no viewer any more, a failure): forgotten after a while, its viewer closed.
    let late: Vec<String> = recs.iter().filter(|(_, r)| r.stopping.is_some_and(|t| t.elapsed() > Duration::from_secs(20))).map(|(vm, _)| vm.clone()).collect();
    for vm in late {
        if let Some(r) = recs.remove(&vm) {
            close_if_ours(&vm, r.ours);
        }
    }
    // A viewer the person closed while the agent still works: it opens again (a new file) next round.
    recs.retain(|vm, r| r.opening || r.stopping.is_some() || crate::viewer::viewer_is_open(vm.clone()));
    // Not recording yet (no picture when asked): ask again.
    for (vm, rec) in recs.iter_mut().filter(|(_, r)| !r.opening && r.stopping.is_none() && !r.confirmed) {
        if crate::capture::is_recording(vm) {
            rec.confirmed = true;
        } else {
            let _ = crate::viewer::send_to(vm, &record_agent_work());
        }
    }
    for (vm, (client, name)) in taken {
        if recs.contains_key(&vm) {
            continue;
        }
        recs.insert(vm.clone(), Rec { client, client_name: name, ours: false, stopping: None, opening: true, confirmed: false });
        let app = app.clone();
        tauri::async_runtime::spawn(async move { start_recording(&app, &vm).await });
    }
}

/// The viewer's command to record an agent's work. Light: the viewer re-encodes it as H.264 at 30 fps and constant
/// quality instead of keeping the 180 fps stream (~160 MB per minute, ~10 GB per hour): 10-35x smaller, and every
/// Windows player opens it (lab 061). What the person sees live doesn't change; their own recordings keep the stream.
fn record_agent_work() -> Value {
    json!({ "type": "record", "on": true, "light": true })
}

async fn start_recording(app: &AppHandle, vm: &str) {
    let mut ours = false;
    if !crate::viewer::viewer_is_open(vm.to_string()) {
        // The machine's own opening (Connect-GpuVM, as its Open button), without showing anything.
        let vm2 = vm.to_string();
        let app2 = app.clone();
        let opened = tauri::async_runtime::spawn_blocking(move || -> Result<bool, String> {
            // After any other opening of this machine (the person's Open) has finished: its viewer is then reused.
            let lock = crate::viewer::opening_lock(&vm2);
            let _opening = lock.lock().unwrap_or_else(|e| e.into_inner());
            if crate::viewer::viewer_is_open(vm2.clone()) {
                return Ok(false);
            }
            let mut conn = crate::backend::connect()?;
            let request = json!({ "id": format!("agent-rec-{vm2}"), "cmd": "Connect-GpuVM", "args": { "Name": vm2, "Viewer": true } });
            let result = conn.call(&request, |_| {})?;
            if result["ok"] != true {
                return Err(result["error"].as_str().unwrap_or("Couldn't open the machine.").to_string());
            }
            let launch = crate::viewer::launch_in(&result["data"]).ok_or("The machine didn't say how to open it.")?;
            crate::viewer::open_background(&app2, &vm2, &launch).map(|()| true)
        }).await.map_err(|e| e.to_string()).and_then(|r| r);
        match opened {
            Err(e) => {
                eprintln!("agent recording {vm}: couldn't open the viewer: {e}");
                lock(&RECS).as_mut().map(|r| r.remove(vm));
                return;
            }
            // The person's opening got there first: their viewer records.
            Ok(false) => {}
            Ok(true) => ours = true,
        }
    }
    let started = crate::viewer::send_to(vm, &record_agent_work()).is_ok();
    let mut recs = lock(&RECS);
    if let Some(r) = recs.as_mut().and_then(|r| r.get_mut(vm)) {
        r.ours = ours;
        r.opening = false;
        if !started {
            r.stopping = Some(Instant::now());
        }
    }
}

/// The machine's viewer was opened again in its place (no picture after connecting, viewer.rs): the new one is asked
/// to record, as the first was.
pub fn viewer_replaced(vm: &str) {
    if let Some(r) = lock(&RECS).as_mut().and_then(|r| r.get_mut(vm)) {
        r.confirmed = false;
    }
}

fn close_if_ours(vm: &str, ours: bool) {
    // Only a viewer GpuVM opened and the person never brought out.
    if ours && crate::viewer::background(vm) && !crate::viewer::viewer_visible(vm) {
        let _ = crate::viewer::send_to(vm, &json!({ "type": "quit" }));
    }
}

/// A capture of a machine was saved (capture.rs): a recording of an agent's work links to its session, and the
/// viewer GpuVM opened for it closes.
pub fn on_capture_saved(app: &AppHandle, vm: &str, saved: &Value) {
    if saved["kind"] != "recording" && saved["kind"] != "clip" {
        return;
    }
    let rec = {
        let mut recs = lock(&RECS);
        let recs = recs.get_or_insert_with(HashMap::new);
        match recs.get(vm) {
            Some(r) if r.stopping.is_some() => recs.remove(vm),
            // Still working: a file cut by the viewer (the stream changed) links too, and recording goes on.
            Some(r) => Some(Rec { client: r.client.clone(), client_name: r.client_name.clone(), ours: false, stopping: None, opening: false, confirmed: true }),
            None => None,
        }
    };
    let Some(rec) = rec else { return };
    let mut list = lock(&RECORDINGS);
    list.push(json!({ "machine": vm, "client": rec.client, "clientName": rec.client_name, "path": saved["path"], "name": saved["name"],
        "durationMs": saved["durationMs"], "bytes": saved["bytes"], "at": saved["at"] }));
    if list.len() > 50 {
        list.remove(0);
    }
    drop(list);
    if rec.stopping.is_some() {
        close_if_ours(vm, rec.ours);
    }
    let _ = app.emit("agents-changed", json!({}));
}

/// The recordings of agents' work, for the pages (agents-state carries them too).
#[tauri::command]
pub fn agent_recordings() -> Value {
    recordings()
}

pub fn recordings() -> Value {
    Value::Array(lock(&RECORDINGS).clone())
}

/* ---------- preferences ---------- */

/// Settings › Agents: how the person takes control. The time to answer is not here: it is the service's own setting,
/// written only when the person moves it in Settings (this ran at every start and once overwrote it with a stale 30 s).
#[tauri::command]
pub fn set_agent_prefs(take_control: String) -> Result<(), String> {
    TAKE_ON_INPUT.store(take_control != "button", Ordering::Relaxed);
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

/// A Windows notification that a request waits, or that the agent needs the person (request_human). Its only action,
/// View, opens that machine's picture in GpuVM, where the request drops as its dock: answering is done there (a GpuVM
/// window), never from the notification.
fn notify(app: &AppHandle, request: &Value) {
    let who = request["clientName"].as_str().unwrap_or("An agent");
    let what = request["title"].as_str().unwrap_or("");
    let vm = request["machine"].as_str().unwrap_or("").to_string();
    let human = request["human"].as_bool() == Some(true);
    let paths: Vec<&str> = send_paths(request).collect();
    let send_body = match paths.len() {
        0 => String::new(),
        1 => paths[0].to_string(),
        n => tr(&format!("{} and {} more", paths[0], n - 1), &format!("{} y {} más", paths[0], n - 1)),
    };
    let (title, body) = if human {
        // The agent's own words: what it needs the person to do.
        (tr(&format!("{who} needs you"), &format!("{who} te necesita")), format!("{} · {vm}", spanish_or(what)))
    } else if request["kind"].as_str() == Some("send") {
        // What it would copy from this PC, by its exact path (answered only in GpuVM).
        (tr(&format!("{who} wants to copy to {vm}"), &format!("{who} quiere copiar a {vm}")), send_body)
    } else if english() {
        (format!("{who} asks: {what}"), format!("{vm} · Waiting for your answer"))
    } else {
        (format!("{who} pide: {}", spanish_title(what)), format!("{vm} · Espera tu respuesta"))
    };
    let view = tr("View", "Ver");
    let app2 = app.clone();
    // View: what only the person can do is done in the machine (its picture); a request to answer opens GpuVM on
    // Agents, where its card waits with Allow and Refuse (the dock drops there too once its picture is open).
    let target = if human { vm } else { String::new() };
    let _ = app.run_on_main_thread(move || {
        if let Err(e) = toast::show(&title, &body, &view, move || open_viewer(&app2, &target)) {
            eprintln!("agent notification: {e}");
        }
    });
}

/// A human request's message is the agent's own words, except the broker's usual ones (said in Spanish).
fn spanish_or(text: &str) -> String {
    if english() {
        return text.to_string();
    }
    match text {
        "Windows asks for a password" => "Windows pide una contraseña".into(),
        "Windows asks for administrator permission" => "Windows pide permiso de administrador".into(),
        "Windows needs you" => "Windows te necesita".into(),
        other => other.to_string(),
    }
}

/// View: GpuVM comes forward and opens that machine's picture, as its Open button (gpuvm.exe --view does the same).
fn open_viewer(app: &AppHandle, vm: &str) {
    crate::show_main(app);
    if let Some(w) = app.get_webview_window("main") {
        if vm.is_empty() {
            let _ = w.emit("open-route", ":agents");
        } else {
            let _ = w.emit("open-viewer", vm);
        }
    }
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


#[cfg(test)]
mod tests {
    use super::*;

    fn client(machine: &str, state: &str) -> Value {
        json!({ "id": "c1", "name": "lab", "machine": machine, "state": state })
    }

    #[test]
    fn agent_work_is_recorded_light() {
        let m = record_agent_work();
        assert_eq!(m["type"], "record");
        assert_eq!(m["on"], true);
        // The viewer re-encodes it small (lab 061); without the flag it keeps the full stream.
        assert_eq!(m["light"], true);
    }

    #[test]
    fn view_opens_only_machines_a_live_session_holds() {
        let clients = vec![client("lab054-1", "idle"), client("win-gpu-x", "stopped")];
        assert!(held_by_agent(&clients, "lab054-1"));
        assert!(held_by_agent(&clients, "LAB054-1"));
        // A stopped session, another name, no session at all: never.
        assert!(!held_by_agent(&clients, "win-gpu-x"));
        assert!(!held_by_agent(&clients, "win-gpu"));
        assert!(!held_by_agent(&[], "lab054-1"));
        assert!(!held_by_agent(&[json!({ "id": "c2", "machine": null, "state": "working" })], "lab054-1"));
    }

    #[test]
    fn take_control_watches_working_and_idle_only() {
        assert!(holds(&client("m", "working")));
        assert!(holds(&client("m", "idle")));
        assert!(holds(&client("m", "waiting")));
        for s in ["control", "paused", "human", "stopped"] {
            assert!(!holds(&client("m", s)), "{s}");
        }
        assert!(!holds(&json!({ "machine": null, "state": "working" })));
    }

    #[test]
    fn dock_answers_only_the_request_it_shows() {
        *lock(&DOCKED) = Some(Docked { vm: "m".into(), request: json!({ "id": "r2", "kind": "network" }), shown: Instant::now() });
        assert!(docked_request("r2").is_ok());
        assert!(docked_request("r1").is_err()); // the page drew r1, r2 replaced it
        assert!(docked_request("").is_err());
        *lock(&DOCKED) = None;
        assert!(docked_request("r2").is_err());
    }

    #[test]
    fn a_copy_from_the_pc_is_answered_one_at_a_time_and_only_with_its_path() {
        // The broker's shape (Get-GpuVMAgentRequest): paths, files, bytes.
        let send = json!({ "id": "s", "kind": "send", "paths": ["C:\\Users\\a\\file.zip"], "files": 1, "bytes": 10 });
        assert!(!task_allowed(&send));
        assert!(send_shown(&send));
        assert!(!send_shown(&json!({ "kind": "send" })));
        assert!(!send_shown(&json!({ "kind": "send", "paths": [] })));
        assert!(!send_shown(&json!({ "kind": "send", "paths": ["  ", 3] })));
        assert!(task_allowed(&json!({ "kind": "network" })));
        assert!(send_shown(&json!({ "kind": "network" })));
    }

    #[test]
    fn a_delivery_shows_copying_then_its_result() {
        let o = |state: &str| json!({ "id": "o1", "machine": "m", "name": "report.md", "state": state, "error": if state == "failed" { json!("Disk full") } else { Value::Null } });
        assert_eq!(copy_notice(&o("copying")).unwrap()["state"], "copying");
        assert_eq!(copy_notice(&o("accepted")).unwrap()["name"], "report.md");
        assert_eq!(copy_notice(&o("failed")).unwrap()["error"], "Disk full");
        for s in ["pending", "refused", "expired", ""] {
            assert!(copy_notice(&o(s)).is_none(), "{s}");
        }
        // A small file done between two polls still shows its result; a finished one shows nothing again.
        assert_eq!(copy_step(Some("pending"), "accepted"), Some("result"));
        assert_eq!(copy_step(Some("pending"), "copying"), Some("copying"));
        assert_eq!(copy_step(Some("copying"), "copying"), None);
        assert_eq!(copy_step(Some("copying"), "failed"), Some("result"));
        assert_eq!(copy_step(None, "accepted"), None); // already finished when GpuVM started
        assert_eq!(copy_step(Some("done"), "accepted"), None);
        assert_eq!(copy_step(Some("pending"), "refused"), None);
    }

    #[test]
    fn return_to_agent_names_the_machine() {
        assert_eq!(resume_args("c1", "lab054-1"), json!({ "Name": "lab054-1", "Connection": "c1" }));
        // A pause left without a session: by Name alone.
        assert_eq!(resume_args("", "lab054-1"), json!({ "Name": "lab054-1" }));
    }
}