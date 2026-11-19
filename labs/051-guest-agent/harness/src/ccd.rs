//! `guest-ccd <mode>` (as the agent user, in its console session): what Windows' display configuration holds when the
//! agent sees no display (lab 051: 2 of 10 copies had 0 active paths and every display device detached), and whether
//! it can be turned on again from the session. mode: `probe` (look only), `vdd` (activate the virtual display's path
//! from QDC_ALL_PATHS, Windows picks the mode), `extend` (SDC_TOPOLOGY_EXTEND, like DisplaySwitch /extend), `all`
//! (vdd, then extend if still nothing). Writes C:\Users\Public\lab051-ccd.json.
use serde_json::{json, Value};
use windows::core::PCWSTR;
use windows::Win32::Devices::Display::*;
use windows::Win32::Graphics::Gdi::*;

fn wstr(b: &[u16]) -> String {
    String::from_utf16_lossy(&b[..b.iter().position(|&c| c == 0).unwrap_or(b.len())])
}

fn devices() -> Vec<Value> {
    let mut v = Vec::new();
    unsafe {
        for i in 0..16 {
            let mut dd = DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(PCWSTR::null(), i, &mut dd, 0).as_bool() {
                break;
            }
            v.push(json!({"name": wstr(&dd.DeviceName), "adapter": wstr(&dd.DeviceString), "flags": format!("{:#x}", dd.StateFlags.0)}));
        }
    }
    v
}

fn query(flags: QUERY_DISPLAY_CONFIG_FLAGS) -> Result<(Vec<DISPLAYCONFIG_PATH_INFO>, Vec<DISPLAYCONFIG_MODE_INFO>), String> {
    unsafe {
        let (mut np, mut nm) = (0u32, 0u32);
        GetDisplayConfigBufferSizes(flags, &mut np, &mut nm).ok().map_err(|e| format!("sizes: {e}"))?;
        let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); np.max(1) as usize];
        let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); nm.max(1) as usize];
        let r = QueryDisplayConfig(flags, &mut np, paths.as_mut_ptr(), &mut nm, modes.as_mut_ptr(), None);
        if r.is_err() {
            return Err(format!("query {} (sizes said {np} paths {nm} modes)", r.0));
        }
        paths.truncate(np as usize);
        modes.truncate(nm as usize);
        Ok((paths, modes))
    }
}

fn source_name(p: &DISPLAYCONFIG_PATH_INFO) -> String {
    unsafe {
        let mut req = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
        req.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        req.header.size = std::mem::size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
        req.header.adapterId = p.sourceInfo.adapterId;
        req.header.id = p.sourceInfo.id;
        let r = DisplayConfigGetDeviceInfo(&mut req.header);
        if r == 0 { wstr(&req.viewGdiDeviceName) } else { format!("err {r}") }
    }
}

fn target_name(p: &DISPLAYCONFIG_PATH_INFO) -> String {
    unsafe {
        let mut req = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
        req.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        req.header.size = std::mem::size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
        req.header.adapterId = p.targetInfo.adapterId;
        req.header.id = p.targetInfo.id;
        let r = DisplayConfigGetDeviceInfo(&mut req.header);
        if r == 0 { format!("{} [{}]", wstr(&req.monitorFriendlyDeviceName), wstr(&req.monitorDevicePath)) } else { format!("err {r}") }
    }
}

fn snapshot() -> Value {
    let active = match query(QDC_ONLY_ACTIVE_PATHS) {
        Ok((p, m)) => json!({"paths": p.len(), "modes": m.len(), "sources": p.iter().map(source_name).collect::<Vec<_>>()}),
        Err(e) => json!({"error": e}),
    };
    let all = match query(QDC_ALL_PATHS) {
        Ok((p, _)) => json!(p
            .iter()
            .filter(|p| p.targetInfo.targetAvailable.as_bool())
            .map(|p| json!({"source": source_name(p), "srcId": p.sourceInfo.id, "target": target_name(p), "tgtId": p.targetInfo.id, "flags": p.flags}))
            .collect::<Vec<_>>()),
        Err(e) => json!({"error": e}),
    };
    json!({"devices": devices(), "active": active, "availablePaths": all, "session": session()})
}

/// Which session this is and whether it owns the console's display (CCD returns nothing at all to a session that
/// doesn't, lab 051).
fn session() -> Value {
    use windows::Win32::System::RemoteDesktop::*;
    use windows::Win32::UI::WindowsAndMessaging::*;
    unsafe {
        let mut me = 0u32;
        let _ = windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(windows::Win32::System::Threading::GetCurrentProcessId(), &mut me);
        let console = WTSGetActiveConsoleSessionId();
        let mut buf = windows::core::PWSTR::null();
        let mut len = 0u32;
        let proto = if WTSQuerySessionInformationW(None, me, WTSClientProtocolType, &mut buf, &mut len).is_ok() && len >= 2 {
            let v = *(buf.0 as *const u16);
            WTSFreeMemory(buf.0 as *mut _);
            v as i64
        } else {
            -1
        };
        let state = if WTSQuerySessionInformationW(None, me, WTSConnectState, &mut buf, &mut len).is_ok() && len >= 4 {
            let v = *(buf.0 as *const i32);
            WTSFreeMemory(buf.0 as *mut _);
            v as i64
        } else {
            -1
        };
        json!({"me": me, "console": console, "protocol": proto, "connectState": state,
            "remote": GetSystemMetrics(SM_REMOTESESSION), "monitors": GetSystemMetrics(SM_CMONITORS),
            "screen": [GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)]})
    }
}

fn active_count() -> usize {
    query(QDC_ONLY_ACTIVE_PATHS).map(|(p, _)| p.len()).unwrap_or(0)
}

/// The virtual display's GDI name (\\.\DISPLAYn) from EnumDisplayDevices.
fn vdd_name() -> Option<String> {
    devices().into_iter().find_map(|d| {
        let a = d["adapter"].as_str().unwrap_or("").to_ascii_lowercase();
        (a.contains("virtual display") || a.contains("iddsample") || a.contains("mttvdd")).then(|| d["name"].as_str().unwrap_or("").to_string())
    })
}

fn activate_vdd() -> Value {
    let Some(gdi) = vdd_name() else { return json!({"error": "no virtual display device"}) };
    let (paths, _) = match query(QDC_ALL_PATHS) {
        Ok(x) => x,
        Err(e) => return json!({"error": e}),
    };
    let Some(mut p) = paths.into_iter().find(|p| p.targetInfo.targetAvailable.as_bool() && source_name(p).eq_ignore_ascii_case(&gdi)) else {
        return json!({"error": format!("no available path with source {gdi}")});
    };
    p.flags = DISPLAYCONFIG_PATH_ACTIVE;
    p.sourceInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
    p.targetInfo.Anonymous.modeInfoIdx = DISPLAYCONFIG_PATH_MODE_IDX_INVALID;
    let flags = SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES;
    let validate = unsafe { SetDisplayConfig(Some(&[p]), None, flags | SDC_VALIDATE) };
    let apply = unsafe { SetDisplayConfig(Some(&[p]), None, flags | SDC_APPLY) };
    std::thread::sleep(std::time::Duration::from_millis(1500));
    json!({"source": gdi, "validate": validate, "apply": apply, "activeAfter": active_count()})
}

fn extend() -> Value {
    let validate = unsafe { SetDisplayConfig(None, None, SDC_TOPOLOGY_EXTEND | SDC_VALIDATE) };
    let apply = unsafe { SetDisplayConfig(None, None, SDC_TOPOLOGY_EXTEND | SDC_APPLY) };
    std::thread::sleep(std::time::Duration::from_millis(1500));
    json!({"validate": validate, "apply": apply, "activeAfter": active_count()})
}

pub fn run(mode: &str) {
    let mut out = serde_json::Map::new();
    out.insert("before".into(), snapshot());
    if mode == "vdd" || mode == "all" {
        out.insert("vdd".into(), activate_vdd());
    }
    if mode == "extend" || (mode == "all" && active_count() == 0) {
        out.insert("extend".into(), extend());
    }
    // `wake`: is the display just powered off? Ask for it (ES_DISPLAY_REQUIRED) and move the mouse by one pixel and
    // back, then only watch for 10 s (no layout call)
    if mode == "wake" {
        use windows::Win32::System::Power::*;
        use windows::Win32::UI::Input::KeyboardAndMouse::*;
        let before = active_count();
        unsafe {
            SetThreadExecutionState(ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
            let mv = |dx: i32| INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy: 0, mouseData: 0, dwFlags: MOUSEEVENTF_MOVE, time: 0, dwExtraInfo: 0 } } };
            let sent = SendInput(&[mv(1), mv(-1)], std::mem::size_of::<INPUT>() as i32);
            let mut seen = Vec::new();
            for _ in 0..20 {
                std::thread::sleep(std::time::Duration::from_millis(500));
                seen.push(active_count());
                if *seen.last().unwrap() > 0 {
                    break;
                }
            }
            out.insert("wake".into(), json!({"before": before, "sent": sent, "activeEvery500ms": seen}));
        }
    }
    // `retry`: extend every 3 s for 30 s until something is active (does it come back later by itself or by retrying?)
    if mode == "retry" {
        let mut tries = Vec::new();
        for _ in 0..10 {
            if active_count() > 0 {
                break;
            }
            tries.push(extend());
            std::thread::sleep(std::time::Duration::from_millis(1500));
        }
        out.insert("retries".into(), json!(tries));
    }
    if mode != "probe" {
        out.insert("after".into(), snapshot());
    }
    let _ = std::fs::write(r"C:\Users\Public\lab051-ccd.json", Value::Object(out).to_string());
}
