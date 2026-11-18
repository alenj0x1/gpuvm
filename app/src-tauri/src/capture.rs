//! Screenshots and recordings from the viewer's side panel (the viewer's side: gpuvm-viewer app/gpuvm/capture.h).
//!
//! The viewer runs at Low integrity and can only write under its LocalLow folder. When it finishes a file it says so
//! ("capture"), and this app moves it to the person's Pictures or Videos folder (GpuVM\<machine>). The viewer is
//! untrusted (it talks to a server the guest controls), so the move never lets it reach anything else:
//! - only a bare file name of a fixed shape is accepted, looked up in the viewer's own Captures folder;
//! - the file is opened without following links, refused if it is a reparse point or has more than one name, and
//!   its real path (from the open handle) must be inside that folder: a junction swapped in for the folder can't
//!   point this app at the person's other files;
//! - it must start like a PNG or an MP4 and stay under a size cap; it is copied into a new file this app names
//!   (never replacing one) and the viewer's copy is deleted through the same handle;
//! - the panel can only open or show files this app moved during this run.

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter};
use windows_sys::Win32::Storage::FileSystem::{
    FileDispositionInfo, GetFileInformationByHandle, GetFinalPathNameByHandleW, SetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
    FILE_ATTRIBUTE_REPARSE_POINT, FILE_DISPOSITION_INFO, FILE_FLAG_OPEN_REPARSE_POINT, FILE_NAME_NORMALIZED, FILE_SHARE_READ,
};

/// The largest file taken from the viewer: a 4K PNG is ~25 MB; a recording can be long.
const MAX_SHOT: u64 = 256 << 20;
const MAX_VIDEO: u64 = 512 << 30;
/// Files the panel may open or show (the newest ones moved in this run).
const RECENT_MAX: usize = 64;

#[derive(Clone, Default)]
struct Prefs {
    replay: bool,
    shots: Option<PathBuf>,
    videos: Option<PathBuf>,
    lang: String,
}

static PREFS: Mutex<Option<Prefs>> = Mutex::new(None);
static RECENT: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

/// Per machine: its newest saved file and whether it is recording (since when, ms since 1970). The panel is created
/// the first time it opens and may be closed meanwhile, so it asks for this when it shows a machine.
#[derive(Default)]
struct MachineState {
    last: Option<Value>,
    recording_since: Option<u64>,
}
static STATE: Mutex<Option<std::collections::HashMap<String, MachineState>>> = Mutex::new(None);

fn with_state<R>(vm: &str, f: impl FnOnce(&mut MachineState) -> R) -> R {
    let mut all = STATE.lock().unwrap_or_else(|e| e.into_inner());
    f(all.get_or_insert_with(Default::default).entry(vm.to_string()).or_default())
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The viewer started or stopped recording, or closed.
pub fn on_recording(vm: &str, on: bool) {
    with_state(vm, |s| s.recording_since = if on { s.recording_since.or(Some(now_ms())) } else { None });
}

/// What the panel shows for a machine: the newest file and the recording's start.
#[tauri::command]
pub fn capture_state(vm: String) -> Value {
    with_state(&vm, |s| json!({ "last": s.last.clone(), "recordingSince": s.recording_since }))
}

fn prefs() -> Prefs {
    PREFS.lock().unwrap_or_else(|e| e.into_inner()).clone().unwrap_or_default()
}

fn wide(s: &std::ffi::OsStr) -> Vec<u16> {
    s.encode_wide().chain(Some(0)).collect()
}

/// A known folder (Pictures, Videos) where Windows keeps it, OneDrive or a moved folder included.
fn known_folder(id: &windows_sys::core::GUID) -> Option<PathBuf> {
    use windows_sys::Win32::System::Com::CoTaskMemFree;
    use windows_sys::Win32::UI::Shell::SHGetKnownFolderPath;
    let mut raw: windows_sys::core::PWSTR = std::ptr::null_mut();
    // SAFETY: on success the shell allocates a NUL-terminated string that is freed with CoTaskMemFree.
    unsafe {
        if SHGetKnownFolderPath(id, 0, std::ptr::null_mut(), &mut raw) != 0 || raw.is_null() {
            return None;
        }
        let len = (0..).take_while(|&i| *raw.add(i) != 0).count();
        let path = String::from_utf16_lossy(std::slice::from_raw_parts(raw, len));
        CoTaskMemFree(raw as _);
        Some(PathBuf::from(path))
    }
}

fn default_folder(video: bool) -> Option<PathBuf> {
    use windows_sys::Win32::UI::Shell::{FOLDERID_Pictures, FOLDERID_Videos};
    let base = known_folder(if video { &FOLDERID_Videos } else { &FOLDERID_Pictures })?;
    Some(base.join("GpuVM"))
}

/// Where screenshots (or videos) go: the folder chosen in Ajustes, or Pictures\GpuVM (Videos\GpuVM).
fn folder(video: bool) -> Option<PathBuf> {
    let p = prefs();
    let chosen = if video { p.videos } else { p.shots };
    chosen.or_else(|| default_folder(video))
}

/// A machine's name as a folder name: Windows' forbidden characters out, never empty or a dot name.
fn safe_name(vm: &str) -> String {
    let cleaned: String = vm.chars().filter(|c| !c.is_control() && !"<>:\"/\\|?*".contains(*c)).take(64).collect();
    let cleaned = cleaned.trim().trim_end_matches('.').to_string();
    if cleaned.is_empty() || cleaned.chars().all(|c| c == '.') { "GpuVM".into() } else { cleaned }
}

/// The viewer's names: (shot|clip|replay)-YYYYMMDD-HHMMSS-N.(png|mp4). Returns the kind, the date as shown in the
/// final name ("2026-11-18 21.04.13") and the extension.
fn parse_name(name: &str) -> Option<(&'static str, String, &'static str)> {
    let (stem, ext) = name.rsplit_once('.')?;
    let ext = match ext { "png" => "png", "mp4" => "mp4", _ => return None };
    let mut parts = stem.split('-');
    let kind = match (parts.next()?, ext) { ("shot", "png") => "shot", ("clip", "mp4") => "clip", ("replay", "mp4") => "replay", _ => return None };
    let (date, time, n) = (parts.next()?, parts.next()?, parts.next()?);
    if parts.next().is_some() || date.len() != 8 || time.len() != 6 || n.is_empty() || n.len() > 4 {
        return None;
    }
    if !date.bytes().chain(time.bytes()).chain(n.bytes()).all(|b| b.is_ascii_digit()) {
        return None;
    }
    let shown = format!("{}-{}-{} {}.{}.{}", &date[..4], &date[4..6], &date[6..], &time[..2], &time[2..4], &time[4..]);
    Some((kind, shown, ext))
}

/// The real path of an open handle (\\?\C:\...), lowercased for comparison.
fn final_path(file: &std::fs::File) -> Option<String> {
    let mut buf = vec![0u16; 1024];
    // SAFETY: valid handle and buffer of the given length.
    let n = unsafe { GetFinalPathNameByHandleW(file.as_raw_handle() as _, buf.as_mut_ptr(), buf.len() as u32, FILE_NAME_NORMALIZED) } as usize;
    if n == 0 || n >= buf.len() {
        return None;
    }
    Some(String::from_utf16_lossy(&buf[..n]).to_lowercase())
}

/// Opens the file itself (a link is opened as the link, never followed), to read and later delete it; nobody else
/// may write or delete it meanwhile.
fn open_no_follow(path: &Path) -> std::io::Result<std::fs::File> {
    const DELETE: u32 = 0x0001_0000;
    const GENERIC_READ: u32 = 0x8000_0000;
    std::fs::OpenOptions::new()
        .read(true)
        .access_mode(GENERIC_READ | DELETE)
        .share_mode(FILE_SHARE_READ)
        .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
        .open(path)
}

/// Takes the viewer's finished file into the person's folder; returns its new path.
fn take(vm: &str, name: &str) -> Result<(PathBuf, &'static str), String> {
    let (kind, shown, ext) = parse_name(name).ok_or("name")?;
    let captures = crate::lowbox::viewer_data().ok_or("folder")?.join("Captures");
    let source = captures.join(name);
    // The file's real path must be exactly this one: a junction anywhere on the way (the viewer can replace its own
    // folders) would show up as another path.
    let expected = format!("\\\\?\\{}", source.to_string_lossy()).to_lowercase();
    let mut file = open_no_follow(&source).map_err(|_| "open")?;
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: valid handle and out struct.
    if unsafe { GetFileInformationByHandle(file.as_raw_handle() as _, &mut info) } == 0 {
        return Err("open".into());
    }
    let size = ((info.nFileSizeHigh as u64) << 32) | info.nFileSizeLow as u64;
    let real = final_path(&file).ok_or("open")?;
    if info.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | 0x10 /* directory */) != 0 || info.nNumberOfLinks != 1 || real != expected {
        return Err("link".into());
    }
    if size == 0 || size > if ext == "png" { MAX_SHOT } else { MAX_VIDEO } {
        return Err("size".into());
    }
    let mut head = [0u8; 12];
    file.read_exact(&mut head).map_err(|_| "read")?;
    let ok = if ext == "png" { head[..8] == [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a] } else { &head[4..8] == b"ftyp" };
    if !ok {
        return Err("format".into());
    }

    let base = folder(ext == "mp4").ok_or("folder")?.join(safe_name(vm));
    std::fs::create_dir_all(&base).map_err(|_| "folder")?;
    let stem = format!("{} {}", safe_name(vm), shown);
    let (mut out, target) = (1..100)
        .find_map(|i| {
            let file_name = if i == 1 { format!("{stem}.{ext}") } else { format!("{stem} ({i}).{ext}") };
            let p = base.join(file_name);
            std::fs::OpenOptions::new().write(true).create_new(true).open(&p).ok().map(|f| (f, p))
        })
        .ok_or("exists")?;
    let copied = (|| -> std::io::Result<()> {
        out.write_all(&head)?;
        let mut buf = vec![0u8; 1 << 20];
        let mut total = head.len() as u64;
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            total += n as u64;
            if total > size {
                return Err(std::io::Error::other("grew"));
            }
            out.write_all(&buf[..n])?;
        }
        out.flush()
    })();
    drop(out);
    if copied.is_err() {
        let _ = std::fs::remove_file(&target);
        return Err("copy".into());
    }
    // The viewer's copy is deleted through the handle that was read (the same file, whatever its name says now).
    let mut disposition = FILE_DISPOSITION_INFO { DeleteFile: true };
    // SAFETY: valid handle opened with DELETE access; the struct outlives the call.
    unsafe {
        SetFileInformationByHandle(file.as_raw_handle() as _, FileDispositionInfo, &mut disposition as *mut _ as _, std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32);
    }
    let mut recent = RECENT.lock().unwrap_or_else(|e| e.into_inner());
    recent.push(target.clone());
    let excess = recent.len().saturating_sub(RECENT_MAX);
    recent.drain(..excess);
    Ok((target, kind))
}

/// A thumbnail the viewer sent, kept only if it is a small JPEG data URL.
fn clean_thumb(v: &Value) -> Value {
    let Some(s) = v.as_str() else { return Value::Null };
    let Some(data) = s.strip_prefix("data:image/jpeg;base64,") else { return Value::Null };
    if data.len() > 13000 || !data.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=') {
        return Value::Null;
    }
    Value::String(s.to_string())
}

/// The viewer finished a file ("capture"): moved on a worker thread (a long recording takes a moment), then the
/// panel hears "capture-saved" (or "capture-error").
pub fn on_file(app: &AppHandle, vm: &str, msg: &Value) {
    let (app, vm, msg) = (app.clone(), vm.to_string(), msg.clone());
    std::thread::spawn(move || {
        let name = msg["file"].as_str().unwrap_or("");
        match take(&vm, name) {
            Ok((path, kind)) => {
                let shown = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
                let saved = json!({
                    "vm": vm, "kind": kind, "path": path.to_string_lossy(), "name": shown,
                    "thumb": clean_thumb(&msg["thumb"]),
                    "durationMs": msg["durationMs"].as_f64().unwrap_or(0.0).max(0.0),
                    "width": msg["width"].as_u64().unwrap_or(0).min(16384), "height": msg["height"].as_u64().unwrap_or(0).min(16384),
                    "bytes": std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0),
                    "at": now_ms(),
                });
                with_state(&vm, |s| s.last = Some(saved.clone()));
                let _ = app.emit("capture-saved", saved);
            }
            Err(reason) => {
                let _ = app.emit("viewer", json!({ "vm": vm, "msg": { "type": "capture-error", "kind": "move", "reason": reason } }));
            }
        }
    });
}

/// What the viewer needs to know (sent when it connects and whenever Ajustes change).
pub fn setup_message() -> Value {
    let p = prefs();
    json!({ "type": "capture-setup", "replay": p.replay, "seconds": 30, "lang": if p.lang == "en" { "en" } else { "es" } })
}

fn check_dir(dir: Option<String>) -> Result<Option<PathBuf>, String> {
    match dir.filter(|d| !d.trim().is_empty()) {
        None => Ok(None),
        Some(d) => {
            let p = PathBuf::from(d);
            if p.is_absolute() && p.is_dir() { Ok(Some(p)) } else { Err("Esa carpeta no existe.".into()) }
        }
    }
}

/// Ajustes › Capturas: the last 30 s on or off, and the folders (empty = Pictures\GpuVM, Videos\GpuVM).
#[tauri::command]
pub fn set_capture_prefs(replay: bool, shots_dir: Option<String>, videos_dir: Option<String>, lang: String) -> Result<(), String> {
    let next = Prefs { replay, shots: check_dir(shots_dir)?, videos: check_dir(videos_dir)?, lang };
    *PREFS.lock().unwrap_or_else(|e| e.into_inner()) = Some(next);
    crate::viewer::broadcast(&setup_message());
    Ok(())
}

/// Whether Windows itself has a decoder for a video format (what its own players use; HEVC and AV1 come as Store
/// extensions).
fn windows_decodes(fourcc: &[u8; 4]) -> bool {
    use windows_sys::core::GUID;
    use windows_sys::Win32::System::Com::CoTaskMemFree;
    #[repr(C)]
    struct TypeInfo { major: GUID, sub: GUID }
    #[link(name = "mfplat")]
    extern "system" {
        fn MFTEnumEx(category: GUID, flags: u32, input: *const TypeInfo, output: *const TypeInfo, activates: *mut *mut *mut core::ffi::c_void, count: *mut u32) -> i32;
    }
    // MFT_CATEGORY_VIDEO_DECODER, MFMediaType_Video, and the format's FOURCC GUID (MFVideoFormat_HEVC = 'HEVC').
    let category = GUID { data1: 0xd6c02d4b, data2: 0x6833, data3: 0x45b4, data4: [0x97, 0x1a, 0x05, 0xa4, 0xb0, 0x4b, 0xab, 0x91] };
    let base = [0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71];
    let video = GUID { data1: 0x73646976, data2: 0, data3: 0x10, data4: base };
    let input = TypeInfo { major: video, sub: GUID { data1: u32::from_le_bytes(*fourcc), data2: 0, data3: 0x10, data4: base } };
    let mut list: *mut *mut core::ffi::c_void = std::ptr::null_mut();
    let mut count = 0u32;
    // SAFETY: MFTEnumEx fills a CoTaskMem array of IMFActivate pointers; each is released and the array freed.
    unsafe {
        let hr = MFTEnumEx(category, 0x3f /* MFT_ENUM_FLAG_ALL */, &input, std::ptr::null(), &mut list, &mut count);
        if hr != 0 || list.is_null() {
            return false;
        }
        for i in 0..count as usize {
            let item = *list.add(i);
            if !item.is_null() {
                // IUnknown::Release, the third entry of the vtable.
                let vtbl = *(item as *const *const usize);
                let release: extern "system" fn(*mut core::ffi::c_void) -> u32 = std::mem::transmute(*vtbl.add(2));
                release(item);
            }
        }
        CoTaskMemFree(list as _);
    }
    count > 0
}

/// The folders in use, as shown in Ajustes, and which recorded formats Windows' own players can open.
#[tauri::command]
pub fn capture_folders() -> Value {
    json!({
        "shots": folder(false).map(|p| p.to_string_lossy().to_string()),
        "videos": folder(true).map(|p| p.to_string_lossy().to_string()),
        "hevc": windows_decodes(b"HEVC"),
        "av1": windows_decodes(b"AV01"),
    })
}

/// Opens Microsoft Store's page of the HEVC video extension (a fixed address, nothing from the pages).
#[tauri::command]
pub fn capture_get_hevc() -> Result<(), String> {
    shell_open(Path::new("ms-windows-store://pdp/?ProductId=9NMZLZ57R3T7"))
}

fn shell_open(target: &Path) -> Result<(), String> {
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    let verb = wide("open".as_ref());
    let file = wide(target.as_os_str());
    // SAFETY: NUL-terminated strings that live through the call.
    let r = unsafe { ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), file.as_ptr(), std::ptr::null(), std::ptr::null(), 1) };
    if r as isize > 32 { Ok(()) } else { Err("No se pudo abrir.".into()) }
}

fn recent(path: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(path);
    if RECENT.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|r| r == &p) && p.is_file() {
        Ok(p)
    } else {
        Err("Ese archivo ya no está.".into())
    }
}

/// Opens a capture this app saved, with the person's usual app for it.
#[tauri::command]
pub fn capture_open(path: String) -> Result<(), String> {
    shell_open(&recent(&path)?)
}

/// Shows a capture this app saved in the Explorer, selected.
#[tauri::command]
pub fn capture_reveal(path: String) -> Result<(), String> {
    let p = recent(&path)?;
    let explorer = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:\\Windows")).join("explorer.exe");
    let mut arg = std::ffi::OsString::from("/select,");
    arg.push(p.as_os_str());
    std::process::Command::new(explorer).arg(arg).spawn().map(|_| ()).map_err(|_| "No se pudo abrir el Explorador.".into())
}

/// Opens the screenshots or videos folder (created if it doesn't exist yet).
#[tauri::command]
pub fn capture_open_folder(video: bool) -> Result<(), String> {
    let dir = folder(video).ok_or("No se encontró la carpeta.")?;
    std::fs::create_dir_all(&dir).map_err(|_| "No se pudo crear la carpeta.".to_string())?;
    shell_open(&dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names() {
        assert_eq!(parse_name("shot-20261118-210413-1.png").map(|n| n.1), Some("2026-11-18 21.04.13".into()));
        assert!(parse_name("clip-20261118-210413-12.mp4").is_some());
        assert!(parse_name("replay-20261118-210413-9999.mp4").is_some());
        for bad in ["shot-20261118-210413-1.mp4", "clip-20261118-210413-1.png", "..\\x.png", "shot-2026111-210413-1.png",
                    "shot-20261118-210413-1.png.part", "shot-20261118-210413-12345.png", "shot-20261118-210413-1-2.png",
                    "shot-2026111a-210413-1.png", "C:\\x\\shot-20261118-210413-1.png", "shot-20261118-210413-.png"] {
            assert!(parse_name(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn machine_names() {
        assert_eq!(safe_name("win11-pruebas"), "win11-pruebas");
        assert_eq!(safe_name("a/b:c*"), "abc");
        assert_eq!(safe_name(".."), "GpuVM");
        assert_eq!(safe_name("  "), "GpuVM");
    }

    #[test]
    fn decoders() {
        // Every Windows has H.264; HEVC and AV1 depend on Store extensions (whatever this PC has, no crash).
        assert!(windows_decodes(b"H264"));
        let _ = windows_decodes(b"HEVC");
        assert!(!windows_decodes(b"ZZZZ"));
    }

    #[test]
    fn thumbs() {
        assert!(clean_thumb(&json!("data:image/jpeg;base64,/9j/4AAQ==")).is_string());
        assert!(clean_thumb(&json!("data:image/svg+xml;base64,PHN2Zz4=")).is_null());
        assert!(clean_thumb(&json!("data:image/jpeg;base64,\"><script>")).is_null());
        assert!(clean_thumb(&json!(format!("data:image/jpeg;base64,{}", "A".repeat(20000)))).is_null());
    }
}
