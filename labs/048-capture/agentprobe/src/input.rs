//! Input for lab 049: SendInput with coordinates normalized to the virtual desktop, and a check of the foreground
//! window before every injection so an elevated window (UIPI drops our input silently) or the secure desktop is
//! reported instead of failing quietly.
use crate::capture;
use crate::token::*;
use crate::util::*;
use std::time::{Duration, Instant};
use windows::Win32::Foundation::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

pub struct Fg {
    pub hwnd: HWND,
    pub title: String,
    pub class: String,
    pub pid: u32,
    pub target_il: Option<u32>,
    pub target_user: String,
    pub open_err: u32,
    pub verdict: &'static str,
}

pub fn foreground() -> Fg {
    unsafe {
        let own_il = token_integrity(self_token()).unwrap_or(0x2000);
        let desk = capture::input_desktop();
        // Right after a window closes or another takes over, there is briefly no foreground window: wait up to
        // 500 ms for one before calling it "no_foreground".
        let mut hwnd = GetForegroundWindow();
        let t = std::time::Instant::now();
        while hwnd.0.is_null() && t.elapsed() < Duration::from_millis(500) {
            std::thread::sleep(Duration::from_millis(20));
            hwnd = GetForegroundWindow();
        }
        let mut title = [0u16; 256];
        let n = GetWindowTextW(hwnd, &mut title);
        let mut class = [0u16; 256];
        let c = GetClassNameW(hwnd, &mut class);
        let mut pid = 0u32;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        let (target_il, target_user, open_err) = match process_integrity(pid) {
            Ok((il, u, _)) => (Some(il), u, 0),
            Err(e) => (None, String::new(), e),
        };
        let verdict = if !matches!(&desk, Ok(n) if n.eq_ignore_ascii_case("Default")) {
            "secure_desktop"
        } else if hwnd.0.is_null() {
            "no_foreground"
        } else if let Some(il) = target_il {
            if il > own_il { "blocked_elevated" } else { "ok" }
        } else {
            // Can't even read its token: not ours and not at our level (elevated, or another user's protected
            // process). Treat as blocked: UIPI would drop input if it is higher.
            "blocked_elevated"
        };
        Fg {
            hwnd,
            title: String::from_utf16_lossy(&title[..n.max(0) as usize]),
            class: String::from_utf16_lossy(&class[..c.max(0) as usize]),
            pid,
            target_il,
            target_user,
            open_err,
            verdict,
        }
    }
}

pub fn fg_json(f: &Fg) -> String {
    // what is under the cursor, to explain a foreground that vanished after a click
    let under = unsafe {
        let mut p = windows::Win32::Foundation::POINT::default();
        let _ = GetCursorPos(&mut p);
        let h = WindowFromPoint(p);
        let root = GetAncestor(h, GA_ROOT);
        let mut t = [0u16; 128];
        let n = GetWindowTextW(root, &mut t);
        let mut c = [0u16; 128];
        let m = GetClassNameW(root, &mut c);
        format!("{{\"x\":{},\"y\":{},\"title\":{},\"class\":{}}}", p.x, p.y, jstr(&String::from_utf16_lossy(&t[..n.max(0) as usize])), jstr(&String::from_utf16_lossy(&c[..m.max(0) as usize])))
    };
    format!(
        "{{\"underCursor\":{under},\"hwnd\":{},\"title\":{},\"class\":{},\"pid\":{},\"targetIntegrity\":{},\"targetUser\":{},\"openErr\":{},\"ownIntegrity\":\"{:#x}\",\"verdict\":\"{}\"}}",
        f.hwnd.0 as isize,
        jstr(&f.title),
        jstr(&f.class),
        f.pid,
        f.target_il.map(|i| format!("\"{i:#x}\"")).unwrap_or("null".into()),
        jstr(&f.target_user),
        f.open_err,
        token_integrity(self_token()).unwrap_or(0),
        f.verdict
    )
}

fn mouse(flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: i32) -> INPUT {
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

fn key(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } },
    }
}

/// Normalized (0..1 of the virtual desktop) -> SendInput absolute units (0..65535 over the virtual desktop).
fn abs_xy(nx: f64, ny: f64) -> (i32, i32) {
    ((nx.clamp(0.0, 1.0) * 65535.0).round() as i32, (ny.clamp(0.0, 1.0) * 65535.0).round() as i32)
}

pub fn send(inputs: &[INPUT]) -> (u32, u32) {
    unsafe {
        SetLastError(WIN32_ERROR(0));
        let n = SendInput(inputs, std::mem::size_of::<INPUT>() as i32);
        (n, GetLastError().0)
    }
}

pub fn click_inputs(nx: f64, ny: f64, button: &str, double: bool) -> Vec<INPUT> {
    let (x, y) = abs_xy(nx, ny);
    let base = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    let (down, up) = match button {
        "right" => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        "middle" => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
    };
    let mut v = vec![mouse(base | MOUSEEVENTF_MOVE, x, y, 0), mouse(base | down, x, y, 0), mouse(base | up, x, y, 0)];
    if double {
        v.push(mouse(base | down, x, y, 0));
        v.push(mouse(base | up, x, y, 0));
    }
    v
}

pub fn text_inputs(text: &str) -> Vec<INPUT> {
    let mut v = Vec::new();
    for u in text.encode_utf16() {
        if u == '\n' as u16 {
            v.push(key(VK_RETURN.0, 0, KEYBD_EVENT_FLAGS(0)));
            v.push(key(VK_RETURN.0, 0, KEYEVENTF_KEYUP));
        } else {
            v.push(key(0, u, KEYEVENTF_UNICODE));
            v.push(key(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
        }
    }
    v
}

/// "ctrl+shift+esc", "enter", "backspace", "a"...
pub fn combo_inputs(combo: &str) -> Vec<INPUT> {
    let vk_of = |k: &str| -> u16 {
        match k.to_ascii_lowercase().as_str() {
            "ctrl" | "control" => VK_CONTROL.0,
            "shift" => VK_SHIFT.0,
            "alt" => VK_MENU.0,
            "win" => VK_LWIN.0,
            "enter" | "return" => VK_RETURN.0,
            "esc" | "escape" => VK_ESCAPE.0,
            "tab" => VK_TAB.0,
            "backspace" => VK_BACK.0,
            "delete" | "del" => VK_DELETE.0,
            "space" => VK_SPACE.0,
            "up" => VK_UP.0,
            "down" => VK_DOWN.0,
            "left" => VK_LEFT.0,
            "right" => VK_RIGHT.0,
            "home" => VK_HOME.0,
            "end" => VK_END.0,
            "f4" => VK_F4.0,
            "f5" => VK_F5.0,
            s if s.len() == 1 => s.to_ascii_uppercase().as_bytes()[0] as u16,
            s => die(&format!("unknown key {s}")),
        }
    };
    let keys: Vec<u16> = combo.split('+').map(vk_of).collect();
    let mut v: Vec<INPUT> = keys.iter().map(|&k| key(k, 0, KEYBD_EVENT_FLAGS(0))).collect();
    v.extend(keys.iter().rev().map(|&k| key(k, 0, KEYEVENTF_KEYUP)));
    v
}

pub fn scroll_inputs(nx: f64, ny: f64, delta: i32) -> Vec<INPUT> {
    let (x, y) = abs_xy(nx, ny);
    let base = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    vec![mouse(base | MOUSEEVENTF_MOVE, x, y, 0), mouse(MOUSEEVENTF_WHEEL, 0, 0, delta)]
}

fn die(m: &str) -> ! {
    eprintln!("{m}");
    std::process::exit(2)
}

/// act --do click|type|key|scroll [--x 0.5 --y 0.5] [--text t] [--combo ctrl+a] [--delta -120] [--force]
/// Checks the foreground first; refuses with the verdict unless --force (used to show the silent failure).
pub fn cmd_act(args: &[String]) -> String {
    let what = arg_or(args, "--do", "click");
    let fg = foreground();
    let force = has(args, "--force");
    if fg.verdict != "ok" && !force {
        return format!("{{\"result\":\"{}\",\"injected\":false,\"foreground\":{}}}", fg.verdict, fg_json(&fg));
    }
    let nx: f64 = arg_or(args, "--x", "0.5").parse().unwrap();
    let ny: f64 = arg_or(args, "--y", "0.5").parse().unwrap();
    let inputs = match what.as_str() {
        "click" => click_inputs(nx, ny, &arg_or(args, "--button", "left"), has(args, "--double")),
        // "\n" in the text (two characters) means Enter: real line breaks can't cross a command line
        "type" => text_inputs(&arg_or(args, "--text", "").replace("\\n", "\n")),
        "key" => combo_inputs(&arg_or(args, "--combo", "enter")),
        "scroll" => scroll_inputs(nx, ny, arg_or(args, "--delta", "-120").parse().unwrap()),
        "move" => { let (x, y) = abs_xy(nx, ny); vec![mouse(MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE, x, y, 0)] }
        _ => die("unknown --do"),
    };
    let t = Instant::now();
    let (n, err) = send(&inputs);
    format!(
        "{{\"result\":\"{}\",\"injected\":true,\"sent\":{n},\"of\":{},\"lastError\":{err},\"sendUs\":{:.0},\"foreground\":{}}}",
        if n as usize == inputs.len() { "sent" } else { "send_failed" },
        inputs.len(),
        t.elapsed().as_secs_f64() * 1e6,
        fg_json(&fg)
    )
}

/// focus --title <substring> : brings the first visible top-level window whose title contains the text to the front.
/// Windows only lets the process that received the last input do that, so a zero mouse move is sent first.
pub fn cmd_focus(args: &[String]) -> String {
    let want = arg_or(args, "--title", "").to_lowercase();
    struct Find {
        want: String,
        hit: HWND,
        title: String,
    }
    unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> windows::core::BOOL {
        let f = &mut *(lp.0 as *mut Find);
        if !IsWindowVisible(h).as_bool() {
            return true.into();
        }
        let mut t = [0u16; 256];
        let n = GetWindowTextW(h, &mut t);
        let s = String::from_utf16_lossy(&t[..n.max(0) as usize]);
        if !s.is_empty() && s.to_lowercase().contains(&f.want) {
            f.hit = h;
            f.title = s;
            return false.into();
        }
        true.into()
    }
    let mut f = Find { want, hit: HWND::default(), title: String::new() };
    unsafe {
        let _ = EnumWindows(Some(cb), LPARAM(&mut f as *mut Find as isize));
        if f.hit.0.is_null() {
            return "{\"ok\":false,\"error\":\"not found\"}".into();
        }
        send(&[mouse(MOUSEEVENTF_MOVE, 0, 0, 0)]);
        if IsIconic(f.hit).as_bool() {
            let _ = ShowWindow(f.hit, SW_RESTORE);
        }
        let ok = SetForegroundWindow(f.hit).as_bool();
        std::thread::sleep(Duration::from_millis(150));
        let now = foreground();
        format!("{{\"ok\":{},\"setForeground\":{ok},\"title\":{},\"foreground\":{}}}", now.hwnd == f.hit, jstr(&f.title), fg_json(&now))
    }
}

fn diff_count(a: &[u8], b: &[u8]) -> usize {
    a.chunks_exact(4).zip(b.chunks_exact(4)).filter(|(p, q)| p[0] != q[0] || p[1] != q[1] || p[2] != q[2]).count()
}

/// latency --n 40 [--threshold 40] : action -> screen. With the target text box focused (e.g. Notepad), alternately
/// types 'm' and Backspace and waits for the first duplicated frame that differs from the frame before the action by
/// more than --threshold pixels (the caret alone changes ~20). Reports ms per sample; skips samples whose
/// foreground changed.
pub fn cmd_latency(args: &[String]) -> String {
    let n: usize = arg_or(args, "--n", "40").parse().unwrap();
    let threshold: usize = arg_or(args, "--threshold", "40").parse().unwrap();
    let o = match capture::enumerate().ok().and_then(capture::pick) {
        Some(o) => o,
        None => return "{\"ok\":false,\"error\":\"no output\"}".into(),
    };
    // WGC: DXGI duplication loses access on GpuVM's virtual display (lab 048)
    let mut d = match capture::wgc_open(&o, false) {
        Ok(d) => d,
        Err(e) => return format!("{{\"ok\":false,\"error\":\"wgc {:#x}\"}}", e.code().0),
    };
    let fg0 = foreground();
    let mut ms = Vec::new();
    let mut skipped = 0;
    let mut timeouts = 0;
    for i in 0..n {
        // settle: drain frames for 150-400 ms
        let settle = Instant::now() + Duration::from_millis(150 + (i as u64 * 53) % 250);
        while Instant::now() < settle {
            let _ = capture::wgc_poll(&mut d);
            std::thread::sleep(Duration::from_millis(2));
        }
        let wait = Instant::now();
        while d.latest.is_none() && wait.elapsed() < Duration::from_millis(1000) {
            let _ = capture::wgc_poll(&mut d);
            std::thread::sleep(Duration::from_millis(2));
        }
        let fg = foreground();
        if fg.hwnd != fg0.hwnd || fg.verdict != "ok" {
            skipped += 1;
            continue;
        }
        let (_, _, before) = capture::read_texture(&d.dev, &d.ctx, d.latest.as_ref().unwrap()).unwrap();
        let inputs = if i % 2 == 0 { text_inputs("m") } else { combo_inputs("backspace") };
        let t = Instant::now();
        send(&inputs);
        let mut got = None;
        while t.elapsed() < Duration::from_millis(1000) {
            match capture::wgc_poll(&mut d) {
                Ok(false) => std::thread::sleep(Duration::from_millis(1)),
                Ok(true) => {
                    let (_, _, now) = capture::read_texture(&d.dev, &d.ctx, d.latest.as_ref().unwrap()).unwrap();
                    if diff_count(&before, &now) > threshold {
                        got = Some(t.elapsed().as_secs_f64() * 1e3);
                        break;
                    }
                }
                Err(_) => break,
            }
        }
        match got {
            Some(v) => ms.push(v),
            None => timeouts += 1,
        }
    }
    format!(
        "{{\"ok\":true,\"foreground\":{},\"n\":{},\"skipped\":{skipped},\"timeouts\":{timeouts},\"p50\":{:.1},\"p95\":{:.1},\"ms\":[{}]}}",
        fg_json(&fg0),
        ms.len(),
        pct(&ms, 50.0),
        pct(&ms, 95.0),
        ms.iter().map(|x| format!("{x:.1}")).collect::<Vec<_>>().join(",")
    )
}
