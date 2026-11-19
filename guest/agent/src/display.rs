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

/// Keeps only the active path whose source is `gdi_name` (\\.\DISPLAYn), at 0,0, and applies it for now.
/// Returns the GDI names of the sources turned off.
fn only_this_source(gdi_name: &str) -> Result<Vec<String>, String> {
    use windows::Win32::Devices::Display::*;
    unsafe {
        let (mut np, mut nm) = (0u32, 0u32);
        GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut np, &mut nm).ok().map_err(|e| format!("display config sizes: {e}"))?;
        let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); np as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); nm as usize];
        QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut np, paths.as_mut_ptr(), &mut nm, modes.as_mut_ptr(), None)
            .ok()
            .map_err(|e| format!("display config: {e}"))?;
        paths.truncate(np as usize);
        modes.truncate(nm as usize);
        let name_of = |p: &DISPLAYCONFIG_PATH_INFO| -> String {
            let mut req = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
            req.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
            req.header.size = std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
            req.header.adapterId = p.sourceInfo.adapterId;
            req.header.id = p.sourceInfo.id;
            if DisplayConfigGetDeviceInfo(&mut req.header) == 0 { wstr(&req.viewGdiDeviceName) } else { String::new() }
        };
        let names: Vec<String> = paths.iter().map(name_of).collect();
        let Some(i) = names.iter().position(|n| n.eq_ignore_ascii_case(gdi_name)) else { return Err(format!("{gdi_name} has no active path")) };
        let mut keep = paths[i];
        let mut kept_modes = Vec::new();
        let src_idx = keep.sourceInfo.Anonymous.modeInfoIdx;
        if (src_idx as usize) < modes.len() {
            let mut m = modes[src_idx as usize];
            if m.infoType == DISPLAYCONFIG_MODE_INFO_TYPE_SOURCE {
                m.Anonymous.sourceMode.position = windows::Win32::Foundation::POINTL { x: 0, y: 0 };
            }
            keep.sourceInfo.Anonymous.modeInfoIdx = kept_modes.len() as u32;
            kept_modes.push(m);
        }
        let tgt_idx = keep.targetInfo.Anonymous.modeInfoIdx;
        if (tgt_idx as usize) < modes.len() {
            keep.targetInfo.Anonymous.modeInfoIdx = kept_modes.len() as u32;
            kept_modes.push(modes[tgt_idx as usize]);
        }
        let r = SetDisplayConfig(Some(&[keep]), Some(&kept_modes), SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES);
        if r != 0 {
            return Err(format!("Windows refused the display layout ({r})"));
        }
        Ok(names.into_iter().enumerate().filter(|(j, _)| *j != i).map(|(_, n)| n).collect())
    }
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

/// True when the virtual display (if any) is the only attached display, at 0,0.
pub fn settled() -> bool {
    let devs = devices();
    let Some(vdd) = devs.iter().find(|d| is_vdd(&d.adapter)) else { return true };
    let alone = devs.iter().all(|d| d.name == vdd.name || !d.attached);
    alone && current(&vdd.name).is_some_and(|c| unsafe { c.Anonymous1.Anonymous2.dmPosition.x == 0 && c.Anonymous1.Anonymous2.dmPosition.y == 0 })
}

/// Makes the virtual display the only (hence primary) display and at least MIN_W x MIN_H. Returns what it did
/// (None when nothing had to change), or an error text.
pub fn ensure() -> Result<Option<Value>, String> {
    // only in the agent user's own session (security review): never rearrange the person's displays
    if !crate::token::is_agent_process() {
        return Ok(None);
    }
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
                    // dynamic: not saved in the registry (security review), so nothing outlives the agent's session
                    let r = change(Some(&vdd.name), Some(&m), CDS_TYPE(0));
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
    // the topology through SetDisplayConfig WITHOUT SDC_SAVE_TO_DATABASE: applied now, never written to the
    // machine's display database (security review: the old ChangeDisplaySettingsEx + CDS_UPDATEREGISTRY batch
    // persisted it for every user)
    let off = only_this_source(&vdd.name)?;
    did.insert("turnedOff".into(), json!(off.iter().map(|d| format!("{d}")).collect::<Vec<_>>()));
    Ok(Some(Value::Object(did)))
}
