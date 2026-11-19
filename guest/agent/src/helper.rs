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
/// One input.act at a time (they run off the main thread so a cancel can reach them).
static INPUT: Mutex<()> = Mutex::new(());

pub fn is_cancelled(id: u64) -> bool {
    CANCELLED.lock().unwrap().contains(&id)
}

fn send(out: &Out, v: &Value, blob: Option<&[u8]>) {
    let mut f = out.lock().unwrap();
    let mut bytes = serde_json::to_vec(v).unwrap();
    let mut blob = blob;
    if bytes.len() > MAX_JSON {
        let id = v["id"].as_u64().unwrap_or(0);
        bytes = serde_json::to_vec(&json!({"t": "res", "id": id, "ok": false, "error": {"code": "too_large", "message": "the result is over 64 KiB"}})).unwrap();
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
           "integrity": crate::token::il_name(state::own_integrity()), "agentUser": crate::files::root().is_ok()})
}

fn dispatch(method: &str, p: &Value, blob: Option<Vec<u8>>, id: u64) -> CallResult {
    match method {
        "agent.info" => Ok((info(), None)),
        "screen.capture" => capture::screen_capture(p),
        "screen.state" => Ok((state::screen_state(), None)),
        "input.act" => {
            let _one = INPUT.lock().unwrap_or_else(|e| e.into_inner());
            crate::input::input_act(p, id)
        }
        "ui.tree" => crate::uia::ui_tree(p),
        "ui.invoke" => crate::uia::ui_invoke(p),
        "exec.run" => crate::exec::exec_run(p, id),
        "files.list" => crate::files::list(p),
        "files.read" => crate::files::read(p),
        "files.write" => crate::files::write(p, blob),
        _ => Err(("bad_request", "unknown method".into())),
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
        if tick % 5 == 0 {
            let now = state::error_boxes();
            for (hw, title) in &now {
                if !boxes.contains(hw) {
                    send(&out, &json!({"t": "evt", "event": "error_box", "data": {"title": title}}), None);
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
        (File::from_raw_handle(i.0 as _), Arc::new(Mutex::new(File::from_raw_handle(o.0 as _))))
    };
    let me = info();
    send(&out, &json!({"t": "hello", "user": me["user"], "session": me["session"], "integrity": me["integrity"]}), None);
    hlog(&out, &format!("helper {} up: {}", std::process::id(), me));
    let ev = out.clone();
    std::thread::spawn(move || events(ev));
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
        if method == "exec.run" || method == "input.act" || method.starts_with("files.") {
            // long or disk-bound: off the main thread so screenshots stay responsive and a cancel can reach them
            let o = out.clone();
            std::thread::spawn(move || {
                let r = guarded(&method, &params, blob, id);
                reply(&o, id, r);
            });
        } else {
            let r = guarded(&method, &params, blob, id);
            reply(&out, id, r);
        }
    }
}
