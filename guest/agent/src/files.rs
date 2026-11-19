//! files.list / files.read / files.write, limited to the `agent` user's profile (`C:\Users\agent`).
//! Run by the helper as that user, so Windows' own ACLs apply too. On top of them: no `..`, no device names or
//! alternate streams, no links anywhere on the path (junctions, symlinks, hard links with more than one name), and
//! the opened handle's final path must still be inside the profile.
use crate::capture::CallResult;
use crate::proto::{hex, sha256};
use crate::util::{wide, wstr};
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::os::windows::io::{FromRawHandle, OwnedHandle};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use windows::core::PCWSTR;
use windows::Win32::Foundation::*;
use windows::Win32::Storage::FileSystem::*;

pub const MAX_FILE: u64 = 16 * 1024 * 1024;
type Fail = (&'static str, String);

/// The profile root, only when the helper runs as `agent` (protocol: files and commands are the agent user's).
pub fn root() -> Result<&'static PathBuf, Fail> {
    static R: OnceLock<Option<PathBuf>> = OnceLock::new();
    R.get_or_init(|| {
        // by SID (recorded by the installer in HKLM), never by name: another account called "agent" doesn't count
        if !crate::token::is_agent_process() {
            return None;
        }
        std::env::var_os("USERPROFILE").map(PathBuf::from).filter(|p| p.is_absolute())
    })
    .as_ref()
    .ok_or(("denied", "files and commands are only available when the machine is signed in as the agent user".into()))
}

fn lower(p: &Path) -> String {
    p.to_string_lossy().to_lowercase().trim_end_matches('\\').to_string()
}

const DEVICES: &[&str] = &["con", "prn", "aux", "nul", "conin$", "conout$", "clock$"];

/// Checks a path given by the host and returns it absolute, normalized, inside the root, with no link on the way.
pub fn resolve(input: &str) -> Result<PathBuf, Fail> {
    let root = root()?;
    if input.is_empty() || input.len() > 1024 || input.contains('\0') {
        return Err(("bad_request", "path is empty or too long".into()));
    }
    let s = input.replace('/', "\\");
    if s.starts_with("\\\\") {
        return Err(("denied", "device and network paths aren't allowed".into()));
    }
    let rel: String = if s.len() >= 2 && s.as_bytes()[1] == b':' {
        let rl = lower(root);
        let n = rl.len();
        // ASCII-only, case-insensitive prefix match (no Unicode case folding tricks)
        if s.len() >= n && s.is_char_boundary(n) && s[..n].eq_ignore_ascii_case(&rl) && (s.len() == n || s.as_bytes()[n] == b'\\') {
            s[n..].to_string()
        } else {
            return Err(("denied", format!("only paths under {} are allowed", root.display())));
        }
    } else {
        s.trim_start_matches('\\').to_string()
    };
    let mut out = root.clone();
    for c in rel.split('\\').filter(|c| !c.is_empty() && *c != ".") {
        if c == ".." {
            return Err(("denied", "'..' isn't allowed".into()));
        }
        if c.contains(':') || c.contains(|ch: char| "<>\"|?*".contains(ch) || (ch as u32) < 32) {
            return Err(("bad_request", format!("'{c}' isn't a valid name")));
        }
        if c.ends_with('.') || c.ends_with(' ') {
            return Err(("bad_request", format!("'{c}' ends with a dot or a space")));
        }
        let stem = c.split('.').next().unwrap_or("").to_lowercase();
        if DEVICES.contains(&stem.as_str()) || ((stem.starts_with("com") || stem.starts_with("lpt")) && stem.len() == 4 && stem.as_bytes()[3].is_ascii_digit()) {
            return Err(("bad_request", format!("'{c}' is a device name")));
        }
        out.push(c);
        // no link on the way (checked for the parts that exist)
        let w = wide(&out.to_string_lossy());
        let a = unsafe { GetFileAttributesW(PCWSTR(w.as_ptr())) };
        if a != INVALID_FILE_ATTRIBUTES && a & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
            return Err(("denied", format!("{} is a link: links aren't followed", out.display())));
        }
    }
    Ok(out)
}

/// Opens without following links, then checks: not a link, one name only, final path inside the root.
fn open_checked(p: &Path, access: u32, disposition: FILE_CREATION_DISPOSITION, dir: bool) -> Result<(OwnedHandle, BY_HANDLE_FILE_INFORMATION, bool), Fail> {
    let root = root()?;
    let w = wide(&p.to_string_lossy());
    let flags = FILE_FLAG_OPEN_REPARSE_POINT | if dir { FILE_FLAG_BACKUP_SEMANTICS } else { FILE_FLAGS_AND_ATTRIBUTES(0) };
    let h = unsafe { CreateFileW(PCWSTR(w.as_ptr()), access, FILE_SHARE_READ, None, disposition, flags, None) }.map_err(|e| {
        let code = (e.code().0 & 0xffff) as u32;
        match code {
            2 | 3 => ("not_found", format!("{} doesn't exist", p.display())),
            5 => ("denied", format!("access to {} is denied", p.display())),
            _ => ("internal", format!("{}: {e}", p.display())),
        }
    })?;
    let created = disposition == OPEN_ALWAYS && unsafe { GetLastError() } != ERROR_ALREADY_EXISTS;
    let h = unsafe { OwnedHandle::from_raw_handle(h.0 as _) };
    let raw = HANDLE(std::os::windows::io::AsRawHandle::as_raw_handle(&h) as _);
    let mut info = BY_HANDLE_FILE_INFORMATION::default();
    unsafe { GetFileInformationByHandle(raw, &mut info) }.map_err(|e| ("internal", e.to_string()))?;
    let mut buf = [0u16; 1024];
    let n = unsafe { GetFinalPathNameByHandleW(raw, &mut buf, FILE_NAME_NORMALIZED) } as usize;
    let fin = wstr(&buf[..n.min(buf.len())]);
    let fin = fin.strip_prefix("\\\\?\\").unwrap_or(&fin).to_lowercase();
    let rl = lower(root);
    let bad = if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
        Some("is a link")
    } else if !dir && info.nNumberOfLinks > 1 {
        Some("has more than one name (hard link)")
    } else if fin != rl && !fin.starts_with(&(rl + "\\")) {
        Some("resolves outside the agent's folder")
    } else {
        None
    };
    if let Some(why) = bad {
        if created {
            let d = FILE_DISPOSITION_INFO { DeleteFile: true };
            unsafe {
                let _ = SetFileInformationByHandle(raw, FileDispositionInfo, &d as *const _ as *const _, std::mem::size_of_val(&d) as u32);
            }
        }
        return Err(("denied", format!("{} {why}", p.display())));
    }
    Ok((h, info, created))
}

fn filetime_ms(ft: FILETIME) -> u64 {
    let t = ((ft.dwHighDateTime as u64) << 32) | ft.dwLowDateTime as u64;
    (t / 10_000).saturating_sub(11_644_473_600_000)
}

pub fn list(p: &Value) -> CallResult {
    let path = resolve(p["path"].as_str().unwrap_or(""))?;
    open_checked(&path, FILE_LIST_DIRECTORY.0, OPEN_EXISTING, true)?;
    let pat = wide(&format!("{}\\*", path.display()));
    let mut entries = Vec::new();
    let mut bytes = 0usize;
    let mut truncated = false;
    unsafe {
        let mut d = WIN32_FIND_DATAW::default();
        let h = FindFirstFileExW(PCWSTR(pat.as_ptr()), FindExInfoBasic, &mut d as *mut _ as *mut _, FindExSearchNameMatch, None, FIND_FIRST_EX_LARGE_FETCH)
            .map_err(|e| ("not_found", format!("{}: {e}", path.display())))?;
        loop {
            let name = wstr(&d.cFileName);
            if name != "." && name != ".." {
                if entries.len() >= 2000 || bytes > 56 * 1024 {
                    truncated = true;
                    break;
                }
                let e = json!({
                    "name": name,
                    "dir": d.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY.0 != 0,
                    "size": ((d.nFileSizeHigh as u64) << 32) | d.nFileSizeLow as u64,
                    "mtime": filetime_ms(d.ftLastWriteTime),
                    "link": d.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0,
                    "hidden": d.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN.0 != 0,
                });
                bytes += e.to_string().len() + 1;
                entries.push(e);
            }
            if FindNextFileW(h, &mut d).is_err() {
                break;
            }
        }
        let _ = FindClose(h);
    }
    // the folder may have been swapped for a link while listing by name: check again (security review L3)
    open_checked(&path, FILE_LIST_DIRECTORY.0, OPEN_EXISTING, true)?;
    Ok((json!({"path": path.to_string_lossy(), "entries": entries, "truncated": truncated}), None))
}

/// files.read {path, offset?, length?}: the bytes from `offset` (at most `length` and 16 MiB) as the blob, with the
/// whole file's size, so the host can copy big files (Outbox deliveries up to 2 GB) in pieces.
pub fn read(p: &Value) -> CallResult {
    use std::io::{Seek, SeekFrom};
    let path = resolve(p["path"].as_str().unwrap_or(""))?;
    let (h, info, _) = open_checked(&path, FILE_GENERIC_READ.0, OPEN_EXISTING, false)?;
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY.0 != 0 {
        return Err(("bad_request", "that's a folder: use files.list".into()));
    }
    let size = ((info.nFileSizeHigh as u64) << 32) | info.nFileSizeLow as u64;
    let ranged = !p["offset"].is_null() || !p["length"].is_null();
    let offset = p["offset"].as_u64().unwrap_or(0);
    if offset > size {
        return Err(("bad_request", format!("offset {offset} is past the end ({size} bytes)")));
    }
    let want = if ranged { p["length"].as_u64().unwrap_or(MAX_FILE).min(MAX_FILE).min(size - offset) } else { size };
    if !ranged && size > MAX_FILE {
        return Err(("too_large", format!("the file has {size} bytes: read it in pieces with offset/length (up to 16 MiB each)")));
    }
    let mut f = std::fs::File::from(h);
    f.seek(SeekFrom::Start(offset)).map_err(|e| ("internal", e.to_string()))?;
    let mut buf = Vec::with_capacity(want as usize);
    Read::by_ref(&mut f).take(want).read_to_end(&mut buf).map_err(|e| ("internal", e.to_string()))?;
    let mut r = json!({"path": path.to_string_lossy(), "size": size, "offset": offset, "length": buf.len()});
    if !ranged {
        r["sha256"] = json!(hex(&sha256(&buf)));
    }
    Ok((r, Some(buf)))
}

pub fn write(p: &Value, blob: Option<Vec<u8>>) -> CallResult {
    let data = blob.ok_or(("bad_request", "files.write needs the content as a blob".to_string()))?;
    let path = resolve(p["path"].as_str().unwrap_or(""))?;
    if path == *root()? {
        return Err(("bad_request", "that's the profile folder itself".into()));
    }
    if p["mkdirs"] == true {
        if let Some(parent) = path.parent() {
            // one level at a time, each checked (not a link, still inside) before the next is made (review L3)
            let root = root()?;
            let rel = parent.strip_prefix(root).map_err(|_| ("denied", "outside the agent's folder".to_string()))?;
            let mut cur = root.clone();
            for c in rel.components() {
                cur.push(c);
                if !cur.exists() {
                    std::fs::create_dir(&cur).map_err(|e| ("internal", format!("{}: {e}", cur.display())))?;
                }
                open_checked(&resolve(&cur.to_string_lossy())?, FILE_LIST_DIRECTORY.0, OPEN_EXISTING, true)?;
            }
        }
    }
    let (h, info, _) = open_checked(&path, (FILE_GENERIC_WRITE | FILE_GENERIC_READ).0 | DELETE.0, OPEN_ALWAYS, false)?;
    if info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY.0 != 0 {
        return Err(("bad_request", "that's a folder".into()));
    }
    let mut f = std::fs::File::from(h);
    f.set_len(0).and_then(|_| f.write_all(&data)).and_then(|_| f.flush()).map_err(|e| ("internal", e.to_string()))?;
    Ok((json!({"path": path.to_string_lossy(), "size": data.len(), "sha256": hex(&sha256(&data))}), None))
}
