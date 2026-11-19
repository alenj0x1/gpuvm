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

fn copy(job: &OfferJob, ctx: &Ctx) -> Result<String, String> {
    let machine = agent::safe_file_name(&job.machine).unwrap_or_else(|| "machine".into());
    let (path, handle) = {
        let _as = AsClient::new(ctx.pipe)?;
        let downloads = downloads_of_client()?;
        let gpuvm = format!("{}\\GpuVM", downloads.trim_end_matches('\\'));
        make_dir(&gpuvm)?;
        let dir = format!("{gpuvm}\\{machine}");
        make_dir(&dir)?;
        create_new(&dir, &job.file_name)?
    };
    let result = (|| -> Result<u64, String> {
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
        }
    })();
    match result {
        Ok(_) => {
            let _as = AsClient::new(ctx.pipe)?;
            mark_downloaded(&path, &job.machine)?;
            Ok(path)
        }
        Err(e) => {
            delete_on_close(&handle);
            Err(e)
        }
    }
}

pub fn resolve(id: &str, answer: &str, ctx: &Ctx) -> Result<Value, CmdError> {
    let approve = match answer {
        "approve" => true,
        "decline" => false,
        _ => return Err(CmdError { code: "bad_request".into(), message: "Answer is approve or decline.".into() }),
    };
    let Some(job) = agent::take_offer(id, approve)? else {
        return Ok(agent::finish_offer(id, "declined", None, None));
    };
    match copy(&job, ctx) {
        Ok(path) => Ok(agent::finish_offer(id, "approved", Some(path), None)),
        // The offer keeps what happened ("failed", error); the call fails too so the app shows it.
        Err(e) => {
            agent::finish_offer(id, "failed", None, Some(e.clone()));
            Err(CmdError { code: "internal".into(), message: format!("The file couldn't be copied: {e}") })
        }
    }
}
