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
