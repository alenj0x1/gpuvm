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
    /// A brand-new file (fails if the name exists), born with the security descriptor given.
    NewFile,
    /// An existing folder kept open so nobody can rename or replace it (no delete sharing) while it is used.
    Hold,
}

fn open_child(parent: &Handle, name: &str, how: Open, secure: bool) -> Result<Handle, String> {
    open_child_sd(parent, name, how, secure, std::ptr::null())
}

fn open_child_sd(parent: &Handle, name: &str, how: Open, secure: bool, sd: *const core::ffi::c_void) -> Result<Handle, String> {
    let w: Vec<u16> = name.encode_utf16().collect();
    let us = UNICODE_STRING { Length: (w.len() * 2) as u16, MaximumLength: (w.len() * 2) as u16, Buffer: w.as_ptr() as *mut u16 };
    let oa = OBJECT_ATTRIBUTES {
        Length: std::mem::size_of::<OBJECT_ATTRIBUTES>() as u32,
        RootDirectory: parent.0,
        ObjectName: &us,
        Attributes: OBJ_CASE_INSENSITIVE,
        SecurityDescriptor: sd,
        SecurityQualityOfService: std::ptr::null(),
    };
    let mut io: IO_STATUS_BLOCK = unsafe { std::mem::zeroed() };
    let mut h: HANDLE = std::ptr::null_mut();
    let (mut access, disposition, kind) = match how {
        Open::Folder => (FILE_TRAVERSE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN_IF, FILE_DIRECTORY_FILE),
        Open::WriteFile => (FILE_GENERIC_WRITE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OVERWRITE_IF, FILE_NON_DIRECTORY_FILE),
        Open::Existing => (FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN, 0),
        Open::NewFile => (FILE_GENERIC_WRITE | FILE_READ_ATTRIBUTES | DELETE | SYNCHRONIZE, FILE_CREATE, FILE_NON_DIRECTORY_FILE),
        Open::Hold => (FILE_TRAVERSE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN, FILE_DIRECTORY_FILE),
    };
    if secure {
        access |= WRITE_DAC | WRITE_OWNER | READ_CONTROL;
    }
    // A part only looked at must not block whoever opens it next (the registry loading a hive needs it alone).
    // A folder must let the rename we do inside it write to it.
    let share = match how {
        Open::Existing => FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        Open::Folder | Open::Hold => FILE_SHARE_READ | FILE_SHARE_WRITE,
        Open::WriteFile | Open::NewFile => FILE_SHARE_READ,
    };
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
    let Some(s) = sddl else {
        let file = open_child(&cur, last, Open::WriteFile, false)?;
        return write_all(&file, bytes, last);
    };
    // A protected file is born with its final ACL under a fresh name, then renamed over the target by handle: no one
    // can have opened it beforehand, as they could a file prepared at the target's name.
    let sd = Sddl::parse(s)?;
    let temp = format!(".gpuvm-{}.tmp", crate::win::random_hex());
    let file = open_child_sd(&cur, &temp, Open::NewFile, false, sd.0)?;
    let written = write_all(&file, bytes, last).and_then(|_| rename_by_handle(&file, &cur, last));
    if written.is_err() {
        let _ = delete_by_handle(&file);
    }
    written
}

struct Sddl(*mut core::ffi::c_void);

impl Sddl {
    fn parse(s: &str) -> Result<Self, String> {
        use windows_sys::Win32::Security::Authorization::*;
        let mut sd = std::ptr::null_mut();
        if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(s).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
            return Err(format!("SDDL {s}: {}", std::io::Error::last_os_error()));
        }
        Ok(Sddl(sd))
    }
}

impl Drop for Sddl {
    fn drop(&mut self) {
        unsafe { LocalFree(self.0) };
    }
}

fn write_all(file: &Handle, bytes: &[u8], what: &str) -> Result<(), String> {
    let mut written = 0u32;
    let ok = unsafe { WriteFile(file.0, bytes.as_ptr(), bytes.len() as u32, &mut written, std::ptr::null_mut()) };
    if ok == 0 || written as usize != bytes.len() {
        return Err(format!("write {what}: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

/// Renames an open file to `name` inside `folder`, both by handle (NT semantics: the name is relative to the folder's
/// handle; Win32's rename would read a bare name against the process's current directory), replacing what is there.
fn rename_by_handle(file: &Handle, folder: &Handle, name: &str) -> Result<(), String> {
    let w: Vec<u16> = name.encode_utf16().collect();
    let header = std::mem::size_of::<FILE_RENAME_INFORMATION>();
    let mut buf = vec![0u64; (header + w.len() * 2).div_ceil(8)];
    let mut io: IO_STATUS_BLOCK = unsafe { std::mem::zeroed() };
    let status = unsafe {
        let info = buf.as_mut_ptr() as *mut FILE_RENAME_INFORMATION;
        (*info).Anonymous.ReplaceIfExists = 1;
        (*info).RootDirectory = folder.0;
        (*info).FileNameLength = (w.len() * 2) as u32;
        std::ptr::copy_nonoverlapping(w.as_ptr(), (*info).FileName.as_mut_ptr(), w.len());
        NtSetInformationFile(file.0, &mut io, buf.as_ptr().cast(), (header + w.len() * 2) as u32, FileRenameInformation)
    };
    if status < 0 {
        return Err(format!("rename to {name}: NTSTATUS 0x{:08X}", status as u32));
    }
    Ok(())
}

fn delete_by_handle(file: &Handle) -> Result<(), String> {
    let info = FILE_DISPOSITION_INFO { DeleteFile: 1 };
    if unsafe { SetFileInformationByHandle(file.0, FileDispositionInfo, (&info as *const FILE_DISPOSITION_INFO).cast(), std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32) } == 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok(())
}

/// Gives an existing folder (a machine's own folder on the host) an owner and protected DACL from SDDL.
pub fn protect_folder(path: &Path, sddl: &str) -> Result<(), String> {
    let h = unsafe {
        CreateFileW(wide(&path.to_string_lossy()).as_ptr(), WRITE_DAC | WRITE_OWNER | READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE,
            std::ptr::null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(format!("open {}: {}", path.display(), std::io::Error::last_os_error()));
    }
    let h = Handle(h);
    if is_link(h.0)? {
        return Err(format!("{} is a link", path.display()));
    }
    apply_sddl(&h, sddl, &path.to_string_lossy())
}

/// Checks by handle that every part of an existing path is a plain folder or file, never a link, and returns the
/// handle of the last part (kept open while the caller uses the path, so the object can't be swapped away).
pub fn existing_plain(root: &Path, relative: &Path) -> Result<Held, String> {
    let parts = plain_parts(relative)?;
    let mut held = vec![open_root(root)?];
    for (i, p) in parts.iter().enumerate() {
        // Folders stay open without delete sharing, so none can be swapped for a link while the caller works with the
        // path by name; the last part only needs to be checked and left for whoever opens it next.
        let how = if i + 1 < parts.len() { Open::Hold } else { Open::Existing };
        let next = open_child(held.last().unwrap(), p, how, false)?;
        held.push(next);
    }
    // The file itself is only checked: whoever opens it next (the registry loading a hive) needs it alone.
    drop(held.pop());
    Ok(Held(held))
}

/// The handles that keep a checked path as it was; drop it once done with the path.
pub struct Held(Vec<Handle>);

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

    #[test]
    fn a_file_prepared_and_held_open_at_the_target_never_sees_the_secret() {
        use std::io::Read;
        let root = std::env::temp_dir().join(format!("gpuvm-safe-held-{}", std::process::id()));
        fs::create_dir_all(root.join(r"Agent")).unwrap();
        fs::write(root.join(r"Agent\secret"), b"planted").unwrap();
        let mut held = fs::File::open(root.join(r"Agent\secret")).unwrap();
        // Windows won't replace a file someone holds open: the write fails instead of exposing anything.
        assert!(write_file_protected(&root, Path::new(r"Agent\secret"), &[9u8; 32], Some("O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)")).is_err());
        let mut seen = Vec::new();
        held.read_to_end(&mut seen).unwrap();
        assert_eq!(seen, b"planted");
        assert_eq!(fs::read_dir(root.join("Agent")).unwrap().count(), 1, "no temporary file left");
        drop(held);
        write_file_protected(&root, Path::new(r"Agent\secret"), &[9u8; 32], Some("O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)")).unwrap();
        assert_eq!(fs::read(root.join(r"Agent\secret")).unwrap(), [9u8; 32], "replaced once nobody holds it");
        let _ = fs::remove_dir_all(&root);
    }
}
