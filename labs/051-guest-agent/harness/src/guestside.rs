//! Lab-only tools that run INSIDE the guest to create the blocking situations the agent must refuse:
//! - `guest-system-window <exe>` (run as SYSTEM by a one-shot task): starts <exe> in the active console session with a
//!   SYSTEM token, i.e. a window above the agent's integrity on the agent's own desktop (what `uiAccess`-less input
//!   can't reach). Writes {pid, rect} to C:\ProgramData\GpuVMLab051\syswin.json.
//! - `guest-errorbox` (run as the agent user): asks csrss for a hard-error box (NtRaiseHardError with
//!   STATUS_SERVICE_NOTIFICATION), the kind of SYSTEM-owned box that blocked all input in lab 049.
use gpuvm_agent::util::wide;
use std::time::{Duration, Instant};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Security::*;
use windows::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;
use windows::Win32::System::Threading::*;
use windows::Win32::UI::WindowsAndMessaging::*;

pub fn system_window(exe: &str) {
    let out = r"C:\ProgramData\GpuVMLab051\syswin.json";
    let r = (|| -> Result<String, String> {
        unsafe {
            let mut tok = HANDLE::default();
            OpenProcessToken(GetCurrentProcess(), TOKEN_ALL_ACCESS, &mut tok).map_err(|e| e.to_string())?;
            let mut dup = HANDLE::default();
            DuplicateTokenEx(tok, TOKEN_ALL_ACCESS, None, SecurityImpersonation, TokenPrimary, &mut dup).map_err(|e| e.to_string())?;
            let session = WTSGetActiveConsoleSessionId();
            SetTokenInformation(dup, TokenSessionId, &session as *const u32 as *const _, 4).map_err(|e| format!("session: {e}"))?;
            let mut desk = wide("winsta0\\default");
            let si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, lpDesktop: PWSTR(desk.as_mut_ptr()), ..Default::default() };
            let mut pi = PROCESS_INFORMATION::default();
            let mut cmd = wide(&format!("\"{exe}\""));
            CreateProcessAsUserW(Some(dup), PCWSTR::null(), Some(PWSTR(cmd.as_mut_ptr())), None, None, false, PROCESS_CREATION_FLAGS(0), None, PCWSTR::null(), &si, &mut pi)
                .map_err(|e| format!("CreateProcessAsUser: {e}"))?;
            // its window and rect
            struct F {
                pid: u32,
                hwnd: HWND,
            }
            unsafe extern "system" fn cb(h: HWND, lp: LPARAM) -> windows::core::BOOL {
                let f = &mut *(lp.0 as *mut F);
                let mut pid = 0;
                GetWindowThreadProcessId(h, Some(&mut pid));
                if pid == f.pid && IsWindowVisible(h).as_bool() {
                    f.hwnd = h;
                    return false.into();
                }
                true.into()
            }
            let mut f = F { pid: pi.dwProcessId, hwnd: HWND::default() };
            let t = Instant::now();
            while f.hwnd.0.is_null() && t.elapsed() < Duration::from_secs(10) {
                std::thread::sleep(Duration::from_millis(100));
                let _ = EnumWindows(Some(cb), LPARAM(&mut f as *mut F as isize));
            }
            let mut rc = RECT::default();
            let _ = GetWindowRect(f.hwnd, &mut rc);
            Ok(format!(
                "{{\"pid\":{},\"session\":{session},\"found\":{},\"rect\":[{},{},{},{}]}}",
                pi.dwProcessId,
                !f.hwnd.0.is_null(),
                rc.left,
                rc.top,
                rc.right,
                rc.bottom
            ))
        }
    })();
    let text = r.unwrap_or_else(|e| format!("{{\"error\":{}}}", serde_json::Value::from(e)));
    let _ = std::fs::write(out, text);
}

/// `guest-dup-refresh <rounds>` (as the agent user): does screen.refresh's repaint give a duplication-based
/// capture (what Sunshine's ddx uses) a new frame of a STILL desktop? Per round, interleaved: wait until no frame
/// came for 1.5 s, then A) do nothing / B) RedrawWindow like screen.refresh, and wait up to 1 s for a frame with a
/// new present. Writes C:\Users\Public\lab051-dup.json.
pub fn dup_refresh(rounds: u32) {
    use windows::core::Interface;
    use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::*;
    use windows::Win32::Graphics::Gdi::*;
    let out = r"C:\Users\Public\lab051-dup.json";
    let res = (|| -> Result<String, String> {
        unsafe {
            let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
            let f: IDXGIFactory1 = CreateDXGIFactory1().map_err(|e| e.to_string())?;
            // the output at 0,0 (the agent's display after 0.3.3+)
            let mut found = None;
            let mut i = 0;
            while let Ok(a) = f.EnumAdapters1(i) {
                i += 1;
                let mut j = 0;
                while let Ok(o) = a.EnumOutputs(j) {
                    j += 1;
                    let d = o.GetDesc().map_err(|e| e.to_string())?;
                    if d.AttachedToDesktop.as_bool() && d.DesktopCoordinates.left == 0 && d.DesktopCoordinates.top == 0 {
                        found = Some((a.clone(), o));
                    }
                }
            }
            let (adapter, output) = found.ok_or("no output at 0,0")?;
            let mut dev = None;
            D3D11CreateDevice(&adapter, D3D_DRIVER_TYPE_UNKNOWN, windows::Win32::Foundation::HMODULE::default(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, None, D3D11_SDK_VERSION, Some(&mut dev), None, None)
                .map_err(|e| format!("device {e}"))?;
            let dev = dev.unwrap();
            let o1: IDXGIOutput1 = output.cast().map_err(|e| e.to_string())?;
            let mut dup = o1.DuplicateOutput(&dev).map_err(|e| format!("DuplicateOutput {e}"))?;
            // one acquire: Some(present?) or None on timeout; re-open on access lost
            let mut acquire = |ms: u32, dup: &mut IDXGIOutputDuplication| -> Result<Option<bool>, String> {
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut r = None;
                match dup.AcquireNextFrame(ms, &mut info, &mut r) {
                    Ok(()) => {
                        let _ = dup.ReleaseFrame();
                        Ok(Some(info.LastPresentTime != 0))
                    }
                    Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => Ok(None),
                    Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST => {
                        // a mode change may still be running: retry the re-open for up to 5 s
                        let t = std::time::Instant::now();
                        loop {
                            match o1.DuplicateOutput(&dev) {
                                Ok(d) => {
                                    *dup = d;
                                    break;
                                }
                                Err(e) if t.elapsed() < Duration::from_secs(5) => {
                                    let _ = e;
                                    std::thread::sleep(Duration::from_millis(200));
                                }
                                Err(e) => return Err(format!("re-open {e}")),
                            }
                        }
                        Ok(None)
                    }
                    Err(e) => Err(format!("acquire {e}")),
                }
            };
            let mut rows = Vec::new();
            for r in 0..rounds {
                // still: 1.5 s without a presented frame (max 20 s)
                let t = std::time::Instant::now();
                let mut quiet = std::time::Instant::now();
                while quiet.elapsed() < Duration::from_millis(1500) && t.elapsed() < Duration::from_secs(20) {
                    if let Some(true) = acquire(100, &mut dup)? {
                        quiet = std::time::Instant::now();
                    }
                }
                let still = quiet.elapsed() >= Duration::from_millis(1500);
                let variant = if r % 2 == 0 { "none" } else { "refresh" };
                let t0 = std::time::Instant::now();
                if variant == "refresh" {
                    let _ = RedrawWindow(None, None, None, RDW_INVALIDATE | RDW_ERASE | RDW_FRAME | RDW_ALLCHILDREN | RDW_UPDATENOW);
                }
                let mut got = None;
                while t0.elapsed() < Duration::from_millis(1000) {
                    if let Some(true) = acquire(50, &mut dup)? {
                        got = Some(t0.elapsed().as_secs_f64() * 1e3);
                        break;
                    }
                }
                rows.push(format!("{{\"round\":{r},\"variant\":\"{variant}\",\"still\":{still},\"frameMs\":{}}}", got.map(|m| format!("{m:.1}")).unwrap_or("null".into())));
            }
            Ok(format!("[{}]", rows.join(",")))
        }
    })();
    let text = res.unwrap_or_else(|e| format!("{{\"error\":{}}}", serde_json::Value::from(e)));
    let _ = std::fs::write(out, text);
}

/// `guest-window-rect <class>` (as the agent user): the rect of the first visible top-level window of that class
/// (OSKMainClass for the on-screen keyboard), to C:\Users\Public\lab051-rect.json.
pub fn window_rect(class: &str) {
    let c = wide(class);
    let r = unsafe {
        let h = FindWindowW(PCWSTR(c.as_ptr()), PCWSTR::null()).unwrap_or_default();
        let mut rc = RECT::default();
        let ok = !h.0.is_null() && GetWindowRect(h, &mut rc).is_ok();
        format!("{{\"found\":{ok},\"rect\":[{},{},{},{}]}}", rc.left, rc.top, rc.right, rc.bottom)
    };
    let _ = std::fs::write(r"C:\Users\Public\lab051-rect.json", r);
}

/// `guest-open-helper` (run as the agent user): tries to open the session helper (gpuvm-agent.exe helper) with the
/// rights an attacker would need to steal its pipes or inject (dup handle, VM read/write, all access) and with the
/// harmless ones; writes the results to C:\Users\Public\lab051-open.json.
pub fn open_helper() {
    use windows::Win32::System::Diagnostics::ToolHelp::*;
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0).unwrap();
        let mut e = PROCESSENTRY32W { dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32, ..Default::default() };
        let mut ok = Process32FirstW(snap, &mut e).is_ok();
        while ok {
            let name = String::from_utf16_lossy(&e.szExeFile[..e.szExeFile.iter().position(|&c| c == 0).unwrap_or(0)]);
            if name.eq_ignore_ascii_case("gpuvm-agent.exe") {
                let mut rights = Vec::new();
                for (label, r) in [
                    ("all", PROCESS_ALL_ACCESS),
                    ("dupHandle", PROCESS_DUP_HANDLE),
                    ("vmRead", PROCESS_VM_READ),
                    ("vmWrite", PROCESS_VM_WRITE | PROCESS_VM_OPERATION),
                    ("suspend", PROCESS_SUSPEND_RESUME),
                    ("terminate", PROCESS_TERMINATE),
                    ("writeDac", PROCESS_ACCESS_RIGHTS(0x0004_0000)),
                    ("queryLimited", PROCESS_QUERY_LIMITED_INFORMATION),
                    ("synchronize", PROCESS_SYNCHRONIZE),
                ] {
                    let r = OpenProcess(r, false, e.th32ProcessID);
                    rights.push(format!("\"{label}\":{}", r.is_ok()));
                    if let Ok(h) = r {
                        let _ = CloseHandle(h);
                    }
                }
                out.push(format!("{{\"pid\":{},\"open\":{{{}}}}}", e.th32ProcessID, rights.join(",")));
            }
            ok = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    let _ = std::fs::write(r"C:\Users\Public\lab051-open.json", format!("[{}]", out.join(",")));
}

#[repr(C)]
struct UnicodeString {
    len: u16,
    max: u16,
    buf: *const u16,
}

#[link(name = "ntdll")]
extern "system" {
    fn NtRaiseHardError(status: i32, n: u32, mask: u32, params: *const usize, options: u32, response: *mut u32) -> i32;
}

pub fn errorbox() {
    let text: Vec<u16> = "GpuVM lab 051: a system error box (the agent must not click it)".encode_utf16().collect();
    let cap: Vec<u16> = "GpuVM lab 051".encode_utf16().collect();
    let t = UnicodeString { len: (text.len() * 2) as u16, max: (text.len() * 2) as u16, buf: text.as_ptr() };
    let c = UnicodeString { len: (cap.len() * 2) as u16, max: (cap.len() * 2) as u16, buf: cap.as_ptr() };
    let params = [&t as *const _ as usize, &c as *const _ as usize, 0usize /* MB_OK */, u32::MAX as usize /* no timeout */];
    let mut resp = 0u32;
    // STATUS_SERVICE_NOTIFICATION, 4 params, strings at 0 and 1, OptionOk = 1
    let s = unsafe { NtRaiseHardError(0x5000_0018u32 as i32, 4, 0b11, params.as_ptr(), 1, &mut resp) };
    println!("{{\"status\":{s},\"response\":{resp}}}");
}
