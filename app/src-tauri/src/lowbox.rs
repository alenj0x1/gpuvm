//! Starts the viewer at Low integrity. The viewer parses what a machine's streaming host sends (video, audio,
//! control), and that host runs inside a VM GpuVM treats as untrusted: if a bug there were exploited, a Low process
//! can't write the user's files or registry, can't open this app's process and can't send messages to its windows
//! (Windows' integrity levels and UIPI), so it can't climb to this app and from there to the GpuVM service.
//! The viewer keeps its settings and pairing under LocalLow (the one place a Low process may write), and its
//! temporary files too.

use std::path::{Path, PathBuf};
use windows_sys::Win32::Foundation::{CloseHandle, LocalFree, HANDLE, WAIT_TIMEOUT};
use windows_sys::Win32::Security::Authorization::ConvertStringSidToSidW;
use windows_sys::Win32::Security::{
    CreateRestrictedToken, GetLengthSid, SetTokenInformation, TokenIntegrityLevel, DISABLE_MAX_PRIVILEGE,
    SID_AND_ATTRIBUTES, TOKEN_ADJUST_DEFAULT, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_MANDATORY_LABEL,
    TOKEN_QUERY,
};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JobObjectBasicUIRestrictions, JobObjectExtendedLimitInformation,
    SetInformationJobObject, JOBOBJECT_BASIC_UI_RESTRICTIONS, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    JOB_OBJECT_LIMIT_ACTIVE_PROCESS, JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    JOB_OBJECT_UILIMIT_DESKTOP, JOB_OBJECT_UILIMIT_DISPLAYSETTINGS, JOB_OBJECT_UILIMIT_EXITWINDOWS,
    JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS, JOB_OBJECT_UILIMIT_WRITECLIPBOARD,
};
use windows_sys::Win32::System::Threading::{
    CreateProcessAsUserW, DeleteProcThreadAttributeList, GetCurrentProcess, InitializeProcThreadAttributeList,
    OpenProcessToken, ResumeThread, TerminateProcess, UpdateProcThreadAttribute, WaitForSingleObject, CREATE_SUSPENDED,
    CREATE_UNICODE_ENVIRONMENT, EXTENDED_STARTUPINFO_PRESENT, LPPROC_THREAD_ATTRIBUTE_LIST, PROCESS_INFORMATION,
    STARTUPINFOEXW, STARTUPINFOW,
};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// BUILTIN\Administrators: deny-only in the viewer's token.
const ADMINISTRATORS: &str = "S-1-5-32-544";
/// SE_GROUP_INTEGRITY (winnt.h).
const SE_GROUP_INTEGRITY: u32 = 0x20;
/// Low mandatory level.
const LOW: &str = "S-1-16-4096";

/// PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY (winbase.h).
const MITIGATION_POLICY_ATTRIBUTE: usize = 0x0002_0007;
/// winnt.h PROCESS_CREATION_MITIGATION_POLICY_*. Not dynamic code or Microsoft-only binaries (Qt's QML engine and
/// the bundled DLLs need them), nor win32k lockdown (it draws a window).
const VIEWER_MITIGATIONS: u64 = (1 << 8)  // FORCE_RELOCATE_IMAGES_ALWAYS_ON
    | (1 << 12) // HEAP_TERMINATE_ALWAYS_ON
    | (1 << 16) // BOTTOM_UP_ASLR_ALWAYS_ON
    | (1 << 20) // HIGH_ENTROPY_ASLR_ALWAYS_ON
    | (1 << 24) // STRICT_HANDLE_CHECKS_ALWAYS_ON
    | (1 << 32) // EXTENSION_POINT_DISABLE_ALWAYS_ON
    | (1 << 52) // IMAGE_LOAD_NO_REMOTE_ALWAYS_ON
    | (1 << 56); // IMAGE_LOAD_NO_LOW_LABEL_ALWAYS_ON

struct Attributes {
    buffer: Vec<u8>,
    _policy: Box<u64>,
}

impl Attributes {
    unsafe fn mitigations() -> Option<Attributes> {
        let mut size = 0usize;
        InitializeProcThreadAttributeList(std::ptr::null_mut(), 1, 0, &mut size);
        let mut buffer = vec![0u8; size];
        let list = buffer.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        if InitializeProcThreadAttributeList(list, 1, 0, &mut size) == 0 {
            return None;
        }
        let policy = Box::new(VIEWER_MITIGATIONS);
        let set = UpdateProcThreadAttribute(list, 0, MITIGATION_POLICY_ATTRIBUTE, (&*policy as *const u64).cast(), std::mem::size_of::<u64>(), std::ptr::null_mut(), std::ptr::null());
        let attributes = Attributes { buffer, _policy: policy };
        (set != 0).then_some(attributes)
    }
    fn list(&mut self) -> LPPROC_THREAD_ATTRIBUTE_LIST {
        self.buffer.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST
    }
}

impl Drop for Attributes {
    fn drop(&mut self) {
        // SAFETY: initialized in mitigations() (a value is only built after that succeeded).
        unsafe { DeleteProcThreadAttributeList(self.list()) };
    }
}

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
// SAFETY: kernel object handles can be used from any thread; each is closed once, on drop.
unsafe impl Send for Handle {}
unsafe impl Sync for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: owned handle, closed once.
            unsafe { CloseHandle(self.0) };
        }
    }
}

/// A viewer started by spawn_low. Held for as long as the app tracks it: the process handle names this process
/// for good (a process id can be reused once it exits), and closing the job ends the viewer with the app.
pub struct LowChild {
    pub pid: u32,
    process: Handle,
    _job: Handle,
}

impl LowChild {
    pub fn running(&self) -> bool {
        // SAFETY: owned process handle.
        unsafe { WaitForSingleObject(self.process.0, 0) == WAIT_TIMEOUT }
    }
    pub fn kill(&self) {
        // SAFETY: owned process handle (PROCESS_ALL_ACCESS from CreateProcess).
        unsafe { TerminateProcess(self.process.0, 1) };
    }
    pub fn handle(&self) -> HANDLE {
        self.process.0
    }
    /// How it ended (its exit code), or None while it runs.
    pub fn exit_code(&self) -> Option<u32> {
        use windows_sys::Win32::System::Threading::GetExitCodeProcess;
        if self.running() {
            return None;
        }
        let mut code = 0u32;
        // SAFETY: owned process handle; the code is written to a local.
        (unsafe { GetExitCodeProcess(self.process.0, &mut code) } != 0).then_some(code)
    }
}

/// The job the viewer runs in: one process (it can't start others), gone when the app lets go of it, and kept away
/// from what a streaming window never needs (other desktops, logging off or shutting down, system settings and
/// display modes, writing the clipboard).
unsafe fn viewer_job() -> Option<Handle> {
    let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
    if job.is_null() {
        return None;
    }
    let job = Handle(job);
    let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS | JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION;
    limits.BasicLimitInformation.ActiveProcessLimit = 1;
    if SetInformationJobObject(job.0, JobObjectExtendedLimitInformation, (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(), std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32) == 0 {
        return None;
    }
    let ui = JOBOBJECT_BASIC_UI_RESTRICTIONS {
        UIRestrictionsClass: JOB_OBJECT_UILIMIT_DESKTOP | JOB_OBJECT_UILIMIT_EXITWINDOWS | JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS | JOB_OBJECT_UILIMIT_DISPLAYSETTINGS | JOB_OBJECT_UILIMIT_WRITECLIPBOARD,
    };
    if SetInformationJobObject(job.0, JobObjectBasicUIRestrictions, (&ui as *const JOBOBJECT_BASIC_UI_RESTRICTIONS).cast(), std::mem::size_of::<JOBOBJECT_BASIC_UI_RESTRICTIONS>() as u32) == 0 {
        return None;
    }
    Some(job)
}

/// Starts `exe` with `args` at Low integrity, with `env` added to this process's environment (and TEMP/TMP in
/// LocalLow). Fails rather than starting it with more rights.
///
/// Its token is this app's with every privilege but change-notify removed and the Administrators group made
/// deny-only, then labelled Low: even when the app runs as administrator, the viewer has no admin rights.
pub fn spawn_low(exe: &Path, args: &[String], env: &[(&str, &str)]) -> Result<LowChild, String> {
    let fail = || "Couldn't open the viewer with reduced rights.".to_string();
    let temp = viewer_data().ok_or_else(fail)?.join("Temp");
    // SAFETY: standard token, job and process calls; every handle and SID is released below.
    unsafe {
        let mut own: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ADJUST_DEFAULT | TOKEN_ASSIGN_PRIMARY, &mut own) == 0 {
            return Err(fail());
        }
        let own = Handle(own);
        let mut admins = std::ptr::null_mut();
        if ConvertStringSidToSidW(wide(ADMINISTRATORS).as_ptr(), &mut admins) == 0 {
            return Err(fail());
        }
        let deny = SID_AND_ATTRIBUTES { Sid: admins, Attributes: 0 };
        let mut low: HANDLE = std::ptr::null_mut();
        let made = CreateRestrictedToken(own.0, DISABLE_MAX_PRIVILEGE, 1, &deny, 0, std::ptr::null(), 0, std::ptr::null(), &mut low);
        LocalFree(admins.cast());
        if made == 0 {
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
        let mut attributes = Attributes::mitigations().ok_or_else(fail)?;
        let mut si: STARTUPINFOEXW = std::mem::zeroed();
        si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        si.lpAttributeList = attributes.list();
        let job = viewer_job().ok_or_else(fail)?;
        let mut pi: PROCESS_INFORMATION = std::mem::zeroed();
        // Suspended until it is in the job: it never runs a single instruction outside it.
        if CreateProcessAsUserW(low.0, wide(&exe_text).as_ptr(), line.as_mut_ptr(), std::ptr::null(), std::ptr::null(), 0,
            CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT, block.as_ptr().cast(), dir.as_ptr(),
            (&si as *const STARTUPINFOEXW).cast::<STARTUPINFOW>(), &mut pi) == 0 {
            return Err(fail());
        }
        drop(attributes);
        let thread = Handle(pi.hThread);
        let child = LowChild { pid: pi.dwProcessId, process: Handle(pi.hProcess), _job: job };
        if AssignProcessToJobObject(child._job.0, child.process.0) == 0 || ResumeThread(thread.0) == u32::MAX {
            child.kill();
            return Err(fail());
        }
        Ok(child)
    }
}

#[cfg(test)]
mod tests {
    use super::quote;

    fn system32(exe: &str) -> std::path::PathBuf {
        std::path::PathBuf::from(std::env::var("SystemRoot").unwrap()).join("System32").join(exe)
    }

    /// The child's token: Low label, Administrators deny-only, no privilege but change-notify.
    #[test]
    fn child_token_is_low_and_restricted() {
        use windows_sys::Win32::Security::*;
        use windows_sys::Win32::System::Threading::OpenProcessToken;
        let child = super::spawn_low(&system32("waitfor.exe"), &["/t".into(), "5".into(), "GpuVMLowboxTest".into()], &[]).expect("spawn");
        // SAFETY: queries on the child's token; buffers are large enough for these classes.
        unsafe {
            let mut token = std::ptr::null_mut();
            assert!(OpenProcessToken(child.handle(), TOKEN_QUERY, &mut token) != 0);
            let mut buf = vec![0u8; 8192];
            let mut len = 0u32;
            assert!(GetTokenInformation(token, TokenIntegrityLevel, buf.as_mut_ptr().cast(), buf.len() as u32, &mut len) != 0);
            let sid = (*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL)).Label.Sid;
            assert_eq!(*GetSidSubAuthority(sid, *GetSidSubAuthorityCount(sid) as u32 - 1), 0x1000, "not Low");
            assert!(GetTokenInformation(token, TokenPrivileges, buf.as_mut_ptr().cast(), buf.len() as u32, &mut len) != 0);
            assert!((*(buf.as_ptr() as *const TOKEN_PRIVILEGES)).PrivilegeCount <= 1, "privileges kept");
            assert!(GetTokenInformation(token, TokenGroups, buf.as_mut_ptr().cast(), buf.len() as u32, &mut len) != 0);
            let groups = &*(buf.as_ptr() as *const TOKEN_GROUPS);
            let list = std::slice::from_raw_parts(groups.Groups.as_ptr(), groups.GroupCount as usize);
            let mut admins = std::ptr::null_mut();
            windows_sys::Win32::Security::Authorization::ConvertStringSidToSidW(super::wide(super::ADMINISTRATORS).as_ptr(), &mut admins);
            for g in list {
                if EqualSid(g.Sid, admins) != 0 {
                    assert!(g.Attributes & 0x10 != 0, "Administrators not deny-only"); // SE_GROUP_USE_FOR_DENY_ONLY
                }
            }
            windows_sys::Win32::Foundation::LocalFree(admins.cast());
            windows_sys::Win32::Foundation::CloseHandle(token);
        }
        assert!(child.running());
        drop(child); // closing the job ends it
    }

    #[test]
    fn child_has_the_mitigations() {
        use windows_sys::Win32::System::Threading::{GetProcessMitigationPolicy, ProcessExtensionPointDisablePolicy, ProcessImageLoadPolicy};
        let child = super::spawn_low(&system32("waitfor.exe"), &["/t".into(), "5".into(), "GpuVMLowboxMit".into()], &[]).expect("spawn");
        // SAFETY: queries on the child's handle into 4-byte policy structs (bit fields in one DWORD).
        unsafe {
            let mut image = 0u32;
            assert!(GetProcessMitigationPolicy(child.handle(), ProcessImageLoadPolicy, (&mut image as *mut u32).cast(), 4) != 0);
            assert!(image & 0b11 == 0b11, "remote and Low-label images not refused: {image:#b}");
            let mut ext = 0u32;
            assert!(GetProcessMitigationPolicy(child.handle(), ProcessExtensionPointDisablePolicy, (&mut ext as *mut u32).cast(), 4) != 0);
            assert!(ext & 1 == 1, "extension points not disabled");
        }
    }

    /// The child runs inside its job, limited to one process, and the job ends it when let go.
    #[test]
    fn child_is_held_by_its_job() {
        use windows_sys::Win32::System::JobObjects::{IsProcessInJob, QueryInformationJobObject, JobObjectExtendedLimitInformation, JOBOBJECT_EXTENDED_LIMIT_INFORMATION};
        let child = super::spawn_low(&system32("waitfor.exe"), &["/t".into(), "5".into(), "GpuVMLowboxJob".into()], &[]).expect("spawn");
        let process = child.handle();
        // SAFETY: queries on the child's handle and its job's.
        unsafe {
            let mut inside = 0;
            assert!(IsProcessInJob(process, child._job.0, &mut inside) != 0 && inside != 0, "not in its job");
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            assert!(QueryInformationJobObject(child._job.0, JobObjectExtendedLimitInformation, (&mut limits as *mut JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(), std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32, std::ptr::null_mut()) != 0);
            assert_eq!(limits.BasicLimitInformation.ActiveProcessLimit, 1);
        }
        // Closing the job ends the child: a duplicate of its handle sees it exit.
        let mut copy = std::ptr::null_mut();
        // SAFETY: duplicating our own handle into this process.
        unsafe {
            use windows_sys::Win32::Foundation::{DuplicateHandle, DUPLICATE_SAME_ACCESS};
            use windows_sys::Win32::System::Threading::{GetCurrentProcess, WaitForSingleObject};
            assert!(DuplicateHandle(GetCurrentProcess(), process, GetCurrentProcess(), &mut copy, 0, 0, DUPLICATE_SAME_ACCESS) != 0);
            drop(child);
            assert_eq!(WaitForSingleObject(copy, 3000), 0, "still running after its job closed");
            windows_sys::Win32::Foundation::CloseHandle(copy);
        }
    }
    /// The installed viewer starts at Low inside its job and stays up (it waits for a pipe that never answers here).
    /// A viewer that dies as it starts at Low (a DLL, the console, a second process the job refuses) fails this.
    /// Run by hand: `cargo test viewer_starts_at_low -- --ignored --nocapture` (GPUVM_VIEWER overrides the exe).
    #[test]
    #[ignore]
    fn viewer_starts_at_low() {
        let exe = std::env::var("GPUVM_VIEWER").map(std::path::PathBuf::from)
            .unwrap_or_else(|_| std::path::PathBuf::from(r"C:\Program Files\GpuVM\gpuvm\viewer\GpuVMViewer.exe"));
        // The pipe the app gives it (the Low label lets a Low process open it), and a thread that waits for it.
        // The app's shapes: gpuvm-viewer-<32 hex> and a token of 32+ characters (bridge.cpp refuses anything else).
        let name = format!(r"\\.\pipe\gpuvm-viewer-{:032x}", std::process::id() as u128 * 0x9e37_79b9_7f4a_7c15 + 0x1234);
        let connected = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        // SAFETY: a test-only pipe with a valid descriptor; the handle lives until the test ends.
        let pipe = unsafe {
            use windows_sys::Win32::Security::{Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1}, SECURITY_ATTRIBUTES};
            use windows_sys::Win32::System::Pipes::{CreateNamedPipeW, PIPE_TYPE_BYTE, PIPE_WAIT};
            let mut sd = std::ptr::null_mut();
            assert!(ConvertStringSecurityDescriptorToSecurityDescriptorW(super::wide("D:P(A;;GA;;;WD)S:(ML;;NW;;;LW)").as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) != 0);
            let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
            let h = CreateNamedPipeW(super::wide(&name).as_ptr(), 3 /* PIPE_ACCESS_DUPLEX */, PIPE_TYPE_BYTE | PIPE_WAIT, 1, 65536, 65536, 0, &sa);
            assert!(h != windows_sys::Win32::Foundation::INVALID_HANDLE_VALUE);
            h as usize
        };
        {
            let connected = connected.clone();
            // SAFETY: blocks on the test's own pipe handle.
            std::thread::spawn(move || unsafe {
                use windows_sys::Win32::System::Pipes::ConnectNamedPipe;
                let ok = ConnectNamedPipe(pipe as _, std::ptr::null_mut()) != 0 || windows_sys::Win32::Foundation::GetLastError() == 535;
                connected.store(ok, std::sync::atomic::Ordering::SeqCst);
            });
        }
        // GPUVM_LOWBOX_PROBE=cmd: a plain cmd in the same token and job opens the pipe instead (is it the pipe or the viewer?).
        let probe = std::env::var("GPUVM_LOWBOX_PROBE").is_ok();
        let exe = if probe { system32("cmd.exe") } else { exe };
        let args: Vec<String> = if probe { vec!["/c".into(), format!("echo x> {name}")] } else {
            ["stream", "127.0.0.1", "Desktop", "--gpuvm-pipe", &name, "--gpuvm-token-env", "GPUVM_VIEWER_TOKEN"].iter().map(|s| s.to_string()).collect()
        };
        let child = super::spawn_low(&exe, &args, &[("GPUVM_VIEWER_TOKEN", "0123456789abcdef0123456789abcdef")]).expect("spawn");
        std::thread::sleep(std::time::Duration::from_secs(6));
        let code = child.exit_code();
        let up = connected.load(std::sync::atomic::Ordering::SeqCst);
        println!("viewer at Low after 6 s: connected to its pipe {up}, {}", code.map(|c| format!("ended, exit code {c:#010x}")).unwrap_or_else(|| "running".into()));
        assert!(up, "the viewer never reached its pipe at Low (exit code {code:#x?})");
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
