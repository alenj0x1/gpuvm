//! Who am I (user, integrity, session) and launching into the interactive session from SYSTEM.
use crate::util::*;
use std::time::Instant;
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Security::*;
use windows::Win32::System::RemoteDesktop::*;
use windows::Win32::System::Threading::*;

/// Integrity RID of a token (0x2000 medium, 0x3000 high, 0x4000 system, 0x1000 low).
pub fn token_integrity(tok: HANDLE) -> Result<u32, u32> {
    unsafe {
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenIntegrityLevel, None, 0, &mut len);
        let mut buf = vec![0u8; len as usize];
        GetTokenInformation(tok, TokenIntegrityLevel, Some(buf.as_mut_ptr() as *mut _), len, &mut len).map_err(|e| e.code().0 as u32 & 0xffff)?;
        let tml = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
        let sid = tml.Label.Sid;
        let n = *GetSidSubAuthorityCount(sid) as u32;
        Ok(*GetSidSubAuthority(sid, n - 1))
    }
}

pub fn token_user(tok: HANDLE) -> String {
    unsafe {
        let mut len = 0u32;
        let _ = GetTokenInformation(tok, TokenUser, None, 0, &mut len);
        let mut buf = vec![0u8; len as usize];
        if GetTokenInformation(tok, TokenUser, Some(buf.as_mut_ptr() as *mut _), len, &mut len).is_err() {
            return "?".into();
        }
        let tu = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut name = [0u16; 256];
        let mut dom = [0u16; 256];
        let (mut nl, mut dl) = (256u32, 256u32);
        let mut use_ = SID_NAME_USE::default();
        if LookupAccountSidW(PCWSTR::null(), tu.User.Sid, Some(PWSTR(name.as_mut_ptr())), &mut nl, Some(PWSTR(dom.as_mut_ptr())), &mut dl, &mut use_).is_ok() {
            format!("{}\\{}", wstr(&dom), wstr(&name))
        } else {
            "?".into()
        }
    }
}

pub fn token_elevated(tok: HANDLE) -> bool {
    unsafe {
        let mut e = TOKEN_ELEVATION::default();
        let mut len = 0u32;
        GetTokenInformation(tok, TokenElevation, Some(&mut e as *mut _ as *mut _), std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut len).is_ok() && e.TokenIsElevated != 0
    }
}

pub fn self_token() -> HANDLE {
    unsafe {
        let mut t = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut t).unwrap();
        t
    }
}

/// Integrity of another process by pid: Ok(rid) or Err(win32 error opening it).
pub fn process_integrity(pid: u32) -> Result<(u32, String, bool), u32> {
    unsafe {
        let p = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).map_err(|e| e.code().0 as u32 & 0xffff)?;
        let mut t = HANDLE::default();
        let r = OpenProcessToken(p, TOKEN_QUERY, &mut t);
        let _ = CloseHandle(p);
        r.map_err(|e| e.code().0 as u32 & 0xffff)?;
        let il = token_integrity(t);
        let user = token_user(t);
        let elev = token_elevated(t);
        let _ = CloseHandle(t);
        Ok((il?, user, elev))
    }
}

pub fn whoami_json() -> String {
    let t = self_token();
    let mut sid = 0u32;
    unsafe {
        let _ = windows::Win32::System::RemoteDesktop::ProcessIdToSessionId(GetCurrentProcessId(), &mut sid);
    }
    let il = token_integrity(t).unwrap_or(0);
    format!(
        "{{\"user\":{},\"integrity\":\"{:#x}\",\"elevated\":{},\"session\":{},\"pid\":{}}}",
        jstr(&token_user(t)),
        il,
        token_elevated(t),
        sid,
        std::process::id()
    )
}

/// launch-as --user agent --password-file f [--wait] -- <agentprobe args...> : from a process in the person's session,
/// start this exe as another local user on the same desktop (CreateProcessWithLogonW: the Secondary Logon service
/// gives the new logon access to winsta0\default, like runas). Lab only: the password comes from a file that the
/// caller deletes right after.
pub fn cmd_launch_as(args: &[String]) -> String {
    let sep = args.iter().position(|a| a == "--").unwrap_or(args.len());
    let own: Vec<String> = args[..sep].to_vec();
    let rest: Vec<String> = args[(sep + 1).min(args.len())..].to_vec();
    let user = arg_or(&own, "--user", "agent");
    let pw = match arg(&own, "--password-file").and_then(|p| std::fs::read_to_string(p).ok()) {
        Some(p) => p.trim().to_string(),
        None => return "{\"ok\":false,\"error\":\"no password file\"}".into(),
    };
    let exe = std::env::current_exe().unwrap();
    let mut cmdline: Vec<u16> = format!("\"{}\" {}", exe.display(), rest.iter().map(|a| format!("\"{a}\"")).collect::<Vec<_>>().join(" "))
        .encode_utf16()
        .chain([0])
        .collect();
    let u: Vec<u16> = user.encode_utf16().chain([0]).collect();
    let d: Vec<u16> = ".".encode_utf16().chain([0]).collect();
    let p: Vec<u16> = pw.encode_utf16().chain([0]).collect();
    let cwd: Vec<u16> = "C:\\GpuVMLab048".encode_utf16().chain([0]).collect();
    let t0 = Instant::now();
    unsafe {
        // lpDesktop NULL: only then does Secondary Logon grant the new logon access to the caller's window station
        // and desktop (an explicit "winsta0\default" left the child hanging in user32 start-up, lab 049).
        let si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, ..Default::default() };
        let mut pi = PROCESS_INFORMATION::default();
        let r = CreateProcessWithLogonW(
            PCWSTR(u.as_ptr()),
            PCWSTR(d.as_ptr()),
            PCWSTR(p.as_ptr()),
            LOGON_WITH_PROFILE,
            PCWSTR::null(),
            Some(PWSTR(cmdline.as_mut_ptr())),
            CREATE_NO_WINDOW,
            None,
            PCWSTR(cwd.as_ptr()),
            &si,
            &mut pi,
        );
        if let Err(e) = r {
            return format!("{{\"ok\":false,\"stage\":\"CreateProcessWithLogonW\",\"err\":{}}}", e.code().0 as u32 & 0xffff);
        }
        let spawn_ms = t0.elapsed().as_secs_f64() * 1e3;
        let mut code = 0u32;
        if has(args, "--wait") {
            WaitForSingleObject(pi.hProcess, 600_000);
            let _ = GetExitCodeProcess(pi.hProcess, &mut code);
        }
        let _ = CloseHandle(pi.hThread);
        let _ = CloseHandle(pi.hProcess);
        format!("{{\"ok\":true,\"user\":{},\"pid\":{},\"spawnMs\":{spawn_ms:.1},\"totalMs\":{:.1},\"exit\":{code}}}", jstr(&user), pi.dwProcessId, t0.elapsed().as_secs_f64() * 1e3)
    }
}

/// launch [--wait] -- <agentprobe args...> : from SYSTEM, start this same exe in the active console session with the
/// signed-in user's token (WTSQueryUserToken gives the filtered, medium token for an admin), desktop winsta0\default.
pub fn cmd_launch(args: &[String]) -> String {
    let sep = args.iter().position(|a| a == "--").unwrap_or(args.len());
    let rest: Vec<String> = args[(sep + 1).min(args.len())..].to_vec();
    let own: Vec<String> = args[..sep].to_vec();
    let exe = arg(&own, "--exe").map(std::path::PathBuf::from).unwrap_or_else(|| std::env::current_exe().unwrap());
    let mut cmdline: Vec<u16> = format!("\"{}\" {}", exe.display(), rest.iter().map(|a| format!("\"{a}\"")).collect::<Vec<_>>().join(" "))
        .encode_utf16()
        .chain([0])
        .collect();
    let mut desktop: Vec<u16> = "winsta0\\default".encode_utf16().chain([0]).collect();
    let t0 = Instant::now();
    unsafe {
        let session = WTSGetActiveConsoleSessionId();
        let mut tok = HANDLE::default();
        if let Err(e) = WTSQueryUserToken(session, &mut tok) {
            return format!("{{\"ok\":false,\"stage\":\"WTSQueryUserToken\",\"session\":{session},\"err\":{}}}", e.code().0 as u32 & 0xffff);
        }
        let si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, lpDesktop: PWSTR(desktop.as_mut_ptr()), ..Default::default() };
        let mut pi = PROCESS_INFORMATION::default();
        // The user's own environment (profile, TEMP...): inheriting SYSTEM's broke Edge (lab 049).
        let mut env: *mut core::ffi::c_void = std::ptr::null_mut();
        let have_env = windows::Win32::System::Environment::CreateEnvironmentBlock(&mut env, Some(tok), false).is_ok();
        let r = CreateProcessAsUserW(
            Some(tok),
            PCWSTR::null(),
            Some(PWSTR(cmdline.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NO_WINDOW | if have_env { CREATE_UNICODE_ENVIRONMENT } else { PROCESS_CREATION_FLAGS(0) },
            if have_env { Some(env as *const _) } else { None },
            PCWSTR::null(),
            &si,
            &mut pi,
        );
        let spawn_ms = t0.elapsed().as_secs_f64() * 1e3;
        if have_env {
            let _ = windows::Win32::System::Environment::DestroyEnvironmentBlock(env);
        }
        let il = token_integrity(tok).unwrap_or(0);
        let user = token_user(tok);
        let _ = CloseHandle(tok);
        if let Err(e) = r {
            return format!("{{\"ok\":false,\"stage\":\"CreateProcessAsUser\",\"err\":{}}}", e.code().0 as u32 & 0xffff);
        }
        let mut code = 0u32;
        if has(args, "--wait") {
            WaitForSingleObject(pi.hProcess, 600_000);
            let _ = GetExitCodeProcess(pi.hProcess, &mut code);
        }
        let _ = CloseHandle(pi.hThread);
        let _ = CloseHandle(pi.hProcess);
        format!(
            "{{\"ok\":true,\"session\":{session},\"user\":{},\"integrity\":\"{il:#x}\",\"pid\":{},\"spawnMs\":{spawn_ms:.1},\"totalMs\":{:.1},\"exit\":{code}}}",
            jstr(&user),
            pi.dwProcessId,
            t0.elapsed().as_secs_f64() * 1e3
        )
    }
}
