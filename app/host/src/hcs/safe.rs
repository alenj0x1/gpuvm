//! Writing into a guest-controlled volume without following its links. Every part of the path is opened relative to
//! the handle of its parent and without following reparse points, then checked: a folder swapped for a junction
//! after a check can't redirect the write, because nothing is ever looked up by path again.

use std::path::{Component, Path};

use windows_sys::Wdk::Foundation::OBJECT_ATTRIBUTES;
use windows_sys::Wdk::Storage::FileSystem::*;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::IO::IO_STATUS_BLOCK;

use crate::win::wide;

const OBJ_CASE_INSENSITIVE: u32 = 0x40;

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

fn is_link(h: HANDLE) -> Result<bool, String> {
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(h, &mut info) } == 0 {
        return Err(format!("read attributes: {}", std::io::Error::last_os_error()));
    }
    Ok(info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0)
}

#[derive(Clone, Copy, PartialEq)]
enum Open {
    Folder,
    WriteFile,
    /// Only look: the part must exist (folder or file) and is opened for its attributes.
    Existing,
}

fn open_child(parent: &Handle, name: &str, how: Open, secure: bool) -> Result<Handle, String> {
    let w: Vec<u16> = name.encode_utf16().collect();
    let us = UNICODE_STRING { Length: (w.len() * 2) as u16, MaximumLength: (w.len() * 2) as u16, Buffer: w.as_ptr() as *mut u16 };
    let oa = OBJECT_ATTRIBUTES {
        Length: std::mem::size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.0,
        ObjectName: &us,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: std::ptr::null(),
        SecurityQualityOfService: std::ptr::null(),
    };
    let mut io: IO_STATUS_BLOCK = unsafe { std::mem::zeroed() };
    let mut h: HANDLE = std::ptr::null_mut();
    let (mut access, disposition, kind) = match how {
        Open::Folder => (FILE_TRAVERSE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN_IF, FILE_DIRECTORY_FILE),
        Open::WriteFile => (FILE_GENERIC_WRITE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OVERWRITE_IF, FILE_NON_DIRECTORY_FILE),
        Open::Existing => (FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN, 0),
    };
    if secure {
        access |= WRITE_DAC | WRITE_OWNER | READ_CONTROL;
    }
    // A part only looked at must not block whoever opens it next (the registry loading a hive needs it alone).
    let share = if how == Open::Existing { FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE } else { FILE_SHARE_READ };
    let status = unsafe {
        NtCreateFile(&mut h, access, &oa, &mut io, std::ptr::null(), FILE_ATTRIBUTE_NORMAL, share, disposition,
            kind | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, std::ptr::null(), 0)
    };
    if status < 0 {
        return Err(format!("open {name}: NTSTATUS 0x{:08X}", status as u32));
    }
    let h = Handle(h);
    if is_link(h.0)? {
        return Err(format!("{name} is a link; GpuVM won't write through it"));
    }
    Ok(h)
}

fn plain_parts(relative: &Path) -> Result<Vec<String>, String> {
    let parts: Vec<String> = relative.components().map(|c| match c {
        Component::Normal(n) => n.to_str().map(String::from).ok_or_else(|| format!("not a valid name in {}", relative.display())),
        _ => Err(format!("not a plain relative path: {}", relative.display())),
    }).collect::<Result<_, _>>()?;
    if parts.is_empty() || parts.iter().any(|p| p.contains(':')) {
        return Err(format!("not a plain relative path: {}", relative.display()));
    }
    Ok(parts)
}

fn open_root(root: &Path) -> Result<Handle, String> {
    let root_w = wide(&root.to_string_lossy());
    let h = unsafe {
        CreateFileW(root_w.as_ptr(), FILE_TRAVERSE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(format!("open {}: {}", root.display(), std::io::Error::last_os_error()));
    }
    let h = Handle(h);
    if is_link(h.0)? {
        return Err(format!("{} is a link", root.display()));
    }
    Ok(h)
}

/// Sets an owner and a protected DACL from SDDL on an open handle.
fn apply_sddl(h: &Handle, sddl: &str, what: &str) -> Result<(), String> {
    use windows_sys::Win32::Security::Authorization::*;
    use windows_sys::Win32::Security::*;
    let mut sd: PSECURITY_DESCRIPTOR = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        return Err(format!("SDDL {sddl}: {}", std::io::Error::last_os_error()));
    }
    let (mut owner, mut dacl) = (std::ptr::null_mut(), std::ptr::null_mut());
    let (mut defaulted, mut present) = (0, 0);
    let code = unsafe {
        GetSecurityDescriptorOwner(sd, &mut owner, &mut defaulted);
        GetSecurityDescriptorDacl(sd, &mut present, &mut dacl, &mut defaulted);
        SetSecurityInfo(h.0, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            owner, std::ptr::null_mut(), dacl, std::ptr::null())
    };
    unsafe { LocalFree(sd) };
    if code != 0 {
        return Err(format!("protect {what}: {} (Windows error {code})", std::io::Error::from_raw_os_error(code as i32)));
    }
    Ok(())
}

/// Writes `bytes` to `relative` under `root` (a volume or folder of a disk a guest controls), creating folders as
/// needed. Refuses links anywhere on the way and anything but a plain relative path.
pub fn write_file(root: &Path, relative: &Path, bytes: &[u8]) -> Result<(), String> {
    write_file_protected(root, relative, bytes, None)
}

/// Like `write_file`, and when `sddl` is given it becomes the owner and protected DACL of both the file and the
/// folder that holds it (as the agent's secret needs: SYSTEM and Administrators only).
pub fn write_file_protected(root: &Path, relative: &Path, bytes: &[u8], sddl: Option<&str>) -> Result<(), String> {
    let parts = plain_parts(relative)?;
    let mut cur = open_root(root)?;
    let (last, folders) = parts.split_last().unwrap();
    for (i, f) in folders.iter().enumerate() {
        let holder = sddl.is_some() && i + 1 == folders.len();
        cur = open_child(&cur, f, Open::Folder, holder)?;
        if holder {
            apply_sddl(&cur, sddl.unwrap(), f)?;
        }
    }
    let file = open_child(&cur, last, Open::WriteFile, sddl.is_some())?;
    if let Some(s) = sddl {
        apply_sddl(&file, s, last)?;
    }
    let mut written = 0u32;
    let ok = unsafe { WriteFile(file.0, bytes.as_ptr(), bytes.len() as u32, &mut written, std::ptr::null_mut()) };
    if ok == 0 || written as usize != bytes.len() {
        return Err(format!("write {last}: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

/// Checks by handle that every part of an existing path is a plain folder or file, never a link, and returns the
/// handle of the last part (kept open while the caller uses the path, so the object can't be swapped away).
pub fn existing_plain(root: &Path, relative: &Path) -> Result<impl Drop, String> {
    let parts = plain_parts(relative)?;
    let mut cur = open_root(root)?;
    for p in &parts {
        cur = open_child(&cur, p, Open::Existing, false)?;
    }
    Ok(cur)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn junction(link: &Path, target: &Path) -> bool {
        std::process::Command::new("cmd").args(["/c", "mklink", "/J"]).arg(link).arg(target).output().map(|o| o.status.success()).unwrap_or(false)
    }

    #[test]
    fn writes_plain_paths_and_refuses_links_and_escapes() {
        let root = std::env::temp_dir().join(format!("gpuvm-safe-{}", std::process::id()));
        let (vol, outside) = (root.join("vol"), root.join("outside"));
        fs::create_dir_all(&vol).unwrap();
        fs::create_dir_all(&outside).unwrap();

        write_file(&vol, Path::new(r"GpuVM\setup\a.txt"), b"one").unwrap();
        write_file(&vol, Path::new(r"GpuVM\setup\a.txt"), b"two").unwrap();
        assert_eq!(fs::read(vol.join(r"GpuVM\setup\a.txt")).unwrap(), b"two");

        for bad in [r"..\outside\x.txt", r"C:\x.txt", r"\x.txt", r"a.txt:stream", ""] {
            assert!(write_file(&vol, Path::new(bad), b"no").is_err(), "{bad:?}");
        }

        assert!(junction(&vol.join("Planted"), &outside), "could not create a junction");
        assert!(write_file(&vol, Path::new(r"Planted\x.txt"), b"no").is_err());
        assert!(junction(&vol.join(r"GpuVM\Deep"), &outside));
        assert!(write_file(&vol, Path::new(r"GpuVM\Deep\sub\x.txt"), b"no").is_err());
        assert!(fs::read_dir(&outside).unwrap().next().is_none(), "nothing may land outside");
        assert!(write_file(&vol.join("Planted"), Path::new("x.txt"), b"no").is_err(), "a link as the root itself");

        assert!(existing_plain(&vol, Path::new(r"GpuVM\setup\a.txt")).is_ok());
        assert!(existing_plain(&vol, Path::new(r"GpuVM\missing.txt")).is_err());
        assert!(existing_plain(&vol, Path::new(r"Planted")).is_err());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn protected_writes_set_owner_and_a_protected_dacl() {
        let root = std::env::temp_dir().join(format!("gpuvm-safe-acl-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        write_file_protected(&root, Path::new(r"ProgramData\GpuVM\Agent\secret"), &[7u8; 32], Some("O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)")).unwrap();
        let acl = |p: &Path| String::from_utf8_lossy(&std::process::Command::new("icacls").arg(p).output().unwrap().stdout).to_string();
        for p in [root.join(r"ProgramData\GpuVM\Agent"), root.join(r"ProgramData\GpuVM\Agent\secret")] {
            let a = acl(&p).replace(&p.display().to_string(), "");
            assert!(!a.contains("(I)"), "nothing inherited: {a}");
            assert!(!a.to_lowercase().contains("users") && !a.contains("Everyone"), "{a}");
        }
        assert_eq!(fs::read(root.join(r"ProgramData\GpuVM\Agent\secret")).unwrap(), [7u8; 32]);
        let _ = fs::remove_dir_all(&root);
    }
}
