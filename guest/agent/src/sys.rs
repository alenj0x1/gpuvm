//! Machine-level methods the host's GpuVM service uses to look after a machine without PowerShell Direct, KVP or
//! the Hyper-V heartbeat (machines run by HCS have none of them). They run in the agent service itself, as SYSTEM.
//! Only the authenticated host connection reaches them, and the host only lets its own administrative side call them.

use std::io::Read;
use std::net::Ipv4Addr;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

pub const METHODS: &[&str] = &["sys.info", "sys.exec", "sys.read", "sys.write", "sys.power"];
const MAX_FILE: usize = 16 << 20;
const OUTPUT_CAP: usize = 1 << 20;

pub type Reply = Result<(Value, Option<Vec<u8>>), (String, String)>;

fn bad(msg: impl Into<String>) -> (String, String) {
    ("bad_request".into(), msg.into())
}

fn failed(msg: impl Into<String>) -> (String, String) {
    ("failed".into(), msg.into())
}

pub fn deadline(method: &str, params: &Value) -> Duration {
    match method {
        "sys.exec" => Duration::from_millis(params["timeoutMs"].as_u64().unwrap_or(60_000).clamp(100, 600_000) + 10_000),
        _ => Duration::from_secs(60),
    }
}

/// A path the host names must be absolute and plain (no `..`, no device or stream names).
pub fn checked_path(p: &str) -> Result<PathBuf, (String, String)> {
    let path = PathBuf::from(p);
    let mut comps = path.components();
    let prefix_ok = matches!(comps.next(), Some(Component::Prefix(pre)) if matches!(pre.kind(), std::path::Prefix::Disk(_)));
    if !prefix_ok || !matches!(comps.next(), Some(Component::RootDir)) {
        return Err(bad(format!("not an absolute local path: {p}")));
    }
    if comps.clone().any(|c| !matches!(c, Component::Normal(_))) || comps.any(|c| c.as_os_str().to_string_lossy().contains(':')) {
        return Err(bad(format!("not a plain path: {p}")));
    }
    Ok(path)
}

pub fn handle(method: &str, params: &Value, blob: Option<Vec<u8>>) -> Reply {
    match method {
        "sys.info" => Ok((info(), None)),
        "sys.exec" => exec(params),
        "sys.read" => {
            let path = checked_path(params["path"].as_str().ok_or_else(|| bad("path is required"))?)?;
            let len = std::fs::metadata(&path).map_err(|e| failed(format!("{}: {e}", path.display())))?.len();
            if len as usize > MAX_FILE {
                return Err(bad(format!("{} is over 16 MiB", path.display())));
            }
            let bytes = std::fs::read(&path).map_err(|e| failed(format!("{}: {e}", path.display())))?;
            Ok((json!({ "bytes": bytes.len() }), Some(bytes)))
        }
        "sys.write" => {
            let path = checked_path(params["path"].as_str().ok_or_else(|| bad("path is required"))?)?;
            let bytes = blob.ok_or_else(|| bad("the file comes as the request's blob"))?;
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| failed(format!("{}: {e}", dir.display())))?;
            }
            std::fs::write(&path, &bytes).map_err(|e| failed(format!("{}: {e}", path.display())))?;
            Ok((json!({ "bytes": bytes.len() }), None))
        }
        "sys.power" => {
            let flag = match params["action"].as_str() {
                Some("shutdown") => "/s",
                Some("restart") => "/r",
                _ => return Err(bad("action is shutdown or restart")),
            };
            // A couple of seconds so the reply reaches the host before the connection goes down.
            Command::new(system32("shutdown.exe")).args([flag, "/t", "2", "/f"]).stdout(Stdio::null()).stderr(Stdio::null()).spawn()
                .map_err(|e| failed(format!("shutdown: {e}")))?;
            Ok((json!({ "action": params["action"] }), None))
        }
        _ => Err(bad("unknown method")),
    }
}

fn system32(exe: &str) -> PathBuf {
    let root = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\Windows"));
    root.join("System32").join(exe)
}

fn exec(params: &Value) -> Reply {
    let file = params["file"].as_str().ok_or_else(|| bad("file is required"))?;
    let file = if Path::new(file).is_absolute() { checked_path(file)? } else { system32(file) };
    let args: Vec<String> = match &params["args"] {
        Value::Null => Vec::new(),
        Value::Array(a) => a.iter().map(|x| x.as_str().map(String::from).ok_or_else(|| bad("args must be strings"))).collect::<Result<_, _>>()?,
        _ => return Err(bad("args must be a list")),
    };
    let timeout = Duration::from_millis(params["timeoutMs"].as_u64().unwrap_or(60_000).clamp(100, 600_000));
    let mut cmd = Command::new(&file);
    cmd.args(&args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    if let Some(cwd) = params["cwd"].as_str() {
        cmd.current_dir(checked_path(cwd)?);
    }
    let start = Instant::now();
    let mut child = cmd.spawn().map_err(|e| failed(format!("{}: {e}", file.display())))?;
    let read = |r: Option<Box<dyn Read + Send>>| std::thread::spawn(move || {
        let mut out = Vec::new();
        if let Some(r) = r {
            let _ = r.take(OUTPUT_CAP as u64).read_to_end(&mut out);
        }
        out
    });
    let out = read(child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let err = read(child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let status = loop {
        if let Some(s) = child.try_wait().map_err(|e| failed(e.to_string()))? {
            break Some(s);
        }
        if start.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let text = |b: Vec<u8>| String::from_utf8_lossy(&b).into_owned();
    Ok((json!({
        "exitCode": status.and_then(|s| s.code()),
        "timedOut": status.is_none(),
        "ms": start.elapsed().as_millis() as u64,
        "stdout": text(out.join().unwrap_or_default()),
        "stderr": text(err.join().unwrap_or_default()),
    }), None))
}

fn ipv4() -> Vec<String> {
    use windows::Win32::NetworkManagement::IpHelper::*;
    use windows::Win32::Networking::WinSock::{AF_INET, SOCKADDR_IN};
    let mut out = Vec::new();
    let mut size = 16 * 1024u32;
    for _ in 0..3 {
        let mut buf = vec![0u64; (size as usize).div_ceil(8)];
        let first = buf.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        let code = unsafe { GetAdaptersAddresses(AF_INET.0 as u32, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER, None, Some(first), &mut size) };
        if code == 111 {
            continue;
        }
        if code != 0 {
            return out;
        }
        unsafe {
            let mut a = first;
            while !a.is_null() {
                let mut u = (*a).FirstUnicastAddress;
                while !u.is_null() {
                    let sa = (*u).Address.lpSockaddr as *const SOCKADDR_IN;
                    if !sa.is_null() && (*sa).sin_family == AF_INET {
                        let ip = Ipv4Addr::from(u32::from_be((*sa).sin_addr.S_un.S_addr));
                        if !ip.is_loopback() && !ip.is_link_local() {
                            out.push(ip.to_string());
                        }
                    }
                    u = (*u).Next;
                }
                a = (*a).Next;
            }
        }
        return out;
    }
    out
}

/// The user signed in on a session (None when nobody is).
fn session_user(session: u32) -> Option<String> {
    use windows::Win32::System::RemoteDesktop::*;
    let mut buf = windows::core::PWSTR::null();
    let mut bytes = 0u32;
    unsafe {
        WTSQuerySessionInformationW(Some(WTS_CURRENT_SERVER_HANDLE), session, WTSUserName, &mut buf, &mut bytes).ok()?;
        let name = buf.to_string().ok();
        WTSFreeMemory(buf.0 as *mut _);
        name.filter(|n| !n.is_empty())
    }
}

fn info() -> Value {
    let uptime_ms = unsafe { windows::Win32::System::SystemInformation::GetTickCount64() };
    json!({
        "version": crate::util::VERSION,
        "uptimeSec": uptime_ms / 1000,
        "session": crate::session::active_session(),
        "user": crate::session::active_session().and_then(session_user),
        "ipv4": ipv4(),
        "setupDone": Path::new(r"C:\GpuVM\setup.done.json").is_file(),
        "setupDoneJson": std::fs::read_to_string(r"C:\GpuVM\setup.done.json").ok().and_then(|t| serde_json::from_str::<Value>(t.trim_start_matches('\u{feff}')).ok()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_must_be_absolute_and_plain() {
        assert!(checked_path(r"C:\GpuVM\setup.ps1").is_ok());
        for bad in [r"setup.ps1", r"\GpuVM\x", r"C:GpuVM\x", r"C:\GpuVM\..\Windows\x", r"\\server\share\x", r"\\?\C:\x", r"C:\x.txt:ads", r"\\.\pipe\x"] {
            assert!(checked_path(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn exec_runs_and_captures_output() {
        let (r, _) = handle("sys.exec", &json!({ "file": "cmd.exe", "args": ["/c", "echo", "hello"] }), None).unwrap();
        assert_eq!(r["exitCode"], json!(0));
        assert!(r["stdout"].as_str().unwrap().contains("hello"));
        let (r, _) = handle("sys.exec", &json!({ "file": "cmd.exe", "args": ["/c", "ping", "-n", "5", "127.0.0.1"], "timeoutMs": 300 }), None).unwrap();
        assert_eq!(r["timedOut"], json!(true));
        assert!(handle("sys.exec", &json!({ "file": "cmd.exe", "args": [1] }), None).is_err());
    }

    #[test]
    fn write_then_read_round_trips() {
        let dir = std::env::temp_dir().join(format!("gpuvm-sys-{}", std::process::id()));
        let p = dir.join(r"a\b.bin");
        let p = p.to_string_lossy().into_owned();
        handle("sys.write", &json!({ "path": p }), Some(b"abc".to_vec())).unwrap();
        let (_, blob) = handle("sys.read", &json!({ "path": p }), None).unwrap();
        assert_eq!(blob.unwrap(), b"abc");
        assert!(handle("sys.write", &json!({ "path": p }), None).is_err(), "no blob");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn info_reports_the_basics() {
        let r = info();
        assert!(r["uptimeSec"].as_u64().is_some());
        assert!(r["ipv4"].is_array());
    }
}
