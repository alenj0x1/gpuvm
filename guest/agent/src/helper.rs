//! The session helper: started by the service in the signed-in user's session with that user's medium token, it
//! talks to the service over its stdin/stdout (unauthenticated frames: only the service holds these pipes) and does
//! the on-screen work. It never runs elevated (the service refuses to start it with an elevated token).
use crate::capture::{self, CallResult};
use crate::proto::*;
use crate::state;
use crate::util::*;
use serde_json::{json, Value};
use std::fs::File;
use std::os::windows::io::FromRawHandle;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use windows::Win32::System::Com::*;
use windows::Win32::System::Console::*;
use windows::Win32::UI::HiDpi::*;
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

type Out = Arc<Mutex<File>>;

/// Requests the host cancelled: long work (exec.run, input.act) checks this and stops.
static CANCELLED: Mutex<Vec<u64>> = Mutex::new(Vec::new());

/// Where a request runs. The main thread only reads frames and routes them, so a cancel always gets through and
/// nothing waits behind a long command (lab 058):
/// - `Own`: a thread of its own per request (commands and files: long, and independent of each other);
/// - `Input`: one thread, first in first out (actions keep the order they were sent in);
/// - `Screen`: one thread for captures and the cheap reads (agent.info, screen.state/refresh), so a screenshot never
///   waits behind a command, an action or a slow UI Automation call;
/// - `Ui`: one thread for UI Automation (its element cache lives in that thread).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lane {
    Own,
    Input,
    Screen,
    Ui,
}

pub fn lane(method: &str) -> Lane {
    match method {
        "exec.run" | "files.list" | "files.read" | "files.write" => Lane::Own,
        "input.act" => Lane::Input,
        "ui.tree" | "ui.invoke" => Lane::Ui,
        _ => Lane::Screen,
    }
}

/// Requests waiting in one lane: more than the service lets in flight (32), so a full lane means something is stuck.
const LANE_QUEUE: usize = 64;

/// A worker thread that runs the jobs sent to it one at a time, in the order they were sent.
pub fn spawn_lane<J: Send + 'static>(name: &str, run: impl Fn(J) + Send + 'static) -> std::sync::mpsc::SyncSender<J> {
    let (tx, rx) = std::sync::mpsc::sync_channel::<J>(LANE_QUEUE);
    let _ = std::thread::Builder::new().name(format!("lane-{name}")).spawn(move || {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
        while let Ok(job) = rx.recv() {
            run(job);
        }
    });
    tx
}

struct Job {
    method: String,
    params: Value,
    blob: Option<Vec<u8>>,
    id: u64,
}

pub fn is_cancelled(id: u64) -> bool {
    CANCELLED.lock().unwrap().contains(&id)
}

fn send(out: &Out, v: &Value, blob: Option<&[u8]>) {
    let mut f = out.lock().unwrap();
    let mut bytes = serde_json::to_vec(v).unwrap();
    let mut blob = blob;
    // room for what the service adds (seq, MAC, blob fields: review M3) and the blob limit checked BEFORE writing
    // the JSON that announces it (review L1)
    if bytes.len() > MAX_JSON - 1024 || blob.is_some_and(|b| b.len() > MAX_BLOB) {
        let id = v["id"].as_u64().unwrap_or(0);
        bytes = serde_json::to_vec(&json!({"t": "res", "id": id, "ok": false, "error": {"code": "too_large", "message": "the result is over the frame limits (63 KiB JSON, 16 MiB blob)"}})).unwrap();
        blob = None;
    }
    if write_frame(&mut *f, KIND_JSON, &bytes).is_err() || blob.is_some_and(|b| write_frame(&mut *f, KIND_BLOB, b).is_err()) {
        std::process::exit(0); // the service is gone
    }
}

fn hlog(out: &Out, msg: &str) {
    send(out, &json!({"t": "log", "msg": msg}), None);
}

fn info() -> Value {
    let (os, lang) = os_info();
    let tok = crate::token::self_token();
    let user = crate::token::token_user(tok.0).0;
    let mut session = 0u32;
    unsafe {
        let _ = windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(std::process::id(), &mut session);
    }
    let screen = capture::output_rect().map(|r| json!({"w": r.right - r.left, "h": r.bottom - r.top}));
    json!({"version": VERSION, "os": os, "lang": lang, "user": user, "session": session, "screen": screen, "signedIn": true,
           "integrity": crate::token::il_name(state::own_integrity()), "agentUser": crate::files::root().is_ok(),
           // the profile folder files.* paths are relative to (normally C:\Users\agent, but Windows may pick another name)
           "home": std::env::var("USERPROFILE").unwrap_or_default(),
           "displays": capture::displays_json(), "noDisplay": crate::display::no_display(), "streamMode": crate::display::stream_info(), "diag": crate::display::diag()})
}

fn dispatch(method: &str, p: &Value, blob: Option<Vec<u8>>, id: u64) -> CallResult {
    match method {
        "agent.info" => Ok((info(), None)),
        "screen.capture" => capture::screen_capture(p),
        "screen.state" => Ok((state::screen_state(), None)),
        "screen.refresh" => Ok((refresh(), None)),
        // one at a time and in order: the Input lane runs them
        "input.act" => crate::input::input_act(p, id),
        "ui.tree" => crate::uia::ui_tree(p),
        "ui.invoke" => crate::uia::ui_invoke(p),
        "exec.run" => crate::exec::exec_run(p, id),
        "files.list" => crate::files::list(p),
        "files.read" => crate::files::read(p),
        "files.write" => crate::files::write(p, blob),
        _ => Err(("bad_request", "unknown method".into())),
    }
}

/// screen.refresh: repaint the whole desktop so the compositor presents a new frame (a still desktop gives a
/// duplication-based stream nothing to send, and Sunshine's ddx stayed black 1 time in 3 when a viewer connected,
/// lab 054). Repaints only: no window is moved, no input is sent, the cursor stays where it is.
pub fn refresh() -> Value {
    use windows::Win32::Graphics::Gdi::*;
    let t = Instant::now();
    let ok = unsafe { RedrawWindow(None, None, None, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW).as_bool() };
    // a repaint of identical pixels barely helped (agent-ui: 3/10 vs 1/10 pictures on open): add a REAL pixel change
    // nobody can see or touch
    let blipped = blip();
    json!({"ok": ok || blipped, "blip": blipped, "ms": (t.elapsed().as_secs_f64() * 1e4).round() / 10.0})
}

/// A 1x1 window at the screen's top-left corner, alpha 1/255, for ~50 ms: the compositor has a changed pixel to
/// present, so a duplication-based stream sends a frame of a still desktop. Never activated, never takes focus or
/// input (WS_EX_NOACTIVATE | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW, SW_SHOWNOACTIVATE), destroyed right after.
fn blip() -> bool {
    use windows::core::PCWSTR;
    use windows::Win32::UI::WindowsAndMessaging::*;
    unsafe {
        let class = crate::util::wide("STATIC");
        let ex = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        let (x, y) = capture::output_rect().map(|r| (r.left, r.top)).unwrap_or((0, 0));
        let Ok(h) = CreateWindowExW(ex, PCWSTR(class.as_ptr()), PCWSTR::null(), WS_POPUP, x, y, 1, 1, None, None, None, None) else { return false };
        let _ = SetLayeredWindowAttributes(h, windows::Win32::Foundation::COLORREF(0), 1, LWA_ALPHA);
        let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
        let mut msg = MSG::default();
        let t = Instant::now();
        while t.elapsed() < Duration::from_millis(50) {
            while PeekMessageW(&mut msg, Some(h), 0, 0, PM_REMOVE).as_bool() {
                let _ = DispatchMessageW(&msg);
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        let _ = DestroyWindow(h);
        true
    }
}

fn reply(out: &Out, id: u64, r: CallResult) {
    match r {
        Ok((result, blob)) => send(out, &json!({"t": "res", "id": id, "ok": true, "result": result, "blob": blob.is_some()}), blob.as_deref()),
        Err((code, message)) => send(out, &json!({"t": "res", "id": id, "ok": false, "error": {"code": code, "message": message}}), None),
    }
}

fn guarded(method: &str, p: &Value, blob: Option<Vec<u8>>, id: u64) -> CallResult {
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| dispatch(method, p, blob, id))).unwrap_or_else(|_| Err(("internal", format!("{method} failed unexpectedly"))));
    CANCELLED.lock().unwrap().retain(|x| *x != id);
    r
}

/// secure_desktop on change, foreground at most 4/s (latest wins), error_box once per box; closes an idle capture.
fn events(out: Out) {
    let mut desk = state::desktop_state();
    let mut fg = unsafe { GetForegroundWindow() }.0 as isize;
    let mut fg_dirty = false;
    let mut fg_sent = Instant::now() - Duration::from_secs(1);
    let mut boxes: Vec<isize> = Vec::new();
    let mut tick = 0u64;
    let size = || capture::output_rect().map(|r| (r.right - r.left, r.bottom - r.top));
    let mut last_size = size();
    loop {
        std::thread::sleep(Duration::from_millis(100));
        tick += 1;
        let d = state::desktop_state();
        if d != desk {
            send(&out, &json!({"t": "evt", "event": "secure_desktop", "data": {"on": d != "default", "desktop": d}}), None);
            desk = d;
        }
        let h = unsafe { GetForegroundWindow() }.0 as isize;
        if h != fg {
            fg = h;
            fg_dirty = true;
        }
        if fg_dirty && fg_sent.elapsed() >= Duration::from_millis(250) && desk == "default" {
            let f = state::foreground(Duration::from_millis(0));
            send(&out, &json!({"t": "evt", "event": "foreground", "data": state::fg_json(&f)}), None);
            fg_dirty = false;
            fg_sent = Instant::now();
        }
        // every 5 s: a display that came back (Windows, a driver, a disconnect) goes off again
        if tick % 50 == 25 && desk == "default" {
            match crate::display::ensure() {
                Ok(Some(did)) => hlog(&out, &format!("displays arranged again: {did}")),
                Ok(None) => {}
                // once per new error, not every 5 s (a machine with no display at all logged it 12 times a minute)
                Err(e) => {
                    static LAST: std::sync::Mutex<String> = std::sync::Mutex::new(String::new());
                    let mut last = LAST.lock().unwrap();
                    if *last != e {
                        hlog(&out, &format!("displays: {e}"));
                        *last = e;
                    }
                }
            }
        }
        // the agent's screen changed size (display arranged, viewer connected): clients recapture
        if tick % 5 == 2 {
            let s = size();
            if s != last_size {
                if let Some((w, h)) = s {
                    send(&out, &json!({"t": "evt", "event": "screen", "data": {"w": w, "h": h}}), None);
                }
                // a new mode: give a duplication-based stream a fresh frame of the still desktop
                let _ = refresh();
                last_size = s;
            }
        }
        if tick % 5 == 0 {
            let now = state::error_boxes();
            for (hw, title) in &now {
                if !boxes.contains(hw) {
                    // the title is whatever the raising program chose: untrusted text, never an instruction
                    send(&out, &json!({"t": "evt", "event": "error_box", "data": {"title": title, "untrustedText": true}}), None);
                }
            }
            boxes = now.into_iter().map(|(h, _)| h).collect();
            capture::close_if_idle();
        }
    }
}

pub fn run() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let (mut input, out) = unsafe {
        let i = GetStdHandle(STD_INPUT_HANDLE).unwrap_or_default();
        let o = GetStdHandle(STD_OUTPUT_HANDLE).unwrap_or_default();
        if i.is_invalid() || o.is_invalid() || i.0.is_null() || o.0.is_null() {
            eprintln!("the helper is started by the GpuVM agent service");
            std::process::exit(2);
        }
        // the pipes to the service must never reach a program the helper starts (security review H1)
        use windows::Win32::Foundation::{SetHandleInformation, HANDLE_FLAGS, HANDLE_FLAG_INHERIT};
        for h in [i, o, GetStdHandle(STD_ERROR_HANDLE).unwrap_or_default()] {
            if !h.is_invalid() && !h.0.is_null() {
                let _ = SetHandleInformation(h, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0));
            }
        }
        (File::from_raw_handle(i.0 as _), Arc::new(Mutex::new(File::from_raw_handle(o.0 as _))))
    };
    // the virtual display alone and primary BEFORE the helper announces itself: the host treats `signed_in` as
    // ready, and a client that captured at 800x600 a moment before the change got stale sizes (lab 053)
    // right after sign-in the input desktop is still Winlogon's: captures are refused and Windows refuses the display
    // layout (ERROR_ACCESS_DENIED, lab 051). Wait for the normal desktop (<= 60 s), then retry the layout (<= 10 s).
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(60) && state::desktop_state() != "default" {
        std::thread::sleep(Duration::from_millis(250));
    }
    let t = Instant::now();
    let mut arranged = crate::display::ensure();
    while arranged.is_err() && t.elapsed() < Duration::from_secs(10) {
        std::thread::sleep(Duration::from_millis(500));
        arranged = crate::display::ensure();
    }
    if matches!(arranged, Ok(Some(_))) {
        // wait (<= 2 s) until Windows reports the new layout
        let t = std::time::Instant::now();
        while t.elapsed() < Duration::from_secs(2) && !crate::display::settled() {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
    let me = info();
    send(&out, &json!({"t": "hello", "user": me["user"], "session": me["session"], "integrity": me["integrity"]}), None);
    match arranged {
        Ok(Some(did)) => hlog(&out, &format!("displays arranged: {did}")),
        Ok(None) => {}
        Err(e) => hlog(&out, &format!("displays: {e}")),
    }
    hlog(&out, &format!("helper {} up: {}", std::process::id(), me));
    let ev = out.clone();
    std::thread::spawn(move || events(ev));
    let worker = |name: &str| {
        let o = out.clone();
        spawn_lane(name, move |j: Job| {
            let r = guarded(&j.method, &j.params, j.blob, j.id);
            reply(&o, j.id, r);
        })
    };
    let (input_lane, screen_lane, ui_lane) = (worker("input"), worker("screen"), worker("ui"));
    loop {
        let v = match read_frame(&mut input) {
            Ok(Frame::Json(b)) => match serde_json::from_slice::<Value>(&b) {
                Ok(v) => v,
                Err(_) => continue,
            },
            Ok(Frame::Blob(_)) => continue,
            Err(_) => std::process::exit(0), // the service closed the pipe
        };
        let blob = if v["blob"] == true {
            match read_frame(&mut input) {
                Ok(Frame::Blob(b)) => Some(b),
                _ => std::process::exit(0),
            }
        } else {
            None
        };
        let Some(id) = v["id"].as_u64() else { continue };
        if v["t"] == "cancel" {
            let mut c = CANCELLED.lock().unwrap();
            if c.len() > 256 {
                c.clear();
            }
            c.push(id);
            continue;
        }
        if v["t"] != "req" {
            continue;
        }
        let method = v["method"].as_str().unwrap_or("").to_string();
        let params = v.get("params").cloned().unwrap_or(json!({}));
        let tx = match lane(&method) {
            Lane::Own => {
                let o = out.clone();
                std::thread::spawn(move || {
                    let r = guarded(&method, &params, blob, id);
                    reply(&o, id, r);
                });
                continue;
            }
            Lane::Input => &input_lane,
            Lane::Screen => &screen_lane,
            Lane::Ui => &ui_lane,
        };
        if tx.try_send(Job { method, params, blob, id }).is_err() {
            reply(&out, id, Err(("internal", "too many requests are waiting in the session helper".into())));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn requests_go_to_their_lanes() {
        // a screenshot must never share a thread with a command, an action or UI Automation (lab 058)
        for m in ["exec.run", "files.read", "files.write", "files.list"] {
            assert_eq!(lane(m), Lane::Own, "{m}");
        }
        assert_eq!(lane("input.act"), Lane::Input);
        for m in ["screen.capture", "screen.state", "screen.refresh", "agent.info"] {
            assert_eq!(lane(m), Lane::Screen, "{m}");
        }
        assert_eq!(lane("ui.tree"), Lane::Ui);
        assert_eq!(lane("ui.invoke"), Lane::Ui);
    }

    #[test]
    fn a_lane_keeps_the_order_jobs_were_sent_in() {
        let (done_tx, done_rx) = channel();
        let lane = spawn_lane("order", move |n: u32| {
            // later jobs are quicker: only a single FIFO worker keeps them in order
            std::thread::sleep(Duration::from_millis((20 - n as u64 % 20) / 4));
            done_tx.send(n).unwrap();
        });
        for n in 0..40 {
            lane.try_send(n).unwrap();
        }
        let got: Vec<u32> = (0..40).map(|_| done_rx.recv_timeout(Duration::from_secs(5)).unwrap()).collect();
        assert_eq!(got, (0..40).collect::<Vec<_>>());
    }

    #[test]
    fn a_busy_lane_does_not_hold_another() {
        let (gate_tx, gate_rx) = channel::<()>();
        let gate_rx = Mutex::new(gate_rx);
        let (done_tx, done_rx) = channel();
        let d1 = done_tx.clone();
        // the "input" lane is stuck in a long job until the gate opens
        let slow = spawn_lane("slow", move |_: ()| {
            let _ = gate_rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
            d1.send("slow").unwrap();
        });
        let fast = spawn_lane("fast", move |_: ()| done_tx.send("fast").unwrap());
        slow.try_send(()).unwrap();
        let t = Instant::now();
        fast.try_send(()).unwrap();
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)).unwrap(), "fast");
        assert!(t.elapsed() < Duration::from_secs(1));
        gate_tx.send(()).unwrap();
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "slow");
    }

    #[test]
    fn a_full_lane_refuses_instead_of_blocking_the_reader() {
        let (gate_tx, gate_rx) = channel::<()>();
        let gate_rx = Mutex::new(gate_rx);
        let lane = spawn_lane("full", move |_: ()| {
            let _ = gate_rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
        });
        // one running + LANE_QUEUE waiting; the next one is refused at once
        let mut accepted = 0;
        let t = Instant::now();
        while lane.try_send(()).is_ok() {
            accepted += 1;
            assert!(accepted <= LANE_QUEUE + 1, "the lane never filled");
        }
        assert!(accepted >= LANE_QUEUE && t.elapsed() < Duration::from_secs(1));
        for _ in 0..=accepted {
            let _ = gate_tx.send(());
        }
    }
}
