//! exec.run: runs a program as the signed-in `agent` user (the helper's own medium token, never elevated), without a
//! shell, with stdin, a timeout and 1 MiB caps on stdout and stderr. The program leaves the helper's job (so the
//! service's lifetime doesn't bound it) and goes into its own job: on timeout the whole tree is ended; when it exits
//! normally, what it started (e.g. `cmd /c start app`) keeps running.
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

/// Console output is UTF-8 or the OEM code page; decode whichever it is.
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

/// Reads what is available without blocking; keeps at most CAP bytes, counts the rest.
fn drain(h: HANDLE, out: &mut Vec<u8>, dropped: &mut usize) -> bool {
    let mut buf = [0u8; 65536];
    loop {
        let mut avail = 0u32;
        if unsafe { PeekNamedPipe(h, None, 0, None, Some(&mut avail), None) }.is_err() {
            return false; // closed
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

pub fn exec_run(p: &Value) -> CallResult {
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
        let mut si = STARTUPINFOW { cb: std::mem::size_of::<STARTUPINFOW>() as u32, ..Default::default() };
        si.dwFlags = STARTF_USESTDHANDLES;
        si.hStdInput = in_r.0;
        si.hStdOutput = out_w.0;
        si.hStdError = err_w.0;
        let mut cmd = wide(&line);
        let cwd_w = wide(&cwd.to_string_lossy());
        CreateProcessW(
            PCWSTR::null(),
            Some(PWSTR(cmd.as_mut_ptr())),
            None,
            None,
            true,
            CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB | CREATE_UNICODE_ENVIRONMENT,
            None,
            PCWSTR(cwd_w.as_ptr()),
            &si,
            &mut pi,
        )
        .map_err(|e| {
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
    // stdin from its own thread (a child that doesn't read must not block us)
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
    let deadline = Duration::from_millis(timeout);
    loop {
        drain(out_r.0, &mut out, &mut dout);
        drain(err_r.0, &mut err, &mut derr);
        if unsafe { WaitForSingleObject(proc_.0, 5) } == WAIT_OBJECT_0 {
            break;
        }
        if t0.elapsed() >= deadline {
            timed_out = true;
            unsafe {
                let _ = TerminateJobObject(job.0, 1);
                WaitForSingleObject(proc_.0, 2000);
            }
            break;
        }
    }
    // what is still in the pipes (children that inherited them may keep them open: give them 100 ms)
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
    let _ = writer.join();
    let stdout = decode(&out);
    let stderr = decode(&err);
    let truncated = dout > 0 || derr > 0;
    let mut r = json!({
        "exitCode": if timed_out { Value::Null } else { json!(code as i32) },
        "timedOut": timed_out, "truncated": truncated, "ms": t0.elapsed().as_millis() as u64,
    });
    if stdout.len() + stderr.len() <= INLINE {
        r["stdout"] = json!(stdout);
        r["stderr"] = json!(stderr);
        Ok((r, None))
    } else {
        // too big for a JSON frame: both go in the blob, stdout then stderr, UTF-8
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
