//! Small safe wrappers over the Win32 calls the service needs (processes, tokens, files).

use std::path::{Path, PathBuf};

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::Cryptography::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::RemoteDesktop::*;
use windows_sys::Win32::System::Threading::*;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

pub fn wide_path(p: &Path) -> Vec<u16> {
    use std::os::windows::ffi::OsStrExt;
    p.as_os_str().encode_wide().chain(Some(0)).collect()
}

pub fn last_error(what: &str) -> String {
    format!("{what} falló (error {})", unsafe { GetLastError() })
}

/// An owned kernel handle, closed on drop.
pub struct Handle(pub HANDLE);
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe { CloseHandle(self.0) };
        }
    }
}

pub fn open_process(pid: u32) -> Result<Handle, String> {
    let h = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
    if h.is_null() { Err(last_error("OpenProcess")) } else { Ok(Handle(h)) }
}

pub fn process_image(process: HANDLE) -> Result<PathBuf, String> {
    let mut buf = [0u16; 1024];
    let mut len = buf.len() as u32;
    if unsafe { QueryFullProcessImageNameW(process, 0, buf.as_mut_ptr(), &mut len) } == 0 {
        return Err(last_error("QueryFullProcessImageNameW"));
    }
    Ok(PathBuf::from(String::from_utf16_lossy(&buf[..len as usize])))
}

pub fn process_token(process: HANDLE) -> Result<Handle, String> {
    let mut token = std::ptr::null_mut();
    if unsafe { OpenProcessToken(process, TOKEN_QUERY, &mut token) } == 0 {
        return Err(last_error("OpenProcessToken"));
    }
    Ok(Handle(token))
}

pub fn session_of(pid: u32) -> u32 {
    let mut session = u32::MAX;
    unsafe { ProcessIdToSessionId(pid, &mut session) };
    session
}

fn token_info(token: HANDLE, class: TOKEN_INFORMATION_CLASS) -> Result<Vec<u8>, String> {
    let mut len = 0u32;
    unsafe { GetTokenInformation(token, class, std::ptr::null_mut(), 0, &mut len) };
    let mut buf = vec![0u8; len.max(8) as usize];
    if unsafe { GetTokenInformation(token, class, buf.as_mut_ptr().cast(), len, &mut len) } == 0 {
        return Err(last_error("GetTokenInformation"));
    }
    Ok(buf)
}

pub fn token_sid(token: HANDLE) -> Result<String, String> {
    let buf = token_info(token, TokenUser)?;
    let user = unsafe { &*(buf.as_ptr() as *const TOKEN_USER) };
    let mut text: *mut u16 = std::ptr::null_mut();
    if unsafe { ConvertSidToStringSidW(user.User.Sid, &mut text) } == 0 {
        return Err(last_error("ConvertSidToStringSidW"));
    }
    let len = (0..).take_while(|&i| unsafe { *text.add(i) } != 0).count();
    let sid = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(text, len) });
    unsafe { LocalFree(text.cast()) };
    Ok(sid)
}

pub fn token_elevated(token: HANDLE) -> Result<bool, String> {
    let buf = token_info(token, TokenElevation)?;
    Ok(unsafe { (*(buf.as_ptr() as *const TOKEN_ELEVATION)).TokenIsElevated } != 0)
}

/// The elevated token of the user signed in to `session`, who must be `expected_sid`. That is the linked token of
/// their filtered token: the same rights a UAC "Sí" gives them. Accounts that are not administrators have none.
pub fn elevated_user_token(session: u32, expected_sid: &str) -> Result<Handle, String> {
    let mut raw = std::ptr::null_mut();
    if unsafe { WTSQueryUserToken(session, &mut raw) } == 0 {
        return Err(last_error("WTSQueryUserToken"));
    }
    let token = Handle(raw);
    if token_sid(token.0)? != expected_sid {
        return Err("La sesión de Windows pertenece a otro usuario.".into());
    }
    let kind = i32::from_ne_bytes(token_info(token.0, TokenElevationType)?[..4].try_into().unwrap());
    let source = if kind == TokenElevationTypeLimited {
        let buf = token_info(token.0, TokenLinkedToken)?;
        Handle(unsafe { (*(buf.as_ptr() as *const TOKEN_LINKED_TOKEN)).LinkedToken })
    } else if token_elevated(token.0)? {
        token
    } else {
        return Err("GpuVM necesita una cuenta de administrador de este equipo.".into());
    };
    let mut primary = std::ptr::null_mut();
    if unsafe { DuplicateTokenEx(source.0, TOKEN_ALL_ACCESS, std::ptr::null(), SecurityImpersonation, TokenPrimary, &mut primary) } == 0 {
        return Err(last_error("DuplicateTokenEx"));
    }
    Ok(Handle(primary))
}

/// 128 random bits as hex, from the system's cryptographic generator.
pub fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    unsafe { BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), bytes.len() as u32, BCRYPT_USE_SYSTEM_PREFERRED_RNG) };
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Only plain local paths (`D:\ISOs\x.iso`): no network shares, device paths or relative paths.
pub fn is_plain_local_path(path: &str) -> bool {
    let b = path.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && b[2] == b'\\' && !path.contains("\\\\") && !path.contains('/')
        && !path.split('\\').any(|part| part == ".." || part == ".")
}

/// Opens `path` with the caller's current identity (the service impersonates the app's user before calling it)
/// and checks it leads where it says: a link anywhere in the path (junction, symbolic link) changes the final path.
pub fn check_access(path: &str, folder: bool) -> Result<(), String> {
    let (access, flags) = if folder { (FILE_LIST_DIRECTORY, FILE_FLAG_BACKUP_SEMANTICS) } else { (GENERIC_READ, 0) };
    let h = unsafe {
        CreateFileW(wide(path).as_ptr(), access, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, std::ptr::null(),
            OPEN_EXISTING, flags, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(match unsafe { GetLastError() } {
            ERROR_ACCESS_DENIED => format!("Tu usuario no tiene acceso a {path}."),
            ERROR_FILE_NOT_FOUND | ERROR_PATH_NOT_FOUND => format!("No existe {path}."),
            code => format!("No se pudo abrir {path} (error {code})."),
        });
    }
    let h = Handle(h);
    let mut buf = [0u16; 1024];
    let len = unsafe { GetFinalPathNameByHandleW(h.0, buf.as_mut_ptr(), buf.len() as u32, FILE_NAME_NORMALIZED) } as usize;
    if len == 0 || len >= buf.len() {
        return Err(last_error("GetFinalPathNameByHandleW"));
    }
    let real = String::from_utf16_lossy(&buf[..len]);
    let real = real.strip_prefix(r"\\?\").unwrap_or(&real);
    if !real.trim_end_matches('\\').eq_ignore_ascii_case(path.trim_end_matches('\\')) {
        return Err(format!("{path} pasa por un enlace a otra carpeta; elige la ubicación real."));
    }
    Ok(())
}
