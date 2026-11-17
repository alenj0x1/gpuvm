//! Starts the viewer at Low integrity. The viewer parses what a machine's streaming host sends (video, audio,
//! control), and that host runs inside a VM GpuVM treats as untrusted: if a bug there were exploited, a Low process
//! can't write the user's files or registry, can't open this app's process and can't send messages to its windows
//! (Windows' integrity levels and UIPI), so it can't climb to this app and from there to the GpuVM service.
//! The viewer keeps its settings and pairing under LocalLow (the one place a Low process may write), and its
//! temporary files too.

use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE};
use windows_sys::Win32::Security::Authorization::ConvertStringSidToSidW;
use windows_sys::Win32::Security::{
    DuplicateTokenEx, GetLengthSid, SecurityImpersonation, SetTokenInformation, TokenIntegrityLevel, TokenPrimary,
    SID_AND_ATTRIBUTES, TOKEN_ADJUST_DEFAULT, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE,
    TOKEN_MANDATORY_LABEL, TOKEN_QUERY,
};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, GetCurrentProcess, OpenProcessToken, CREATE_UNICODE_ENVIRONMENT, PROCESS_INFORMATION,
    STARTUPINFOW,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// SE_GROUP_INTEGRITY (winnt.h).
const SE_GROUP_INTEGRITY: u32 = 0x20;
/// Low mandatory level.
const LOW: &str = "S-1-16-4096";

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// The viewer's own folder under LocalLow (settings, pairing, temporary files), created if missing. Folders made
/// there inherit LocalLow's Low label, so the viewer can write them.
pub fn viewer_data() -> Option<PathBuf> {
    let profile = std::env::var_os("USERPROFILE")?;
    let dir = Path::new(&profile).join("AppData").join("LocalLow").join("GpuVM").join("Viewer");
    std::fs::create_dir_all(dir.join("Temp")).ok()?;
    Some(dir)
}

/// One argument quoted the way the C runtime splits a command line.
fn quote(arg: &str) -> String {
    if !arg.is_empty() && !arg.contains([' ', '\t', '\n', '"']) {
        return arg.to_string();
    }
    let mut out = String::from("\"");
    let mut slashes = 0usize;
    for c in arg.chars() {
        match c {
            '\\' => slashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(slashes * 2 + 1));
                out.push('"');
                slashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(slashes));
                out.push(c);
                slashes = 0;
            }
        }
    }
    out.push_str(&"\\".repeat(slashes * 2));
    out.push('"');
    out
}

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: owned handle, closed once.
            unsafe { CloseHandle(self.0) };
        }
    }
}

/// Starts `exe` with `args` at Low integrity, with `env` added to this process's environment (and TEMP/TMP in
/// LocalLow). Returns its process id. Fails rather than starting it at this app's level.
pub fn spawn_low(exe: &Path, args: &[String], env: &[(&str, &str)]) -> Result<u32, String> {
    let fail = || "No se pudo abrir el visor con permisos reducidos.".to_string();
    let temp = viewer_data().ok_or_else(fail)?.join("Temp");
    // SAFETY: standard token calls on this process's own token; every handle and SID is released below.
    unsafe {
        let mut own: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY, &mut own) == 0 {
            return Err(fail());
        }
        let own = Handle(own);
        let mut low: HANDLE = std::ptr::null_mut();
        if DuplicateTokenEx(own.0, TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY, std::ptr::null(), SecurityImpersonation, TokenPrimary, &mut low) == 0 {
            return Err(fail());
        }
        let low = Handle(low);
        let mut sid = std::ptr::null_mut();
        if ConvertStringSidToSidW(wide(LOW).as_ptr(), &mut sid) == 0 {
            return Err(fail());
        }
        let label = TOKEN_MANDATORY_LABEL { Label: SID_AND_ATTRIBUTES { Sid: sid, Attributes: SE_GROUP_INTEGRITY } };
        let set = SetTokenInformation(low.0, TokenIntegrityLevel, (&label as *const TOKEN_MANDATORY_LABEL).cast(), (std::mem::size_of::<TOKEN_MANDATORY_LABEL>() + GetLengthSid(sid) as usize) as u32);
        LocalFree(sid.cast());
        if set == 0 {
            return Err(fail());
        }

        // Environment: this process's, minus TEMP/TMP and the added names, then the added values.
        let replaced: Vec<String> = env.iter().map(|(k, _)| k.to_ascii_uppercase()).chain(["TEMP".into(), "TMP".into()]).collect();
        let mut block: Vec<u16> = Vec::new();
        for (k, v) in std::env::vars_os() {
            let (k, v) = (k.to_string_lossy().into_owned(), v.to_string_lossy().into_owned());
            if replaced.contains(&k.to_ascii_uppercase()) {
                continue;
            }
            block.extend(format!("{k}={v}").encode_utf16());
            block.push(0);
        }
        let temp = temp.to_string_lossy().into_owned();
        for (k, v) in env.iter().copied().chain([("TEMP", temp.as_str()), ("TMP", temp.as_str())]) {
            block.extend(format!("{k}={v}").encode_utf16());
            block.push(0);
        }
        block.push(0);

        let exe_text = exe.to_string_lossy().into_owned();
        let line = std::iter::once(quote(&exe_text)).chain(args.iter().map(|a| quote(a))).collect::<Vec<_>>().join(" ");
        let mut line = wide(&line);
        let dir = exe.parent().map(|d| wide(&d.to_string_lossy())).unwrap_or_else(|| wide("."));
        let mut si: STARTUPINFOW = std::mem::zeroed();
        si.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        if CreateProcessAsUserW(low.0, wide(&exe_text).as_ptr(), line.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 0,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT, block.as_ptr().cast(), dir.as_ptr(), &si, &mut pi) == 0 {
            return Err(fail());
        }
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
        Ok(pi.dwProcessId)
    }
}

#[cfg(test)]
mod tests {
    use super::quote;

    /// Starts `whoami /groups` through spawn_low and checks it ran at Low integrity, could write its LocalLow
    /// folder and could not write the user's profile.
    #[test]
    fn child_runs_at_low_integrity() {
        let dir = super::viewer_data().expect("LocalLow folder").join("Temp");
        let out = dir.join("lowbox-test.txt");
        let blocked = std::path::Path::new(&std::env::var("USERPROFILE").unwrap()).join("lowbox-should-not-exist.txt");
        let _ = std::fs::remove_file(&out);
        let _ = std::fs::remove_file(&blocked);
        let cmd = std::path::PathBuf::from(std::env::var("SystemRoot").unwrap()).join("System32").join("cmd.exe");
        // cmd.exe reads its line raw (not by C runtime rules): no inner quotes, these paths have no spaces.
        let whoami = std::path::PathBuf::from(std::env::var("SystemRoot").unwrap()).join("System32").join("whoami.exe");
        let script = format!("{} /groups > {} 2>&1 & echo x > {}", whoami.display(), out.display(), blocked.display());
        super::spawn_low(&cmd, &["/c".into(), script], &[("GPUVM_TEST", "1")]).expect("spawn");
        for _ in 0..50 {
            if out.exists() && std::fs::read_to_string(&out).map(|t| t.contains("Mandatory")).unwrap_or(false) { break; }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        std::thread::sleep(std::time::Duration::from_millis(300));
        let text = std::fs::read_to_string(&out).expect("the Low child writes LocalLow");
        assert!(text.contains("S-1-16-4096"), "not Low: {text}");
        assert!(!blocked.exists(), "a Low child wrote the profile");
        let _ = std::fs::remove_file(&out);
    }
    #[test]
    fn quotes_like_the_c_runtime() {
        assert_eq!(quote("plain"), "plain");
        assert_eq!(quote("two words"), "\"two words\"");
        assert_eq!(quote(""), "\"\"");
        assert_eq!(quote("a\"b"), "\"a\\\"b\"");
        assert_eq!(quote("C:\\dir with space\\"), "\"C:\\dir with space\\\\\"");
    }
}
