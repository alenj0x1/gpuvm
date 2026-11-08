//! Development only: the app starts `bridge.ps1` itself from the repository, as GpuVM did before it had a
//! service. It needs the app to run as administrator (the window offers to relaunch it that way). Installed
//! builds never use this: they talk to the GpuVM service (backend.rs).

use std::path::PathBuf;
use std::process::{Command, Stdio};

use crate::{system32, wide_to_path};
use std::os::windows::process::CommandExt;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[repr(C)]
struct Guid(u32, u16, u16, [u8; 8]);
const FOLDERID_PROGRAM_FILES: Guid = Guid(0x905e63b6, 0xc1bf, 0x494e, [0xb2, 0x9c, 0x65, 0xb7, 0x32, 0xd3, 0xd2, 0x1a]);

#[link(name = "shell32")]
extern "system" {
    fn SHGetKnownFolderPath(id: *const Guid, flags: u32, token: isize, path: *mut *mut u16) -> i32;
}
#[link(name = "ole32")]
extern "system" {
    fn CoTaskMemFree(memory: *mut std::ffi::c_void);
}

fn program_files() -> PathBuf {
    let mut raw: *mut u16 = std::ptr::null_mut();
    // SAFETY: Windows allocates the string; it is read up to its terminating zero and freed with CoTaskMemFree.
    unsafe {
        let ok = SHGetKnownFolderPath(&FOLDERID_PROGRAM_FILES, 0, 0, &mut raw) == 0;
        let path = if ok && !raw.is_null() {
            let len = (0..).take_while(|&i| *raw.add(i) != 0).count();
            Some(wide_to_path(std::slice::from_raw_parts(raw, len)))
        } else {
            None
        };
        CoTaskMemFree(raw.cast());
        path.unwrap_or_else(|| PathBuf::from(r"C:\Program Files"))
    }
}

pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

static PWSH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

/// PowerShell 7: the MSI install, else the Store package's real folder (its alias does not start from an elevated
/// process), else whatever pwsh.exe is in the PATH.
fn pwsh_path() -> PathBuf {
    PWSH.get_or_init(|| {
        let msi = program_files().join("PowerShell").join("7").join("pwsh.exe");
        if msi.exists() {
            return msi;
        }
        Command::new(system32(r"WindowsPowerShell\v1.0\powershell.exe"))
            .env("PSModulePath", system32(r"WindowsPowerShell\v1.0\Modules"))
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()).join("pwsh.exe"))
            .filter(|p| p.exists())
            .unwrap_or_else(|| PathBuf::from("pwsh.exe"))
    })
    .clone()
}

pub fn spawn_bridge() -> Result<std::process::Child, String> {
    Command::new(pwsh_path())
        .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(repo_root().join("src").join("bridge.ps1"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("No se pudo iniciar PowerShell 7 (pwsh.exe): {e}"))
}
