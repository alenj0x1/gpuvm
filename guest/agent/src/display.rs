//! Agent-mode displays: GpuVM's virtual display must be the ONLY desktop display (so it is also the primary one) even
//! with no viewer connected, or the windows the agent opens land on the GPU-P guest's extra "Microsoft Basic Display"
//! (1024x768, primary by default) that the agent doesn't see (lab 051). Same technique as GpuVM's
//! guest/set-resolution.ps1 (MakeOnlyDisplay + SetMode), run by the session helper, so only machines with the agent.
//! The size is raised to the agent's minimum only when the virtual display is smaller (it starts at 800x600); a size
//! the viewer sets later is left alone.
use crate::util::{wide, wstr};
use serde_json::{json, Value};
use windows::core::PCWSTR;
use windows::Win32::Foundation::HWND;
use windows::Win32::Graphics::Gdi::*;

const MIN_W: u32 = 1280;
const MIN_H: u32 = 800;

fn is_vdd(adapter: &str) -> bool {
    let a = adapter.to_ascii_lowercase();
    a.contains("virtual display") || a.contains("iddsample") || a.contains("mttvdd")
}

struct Dev {
    name: String,
    adapter: String,
    attached: bool,
}

fn devices() -> Vec<Dev> {
    let mut v = Vec::new();
    unsafe {
        for i in 0..32 {
            let mut dd = DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0).as_bool() {
                break;
            }
            v.push(Dev { name: wstr(&dd.DeviceName), adapter: wstr(&dd.DeviceString), attached: (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP).0 != 0 });
        }
    }
    v
}

fn current(dev: &str) -> Option<DEVMODEW> {
    let w = wide(dev);
    let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
    unsafe { EnumDisplaySettingsW(PCWSTR(w.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool().then_some(dm) }
}

/// The best mode of exactly w x h (highest refresh <= 60).
fn find_mode(dev: &str, w: u32, h: u32) -> Option<DEVMODEW> {
    let wd = wide(dev);
    let mut best: Option<DEVMODEW> = None;
    unsafe {
        for m in 0..4096u32 {
            let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
            if !EnumDisplaySettingsW(PCWSTR(wd.as_ptr()), ENUM_DISPLAY_SETTINGS_MODE(m), &mut dm).as_bool() {
                break;
            }
            if dm.dmPelsWidth != w || dm.dmPelsHeight != h || dm.dmDisplayFrequency > 60 {
                continue;
            }
            if best.as_ref().map_or(true, |b| dm.dmDisplayFrequency > b.dmDisplayFrequency) {
                best = Some(dm);
            }
        }
    }
    best
}

/// The sizes a display offers ("1280x800", ...), for the log when none fits.
fn offered(dev: &str) -> Vec<String> {
    let wd = wide(dev);
    let mut v: Vec<String> = Vec::new();
    unsafe {
        for m in 0..4096u32 {
            let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
            if !EnumDisplaySettingsW(PCWSTR(wd.as_ptr()), ENUM_DISPLAY_SETTINGS_MODE(m), &mut dm).as_bool() {
                break;
            }
            let s = format!("{}x{}", dm.dmPelsWidth, dm.dmPelsHeight);
            if !v.contains(&s) {
                v.push(s);
            }
        }
    }
    v
}

fn change(dev: Option<&str>, dm: Option<&DEVMODEW>, flags: CDS_TYPE) -> i32 {
    let w = dev.map(wide);
    unsafe {
        ChangeDisplaySettingsExW(
            w.as_ref().map_or(PCWSTR::null(), |w| PCWSTR(w.as_ptr())),
            dm.map(|d| d as *const DEVMODEW),
            Some(HWND::default()),
            flags,
            None,
        )
        .0
    }
}

/// Makes the virtual display the only (hence primary) display and at least MIN_W x MIN_H. Returns what it did
/// (None when nothing had to change), or an error text.
pub fn ensure() -> Result<Option<Value>, String> {
    let devs = devices();
    let Some(vdd) = devs.iter().find(|d| is_vdd(&d.adapter)) else { return Ok(None) }; // no virtual display: not GpuVM
    let mut did = serde_json::Map::new();
    // 1. size, only when smaller than the agent's minimum (the viewer may set a bigger one later)
    if let Some(cur) = current(&vdd.name) {
        // only when it is below every usable size (it starts at 800x600); 1366x768 or a viewer's size stays: a change
        // every few seconds would make Sunshine re-test its encoders each time (first lab run did exactly that)
        if vdd.attached && (cur.dmPelsWidth < 1280 || cur.dmPelsHeight < 720) {
            // the first of these the virtual display offers (it doesn't offer every size, lab 048: no 1280x720)
            let sizes = [(MIN_W, MIN_H), (1366, 768), (1280, 720), (1440, 900), (1600, 900), (1680, 1050), (1920, 1080)];
            match sizes.iter().find_map(|&(w, h)| find_mode(&vdd.name, w, h).map(|m| (w, h, m))) {
                Some((w, h, mut m)) => {
                    m.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY;
                    let r = change(Some(&vdd.name), Some(&m), CDS_UPDATEREGISTRY);
                    did.insert("mode".into(), json!({"from": [cur.dmPelsWidth, cur.dmPelsHeight], "to": [w, h], "code": r}));
                }
                None => {
                    did.insert("mode".into(), json!({"from": [cur.dmPelsWidth, cur.dmPelsHeight], "error": "no usable size offered", "offered": offered(&vdd.name)}));
                }
            }
        }
    }
    // 2. alone at 0,0
    let others: Vec<&Dev> = devs.iter().filter(|d| d.name != vdd.name && d.attached).collect();
    let at_origin = current(&vdd.name).is_some_and(|c| unsafe { c.Anonymous1.Anonymous2.dmPosition.x == 0 && c.Anonymous1.Anonymous2.dmPosition.y == 0 });
    if vdd.attached && at_origin && others.is_empty() {
        return Ok((!did.is_empty()).then(|| Value::Object(did)));
    }
    let mut primary = current(&vdd.name).ok_or("can't read the virtual display's mode")?;
    primary.Anonymous1.Anonymous2.dmPosition = windows::Win32::Foundation::POINTL { x: 0, y: 0 };
    primary.dmFields = DM_POSITION;
    if !vdd.attached {
        primary.dmFields |= DM_PELSWIDTH | DM_PELSHEIGHT;
        if primary.dmPelsWidth == 0 {
            primary.dmPelsWidth = MIN_W;
            primary.dmPelsHeight = MIN_H;
        }
    }
    let r = change(Some(&vdd.name), Some(&primary), CDS_UPDATEREGISTRY | CDS_SET_PRIMARY | CDS_NORESET);
    if r != 0 {
        return Err(format!("Windows refused to make the virtual display primary ({r})"));
    }
    let mut off = Vec::new();
    for d in others {
        let mut detach = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
        detach.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT; // 0x0 at 0,0 removes it from the desktop
        if change(Some(&d.name), Some(&detach), CDS_UPDATEREGISTRY | CDS_NORESET) == 0 {
            off.push(format!("{} ({})", d.name, d.adapter));
        }
    }
    let r = change(None, None, CDS_TYPE(0));
    did.insert("turnedOff".into(), json!(off));
    did.insert("apply".into(), json!(r));
    if r != 0 {
        return Err(format!("Windows didn't apply the display change ({r})"));
    }
    Ok(Some(Value::Object(did)))
}
