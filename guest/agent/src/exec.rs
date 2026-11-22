use crate::capture::CallResult;
use crate::token::Owned;
use crate::util::wide;
use serde_json::{json, Value};
use std::time::{Duration, Instant};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::*;
use windows::Win32::Globalization::*;
use windows::Win32::Security::SECURITY_ATTRIBUTES;
use windows::Win32::Storage::FileSystem::{ReadFile, WriteFile};
use windows::Win32::System::JobObjects::*;
use windows::Win32::System::Pipes::{CreatePipe, PeekNamedPipe};
use windows::Win32::System::Threading::*;

const CAP: usize = 1 << 20;
const INLINE: usize = 48 * 1024;

/// MSVC command-line quoting (what CommandLineToArgvW and the C runtime parse back).
fn quote(a: &str) -> String {
    if !a.is_empty() && !a.contains(|c: char| c == ' ' || c == '\t' || c == '"' || c == '\n') {
        return a.to_string();
    }
    let mut o = String::from("\"");
    let mut bs = 0;
    for c in a.chars() {
        match c {
            '\\' => bs += 1,
            '"' => {
                o.push_str(&"\\".repeat(bs * 2 + 1));
                o.push('"');
                bs = 0;
            }
            c => {
                o.push_str(&"\\".repeat(bs));
                o.push(c);
                bs = 0;
            }
        }
    }
    o.push_str(&"\\".repeat(bs * 2));
    o.push('"');
    o
}

fn decode(b: &[u8]) -> String {
    if let Ok(s) = std::str::from_utf8(b) {
        return s.to_string();
    }
    unsafe {
        let n = MultiByteToWideChar(CP_OEMCP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS(0), b, None);
        let mut w = vec![0u16; n.max(0) as usize];
        MultiByteToWideChar(CP_OEMCP, MULTI_BYTE_TO_WIDE_CHAR_FLAGS(0), b, Some(&mut w));
        String::from_utf16_lossy(&w)
    }
}

fn pipe() -> Result<(Owned, Owned), (&'static str, String)> {
    let sa = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: std::ptr::null_mut(), bInheritHandle: TRUE };
    let (mut r, mut w) = (HANDLE::default(), HANDLE::default());
    unsafe { CreatePipe(&mut r, &mut w, Some(&sa), 1 << 16) }.map_err(|e| ("internal", format!("pipe: {e}")))?;
    Ok((Owned(r), Owned(w)))
}

fn drain(h: HANDLE, out: &mut Vec<u8>, dropped: &mut usize) -> bool {
    let mut buf = [0u8; 65536];
    loop {
        let mut avail = 0u32;
        if unsafe { PeekNamedPipe(h, None, 0, None, Some(&mut avail), None) }.is_err() {
            return false;
        }
        if avail == 0 {
            return true;
        }
        let mut n = 0u32;
        let want = (avail as usize).min(buf.len());
        if unsafe { ReadFile(h, Some(&mut buf[..want]), Some(&mut n), None) }.is_err() || n == 0 {
            return false;
        }
        let keep = (CAP - out.len().min(CAP)).min(n as usize);
        out.extend_from_slice(&buf[..keep]);
        *dropped += n as usize - keep;
    }
}

pub fn exec_run(p: &Value, id: u64) -> CallResult {
    let root = crate::files::root()?;
    let file = p["file"].as_str().filter(|f| !f.is_empty()).ok_or(("bad_request", "file is required".to_string()))?;
    let args: Vec<String> = match &p["args"] {
        Value::Null => vec![],
        Value::Array(a) => a.iter().map(|x| x.as_str().map(str::to_string).ok_or(("bad_request", "args are strings".to_string()))).collect::<Result<_, _>>()?,
        _ => return Err(("bad_request", "args is a list of strings".into())),
    };
    let timeout = p["timeoutMs"].as_u64().unwrap_or(60_000).clamp(100, 600_000);
    let stdin = p["stdin"].as_str().unwrap_or("");
    if stdin.len() > CAP {
        return Err(("too_large", "stdin takes up to 1 MiB".into()));
    }
    let cwd = match p["cwd"].as_str() {
        Some(c) => {
            let path = std::path::PathBuf::from(c);
            if !path.is_absolute() || !path.is_dir() {
                return Err(("bad_request", format!("cwd '{c}' isn't an existing folder")));
            }
            path
        }
        None => root.clone(),
    };
    let mut line = quote(file);
    for a in &args {
        line.push(' ');
        line.push_str(&quote(a));
    }
    if line.len() > 32000 {
        return Err(("too_large", "the command line is over 32000 characters".into()));
    }

    let (in_r, in_w) = pipe()?;
    let (out_r, out_w) = pipe()?;
    let (err_r, err_w) = pipe()?;
    unsafe {
        for h in [&in_w, &out_r, &err_r] {
            let _ = SetHandleInformation(h.0, HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0));
        }
    }
    let job = Owned(unsafe { CreateJobObjectW(None, PCWSTR::null()) }.map_err(|e| ("internal", format!("job: {e}")))?);
    let t0 = Instant::now();
    let mut pi = PROCESS_INFORMATION::default();
    unsafe {
        // exactly these three handles are inherited, never the helper's pipes to the service or another exec.run's
        let handles = [in_r.0, out_w.0, err_w.0];
        let mut size = 0usize;
        let _ = InitializeProcThreadAttributeList(None, 1, None, &mut size);
        let mut attr_buf = vec![0u8; size];
        let attrs = LPPROC_THREAD_ATTRIBUTE_LIST(attr_buf.as_mut_ptr() as _);
        InitializeProcThreadAttributeList(Some(attrs), 1, None, &mut size).map_err(|e| ("internal", format!("attr list {e}")))?;
        UpdateProcThreadAttribute(attrs, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize, Some(handles.as_ptr() as *const _), std::mem::size_of_val(&handles), None, None)
            .map_err(|e| ("internal", format!("handle list {e}")))?;
        let mut si = STARTUPINFOEXW::default();
        si.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        si.StartupInfo.hStdInput = in_r.0;
        si.StartupInfo.hStdOutput = out_w.0;
        si.StartupInfo.hStdError = err_w.0;
        si.lpAttributeList = attrs;
        let mut cmd = wide(&line);
        let cwd_w = wide(&cwd.to_string_lossy());
        let r = CreateProcessW(
            PCWSTR::null(),
            Some(PWSTR(cmd.as_mut_ptr())),
            None,
            None,
            true,
            EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB,
            None,
            PCWSTR(cwd_w.as_ptr()),
            &si.StartupInfo,
            &mut pi,
        );
        DeleteProcThreadAttributeList(attrs);
        r.map_err(|e| {
            let code = (e.code().0 & 0xffff) as u32;
            if code == 2 || code == 3 {
                ("not_found", format!("'{file}' wasn't found"))
            } else {
                ("internal", format!("can't start '{file}': {e}"))
            }
        })?;
    }
    let proc_ = Owned(pi.hProcess);
    let thread = Owned(pi.hThread);
    unsafe {
        let _ = AssignProcessToJobObject(job.0, proc_.0);
        ResumeThread(thread.0);
    }
    drop((in_r, out_w, err_w));
    // stdin from its own thread: a child that doesn't read must not block us
    let in_w_raw = in_w.0 .0 as isize;
    let data = stdin.as_bytes().to_vec();
    let writer = std::thread::spawn(move || {
        let h = Owned(HANDLE(in_w_raw as _));
        let mut off = 0;
        while off < data.len() {
            let mut n = 0u32;
            if unsafe { WriteFile(h.0, Some(&data[off..]), Some(&mut n), None) }.is_err() || n == 0 {
                break;
            }
            off += n as usize;
        }
    });
    std::mem::forget(in_w); // owned by the writer thread now

    let (mut out, mut err) = (Vec::new(), Vec::new());
    let (mut dout, mut derr) = (0usize, 0usize);
    let mut timed_out = false;
    let mut cancelled = false;
    let deadline = Duration::from_millis(timeout);
    loop {
        drain(out_r.0, &mut out, &mut dout);
        drain(err_r.0, &mut err, &mut derr);
        if unsafe { WaitForSingleObject(proc_.0, 5) } == WAIT_OBJECT_0 {
            break;
        }
        cancelled = crate::helper::is_cancelled(id);
        if t0.elapsed() >= deadline || cancelled {
            timed_out = !cancelled;
            unsafe {
                let _ = TerminateJobObject(job.0, 1);
                WaitForSingleObject(proc_.0, 2000);
            }
            break;
        }
    }
    // children that inherited the pipes may keep them open: give them 100 ms
    let grace = Instant::now();
    while grace.elapsed() < Duration::from_millis(100) {
        let a = drain(out_r.0, &mut out, &mut dout);
        let b = drain(err_r.0, &mut err, &mut derr);
        if !a && !b {
            break;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut code = 0u32;
    unsafe {
        let _ = GetExitCodeProcess(proc_.0, &mut code);
    }
    drop(job); // no kill-on-close: what the program started on its own keeps running
    // a stdin write can block forever when a grandchild holds stdin and nobody reads: cancel it
    if !writer.is_finished() {
        let th = HANDLE(std::os::windows::io::AsRawHandle::as_raw_handle(&writer) as _);
        let t = Instant::now();
        while !writer.is_finished() && t.elapsed() < Duration::from_millis(500) {
            unsafe {
                let _ = windows::Win32::System::IO::CancelSynchronousIo(th);
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    if writer.is_finished() {
        let _ = writer.join();
    }
    if cancelled {
        return Err(("cancelled", "cancelled by the host: the program and what it started were ended".into()));
    }
    let stdout = decode(&out);
    let stderr = decode(&err);
    let truncated = dout > 0 || derr > 0;
    let mut r = json!({
        "exitCode": if timed_out { Value::Null } else { json!(code as i32) },
        "timedOut": timed_out, "truncated": truncated, "ms": t0.elapsed().as_millis() as u64,
    });
    // measured as JSON: escaping can make control characters 6x bigger
    let json_len = serde_json::to_string(&stdout).map(|s| s.len()).unwrap_or(usize::MAX) + serde_json::to_string(&stderr).map(|s| s.len()).unwrap_or(usize::MAX);
    if json_len <= INLINE {
        r["stdout"] = json!(stdout);
        r["stderr"] = json!(stderr);
        Ok((r, None))
    } else {
        r["outputInBlob"] = json!(true);
        r["stdoutBytes"] = json!(stdout.len());
        r["stderrBytes"] = json!(stderr.len());
        let mut blob = stdout.into_bytes();
        blob.extend_from_slice(stderr.as_bytes());
        Ok((r, Some(blob)))
    }
}

#[cfg(test)]
mod tests {
    use super::quote;
    #[test]
    fn quoting() {
        assert_eq!(quote("a"), "a");
        assert_eq!(quote("a b"), "\"a b\"");
        assert_eq!(quote(""), "\"\"");
        assert_eq!(quote(r#"say "hi""#), r#""say \"hi\"""#);
        assert_eq!(quote(r"C:\dir with space\"), r#""C:\dir with space\\""#);
    }
}
