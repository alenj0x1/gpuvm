//! Files leaving a machine through the agent's Outbox, once the person approved them (Resolve-GpuVMAgentOffer).
//!
//! The copy is made as the person on the other end of the pipe (impersonated): it lands in *their*
//! `Downloads\GpuVM\<machine>`, with their rights, never overwriting anything (`name (2).ext`), marked as downloaded
//! from the internet (Zone.Identifier, ZoneId=3) so Windows treats it like any download. The bytes come from the
//! guest, which is untrusted: every piece is bounded and the total can't pass the size the guest announced or 2 GB.

use std::fs::File;
use std::io::Write;
use std::os::windows::io::FromRawHandle;

use serde_json::Value;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Com::CoTaskMemFree;
use windows_sys::Win32::System::Pipes::ImpersonateNamedPipeClient;
use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};
use windows_sys::Win32::UI::Shell::{FOLDERID_Downloads, SHGetKnownFolderPath};

use crate::agent::{self, CmdError, Ctx, OfferJob};
use crate::server::log;
use crate::win::{check_access, last_error, wide, Handle, PathAccess};

/// Runs as the pipe's client until dropped. If going back fails the service stops rather than keep their identity.
struct AsClient;

impl AsClient {
    fn new(pipe: HANDLE) -> Result<AsClient, String> {
        if unsafe { ImpersonateNamedPipeClient(pipe) } == 0 {
            return Err(last_error("ImpersonateNamedPipeClient"));
        }
        Ok(AsClient)
    }
}

impl Drop for AsClient {
    fn drop(&mut self) {
        if unsafe { RevertToSelf() } == 0 {
            log("RevertToSelf failed; the service stops");
            std::process::exit(1);
        }
    }
}

fn downloads_of_client() -> Result<String, String> {
    let mut token = std::ptr::null_mut();
    if unsafe { OpenThreadToken(GetCurrentThread(), TOKEN_QUERY | TOKEN_IMPERSONATE, 1, &mut token) } == 0 {
        return Err(last_error("OpenThreadToken"));
    }
    let token = Handle(token);
    let mut path: windows_sys::core::PWSTR = std::ptr::null_mut();
    let hr = unsafe { SHGetKnownFolderPath(&FOLDERID_Downloads, 0, token.0, &mut path) };
    if hr < 0 || path.is_null() {
        return Err(format!("Your Downloads folder couldn't be found ({hr:#x})."));
    }
    let len = (0..).take_while(|&i| unsafe { *path.add(i) } != 0).count();
    let text = String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(path, len) });
    unsafe { CoTaskMemFree(path.cast()) };
    Ok(text)
}

fn make_dir(path: &str) -> Result<(), String> {
    if unsafe { CreateDirectoryW(wide(path).as_ptr(), std::ptr::null()) } == 0 && unsafe { GetLastError() } != ERROR_ALREADY_EXISTS {
        return Err(format!("{path} couldn't be created (error {}).", unsafe { GetLastError() }));
    }
    // No links: the folder must be where it says (a junction planted there would send the file elsewhere).
    check_access(path, PathAccess::WriteFolder)
}

/// `name.ext`, then `name (2).ext`, ... : the first name that doesn't exist, created empty and kept open.
fn create_new(dir: &str, file_name: &str) -> Result<(String, Handle), String> {
    let (stem, ext) = match file_name.rfind('.') {
        Some(i) if i > 0 => (&file_name[..i], &file_name[i..]),
        _ => (file_name, ""),
    };
    for n in 1..1000 {
        let name = if n == 1 { file_name.to_string() } else { format!("{stem} ({n}){ext}") };
        let path = format!("{dir}\\{name}");
        let h = unsafe {
            CreateFileW(wide(&path).as_ptr(), GENERIC_WRITE | DELETE, 0, std::ptr::null(), CREATE_NEW,
                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut())
        };
        if h != INVALID_HANDLE_VALUE {
            return Ok((path, Handle(h)));
        }
        match unsafe { GetLastError() } {
            ERROR_FILE_EXISTS | ERROR_ALREADY_EXISTS => continue,
            code => return Err(format!("{path} couldn't be created (error {code}).")),
        }
    }
    Err("Too many files with that name already.".into())
}

fn mark_downloaded(path: &str, machine: &str) -> Result<(), String> {
    let stream = format!("{path}:Zone.Identifier");
    let h = unsafe {
        CreateFileW(wide(&stream).as_ptr(), GENERIC_WRITE, 0, std::ptr::null(), CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        return Err(last_error("CreateFileW Zone.Identifier"));
    }
    let mut f = unsafe { File::from_raw_handle(h) };
    // The machine's name only as text: it isn't a URL anyone can open.
    let host: String = machine.chars().filter(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    f.write_all(format!("[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=gpuvm://{host}/\r\n").as_bytes()).map_err(|e| e.to_string())
}

fn delete_on_close(h: &Handle) {
    let info = FILE_DISPOSITION_INFO { DeleteFile: 1 };
    unsafe { SetFileInformationByHandle(h.0, FileDispositionInfo, &info as *const _ as *const _, std::mem::size_of::<FILE_DISPOSITION_INFO>() as u32) };
}

/// The copy can't take longer than this plus a second per MIN_RATE bytes: a guest that trickles bytes (one per read)
/// can't keep an approved copy open for ever (review 2, #5).
const GRACE_SECS: u64 = 30;
const MIN_RATE: u64 = 1 << 20;
/// And never longer than this, whatever the size.
const MAX_SECS: u64 = 60 * 60;

/// Whether a copy that wrote `offset` bytes in `elapsed` is too slow to go on.
pub(crate) fn too_slow(elapsed: std::time::Duration, offset: u64) -> bool {
    let allowed = (GRACE_SECS + offset / MIN_RATE).min(MAX_SECS);
    elapsed.as_secs() > allowed
}

/// A handle the copy's thread owns.
struct Owned(Handle);
unsafe impl Send for Owned {}

/// As the person: the new file in their Downloads\GpuVM\<machine>, already marked as downloaded from the internet, and
/// opened for writing (the guest's bytes go in afterwards, without the person's identity).
fn prepare(job: &OfferJob, ctx: &Ctx) -> Result<(String, Handle), String> {
    let machine = agent::safe_file_name(&job.machine).unwrap_or_else(|| "machine".into());
    let _as = AsClient::new(ctx.pipe)?;
    let downloads = downloads_of_client()?;
    let gpuvm = format!("{}\\GpuVM", downloads.trim_end_matches('\\'));
    make_dir(&gpuvm)?;
    let dir = format!("{gpuvm}\\{machine}");
    make_dir(&dir)?;
    let (path, created) = create_new(&dir, &job.file_name)?;
    // Opened without sharing: closed first, or the stream can't be opened next to it (error 32).
    drop(created);
    // A file that can't be marked as downloaded doesn't stay: unmarked, Windows would trust it.
    if let Err(e) = mark_downloaded(&path, &job.machine) {
        unsafe { DeleteFileW(wide(&path).as_ptr()) };
        return Err(e);
    }
    let h = unsafe {
        CreateFileW(wide(&path).as_ptr(), GENERIC_WRITE | DELETE, 0, std::ptr::null(), OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, std::ptr::null_mut())
    };
    if h == INVALID_HANDLE_VALUE {
        let e = last_error("CreateFileW");
        unsafe { DeleteFileW(wide(&path).as_ptr()) };
        return Err(e);
    }
    let handle = Handle(h);
    // Still the file just made, not a link put there meanwhile.
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    if unsafe { GetFileInformationByHandle(handle.0, &mut info) } == 0 || info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        delete_on_close(&handle);
        return Err("The new file was replaced while it was being made.".into());
    }
    Ok((path, handle))
}

/// The guest's bytes into the open file: bounded in size and in time.
fn fill(job: &OfferJob, handle: &Handle) -> Result<u64, String> {
    // Writes through the handle opened as the person; the service only moves bytes.
    let dup = unsafe {
        let mut d = std::ptr::null_mut();
        let me = windows_sys::Win32::System::Threading::GetCurrentProcess();
        if DuplicateHandle(me, handle.0, me, &mut d, 0, 0, DUPLICATE_SAME_ACCESS) == 0 {
            return Err(last_error("DuplicateHandle"));
        }
        d
    };
    let mut file = unsafe { File::from_raw_handle(dup) };
    let started = std::time::Instant::now();
    let mut offset = 0u64;
    let mut announced: Option<u64> = None;
    loop {
        let (total, bytes) = job.read(offset, agent::CHUNK)?;
        if bytes.len() as u64 > agent::CHUNK {
            return Err("The guest sent more than asked.".into());
        }
        let total = match (announced, total) {
            (None, Some(t)) => {
                announced = Some(t);
                t
            }
            (Some(a), Some(t)) if a != t => return Err("The file changed while it was copied.".into()),
            (Some(a), _) => a,
            // An agent that doesn't say the size: the file ends with the first short piece.
            (None, None) => u64::MAX,
        };
        if total != u64::MAX && total > agent::MAX_OFFER || offset + bytes.len() as u64 > agent::MAX_OFFER {
            return Err("Files over 2 GB can't leave the machine this way.".into());
        }
        if offset + bytes.len() as u64 > total {
            return Err("The guest sent more than the file's size.".into());
        }
        file.write_all(&bytes).map_err(|e| e.to_string())?;
        offset += bytes.len() as u64;
        if offset == total || (total == u64::MAX && (bytes.len() as u64) < agent::CHUNK) {
            return Ok(offset);
        }
        if bytes.is_empty() {
            return Err("The file ended before its size.".into());
        }
        if too_slow(started.elapsed(), offset) {
            return Err("The machine sent the file too slowly; the copy was stopped.".into());
        }
    }
}

/// The person's answer to an offer. Accepted, the file is created now (as the person) and filled in the background:
/// the answer is the offer "copying"; Get-GpuVMAgentOffer later says "accepted" (with savedTo) or "failed" (with the
/// error, and nothing left in Downloads).
pub fn resolve(id: &str, accept: bool, ctx: &Ctx) -> Result<Value, CmdError> {
    let Some(job) = agent::take_offer(id, accept)? else {
        return Ok(agent::finish_offer(id, "refused", None, None));
    };
    let (path, handle) = match prepare(&job, ctx) {
        Ok(p) => p,
        Err(e) => {
            agent::finish_offer(id, "failed", None, Some(e.clone()));
            return Err(CmdError { code: "internal".into(), message: format!("The file couldn't be copied: {e}") });
        }
    };
    let shown = agent::finish_offer(id, "copying", Some(path.clone()), None);
    let (id, owned) = (id.to_string(), Owned(handle));
    std::thread::spawn(move || {
        let owned = owned;
        match fill(&job, &owned.0) {
            Ok(_) => {
                drop(owned);
                agent::finish_offer(&id, "accepted", Some(path), None);
            }
            Err(e) => {
                // Nothing half-copied stays in Downloads.
                delete_on_close(&owned.0);
                drop(owned);
                log(&format!("agent: offer {id} failed: {e}"));
                agent::finish_offer(&id, "failed", None, Some(e));
            }
        }
    });
    Ok(shown)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn a_trickling_guest_is_stopped() {
        assert!(!too_slow(Duration::from_secs(20), 0));
        assert!(too_slow(Duration::from_secs(31), 10)); // a few bytes in half a minute
        assert!(!too_slow(Duration::from_secs(40), 20 << 20)); // 20 MB in 40 s
        assert!(too_slow(Duration::from_secs(MAX_SECS + 1), u64::MAX)); // never more than an hour
    }
}
