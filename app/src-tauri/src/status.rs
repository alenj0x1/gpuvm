use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, WebviewUrl, WebviewWindowBuilder};
use windows_sys::Win32::Foundation::HWND;
use windows_sys::Win32::UI::WindowsAndMessaging::{SetWindowLongPtrW, GWLP_HWNDPARENT};

pub const LABEL: &str = "status-notch";
const NOTICES: &[&str] = &["shot", "recording", "replay", "replay-off", "disk-full", "error"];
const NOTICE_MS: u64 = 2500;
const DOCK_DEFAULT: (f64, f64) = (540.0, 60.0);

struct State {
    items: HashMap<String, Vec<Value>>,
    placement: String,
    pos: (f64, f64),
    dock_pos: (f64, f64),
    size: (f64, f64),
    shown: Option<String>,
    under_dock: bool,
    next: u64,
    dock: (f64, f64),
}

static STATE: Mutex<Option<State>> = Mutex::new(None);

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    let mut g = STATE.lock().unwrap_or_else(|e| e.into_inner());
    let s = g.get_or_insert_with(|| State { items: HashMap::new(), placement: "picture".into(), pos: (0.5, 0.93), dock_pos: (0.5, 0.0), size: (0.0, 0.0), shown: None, under_dock: false, next: 1, dock: DOCK_DEFAULT });
    f(s)
}

pub fn set(app: &AppHandle, vm: &str, id: &str, item: Option<Value>) {
    crate::diag(&format!("notch set {vm} {id} {}", if item.is_some() { "on" } else { "off" }));
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

pub fn flash(app: &AppHandle, vm: &str, key: &str) {
    if !NOTICES.contains(&key) {
        return;
    }
    let id = with(|s| {
        s.next += 1;
        let id = format!("notice:{}", s.next);
        let list = s.items.entry(vm.to_string()).or_default();
        list.retain(|i| i["key"] != key);
        list.push(json!({ "id": id, "kind": "notice", "key": key }));
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

fn current() -> Option<(String, Vec<Value>, String)> {
    with(|s| {
        s.items.iter().filter(|(_, l)| !l.is_empty())
            .find(|(vm, _)| crate::dock::wants(vm))
            .map(|(vm, l)| (vm.clone(), l.clone(), s.placement.clone()))
    })
}

pub fn ensure(app: &AppHandle) {
    let want = current().map(|(vm, _, placement)| (vm, placement == "panel"));
    let shown = with(|s| s.shown.clone());
    let showing = shown.is_some() && app.get_webview_window(LABEL).is_some();
    match (&want, showing) {
        (Some((vm, false)), true) if shown.as_deref() == Some(vm.as_str()) => {}
        (None, false) | (Some((_, true)), false) => {}
        _ => refresh(app),
    }
}

pub fn refresh(app: &AppHandle) {
    let now = current();
    let payload = now.as_ref().map(|(vm, items, placement)| json!({ "vm": vm, "items": items, "placement": placement }));
    let _ = app.emit("status-items", payload.clone().unwrap_or(json!({ "vm": Value::Null, "items": [] })));
    let in_panel = now.as_ref().is_some_and(|(_, _, p)| p == "panel");
    if now.is_none() {
        let wants: Vec<String> = with(|s| s.items.iter().filter(|(_, l)| !l.is_empty()).map(|(vm, _)| format!("{vm} (visible {}, window {})", crate::viewer::viewer_visible(vm), crate::viewer::viewer_hwnd(vm).is_some())).collect());
        if !wants.is_empty() {
            crate::diag(&format!("notch refresh: nothing to show; notices for {}", wants.join(", ")));
        }
    }
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
    crate::diag(&format!("notch refresh: shows {vm}"));
    let switched = with(|s| { let other = s.shown.as_deref() != Some(&vm); s.shown = Some(vm.clone()); other });
    let window = match app.get_webview_window(LABEL) {
        Some(w) if !switched => w,
        existing => {
            if let Some(w) = existing {
                let _ = w.destroy();
            }
            let Ok(w) = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS)
                .title("GpuVM").decorations(false).transparent(true).shadow(false).resizable(false)
                .skip_taskbar(true).focused(false).visible(false).build() else { return };
            with(|s| s.size = (0.0, 0.0));
            w
        }
    };
    let _ = window.emit("status-notch", payload);
    place(app, &window, &vm, false);
}

// On Windows 10 a transparent WebView2 window shows pale: cut to the notch's shape (needs the frame off, or it gets a title bar).
fn shape(hwnd: HWND, w: i32, h: i32, radius: i32, (fx, fy): (f64, f64)) {
    use windows_sys::Win32::Graphics::Gdi::{CombineRgn, CreateRectRgn, CreateRoundRectRgn, DeleteObject, SetWindowRgn, RGN_OR};
    let (top, bottom, left, right) = (fy <= 0.001, fy >= 0.999, fx <= 0.001, fx >= 0.999);
    let r = radius.min(w / 2).min(h / 2).max(0);
    // SAFETY: GDI regions this function creates; the one given to SetWindowRgn belongs to the window afterwards.
    unsafe {
        let region = CreateRoundRectRgn(0, 0, w + 1, h + 1, r * 2, r * 2);
        for (square, (x0, y0)) in [(top || left, (0, 0)), (top || right, (w - r, 0)), (bottom || right, (w - r, h - r)), (bottom || left, (0, h - r))] {
            if square && r > 0 {
                let corner = CreateRectRgn(x0, y0, x0 + r, y0 + r);
                CombineRgn(region, region, corner, RGN_OR);
                DeleteObject(corner);
            }
        }
        if SetWindowRgn(hwnd, region, 1) == 0 {
            DeleteObject(region);
        }
    }
}

fn place(app: &AppHandle, window: &tauri::WebviewWindow, vm: &str, slide: bool) {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return };
    let Some((x, y, w, h, scale)) = crate::overlay::client_rect(viewer) else { return };
    let w = w - crate::overlay::open_width(app, vm).unwrap_or(0).min(w / 2);
    let (placement, (lw, lh)) = with(|s| (s.placement.clone(), s.size));
    if lw <= 0.0 || lh <= 0.0 {
        return;
    }
    let (nw, nh) = (((lw * scale) as i32).min(w), (lh * scale) as i32);
    let ((fx, fy), (dfx, dfy)) = with(|s| (s.pos, s.dock_pos));
    let docked = crate::dock::current_vm().as_deref() == Some(vm) || crate::agent::docked_vm().as_deref() == Some(vm);
    let at = |fx: f64, fy: f64, bw: i32, bh: i32| -> (i32, i32) { (x + ((w - bw).max(0) as f64 * fx).round() as i32, y + ((h - bh).max(0) as f64 * fy).round() as i32) };
    let (px, mut py) = at(fx, fy, nw, nh);
    let (dw, dh) = with(|s| s.dock);
    let (dw, dh) = (((dw * scale) as i32).min(w), (dh * scale) as i32);
    let (dx, dy) = at(dfx, dfy, dw, dh);
    let touches = px < dx + dw && dx < px + nw && py < dy + dh && dy < py + nh;
    let under = docked && touches;
    if under {
        py = if dfy > 0.5 { dy - nh - (6.0 * scale) as i32 } else { dy + dh + (6.0 * scale) as i32 };
    }
    let was_under = with(|s| std::mem::replace(&mut s.under_dock, under));
    let _ = window.set_size(PhysicalSize::new(nw.max(1) as u32, nh.max(1) as u32));
    // Resizing can bring the caption back.
    crate::overlay::borderless(window);
    if let Ok(own) = window.hwnd() {
        // SAFETY: the viewer becomes the window's owner, so the notch stays just above the picture and moves with it.
        unsafe { SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer) };
        let corners = if under { (0.5, 0.5) } else { (fx, fy) };
        shape(own.0 as HWND, nw, nh, (14.0 * scale).round() as i32, corners);
    }
    if (slide || was_under != under) && window.is_visible().unwrap_or(false) {
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
    crate::diag(&format!("notch place {vm} at {px},{py} {nw}x{nh} visible {}", window.is_visible().unwrap_or(false)));
    if !window.is_visible().unwrap_or(false) {
        let _ = window.show();
        crate::overlay::mark_taskbar(window, crate::viewer::viewer_full_screen(vm));
    }
    let _ = window.emit("status-place", json!({ "placement": placement, "under": under }));
}

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

pub fn dock_changed(app: &AppHandle) {
    let Some(vm) = with(|s| s.shown.clone()) else { return };
    if let Some(w) = app.get_webview_window(LABEL) {
        place(app, &w, &vm, true);
    }
}

#[tauri::command]
pub fn status_resize(app: AppHandle, width: f64, height: f64) {
    crate::diag(&format!("notch page measured {width}x{height}"));
    with(|s| s.size = (width.clamp(1.0, 900.0), height.clamp(1.0, 400.0)));
    let Some(vm) = with(|s| s.shown.clone()) else { return };
    if let Some(w) = app.get_webview_window(LABEL) {
        place(&app, &w, &vm, false);
    }
}

#[tauri::command]
pub fn status_state() -> Value {
    current().map(|(vm, items, placement)| json!({ "vm": vm, "items": items, "placement": placement })).unwrap_or(Value::Null)
}

#[tauri::command]
pub async fn status_action(app: AppHandle, id: String) -> Result<(), String> {
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

pub fn dock_placement() -> (f64, f64) {
    with(|s| s.dock_pos)
}

#[tauri::command]
pub fn set_status_prefs(app: AppHandle, placement: String, x: Option<f64>, y: Option<f64>, dock_x: Option<f64>, dock_y: Option<f64>) {
    let placement = if placement == "panel" { placement } else { "picture".into() };
    let f = |v: Option<f64>, d: f64| v.filter(|v| v.is_finite()).unwrap_or(d).clamp(0.0, 1.0);
    let (pos, dock_pos) = ((f(x, 0.5), f(y, 0.93)), (f(dock_x, 0.5), f(dock_y, 0.0)));
    with(|s| { s.pos = pos; s.dock_pos = dock_pos; });
    let changed = with(|s| { let c = s.placement != placement; s.placement = placement; c });
    if changed {
        with(|s| s.size = (0.0, 0.0));
        if let Some(w) = app.get_webview_window(LABEL) {
            let _ = w.destroy();
        }
        with(|s| s.shown = None);
        refresh(&app);
    } else {
        dock_changed(&app);
        if let (Some(vm), Some(w)) = (with(|s| s.shown.clone()), app.get_webview_window(LABEL)) {
            place(&app, &w, &vm, true);
        }
    }
}
