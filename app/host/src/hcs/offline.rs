//! Changes to a stopped machine's Windows registry, done on its hive files. A hive Windows shut down with leaves its
//! last changes in its logs (SYSTEM.LOG1/2); a private app hive refuses such a hive as corrupt, so the hive is loaded
//! by reg.exe (present on every edition, it replays the logs) under a random name in HKLM for the moment it takes,
//! changed through the registry API, and unloaded at once.

use std::path::Path;
use std::process::Command;

use windows_sys::Win32::Foundation::ERROR_SUCCESS;
use windows_sys::Win32::System::Registry::*;

use crate::win::wide;

pub struct Hive {
    key: HKEY,
    mount: String,
}

fn reg(args: &[&str]) -> Result<(), String> {
    let exe = std::env::var_os("SystemRoot").map(std::path::PathBuf::from).unwrap_or_else(|| r"C:\Windows".into()).join("System32").join("reg.exe");
    let out = Command::new(exe).args(args).output().map_err(|e| format!("reg.exe: {e}"))?;
    if out.status.success() { Ok(()) } else { Err(format!("reg.exe {}: {}", args[0], String::from_utf8_lossy(&out.stderr).trim())) }
}

impl Drop for Hive {
    fn drop(&mut self) {
        unsafe { RegCloseKey(self.key) };
        let path = format!(r"HKLM\{}", self.mount);
        for _ in 0..10 {
            if reg(&["unload", &path]).is_ok() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(300));
        }
    }
}

pub struct Key(HKEY);

impl Drop for Key {
    fn drop(&mut self) {
        unsafe { RegCloseKey(self.0) };
    }
}

fn check(code: u32, what: &str) -> Result<(), String> {
    if code == ERROR_SUCCESS { Ok(()) } else { Err(format!("{what}: {} (Windows error {code})", std::io::Error::from_raw_os_error(code as i32))) }
}

pub fn load(file: &Path) -> Result<Hive, String> {
    let mount = format!("GpuVMoff{}", &crate::win::random_hex()[..8]);
    reg(&["load", &format!(r"HKLM\{mount}"), &file.to_string_lossy()]).map_err(|e| format!("load hive {}: {e}", file.display()))?;
    let mut key: HKEY = std::ptr::null_mut();
    let opened = unsafe { RegOpenKeyExW(HKEY_LOCAL_MACHINE, wide(&mount).as_ptr(), REG_OPTION_OPEN_LINK, KEY_ALL_ACCESS, &mut key) };
    if opened != ERROR_SUCCESS {
        let _ = reg(&["unload", &format!(r"HKLM\{mount}")]);
        return Err(format!("open the loaded hive: Windows error {opened}"));
    }
    let hive = Hive { key, mount };
    if is_link(hive.key) {
        return Err("the machine's hive root is a link".into());
    }
    Ok(hive)
}

const REG_OPTION_OPEN_LINK: u32 = 0x8;

/// A key that is a registry symbolic link carries this value; the guest controls its hive and could point one at the
/// host's own registry.
fn is_link(key: HKEY) -> bool {
    let mut kind = 0u32;
    let code = unsafe { RegQueryValueExW(key, wide("SymbolicLinkValue").as_ptr(), std::ptr::null(), &mut kind, std::ptr::null_mut(), std::ptr::null_mut()) };
    code == ERROR_SUCCESS && kind == REG_LINK
}

/// Opens (or with `create`, creates) one subkey under `parent` without following links, and refuses a link.
fn child(parent: HKEY, name: &str, create: bool) -> Result<Key, String> {
    let mut h: HKEY = std::ptr::null_mut();
    let code = unsafe { RegOpenKeyExW(parent, wide(name).as_ptr(), REG_OPTION_OPEN_LINK, KEY_ALL_ACCESS, &mut h) };
    if code != ERROR_SUCCESS {
        if !create {
            return check(code, &format!("open {name}")).map(|_| Key(h));
        }
        check(unsafe { RegCreateKeyExW(parent, wide(name).as_ptr(), 0, std::ptr::null(), REG_OPTION_NON_VOLATILE | REG_OPTION_OPEN_LINK, KEY_ALL_ACCESS, std::ptr::null(), &mut h, std::ptr::null_mut()) }, &format!("create {name}"))?;
        unsafe { RegCloseKey(h) };
        h = std::ptr::null_mut();
        check(unsafe { RegOpenKeyExW(parent, wide(name).as_ptr(), REG_OPTION_OPEN_LINK, KEY_ALL_ACCESS, &mut h) }, &format!("open {name}"))?;
    }
    let key = Key(h);
    if is_link(key.0) {
        return Err(format!("{name} in the machine's registry is a link; GpuVM won't write through it"));
    }
    Ok(key)
}

impl Hive {
    /// Walks `path` one key at a time, never through a link, creating what is missing.
    pub fn create(&self, path: &str) -> Result<Key, String> {
        let mut parts = path.split('\\').filter(|p| !p.is_empty());
        let first = parts.next().ok_or("empty key path")?;
        let mut cur = child(self.key, first, true)?;
        for p in parts {
            cur = child(cur.0, p, true)?;
        }
        Ok(cur)
    }

    pub fn dword(&self, path: &str, name: &str) -> Option<u32> {
        let key = child(self.key, path, false).ok()?;
        let mut data = 0u32;
        let mut size = 4u32;
        let code = unsafe { RegGetValueW(key.0, std::ptr::null(), wide(name).as_ptr(), RRF_RT_REG_DWORD, std::ptr::null_mut(), (&mut data as *mut u32).cast(), &mut size) };
        (code == ERROR_SUCCESS).then_some(data)
    }
}

impl Key {
    fn set(&self, name: &str, kind: REG_VALUE_TYPE, bytes: &[u8]) -> Result<(), String> {
        check(unsafe { RegSetValueExW(self.0, wide(name).as_ptr(), 0, kind, bytes.as_ptr(), bytes.len() as u32) }, &format!("set {name}"))
    }

    pub fn set_dword(&self, name: &str, v: u32) -> Result<(), String> {
        self.set(name, REG_DWORD, &v.to_le_bytes())
    }

    pub fn set_string(&self, name: &str, v: &str, expand: bool) -> Result<(), String> {
        let bytes: Vec<u8> = wide(v).iter().flat_map(|c| c.to_le_bytes()).collect();
        self.set(name, if expand { REG_EXPAND_SZ } else { REG_SZ }, &bytes)
    }

    pub fn set_binary(&self, name: &str, v: &[u8]) -> Result<(), String> {
        self.set(name, REG_BINARY, v)
    }
}

/// The service-failure policy the agent's installer sets with `sc failure`: restart after 2 s, 2 s, then 10 s,
/// counters reset after a day (the registry form of SERVICE_FAILURE_ACTIONS).
pub fn failure_actions() -> Vec<u8> {
    let mut v = Vec::new();
    for x in [86_400u32, 0, 0, 3, 0x14] {
        v.extend_from_slice(&x.to_le_bytes());
    }
    for (kind, delay) in [(1u32, 2000u32), (1, 2000), (1, 10_000)] {
        v.extend_from_slice(&kind.to_le_bytes());
        v.extend_from_slice(&delay.to_le_bytes());
    }
    v
}

/// Registers an automatic LocalSystem service in an offline SYSTEM hive, in the control set Windows boots with.
pub fn add_service(system_hive: &Path, name: &str, display: &str, image_path: &str) -> Result<(), String> {
    let hive = load(system_hive)?;
    let current = hive.dword("Select", "Current").ok_or("the SYSTEM hive has no Select\\Current")?;
    if current == 0 || current > 999 {
        return Err(format!("unexpected control set {current}"));
    }
    let key = hive.create(&format!(r"ControlSet{current:03}\Services\{name}"))?;
    key.set_dword("Type", 0x10)?;
    key.set_dword("Start", 2)?;
    key.set_dword("ErrorControl", 1)?;
    key.set_string("ImagePath", image_path, true)?;
    key.set_string("ObjectName", "LocalSystem", false)?;
    key.set_string("DisplayName", display, false)?;
    key.set_binary("FailureActions", &failure_actions())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_links_are_refused() {
        const REG_OPTION_CREATE_LINK: u32 = 0x2;
        let base = format!(r"Software\GpuVMLinkTest{}", std::process::id());
        let mut root: HKEY = std::ptr::null_mut();
        unsafe { RegCreateKeyExW(HKEY_CURRENT_USER, wide(&base).as_ptr(), 0, std::ptr::null(), 0, KEY_ALL_ACCESS, std::ptr::null(), &mut root, std::ptr::null_mut()) };
        let root = Key(root);
        let mut link: HKEY = std::ptr::null_mut();
        let made = unsafe { RegCreateKeyExW(root.0, wide("Planted").as_ptr(), 0, std::ptr::null(), REG_OPTION_CREATE_LINK | REG_OPTION_VOLATILE, KEY_ALL_ACCESS | KEY_CREATE_LINK, std::ptr::null(), &mut link, std::ptr::null_mut()) };
        assert_eq!(made, ERROR_SUCCESS);
        let target: Vec<u8> = r"\REGISTRY\MACHINE\SOFTWARE\Microsoft".encode_utf16().flat_map(|c| c.to_le_bytes()).collect();
        unsafe { RegSetValueExW(link, wide("SymbolicLinkValue").as_ptr(), 0, REG_LINK, target.as_ptr(), target.len() as u32) };
        unsafe { RegCloseKey(link) };
        assert!(child(root.0, "Planted", true).is_err(), "a link must be refused");
        assert!(child(root.0, "Plain", true).is_ok());
        unsafe {
            RegDeleteKeyExW(root.0, wide("Plain").as_ptr(), 0, 0);
            let mut l: HKEY = std::ptr::null_mut();
            RegOpenKeyExW(root.0, wide("Planted").as_ptr(), REG_OPTION_OPEN_LINK, KEY_ALL_ACCESS, &mut l);
            windows_sys::Wdk::System::Registry::NtDeleteKey(l as _);
            RegCloseKey(l);
        }
        drop(root);
        unsafe { RegDeleteKeyExW(HKEY_CURRENT_USER, wide(&base).as_ptr(), 0, 0) };
    }

    #[test]
    fn failure_actions_layout() {
        let v = failure_actions();
        assert_eq!(v.len(), 20 + 3 * 8);
        assert_eq!(u32::from_le_bytes(v[0..4].try_into().unwrap()), 86_400);
        assert_eq!(u32::from_le_bytes(v[12..16].try_into().unwrap()), 3);
        assert_eq!(u32::from_le_bytes(v[24..28].try_into().unwrap()), 2000);
    }

}

