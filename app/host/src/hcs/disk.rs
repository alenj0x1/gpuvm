//! VHDX files through virtdisk.dll, which every Windows edition has (New-VHD and Mount-VHD need Hyper-V's module).

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::Storage::Vhd::*;
use windows_sys::Win32::System::Ioctl::*;
use windows_sys::Win32::System::IO::DeviceIoControl;

use crate::win::{wide, wide_path};

const VENDOR_MICROSOFT: GUID = GUID::from_u128(0xec984aec_a0f9_47e9_901f_71415a66345b);

fn vhdx() -> VIRTUAL_STORAGE_TYPE {
    VIRTUAL_STORAGE_TYPE { DeviceId: VIRTUAL_STORAGE_TYPE_DEVICE_VHDX, VendorId: VENDOR_MICROSOFT }
}

fn any_type() -> VIRTUAL_STORAGE_TYPE {
    VIRTUAL_STORAGE_TYPE { DeviceId: VIRTUAL_STORAGE_TYPE_DEVICE_UNKNOWN, VendorId: GUID::from_u128(0) }
}

fn win32(code: u32, what: &str, path: &Path) -> Result<(), String> {
    if code == ERROR_SUCCESS {
        return Ok(());
    }
    Err(format!("{what} {}: {} (Windows error {code})", path.display(), std::io::Error::from_raw_os_error(code as i32)))
}

struct Handle(HANDLE);

impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { CloseHandle(self.0) };
    }
}

fn create(path: &Path, size_bytes: u64, parent: Option<&Path>) -> Result<(), String> {
    create_from(path, size_bytes, parent, None)
}

fn create_from(path: &Path, size_bytes: u64, parent: Option<&Path>, source: Option<&Path>) -> Result<(), String> {
    let parent_w = parent.map(wide_path);
    let source_w = source.map(wide_path);
    let mut params: CREATE_VIRTUAL_DISK_PARAMETERS = unsafe { std::mem::zeroed() };
    params.Version = CREATE_VIRTUAL_DISK_VERSION_2;
    unsafe {
        let v2 = &mut params.Anonymous.Version2;
        v2.MaximumSize = if parent.is_some() { 0 } else { size_bytes };
        if let Some(p) = &parent_w {
            v2.ParentPath = p.as_ptr();
            v2.ParentVirtualStorageType = any_type();
        }
        if let Some(s) = &source_w {
            v2.SourcePath = s.as_ptr();
            v2.SourceVirtualStorageType = any_type();
        }
    }
    let path_w = wide_path(path);
    let mut handle: HANDLE = std::ptr::null_mut();
    let code = unsafe {
        CreateVirtualDisk(&vhdx(), path_w.as_ptr(), VIRTUAL_DISK_ACCESS_NONE, std::ptr::null_mut(), CREATE_VIRTUAL_DISK_FLAG_NONE, 0, &params, std::ptr::null(), &mut handle)
    };
    win32(code, "create disk", path)?;
    drop(Handle(handle));
    Ok(())
}

/// A new dynamically expanding VHDX of `size_bytes` (it only takes what is written).
pub fn create_dynamic(path: &Path, size_bytes: u64) -> Result<(), String> {
    create(path, size_bytes, None)
}

/// A new dynamic VHDX at `dest` with everything `source` shows, its parents included: a disk that stands alone.
pub fn flatten(source: &Path, dest: &Path) -> Result<(), String> {
    create_from(dest, 0, None, Some(source))
}

/// A new VHDX that records only the changes on top of `parent`, which must not change afterwards.
pub fn create_differencing(path: &Path, parent: &Path) -> Result<(), String> {
    create(path, 0, Some(parent))
}

fn open(path: &Path, access: VIRTUAL_DISK_ACCESS_MASK, flags: OPEN_VIRTUAL_DISK_FLAG) -> Result<Handle, String> {
    let mut params: OPEN_VIRTUAL_DISK_PARAMETERS = unsafe { std::mem::zeroed() };
    params.Version = OPEN_VIRTUAL_DISK_VERSION_1;
    params.Anonymous.Version1.RWDepth = 1;
    let path_w = wide_path(path);
    let mut handle: HANDLE = std::ptr::null_mut();
    let code = unsafe { OpenVirtualDisk(&any_type(), path_w.as_ptr(), access, flags, &params, &mut handle) };
    win32(code, "open disk", path)?;
    Ok(Handle(handle))
}

/// The file a differencing disk builds on, as recorded in it (None for a disk without a parent).
pub fn parent_of(path: &Path) -> Result<Option<PathBuf>, String> {
    let disk = open(path, VIRTUAL_DISK_ACCESS_GET_INFO, OPEN_VIRTUAL_DISK_FLAG_NO_PARENTS)?;
    let mut buf = vec![0u64; 1024];
    let mut size = (buf.len() * 8) as u32;
    let info = buf.as_mut_ptr() as *mut GET_VIRTUAL_DISK_INFO;
    unsafe { (*info).Version = GET_VIRTUAL_DISK_INFO_PARENT_LOCATION };
    let code = unsafe { GetVirtualDiskInformation(disk.0, &mut size, info, std::ptr::null_mut()) };
    if code == ERROR_VHD_INVALID_TYPE {
        return Ok(None);
    }
    win32(code, "read parent of", path)?;
    unsafe {
        let loc = &(*info).Anonymous.ParentLocation;
        let start = loc.ParentLocationBuffer.as_ptr();
        let max = (size as usize).saturating_sub(start as usize - info as usize) / 2;
        Ok(absolute_entry(std::slice::from_raw_parts(start, max)))
    }
}

// The location list holds the stored relative and absolute paths, null-separated, in no promised order.
fn absolute_entry(list: &[u16]) -> Option<PathBuf> {
    let end = list.windows(2).position(|w| w == [0, 0]).map_or(list.len(), |i| i + 1);
    list[..end].split(|&c| c == 0).map(String::from_utf16_lossy)
        .find(|s| s.starts_with(r"\\?\") || s.as_bytes().get(1) == Some(&b':'))
        .map(PathBuf::from)
}

/// The disk's virtual size (what Windows inside sees) and the bytes its file takes now.
pub fn size_of(path: &Path) -> Result<(u64, u64), String> {
    let disk = open(path, VIRTUAL_DISK_ACCESS_GET_INFO, OPEN_VIRTUAL_DISK_FLAG_NO_PARENTS)?;
    let mut info: GET_VIRTUAL_DISK_INFO = unsafe { std::mem::zeroed() };
    info.Version = GET_VIRTUAL_DISK_INFO_SIZE;
    let mut size = std::mem::size_of::<GET_VIRTUAL_DISK_INFO>() as u32;
    let code = unsafe { GetVirtualDiskInformation(disk.0, &mut size, &mut info, std::ptr::null_mut()) };
    win32(code, "read size of", path)?;
    let s = unsafe { info.Anonymous.Size };
    Ok((s.VirtualSize, s.PhysicalSize))
}

/// Grows a disk's virtual size (the partition inside is grown separately).
pub fn resize(path: &Path, new_size: u64) -> Result<(), String> {
    let disk = open(path, VIRTUAL_DISK_ACCESS_ALL, OPEN_VIRTUAL_DISK_FLAG_NONE)?;
    let mut params: RESIZE_VIRTUAL_DISK_PARAMETERS = unsafe { std::mem::zeroed() };
    params.Version = RESIZE_VIRTUAL_DISK_VERSION_1;
    params.Anonymous.Version1.NewSize = new_size;
    let code = unsafe { ResizeVirtualDisk(disk.0, RESIZE_VIRTUAL_DISK_FLAG_NONE, &params, std::ptr::null()) };
    win32(code, "resize", path)
}

/// A disk attached to this PC without a drive letter, detached when dropped.
pub struct Attached {
    disk: Handle,
    pub physical: String,
    pub number: u32,
}

impl Attached {
    /// Volume paths (`\\?\Volume{...}\`) on this disk; they appear a moment after attaching.
    pub fn volumes(&self, wait: Duration) -> Vec<String> {
        let until = Instant::now() + wait;
        loop {
            let found = volumes_on_disk(self.number);
            if !found.is_empty() || Instant::now() >= until {
                return found;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    /// The volume that holds Windows (`Windows\System32\config\SOFTWARE`), for changes made with the machine off.
    /// A disk a guest has run is guest-controlled: its junctions and symlinks can point at host paths, so writes into
    /// it must refuse reparse points along the way.
    pub fn windows_volume(&self, wait: Duration) -> Option<String> {
        // Small partitions (EFI, recovery) usually mount first: keep looking until Windows' own volume is there.
        let until = Instant::now() + wait;
        loop {
            let found = volumes_on_disk(self.number).into_iter().find(|v| Path::new(v).join(r"Windows\System32\config\SOFTWARE").is_file());
            if found.is_some() || Instant::now() >= until {
                return found;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
}

impl Drop for Attached {
    fn drop(&mut self) {
        unsafe { DetachVirtualDisk(self.disk.0, DETACH_VIRTUAL_DISK_FLAG_NONE, 0) };
    }
}

pub fn attach(path: &Path, read_only: bool) -> Result<Attached, String> {
    let access = if read_only {
        VIRTUAL_DISK_ACCESS_ATTACH_RO | VIRTUAL_DISK_ACCESS_DETACH | VIRTUAL_DISK_ACCESS_GET_INFO
    } else {
        VIRTUAL_DISK_ACCESS_ALL
    };
    let disk = open(path, access, OPEN_VIRTUAL_DISK_FLAG_NONE)?;
    let mut params: ATTACH_VIRTUAL_DISK_PARAMETERS = unsafe { std::mem::zeroed() };
    params.Version = ATTACH_VIRTUAL_DISK_VERSION_1;
    let mut flags = ATTACH_VIRTUAL_DISK_FLAG_NO_DRIVE_LETTER;
    if read_only {
        flags |= ATTACH_VIRTUAL_DISK_FLAG_READ_ONLY;
    }
    let code = unsafe { AttachVirtualDisk(disk.0, std::ptr::null_mut(), flags, 0, &params, std::ptr::null()) };
    win32(code, "attach", path)?;
    let mut buf = [0u16; 260];
    let mut bytes = (buf.len() * 2) as u32;
    let code = unsafe { GetVirtualDiskPhysicalPath(disk.0, &mut bytes, buf.as_mut_ptr()) };
    if code != ERROR_SUCCESS {
        unsafe { DetachVirtualDisk(disk.0, DETACH_VIRTUAL_DISK_FLAG_NONE, 0) };
        return Err(format!("physical path of {}: Windows error {code}", path.display()));
    }
    let physical = String::from_utf16_lossy(&buf[..buf.iter().position(|&c| c == 0).unwrap_or(0)]);
    let number = disk_number(&physical).ok_or_else(|| format!("unexpected disk path {physical}"))?;
    Ok(Attached { disk, physical, number })
}

fn disk_number(physical: &str) -> Option<u32> {
    let upper = physical.to_ascii_uppercase();
    upper.strip_prefix(r"\\.\PHYSICALDRIVE")?.parse().ok()
}

fn volumes_on_disk(number: u32) -> Vec<String> {
    let mut out = Vec::new();
    let mut name = [0u16; 64];
    unsafe {
        let find = FindFirstVolumeW(name.as_mut_ptr(), name.len() as u32);
        if find == INVALID_HANDLE_VALUE {
            return out;
        }
        loop {
            let vol = String::from_utf16_lossy(&name[..name.iter().position(|&c| c == 0).unwrap_or(0)]);
            if volume_disk(&vol) == Some(number) {
                out.push(vol);
            }
            if FindNextVolumeW(find, name.as_mut_ptr(), name.len() as u32) == 0 {
                break;
            }
        }
        FindVolumeClose(find);
    }
    out
}

fn volume_disk(volume: &str) -> Option<u32> {
    let device = wide(volume.trim_end_matches('\\'));
    unsafe {
        let h = CreateFileW(device.as_ptr(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE, std::ptr::null(), OPEN_EXISTING, 0, std::ptr::null_mut());
        if h == INVALID_HANDLE_VALUE {
            return None;
        }
        let h = Handle(h);
        let mut extents: VOLUME_DISK_EXTENTS = std::mem::zeroed();
        let mut returned = 0u32;
        let ok = DeviceIoControl(h.0, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, std::ptr::null(), 0,
            (&mut extents as *mut VOLUME_DISK_EXTENTS).cast(), std::mem::size_of::<VOLUME_DISK_EXTENTS>() as u32, &mut returned, std::ptr::null_mut());
        (ok != 0 && extents.NumberOfDiskExtents >= 1).then(|| extents.Extents[0].DiskNumber)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parent_location_prefers_an_absolute_path() {
        let list: Vec<u16> = ".\\base.vhdx\0C:\\GpuVM\\base.vhdx\0\0".encode_utf16().collect();
        assert_eq!(absolute_entry(&list), Some(PathBuf::from(r"C:\GpuVM\base.vhdx")));
        let unc: Vec<u16> = "\\\\?\\Volume{1}\\base.vhdx\0\0".encode_utf16().collect();
        assert_eq!(absolute_entry(&unc), Some(PathBuf::from(r"\\?\Volume{1}\base.vhdx")));
        let none: Vec<u16> = ".\\base.vhdx\0\0".encode_utf16().collect();
        assert_eq!(absolute_entry(&none), None);
    }

    #[test]
    fn disk_number_ignores_case() {
        assert_eq!(disk_number(r"\\.\PhysicalDrive3"), Some(3));
        assert_eq!(disk_number(r"\\.\PHYSICALDRIVE12"), Some(12));
        assert_eq!(disk_number(r"\\.\CdRom0"), None);
    }
}

#[cfg(test)]
mod live {
    use super::*;

    struct Gone(PathBuf);

    impl Drop for Gone {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    // Needs an elevated shell; run with `cargo test -- --ignored hcs`.
    #[test]
    #[ignore]
    fn hcs_disks_create_chain_and_attach() {
        let dir = std::env::temp_dir().join(format!("gpuvm-disk-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let _gone = Gone(dir.clone());
        let (base, child) = (dir.join("base.vhdx"), dir.join("child.vhdx"));
        create_dynamic(&base, 64 << 20).unwrap();
        create_differencing(&child, &base).unwrap();
        assert_eq!(parent_of(&base).unwrap(), None);
        let parent = parent_of(&child).unwrap().expect("child has a parent");
        assert_eq!(std::fs::canonicalize(&parent).unwrap(), std::fs::canonicalize(&base).unwrap());
        {
            let attached = attach(&child, true).unwrap();
            assert!(attached.physical.to_uppercase().starts_with(r"\\.\PHYSICALDRIVE"));
            assert!(attached.volumes(Duration::from_millis(500)).is_empty(), "a blank disk has no volume");
        }
        assert!(attach(&child, false).is_ok(), "detached on drop, so it can be attached again");
        assert_eq!(size_of(&base).unwrap().0, 64 << 20);
        resize(&base, 128 << 20).unwrap();
        assert_eq!(size_of(&base).unwrap().0, 128 << 20);
    }

    // GPUVM_TEST_LAYER = the newest layer of a GpuVM template; a throwaway child is attached, never the layer itself.
    #[test]
    #[ignore]
    fn hcs_disks_find_windows_in_a_template_copy() {
        let Ok(layer) = std::env::var("GPUVM_TEST_LAYER") else { panic!("set GPUVM_TEST_LAYER") };
        let dir = std::env::temp_dir().join(format!("gpuvm-disk-test-win-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let _gone = Gone(dir.clone());
        let child = dir.join("copy.vhdx");
        create_differencing(&child, Path::new(&layer)).unwrap();
        let found = {
            let attached = attach(&child, true).unwrap();
            attached.windows_volume(Duration::from_secs(10))
        };
        let volume = found.expect("a Windows volume");
        assert!(volume.starts_with(r"\\?\Volume{"), "{volume}");
    }
}
