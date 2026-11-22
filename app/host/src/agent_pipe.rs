// Only SYSTEM and elevated administrators may open it: they can already drive any VM through Hyper-V, so it grants nothing new.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::windows::io::FromRawHandle;
use std::time::Duration;

use serde_json::{json, Value};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Pipes::*;

use crate::agent;
use crate::server::log;
use crate::win::{last_error, wide, Handle};

pub const PIPE: &str = r"\\.\pipe\gpuvm-agent";
const MAX_LINE: u64 = 24 << 20;

fn handle(pipe: HANDLE) {
    let mut pid = 0;
    unsafe { GetNamedPipeClientProcessId(pipe, &mut pid) };
    let file = std::mem::ManuallyDrop::new(unsafe { File::from_raw_handle(pipe) });
    let mut out: &File = &file;
    let mut reader = BufReader::new(&*file);
    let mut ctx = agent::Ctx::new(pipe, pid, true);
    let mut line = String::new();
    loop {
        line.clear();
        if (&mut reader).take(MAX_LINE).read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let request = serde_json::from_str::<Value>(&line).unwrap_or(Value::Null);
        let id = request["id"].clone();
        let reply = match request["cmd"].as_str() {
            Some(cmd) if agent::is_command(cmd) => {
                let _busy = crate::server::Busy::quick();
                agent::result_line(&id, agent::command(cmd, &request["args"], &mut ctx))
            }
            _ => json!({ "id": id, "type": "result", "ok": false, "error": "Invalid request.", "code": "bad_request" }),
        };
        if writeln!(out, "{reply}").and_then(|_| out.flush()).is_err() {
            return;
        }
    }
}

pub fn serve() {
    let sddl = "D:P(A;;GA;;;SY)(A;;GA;;;BA)";
    let mut sd = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(wide(sddl).as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0 {
        log(&last_error("agent pipe SDDL"));
        return;
    }
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: sd, bInheritHandle: 0 };
    let name = wide(PIPE);
    let mut first = true;
    loop {
        let open = PIPE_ACCESS_DUPLEX | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        let pipe = unsafe {
            CreateNamedPipeW(name.as_ptr(), open, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, &sa)
        };
        if pipe == INVALID_HANDLE_VALUE {
            log(&last_error("CreateNamedPipeW gpuvm-agent"));
            std::thread::sleep(Duration::from_secs(if first { 5 } else { 1 }));
            continue;
        }
        first = false;
        let connected = unsafe { ConnectNamedPipe(pipe, std::ptr::null_mut()) } != 0 || unsafe { GetLastError() } == ERROR_PIPE_CONNECTED;
        let pipe = Handle(pipe);
        if !connected {
            continue;
        }
        std::thread::spawn(move || {
            let pipe = pipe;
            handle(pipe.0);
            unsafe {
                FlushFileBuffers(pipe.0);
                DisconnectNamedPipe(pipe.0);
            }
        });
    }
}
