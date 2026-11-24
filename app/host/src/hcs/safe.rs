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

fn open_child(parent: &Handle, name: &str, dir: bool) -> Result<Handle, String> {
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
    let (access, disposition, kind) = if dir {
        (FILE_TRAVERSE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OPEN_IF, FILE_DIRECTORY_FILE)
    } else {
        (FILE_GENERIC_WRITE | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_OVERWRITE_IF, FILE_NON_DIRECTORY_FILE)
    };
    let status = unsafe {
        NtCreateFile(&mut h, access, &oa, &mut io, std::ptr::null(), FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ, disposition,
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

/// Writes `bytes` to `relative` under `root` (a volume or folder of a disk a guest controls), creating folders as
/// needed. Refuses links anywhere on the way and anything but a plain relative path.
pub fn write_file(root: &Path, relative: &Path, bytes: &[u8]) -> Result<(), String> {
    let parts: Vec<String> = relative.components().map(|c| match c {
        Component::Normal(n) => n.to_str().map(String::from).ok_or_else(|| format!("not a valid name in {}", relative.display())),
        _ => Err(format!("not a plain relative path: {}", relative.display())),
    }).collect::<Result<_, _>>()?;
    if parts.is_empty() || parts.iter().any(|p| p.contains(':')) {
        return Err(format!("not a plain relative path: {}", relative.display()));
    }
    let root_w = wide(&root.to_string_lossy());
    let h = unsafe {
        CreateFileW(root_w.as_ptr(), FILE_TRAVERSE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
            FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(format!("open {}: {}", root.display(), std::io::Error::last_os_error()));
    }
    let mut cur = Handle(h);
    if is_link(cur.0)? {
        return Err(format!("{} is a link", root.display()));
    }
    let (last, folders) = parts.split_last().unwrap();
    for f in folders {
        cur = open_child(&cur, f, true)?;
    }
    let file = open_child(&cur, last, false)?;
    let mut written = 0u32;
    let ok = unsafe { WriteFile(file.0, bytes.as_ptr(), bytes.len() as u32, &mut written, std::ptr::null_mut()) };
    if ok == 0 || written as usize != bytes.len() {
        return Err(format!("write {last}: {}", std::io::Error::last_os_error()));
    }
    Ok(())
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
        let _ = fs::remove_dir_all(&root);
    }
}
