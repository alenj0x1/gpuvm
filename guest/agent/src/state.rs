//! What the session looks like right now: which desktop has the input (default / secure / locked), the foreground
//! window and whether the agent may act on it (lab 049: an elevated window drops our input silently; a csrss
//! hard-error box leaves no foreground window and blocks all input), and the system error boxes on screen.
use crate::token::*;
use crate::util::wstr;
use serde_json::{json, Value};
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::*;
use windows::Win32::System::Diagnostics::ToolHelp::*;
use windows::Win32::System::RemoteDesktop::*;
use windows::Win32::System::StationsAndDesktops::*;
use windows::Win32::UI::WindowsAndMessaging::*;

/// "default" when this process can open the input desktop and it is `Default`; otherwise "locked" when the session is
/// locked, else "secure" (UAC prompt, Ctrl+Alt+Del screen: lab 048, OpenInputDesktop fails with error 5).
pub fn desktop_state() -> &'static str {
    unsafe {
        if let Ok(h) = OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x0001)) {
            let mut name = [0u16; 64];
            let mut need = 0u32;
            let ok = GetUserObjectInformationW(HANDLE(h.0), UOI_NAME, Some(name.as_mut_ptr() as *mut _), (name.len() * 2) as u32, Some(&mut need)).is_ok();
            let _ = CloseDesktop(h);
            if ok && wstr(&name).eq_ignore_ascii_case("Default") {
                return "default";
            }
        }
        if session_locked() {
            "locked"
        } else {
            "secure"
        }
    }
}

fn session_locked() -> bool {
    unsafe {
        let mut buf = windows::core::PWSTR::null();
        let mut len = 0u32;
        if WTSQuerySessionInformationW(Some(WTS_CURRENT_SERVER_HANDLE), WTS_CURRENT_SESSION, WTSSessionInfoEx, &mut buf, &mut len).is_err() {
            return false;
        }
        let info = &*(buf.0 as *const WTSINFOEXW);
        let locked = info.Level == 1 && info.Data.WTSInfoExLevel1.SessionFlags == WTS_SESSIONSTATE_LOCK as i32;
        WTSFreeMemory(buf.0 as *mut _);
        locked
    }
}

/// csrss.exe of this session (owner of the system hard-error boxes); found once.
fn csrss_pids() -> &'static Vec<u32> {
    static P: OnceLock<Vec<u32>> = OnceLock::new();
    P.get_or_init(|| unsafe {
        let mut own = 0u32;
        let _ = windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(std::process::id(), &mut own);
        let mut v = Vec::new();
        if let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) {
            let snap = Owned(snap);
            let mut e = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
            let mut ok = Process32FirstW(snap.0, &mut e).is_ok();
            while ok {
                if wstr(&e.szExeFile).eq_ignore_ascii_case("csrss.exe") {
                    let mut s = 0u32;
                    if windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(e.th32ProcessID, &mut s).is_ok() && s == own {
                        v.push(e.th32ProcessID);
                    }
                }
                ok = Process32NextW(snap.0, &mut e).is_ok();
            }
        }
        v
    })
}

pub fn window_text(h: HWND) -> String {
    let mut t = [0u16; 256];
    let n = unsafe { GetWindowTextW(h, &mut t) };
    String::from_utf16_lossy(&t[..n.max(0) as usize])
}

pub fn window_class(h: HWND) -> String {
    let mut t = [0u16; 128];
    let n = unsafe { GetClassNameW(h, &mut t) };
    String::from_utf16_lossy(&t[..n.max(0) as usize])
}

pub fn window_pid(h: HWND) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    pid
}

/// Visible top-level windows owned by csrss (system error boxes) as (hwnd, title).
pub fn error_boxes() -> Vec<(isize, String)> {
    struct Acc<'a> {
        pids: &'a [u32],
        out: Vec<(isize, String)>,
    }
    unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> windows::core::BOOL {
        let a = &mut *(lp.0 as *mut Acc);
        if IsWindowVisible(h).as_bool() && a.pids.contains(&window_pid(h)) {
            a.out.push((h.0 as isize, window_text(h)));
        }
        true.into()
    }
    let pids = csrss_pids();
    if pids.is_empty() {
        return Vec::new();
    }
    let mut a = Acc { pids, out: Vec::new() };
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut a as *mut Acc as isize));
    }
    a.out
}

pub fn own_integrity() -> u32 {
    static IL: OnceLock<u32> = OnceLock::new();
    *IL.get_or_init(|| token_integrity(self_token().0).unwrap_or(IL_MEDIUM))
}

pub struct Fg {
    pub hwnd: HWND,
    pub title: String,
    pub process: String,
    pub integrity: Option<u32>,
    /// None when the agent may act; otherwise the protocol error code.
    pub blocked: Option<&'static str>,
}

/// Window integrity check: Some(code) when our input would be dropped (above our level, or unreadable).
pub fn window_block(h: HWND) -> (Option<&'static str>, ProcInfo) {
    let info = process_info(window_pid(h));
    let b = match info.integrity {
        Some(il) if il <= own_integrity() => None,
        _ => Some("blocked_elevated"),
    };
    (b, info)
}

/// The foreground window, waiting up to `wait` for one to appear (right after a window closes there briefly is none).
pub fn foreground(wait: Duration) -> Fg {
    let desk = desktop_state();
    let mut hwnd = unsafe { GetForegroundWindow() };
    let t = Instant::now();
    while hwnd.0.is_null() && t.elapsed() < wait {
        std::thread::sleep(Duration::from_millis(20));
        hwnd = unsafe { GetForegroundWindow() };
    }
    if desk != "default" {
        return Fg { hwnd, title: String::new(), process: String::new(), integrity: None, blocked: Some("secure_desktop") };
    }
    if hwnd.0.is_null() {
        return Fg { hwnd, title: String::new(), process: String::new(), integrity: None, blocked: Some("no_foreground") };
    }
    let (blocked, info) = window_block(hwnd);
    // a csrss box in front counts as blocked too (lab 049: input to it hung the session)
    let blocked = blocked.or_else(|| csrss_pids().contains(&window_pid(hwnd)).then_some("no_foreground"));
    Fg { hwnd, title: window_text(hwnd), process: info.image, integrity: info.integrity, blocked }
}

pub fn fg_json(f: &Fg) -> Value {
    json!({
        "title": f.title, "process": f.process,
        "integrity": f.integrity.map(il_name).unwrap_or("unknown"),
        "blocked": f.blocked.is_some(), "reason": f.blocked,
    })
}

/// A human-readable reason for a refusal.
pub fn block_message(code: &str, f: &Fg) -> String {
    match code {
        "secure_desktop" => "a secure desktop (UAC prompt, lock or sign-in screen) has the input: only the person can act there".into(),
        "blocked_elevated" => format!("the window '{}' ({}) runs elevated: the agent can't act on it; ask the person", f.title, f.process),
        _ => {
            let boxes = error_boxes();
            match boxes.first() {
                Some((_, t)) => format!("a system error box '{t}' blocks input: ask the person to close it"),
                None => "there is no foreground window".into(),
            }
        }
    }
}

pub fn screen_state() -> Value {
    let desk = desktop_state();
    let f = foreground(Duration::from_millis(0));
    let boxes: Vec<String> = error_boxes().into_iter().map(|(_, t)| t).collect();
    json!({"desktop": desk, "foreground": fg_json(&f), "errorBoxes": boxes})
}
