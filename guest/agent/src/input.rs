//! input.act: SendInput from the medium-integrity helper (lab 049). Before every action: the input desktop is
//! `Default`, there is a foreground window, and neither it nor the window under the pointer runs above our integrity.
//! Nothing is injected when a check fails (UIPI would drop it silently and the agent would believe it worked).
use crate::capture::{output_rect, CallResult};
use crate::state::*;
use serde_json::{json, Value};
use std::time::Duration;
use windows::Win32::Foundation::*;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

const MAX_ACTIONS: usize = 100;
const MAX_TEXT: usize = 10_000;
const MAX_WAIT_TOTAL_MS: u64 = 30_000;

type Fail = (&'static str, String);

fn mouse(flags: MOUSE_EVENT_FLAGS, dx: i32, dy: i32, data: i32) -> INPUT {
    INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn key(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn send(inputs: &[INPUT]) -> Result<(), Fail> {
    let n = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if n as usize != inputs.len() {
        return Err(("internal", format!("SendInput sent {n} of {} events", inputs.len())));
    }
    Ok(())
}

/// Protocol pixel (relative to the captured display) -> desktop pixel -> SendInput absolute units.
struct Mapper {
    ox: i32,
    oy: i32,
    w: i32,
    h: i32,
    vx: i32,
    vy: i32,
    vw: i32,
    vh: i32,
}

impl Mapper {
    fn new() -> Result<Mapper, Fail> {
        let r = output_rect().ok_or(("internal", "no display".to_string()))?;
        unsafe {
            Ok(Mapper {
                ox: r.left,
                oy: r.top,
                w: r.right - r.left,
                h: r.bottom - r.top,
                vx: GetSystemMetrics(SM_XVIRTUALSCREEN),
                vy: GetSystemMetrics(SM_YVIRTUALSCREEN),
                vw: GetSystemMetrics(SM_CXVIRTUALSCREEN).max(2),
                vh: GetSystemMetrics(SM_CYVIRTUALSCREEN).max(2),
            })
        }
    }
    fn point(&self, a: &Value, kx: &str, ky: &str) -> Result<POINT, Fail> {
        let x = a[kx].as_f64().ok_or(("bad_request", format!("{kx} is required")))?;
        let y = a[ky].as_f64().ok_or(("bad_request", format!("{ky} is required")))?;
        if x < 0.0 || y < 0.0 || x >= self.w as f64 || y >= self.h as f64 {
            return Err(("bad_request", format!("({x},{y}) is outside the {}x{} screen", self.w, self.h)));
        }
        Ok(POINT { x: self.ox + x.round() as i32, y: self.oy + y.round() as i32 })
    }
    /// Pixel -> 0..65535 at the CENTER of the pixel: Windows maps back with abs * size / 65536 (floor), so a
    /// truncated value can land one pixel short (lab 053: 1 px off at y=1).
    fn abs(&self, p: POINT) -> (i32, i32) {
        let f = |v: i32, size: i32| (((2 * v as i64 + 1) * 32768) / size.max(1) as i64).clamp(0, 65535) as i32;
        (f(p.x - self.vx, self.vw), f(p.y - self.vy, self.vh))
    }
    fn move_to(&self, p: POINT) -> INPUT {
        let (x, y) = self.abs(p);
        mouse(MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK | MOUSEEVENTF_MOVE, x, y, 0)
    }
}

/// The checks before an action; `points` are the desktop points the pointer will touch.
fn precheck(points: &[POINT]) -> Result<(), Fail> {
    let f = foreground(Duration::from_millis(500));
    if let Some(code) = f.blocked {
        return Err((code, block_message(code, &f)));
    }
    for p in points {
        let h = unsafe { GetAncestor(WindowFromPoint(*p), GA_ROOT) };
        if h.0.is_null() {
            continue;
        }
        if let (Some(code), info) = window_block(h) {
            return Err((code, format!("the window '{}' ({}) under the pointer runs elevated: the agent can't act on it", window_text(h), info.image)));
        }
    }
    Ok(())
}

fn ext(vk: u16) -> bool {
    matches!(
        VIRTUAL_KEY(vk),
        VK_INSERT | VK_DELETE | VK_HOME | VK_END | VK_PRIOR | VK_NEXT | VK_LEFT | VK_RIGHT | VK_UP | VK_DOWN | VK_LWIN | VK_RWIN | VK_APPS | VK_DIVIDE | VK_NUMLOCK | VK_SNAPSHOT
    )
}

fn vk_of(name: &str) -> Result<u16, Fail> {
    let n = name.trim().to_ascii_lowercase();
    let vk = match n.as_str() {
        "ctrl" | "control" => VK_CONTROL,
        "shift" => VK_SHIFT,
        "alt" => VK_MENU,
        "win" | "meta" | "cmd" => VK_LWIN,
        "enter" | "return" => VK_RETURN,
        "esc" | "escape" => VK_ESCAPE,
        "tab" => VK_TAB,
        "backspace" => VK_BACK,
        "delete" | "del" => VK_DELETE,
        "insert" | "ins" => VK_INSERT,
        "space" => VK_SPACE,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "home" => VK_HOME,
        "end" => VK_END,
        "pageup" | "pgup" => VK_PRIOR,
        "pagedown" | "pgdn" => VK_NEXT,
        "capslock" => VK_CAPITAL,
        "printscreen" => VK_SNAPSHOT,
        "menu" | "apps" => VK_APPS,
        s if s.len() >= 2 && s.starts_with('f') && s[1..].parse::<u16>().is_ok_and(|n| (1..=24).contains(&n)) => {
            VIRTUAL_KEY(VK_F1.0 + s[1..].parse::<u16>().unwrap() - 1)
        }
        s if s.len() == 1 && s.as_bytes()[0].is_ascii_alphanumeric() => VIRTUAL_KEY(s.to_ascii_uppercase().as_bytes()[0] as u16),
        s if s.chars().count() == 1 => {
            // punctuation: the key that types it on the current layout
            let c = s.encode_utf16().next().unwrap();
            let r = unsafe { VkKeyScanW(c) };
            if r == -1 {
                return Err(("bad_request", format!("no key types '{s}' on this keyboard layout")));
            }
            VIRTUAL_KEY((r & 0xff) as u16)
        }
        _ => return Err(("bad_request", format!("unknown key '{name}'"))),
    };
    Ok(vk.0)
}

fn combo(keys: &str) -> Result<Vec<INPUT>, Fail> {
    let vks: Vec<u16> = keys.split('+').filter(|k| !k.trim().is_empty()).map(vk_of).collect::<Result<_, _>>()?;
    if vks.is_empty() || vks.len() > 5 {
        return Err(("bad_request", "keys is 1 to 5 keys joined by '+', e.g. ctrl+shift+end".into()));
    }
    let mk = |vk: u16, up: bool| {
        let scan = unsafe { MapVirtualKeyW(vk as u32, MAPVK_VK_TO_VSC) } as u16;
        let mut f = if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) };
        if ext(vk) {
            f |= KEYEVENTF_EXTENDEDKEY;
        }
        key(vk, scan, f)
    };
    let mut v: Vec<INPUT> = vks.iter().map(|&k| mk(k, false)).collect();
    v.extend(vks.iter().rev().map(|&k| mk(k, true)));
    Ok(v)
}

fn mods(a: &Value) -> Result<Vec<u16>, Fail> {
    let list: Vec<String> = match &a["mods"] {
        Value::Null => vec![],
        Value::String(s) => s.split('+').map(str::to_string).collect(),
        Value::Array(v) => v.iter().filter_map(|x| x.as_str().map(str::to_string)).collect(),
        _ => return Err(("bad_request", "mods is a list like [\"ctrl\",\"shift\"]".into())),
    };
    list.iter().filter(|s| !s.trim().is_empty()).map(|s| vk_of(s)).collect()
}

fn text_inputs(text: &str) -> Vec<INPUT> {
    let mut v = Vec::new();
    for u in text.encode_utf16() {
        match u {
            0x0D => {}
            0x0A | 0x09 => {
                let vk = if u == 0x0A { VK_RETURN.0 } else { VK_TAB.0 };
                v.push(key(vk, 0, KEYBD_EVENT_FLAGS(0)));
                v.push(key(vk, 0, KEYEVENTF_KEYUP));
            }
            _ => {
                v.push(key(0, u, KEYEVENTF_UNICODE));
                v.push(key(0, u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
            }
        }
    }
    v
}

fn buttons(a: &Value) -> Result<(MOUSE_EVENT_FLAGS, MOUSE_EVENT_FLAGS), Fail> {
    Ok(match a["button"].as_str().unwrap_or("left") {
        "left" => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
        "right" => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
        "middle" => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
        b => return Err(("bad_request", format!("unknown button '{b}'"))),
    })
}

fn do_action(a: &Value, m: &Mapper, waited: &mut u64) -> Result<(), Fail> {
    let kind = a["type"].as_str().or_else(|| a["do"].as_str()).ok_or(("bad_request", "each action needs a type".to_string()))?;
    let base = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    match kind {
        "click" => {
            let p = m.point(a, "x", "y")?;
            let count = a["count"].as_u64().unwrap_or(1).clamp(1, 3);
            let (down, up) = buttons(a)?;
            let mods = mods(a)?;
            precheck(&[p])?;
            let (x, y) = m.abs(p);
            let mut v: Vec<INPUT> = mods.iter().map(|&k| key(k, 0, KEYBD_EVENT_FLAGS(0))).collect();
            v.push(m.move_to(p));
            for _ in 0..count {
                v.push(mouse(base | down, x, y, 0));
                v.push(mouse(base | up, x, y, 0));
            }
            v.extend(mods.iter().rev().map(|&k| key(k, 0, KEYEVENTF_KEYUP)));
            send(&v)
        }
        "move" => {
            let p = m.point(a, "x", "y")?;
            precheck(&[p])?;
            send(&[m.move_to(p)])
        }
        "drag" => {
            let p = m.point(a, "x", "y")?;
            let q = m.point(a, "toX", "toY")?;
            let (down, up) = buttons(a)?;
            precheck(&[p, q])?;
            let (x, y) = m.abs(p);
            send(&[m.move_to(p), mouse(base | down, x, y, 0)])?;
            // move in steps so apps see a drag, not a jump
            for i in 1..=12 {
                std::thread::sleep(Duration::from_millis(12));
                let s = POINT { x: p.x + (q.x - p.x) * i / 12, y: p.y + (q.y - p.y) * i / 12 };
                send(&[m.move_to(s)])?;
            }
            let (qx, qy) = m.abs(q);
            send(&[mouse(base | up, qx, qy, 0)])
        }
        "scroll" => {
            let p = m.point(a, "x", "y")?;
            let dx = a["dx"].as_f64().unwrap_or(0.0).clamp(-50.0, 50.0);
            let dy = a["dy"].as_f64().unwrap_or(0.0).clamp(-50.0, 50.0);
            precheck(&[p])?;
            let mut v = vec![m.move_to(p)];
            if dy != 0.0 {
                v.push(mouse(MOUSEEVENTF_WHEEL, 0, 0, (-dy * 120.0) as i32)); // dy > 0 scrolls down
            }
            if dx != 0.0 {
                v.push(mouse(MOUSEEVENTF_HWHEEL, 0, 0, (dx * 120.0) as i32)); // dx > 0 scrolls right
            }
            send(&v)
        }
        "type" => {
            let t = a["text"].as_str().ok_or(("bad_request", "text is required".to_string()))?;
            if t.chars().count() > MAX_TEXT {
                return Err(("too_large", format!("type takes at most {MAX_TEXT} characters")));
            }
            precheck(&[])?;
            // in chunks, re-checking in between (a window can take the focus while we type)
            let all = text_inputs(t);
            for chunk in all.chunks(256) {
                send(chunk)?;
                if all.len() > 256 {
                    precheck(&[])?;
                }
            }
            Ok(())
        }
        "key" => {
            let keys = a["keys"].as_str().ok_or(("bad_request", "keys is required".to_string()))?;
            let repeat = a["repeat"].as_u64().unwrap_or(1).clamp(1, 100);
            let v = combo(keys)?;
            for _ in 0..repeat {
                precheck(&[])?;
                send(&v)?;
            }
            Ok(())
        }
        "wait" => {
            let ms = a["ms"].as_u64().unwrap_or(0).min(5000);
            if *waited + ms > MAX_WAIT_TOTAL_MS {
                return Err(("bad_request", format!("waits add up to more than {} s in one request", MAX_WAIT_TOTAL_MS / 1000)));
            }
            *waited += ms;
            std::thread::sleep(Duration::from_millis(ms));
            Ok(())
        }
        k => Err(("bad_request", format!("unknown action '{k}'"))),
    }
}

pub fn input_act(p: &Value, id: u64) -> CallResult {
    let actions = p["actions"].as_array().ok_or(("bad_request", "actions is a list".to_string()))?;
    if actions.is_empty() || actions.len() > MAX_ACTIONS {
        return Err(("bad_request", format!("1 to {MAX_ACTIONS} actions per request")));
    }
    let stop = p["stopOnError"].as_bool().unwrap_or(true);
    let m = Mapper::new()?;
    let mut done = 0;
    let mut waited = 0;
    let mut failed = Vec::new();
    for (i, a) in actions.iter().enumerate() {
        if crate::helper::is_cancelled(id) {
            return Err(("cancelled", format!("cancelled by the host (done: {done})")));
        }
        match do_action(a, &m, &mut waited) {
            Ok(()) => done += 1,
            Err((code, msg)) if stop => return Err((code, format!("action {i}: {msg} (done: {done})"))),
            Err((code, msg)) => failed.push(json!({"i": i, "code": code, "message": msg})),
        }
    }
    let mut r = json!({"done": done});
    if !failed.is_empty() {
        r["failed"] = json!(failed);
    }
    Ok((r, None))
}

#[cfg(test)]
mod tests {
    #[test]
    fn absolute_coordinates_land_on_the_same_pixel() {
        // Windows maps an absolute coordinate back to a pixel as abs * size / 65536 (floor)
        for size in [600, 768, 800, 1080, 1366, 1920, 3840] {
            let m = super::Mapper { ox: 0, oy: 0, w: size, h: size, vx: 0, vy: 0, vw: size, vh: size };
            for p in 0..size {
                let (a, _) = m.abs(windows::Win32::Foundation::POINT { x: p, y: 0 });
                assert_eq!((a as i64 * size as i64 / 65536) as i32, p, "size {size} pixel {p}");
            }
        }
    }
}
