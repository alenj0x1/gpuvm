//! Tokens: integrity, user, elevation of this process or another one.
use crate::util::wstr;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Security::*;
use windows::Win32::System::Threading::*;

pub const IL_LOW: u32 = 0x1000;
pub const IL_MEDIUM: u32 = 0x2000;
pub const IL_HIGH: u32 = 0x3000;
pub const IL_SYSTEM: u32 = 0x4000;

pub fn il_name(il: u32) -> &'static str {
    match il {
        x if x >= IL_SYSTEM => "system",
        x if x >= IL_HIGH => "high",
        x if x >= IL_MEDIUM => "medium",
        x if x >= IL_LOW => "low",
        _ => "untrusted",
    }
}

/// Owned handle closed on drop.
pub struct Owned(pub HANDLE);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_invalid() && !self.0 .0.is_null() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}
unsafe impl Send for Owned {}
unsafe impl Sync for Owned {}

pub fn token_integrity(tok: HANDLE) -> Option<u32> {
    unsafe {
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenIntegrityLevel, None, 0, &mut len);
        if len == 0 {
            return None;
        }
        let mut buf = vec![0u8; len as usize];
        GetTokenInformation(tok, TokenIntegrityLevel, Some(buf.as_mut_ptr() as *mut _), len, &mut len).ok()?;
        let tml = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let n = *GetSidSubAuthorityCount(tml.Label.Sid) as u32;
        Some(*GetSidSubAuthority(tml.Label.Sid, n - 1))
    }
}

pub fn token_elevated(tok: HANDLE) -> bool {
    unsafe {
        let mut e = TOKEN_ELEVATION::default();
        let mut len = 0u32;
        GetTokenInformation(tok, TokenElevation, Some(&mut e as *mut _ as *mut _), std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut len).is_ok()
            && e.TokenIsElevated != 0
    }
}

/// "DOMAIN\name" and the bare name of the token's user.
pub fn token_user(tok: HANDLE) -> (String, String) {
    unsafe {
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenUser, None, 0, &mut len);
        let mut buf = vec![0u8; len.max(1) as usize];
        if GetTokenInformation(tok, TokenUser, Some(buf.as_mut_ptr() as *mut _), len, &mut len).is_err() {
            return ("?".into(), "?".into());
        }
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut name = [0u16; 256];
        let mut dom = [0u16; 256];
        let (mut nl, mut dl) = (256u32, 256u32);
        let mut use_ = SID_NAME_USE::default();
        if LookupAccountSidW(PCWSTR::null(), tu.User.Sid, Some(PWSTR(name.as_mut_ptr())), &mut nl, Some(PWSTR(dom.as_mut_ptr())), &mut dl, &mut use_).is_ok() {
            (format!("{}\\{}", wstr(&dom), wstr(&name)), wstr(&name))
        } else {
            ("?".into(), "?".into())
        }
    }
}

pub fn self_token() -> Owned {
    unsafe {
        let mut t = HANDLE::default();
        let _ = OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut t);
        Owned(t)
    }
}

pub struct ProcInfo {
    pub integrity: Option<u32>,
    pub image: String,
}

/// Integrity (None when the token can't be opened: elevated or protected) and image name of a process.
pub fn process_info(pid: u32) -> ProcInfo {
    unsafe {
        let p = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(p) => Owned(p),
            Err(_) => return ProcInfo { integrity: None, image: String::new() },
        };
        let mut buf = [0u16; 520];
        let mut n = buf.len() as u32;
        let image = if QueryFullProcessImageNameW(p.0, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut n).is_ok() {
            let full = String::from_utf16_lossy(&buf[..n as usize]);
            full.rsplit('\\').next().unwrap_or("").to_string()
        } else {
            String::new()
        };
        let mut t = HANDLE::default();
        let integrity = if OpenProcessToken(p.0, TOKEN_QUERY, &mut t).is_ok() {
            let t = Owned(t);
            token_integrity(t.0)
        } else {
            None
        };
        ProcInfo { integrity, image }
    }
}
