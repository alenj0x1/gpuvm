//! The status notch: one place over a machine's picture for everything that only tells the person how things are
//! (recording and its time, "Screenshot saved", "You took control", "Claude Code paused"). Requests and approvals
//! drop from the top as docks (dock.rs, agent.rs); status lives here, at the bottom center by default, or where the
//! person put it (Settings › Appearance): top center, a top corner, or only in the side panel.
//!
//! - One window of this app, owned by the viewer, exactly the size of its notch: nothing around it takes the clicks
//!   meant for the picture. Several notices stack inside it, newest nearest the edge.
//! - At the top center it gives way to a dock: while one is down over the same picture it slides to sit just under it,
//!   and slides back when the dock goes up.
//! - The viewer only names what happened (a fixed key, "recording" on/off); the texts are the app's. A viewer that sends
//!   anything else is ignored.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "status-notch";
/// What the viewer may name ("notice"): the app has the texts.
const NOTICES: &[&str] = &["shot", "recording", "replay", "replay-off", "disk-full", "error"];
const NOTICE_MS: u64 = 2500;
/// A dock's size over the picture until its page reports the real one (dockSize.ts), in logical pixels.
const DOCK_DEFAULT: (f64, f64) = (540.0, 60.0);
/// Space between the notch and the picture's edge in a corner.
const CORNER_GAP: f64 = 12.0;

struct State {
    /// Per machine: its notices, by id ("recording", "control", "paused", "notice:<n>").
    items: HashMap<String, Vec<Value>>,
    placement: String,
    /// Its distance from the picture's edge, and where the docks drop and theirs (logical px; Settings › Appearance).
    gap: f64,
    dock_spot: String,
    dock_gap: f64,
    /// The notch's size as its page measured it (logical pixels).
    size: (f64, f64),
    /// The machine the window shows now, and whether it sits under a dock.
    shown: Option<String>,
    under_dock: bool,
    next: u64,
    /// The open dock's size as its page measured it.
    dock: (f64, f64),
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut g = STATE.lock().unwrap_or_else(|e| e.into_inner());
    let s = g.get_or_insert_with(|| State { items: HashMap::new(), placement: "bottom".into(), gap: 52.0, dock_spot: "top".into(), dock_gap: 0.0, size: (0.0, 0.0), shown: None, under_dock: false, next: 1, dock: DOCK_DEFAULT });
    f(s)
}

/// Puts (or replaces) a lasting notice of a machine, or takes it away with None.
pub fn set(app: &AppHandle, vm: &str, id: &str, item: Option<Value>) {
    with(|s| {
        let list = s.items.entry(vm.to_string()).or_default();
        list.retain(|i| i["id"] != id);
        if let Some(mut item) = item {
            item["id"] = json!(id);
            list.push(item);
        }
    });
    refresh(app);
}

/// A notice for a moment ("Screenshot saved").
pub fn flash(app: &AppHandle, vm: &str, key: &str) {
    if !NOTICES.contains(&key) {
        return;
    }
    let id = with(|s| {
        s.next += 1;
        let id = format!("notice:{}", s.next);
        let list = s.items.entry(vm.to_string()).or_default();
        // The same notice again replaces the last one instead of piling up.
        list.retain(|i| i["key"] != key);
        list.push(json!({ "id": id, "kind": "notice", "key": key }));
        // At most four at once: the oldest moment-notices go first.
        while list.len() > 4 {
            if let Some(k) = list.iter().position(|i| i["kind"] == "notice") { list.remove(k); } else { break; }
        }
        id
    });
    refresh(app);
    let app = app.clone();
    let vm = vm.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(NOTICE_MS));
        with(|s| { if let Some(l) = s.items.get_mut(&vm) { l.retain(|i| i["id"] != id.as_str()); } });
        refresh(&app);
    });
}

/// What the viewer says about the picture's status.
pub fn on_viewer(app: &AppHandle, vm: &str, msg: &Value) {
    match msg["type"].as_str().unwrap_or("") {
        "recording" => {
            let on = msg["on"].as_bool().unwrap_or(false);
            set(app, vm, "recording", on.then(|| json!({ "kind": "recording", "since": now_ms() })));
        }
        "notice" => flash(app, vm, msg["key"].as_str().unwrap_or("")),
        "window" | "panel" => refresh(app),
        "closed" | "ended" => {
            with(|s| { s.items.remove(vm); });
            refresh(app);
        }
        _ => {}
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The machine whose picture is in view and has something to say, and what.
fn current() -> Option<(String, Vec<Value>, String)> {
    with(|s| {
        s.items.iter().filter(|(_, l)| !l.is_empty())
            .find(|(vm, _)| crate::dock::wants(vm))
            .map(|(vm, l)| (vm.clone(), l.clone(), s.placement.clone()))
    })
}

/// Shows, updates or hides the notch, and tells the side panel (it shows them when placed there).
pub fn refresh(app: &AppHandle) {
    let now = current();
    let payload = now.as_ref().map(|(vm, items, placement)| json!({ "vm": vm, "items": items, "placement": placement }));
    let _ = app.emit("status-items", payload.clone().unwrap_or(json!({ "vm": Value::Null, "items": [] })));
    let in_panel = now.as_ref().is_some_and(|(_, _, p)| p == "panel");
    let Some((vm, _, _)) = now.filter(|_| !in_panel) else {
        with(|s| s.shown = None);
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.emit("status-notch", json!(null));
            let app = app.clone();
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(320));
                if with(|s| s.shown.is_none()) {
                    if let Some(w) = app.get_webview_window(LABEL) {
                        let _ = w.destroy();
                    }
                }
            });
        }
        return;
    };
    let switched = with(|s| { let other = s.shown.as_deref() != Some(&vm); s.shown = Some(vm.clone()); other });
    let window = match app.get_webview_window(LABEL) {
        Some(w) if !switched => w,
        existing => {
            if let Some(w) = existing {
                let _ = w.destroy();
            }
            let Ok(w) = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into()))
                .title("GpuVM").decorations(false).transparent(true).shadow(false).resizable(false)
                .skip_taskbar(true).focused(false).visible(false).build() else { return };
            with(|s| s.size = (0.0, 0.0));
            w
        }
    };
    let _ = window.emit("status-notch", payload);
    place(app, &window, &vm, false);
}

/// The notch window trimmed one pixel in from every edge: on Windows 10 a transparent WebView2 window showed a 1px grey
/// line around its rectangle (2026-11-21, around "Recording"). The rounded corners are the CSS's own, smooth: a window
/// region cut them to the pixel, and they looked jagged ("los bordes salen como rotos", 2026-11-21).
fn shape(hwnd: HWND, w: i32, h: i32, _radius: i32, _placement: &str) {
    use windows_sys::Win32::Graphics::Gdi::{CreateRectRgn, DeleteObject, SetWindowRgn};
    // SAFETY: a GDI region this function creates; once given to SetWindowRgn it belongs to the window.
    unsafe {
        let rect = CreateRectRgn(1, 1, w - 1, h - 1);
        if SetWindowRgn(hwnd, rect, 1) == 0 {
            DeleteObject(rect);
        }
    }
}

/// Where the notch goes over the picture, for its placement and size; at the top center, under a dock that is down.
fn place(app: &AppHandle, window: &tauri::WebviewWindow, vm: &str, slide: bool) {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return };
    let Some((x, y, w, h, scale)) = crate::overlay::client_rect(viewer) else { return };
    let w = w - crate::overlay::open_width(app, vm).unwrap_or(0).min(w / 2);
    let (placement, (lw, lh)) = with(|s| (s.placement.clone(), s.size));
    if lw <= 0.0 || lh <= 0.0 {
        // Not measured yet: the page asks to be sized as soon as it has drawn (status_resize).
        let _ = window.set_size(PhysicalSize::new(1, 1));
        return;
    }
    let (nw, nh) = (((lw * scale) as i32).min(w), (lh * scale) as i32);
    let (gap_l, dock_spot, dock_gap_l) = with(|s| (s.gap, s.dock_spot.clone(), s.dock_gap));
    let gap = (gap_l * scale) as i32;
    let side = if gap > 0 { (CORNER_GAP * scale) as i32 } else { 0 };
    let docked = crate::dock::current_vm().as_deref() == Some(vm) || crate::agent::docked_vm().as_deref() == Some(vm);
    let at = |spot: &str, bw: i32, bh: i32, g: i32, sd: i32| -> (i32, i32) {
        let px = if spot.ends_with("left") { x + sd } else if spot.ends_with("right") { x + w - bw - sd } else { x + (w - bw) / 2 };
        let py = if spot.starts_with("bottom") { y + h - bh - g } else { y + g };
        (px, py)
    };
    let (px, mut py) = at(&placement, nw, nh, gap, side);
    // The dock has priority: a notch that would touch it moves out of its way, just past it (away from that edge).
    let (dw, dh) = with(|s| s.dock);
    let (dw, dh) = (((dw * scale) as i32).min(w), (dh * scale) as i32);
    let dgap = (dock_gap_l * scale) as i32;
    let (dx, dy) = at(&dock_spot, dw, dh, dgap, if dgap > 0 { (16.0 * scale) as i32 } else { 0 });
    let touches = px < dx + dw && dx < px + nw && py < dy + dh && dy < py + nh;
    let under = docked && touches;
    if under {
        py = if dock_spot.starts_with("bottom") { dy - nh - (6.0 * scale) as i32 } else { dy + dh + (6.0 * scale) as i32 };
    }
    let was_under = with(|s| std::mem::replace(&mut s.under_dock, under));
    let _ = window.set_size(PhysicalSize::new(nw.max(1) as u32, nh.max(1) as u32));
    if let Ok(own) = window.hwnd() {
        // SAFETY: the viewer becomes the window's owner, so the notch stays just above the picture and moves with it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
        shape(own.0 as HWND, nw, nh, (14.0 * scale) as i32, &placement);
    }
    if (slide || was_under != under) && window.is_visible().unwrap_or(false) {
        // It slides to its new place (with the dock's own drop), instead of jumping.
        let from = window.outer_position().map(|p| (p.x, p.y)).unwrap_or((px, py));
        let w2 = window.clone();
        std::thread::spawn(move || {
            let start = Instant::now();
            let dur = Duration::from_millis(320);
            loop {
                let t = (start.elapsed().as_secs_f64() / dur.as_secs_f64()).min(1.0);
                let e = 1.0 - (1.0 - t).powi(3);
                let nx = from.0 + ((px - from.0) as f64 * e) as i32;
                let ny = from.1 + ((py - from.1) as f64 * e) as i32;
                let _ = w2.set_position(PhysicalPosition::new(nx, ny));
                if t >= 1.0 { break; }
                std::thread::sleep(Duration::from_millis(12));
            }
        });
    } else {
        let _ = window.set_position(PhysicalPosition::new(px, py));
    }
    if !window.is_visible().unwrap_or(false) {
        // Shown without taking the keyboard: the person keeps typing into the machine.
        let _ = window.show();
        crate::overlay::mark_taskbar(window, crate::viewer::viewer_full_screen(vm));
    }
    let _ = window.emit("status-place", json!({ "placement": placement, "under": under }));
}

/// The docks report their real size (dockSize.ts): a notch near one moves exactly out of its way.
pub fn start(app: &AppHandle) {
    use tauri::Listener;
    let handle = app.clone();
    app.listen_any("dock-size", move |e| {
        let Ok(v) = serde_json::from_str::<Value>(e.payload()) else { return };
        let (w, h) = (v["width"].as_f64().unwrap_or(0.0), v["height"].as_f64().unwrap_or(0.0));
        if !(1.0..=2000.0).contains(&w) || !(1.0..=400.0).contains(&h) {
            return;
        }
        let changed = with(|s| { let c = s.dock != (w, h); s.dock = (w, h); c });
        if changed {
            dock_changed(&handle);
        }
    });
}

/// A dock went down or up over a machine's picture: a notch near it gets out of its way (or back).
pub fn dock_changed(app: &AppHandle) {
    let Some(vm) = with(|s| s.shown.clone()) else { return };
    if let Some(w) = app.get_webview_window(LABEL) {
        place(app, &w, &vm, true);
    }
}

/// The notch's page measured what it shows (logical pixels): the window takes exactly that.
#[tauri::command]
pub fn status_resize(app: AppHandle, width: f64, height: f64) {
    with(|s| s.size = (width.clamp(1.0, 900.0), height.clamp(1.0, 400.0)));
    let Some(vm) = with(|s| s.shown.clone()) else { return };
    if let Some(w) = app.get_webview_window(LABEL) {
        place(&app, &w, &vm, false);
    }
}

/// What the notch shows, for its page (and the side panel's) when it loads.
#[tauri::command]
pub fn status_state() -> Value {
    current().map(|(vm, items, placement)| json!({ "vm": vm, "items": items, "placement": placement })).unwrap_or(Value::Null)
}

/// A notice's button: "Return to agent" (control) or "Resume" (paused). Only the ones this app put there.
#[tauri::command]
pub async fn status_action(app: AppHandle, id: String) -> Result<(), String> {
    // The machine is the one the notice is on: only that machine goes back to its agent.
    // Ids repeat across machines ("live", "control"): the machine the notch is showing comes first.
    let (vm, item) = with(|s| {
        let find = |vm: &String| s.items.get(vm).and_then(|l| l.iter().find(|i| i["id"] == id.as_str())).map(|i| (vm.clone(), i.clone()));
        s.shown.as_ref().and_then(find).or_else(|| s.items.keys().find_map(find))
    }).ok_or("That notice already went.")?;
    match item["kind"].as_str().unwrap_or("") {
        "control" | "paused" => crate::agent::resume(&app, item["client"].as_str().unwrap_or(""), &vm).await,
        "live" => crate::agent::take_control(&app, &vm).await,
        _ => Err("This notice has no action.".into()),
    }
}

const SPOTS: &[&str] = &["top-left", "top", "top-right", "bottom-left", "bottom", "bottom-right"];

/// Where the docks drop (a spot) and how far from the picture's edge (logical px): the strip dock (agent.rs) and the
/// notch's way around them read it.
pub fn dock_placement() -> (String, f64) {
    with(|s| (s.dock_spot.clone(), s.dock_gap))
}

/// Settings › Appearance: where status notices go (a spot or the panel) and how far from the edge, and where requests
/// drop and how far from the edge.
#[tauri::command]
pub fn set_status_prefs(app: AppHandle, placement: String, gap: Option<f64>, dock: Option<String>, dock_gap: Option<f64>) {
    let placement = if SPOTS.contains(&placement.as_str()) || placement == "panel" { placement } else { "bottom".into() };
    let dock = dock.filter(|d| SPOTS.contains(&d.as_str())).unwrap_or_else(|| "top".into());
    let (gap, dock_gap) = (gap.unwrap_or(52.0).clamp(0.0, 160.0), dock_gap.unwrap_or(0.0).clamp(0.0, 160.0));
    with(|s| { s.gap = gap; s.dock_spot = dock; s.dock_gap = dock_gap; });
    let changed = with(|s| { let c = s.placement != placement; s.placement = placement; c });
    if changed {
        with(|s| s.size = (0.0, 0.0));
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.destroy();
        }
        with(|s| s.shown = None);
        refresh(&app);
    } else {
        // Same place, another distance (or the docks moved): placed again where it is.
        dock_changed(&app);
        if let (Some(vm), Some(w)) = (with(|s| s.shown.clone()), app.get_webview_window(LABEL)) {
            place(&app, &w, &vm, true);
        }
    }
}
