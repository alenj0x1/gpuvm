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

pub fn token_sid(tok: HANDLE) -> Option<String> {
    unsafe {
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenUser, None, 0, &mut len);
        let mut buf = vec![0u8; len.max(1) as usize];
        GetTokenInformation(tok, TokenUser, Some(buf.as_mut_ptr() as *mut _), len, &mut len).ok()?;
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut s = PWSTR::null();
        windows::Win32::Security::Authorization::ConvertSidToStringSidW(tu.User.Sid, &mut s).ok()?;
        let r = s.to_string().ok();
        let _ = LocalFree(Some(HLOCAL(s.0 as _)));
        r
    }
}

/// TokenElevationType: 1 default (no split token), 2 full (elevated admin), 3 limited (an administrator's filtered token).
pub fn token_elevation_type(tok: HANDLE) -> u32 {
    unsafe {
        let mut t = TOKEN_ELEVATION_TYPE::default();
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenElevationType, Some(&mut t as *mut _ as *mut _), 4, &mut len);
        t.0 as u32
    }
}

pub fn token_uiaccess(tok: HANDLE) -> bool {
    unsafe {
        let mut v = 0u32;
        let mut len = 0u32;
        GetTokenInformation(tok, TokenUIAccess, Some(&mut v as *mut _ as *mut _), 4, &mut len).is_ok() && v != 0
    }
}

pub fn agent_mode() -> (Option<String>, String) {
    const K: &str = r"SOFTWARE\GpuVM\Agent";
    (crate::util::reg_hklm(K, "AgentSid"), crate::util::reg_hklm(K, "SignInAs").unwrap_or_else(|| "agent".into()))
}

/// Never an administrator's filtered token when the machine signs in as the person: UAC would be one consent away.
pub fn helper_allowed(agent_sid: Option<&str>, mode: &str, user_sid: &str, elevation_type: u32) -> Result<(), String> {
    let Some(agent) = agent_sid else { return Err("the agent isn't installed (no agent user recorded)".into()) };
    if user_sid.eq_ignore_ascii_case(agent) {
        return Ok(());
    }
    if mode == "agent" {
        return Err("the signed-in user isn't the agent user: the agent only works in the agent's own session".into());
    }
    if elevation_type == 3 {
        return Err("the signed-in user is an administrator: the agent doesn't work in an administrator's session".into());
    }
    if elevation_type == 2 {
        return Err("the signed-in user's session is elevated".into());
    }
    Ok(())
}

/// True when this process runs as the agent user (by SID, never by name).
pub fn is_agent_process() -> bool {
    static A: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
    *A.get_or_init(|| {
        let (agent, _) = agent_mode();
        match (agent, token_sid(self_token().0)) {
            (Some(a), Some(me)) => a.eq_ignore_ascii_case(&me),
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::helper_allowed;
    const A: &str = "S-1-5-21-1-2-3-1001";
    const P: &str = "S-1-5-21-1-2-3-1000";
    #[test]
    fn who_gets_a_helper() {
        assert!(helper_allowed(Some(A), "agent", A, 1).is_ok());
        assert!(helper_allowed(Some(A), "agent", P, 1).is_err(), "agent mode: only the agent");
        assert!(helper_allowed(Some(A), "agent", P, 3).is_err());
        assert!(helper_allowed(Some(A), "previous", P, 1).is_ok(), "person mode: a standard person");
        assert!(helper_allowed(Some(A), "previous", P, 3).is_err(), "never an admin's filtered token");
        assert!(helper_allowed(Some(A), "previous", P, 2).is_err());
        assert!(helper_allowed(None, "agent", A, 1).is_err(), "not installed");
        assert!(helper_allowed(Some(A), "previous", A, 1).is_ok());
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
    pub uiaccess: bool,
}

pub fn process_info(pid: u32) -> ProcInfo {
    unsafe {
        let p = match OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) {
            Ok(p) => Owned(p),
            Err(_) => return ProcInfo { integrity: None, image: String::new(), uiaccess: false },
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
        let (integrity, uiaccess) = if OpenProcessToken(p.0, TOKEN_QUERY, &mut t).is_ok() {
            let t = Owned(t);
            (token_integrity(t.0), token_uiaccess(t.0))
        } else {
            (None, false)
        };
        ProcInfo { integrity, image, uiaccess }
    }
}
