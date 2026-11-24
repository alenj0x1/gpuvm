//! Machine-level methods the host's GpuVM service uses to look after a machine without PowerShell Direct, KVP or
//! the Hyper-V heartbeat (machines run by HCS have none of them). They run in the agent service itself, as SYSTEM.
//! Only the authenticated host connection reaches them, and the host only lets its own administrative side call them.

use std::io::Read;
use std::net::Ipv4Addr;
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

pub const METHODS: &[&str] = &["sys.info", "sys.exec", "sys.read", "sys.write", "sys.power", "sys.net", "sys.kvp"];
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
            // Whole files up to 16 MiB, or a piece of a bigger one with "offset" (and "length", at most 16 MiB).
            use std::io::{Seek, SeekFrom};
            let path = checked_path(params["path"].as_str().ok_or_else(|| bad("path is required"))?)?;
            let size = std::fs::metadata(&path).map_err(|e| failed(format!("{}: {e}", path.display())))?.len();
            let offset = params["offset"].as_u64();
            let length = match offset {
                None if size as usize > MAX_FILE => return Err(bad(format!("{} is over 16 MiB; read it in pieces with offset", path.display()))),
                None => size,
                Some(o) => params["length"].as_u64().unwrap_or(MAX_FILE as u64).min(MAX_FILE as u64).min(size.saturating_sub(o)),
            };
            let mut f = std::fs::File::open(&path).map_err(|e| failed(format!("{}: {e}", path.display())))?;
            f.seek(SeekFrom::Start(offset.unwrap_or(0))).map_err(|e| failed(format!("{}: {e}", path.display())))?;
            let mut bytes = Vec::with_capacity(length as usize);
            f.take(length).read_to_end(&mut bytes).map_err(|e| failed(format!("{}: {e}", path.display())))?;
            Ok((json!({ "bytes": bytes.len(), "size": size }), Some(bytes)))
        }
        "sys.write" => {
            // A whole file, or with "offset" a piece of one written in order (offset 0 starts it anew).
            use std::io::{Seek, SeekFrom, Write};
            let path = checked_path(params["path"].as_str().ok_or_else(|| bad("path is required"))?)?;
            let bytes = blob.ok_or_else(|| bad("the file comes as the request's blob"))?;
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| failed(format!("{}: {e}", dir.display())))?;
            }
            match params["offset"].as_u64() {
                None => std::fs::write(&path, &bytes).map_err(|e| failed(format!("{}: {e}", path.display())))?,
                Some(o) => {
                    let mut f = std::fs::OpenOptions::new().write(true).create(true).truncate(o == 0).open(&path)
                        .map_err(|e| failed(format!("{}: {e}", path.display())))?;
                    f.seek(SeekFrom::Start(o)).and_then(|_| f.write_all(&bytes)).map_err(|e| failed(format!("{}: {e}", path.display())))?;
                }
            }
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
        "sys.net" => crate::net::configure(params).map(|v| (v, None)).map_err(failed),
        "sys.kvp" => kvp(params),
        _ => Err(bad("unknown method")),
    }
}

/// Hyper-V's data exchange without Hyper-V: the guest's items (HKLM\...\Virtual Machine\Guest, where guest programs
/// publish) are read, and the host's items (HKLM\...\Virtual Machine\External, writable only by SYSTEM and
/// administrators) are written, as the KVP service does on Hyper-V machines.
const KVP_GUEST: &str = r"SOFTWARE\Microsoft\Virtual Machine\Guest";
const KVP_HOST: &str = r"SOFTWARE\Microsoft\Virtual Machine\External";
const KVP_MAX: usize = 2048;

fn kvp(params: &Value) -> Reply {
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::*;
    let key = params["key"].as_str().filter(|k| !k.is_empty() && k.len() <= 64 && k.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c)))
        .ok_or_else(|| bad("key is 1-64 letters, digits, dot, dash or underscore"))?;
    let name = crate::util::wide(key);
    match params["op"].as_str() {
        Some("get") => {
            let sub = crate::util::wide(KVP_GUEST);
            let mut buf = vec![0u16; KVP_MAX + 1];
            let mut len = (buf.len() * 2) as u32;
            let r = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, PCWSTR(sub.as_ptr()), PCWSTR(name.as_ptr()), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as *mut _), Some(&mut len)) };
            let value = if r.is_ok() { Some(crate::util::wstr(&buf)) } else { None };
            Ok((json!({ "value": value }), None))
        }
        Some("set") => {
            let value = params["value"].as_str().filter(|v| v.len() <= KVP_MAX).ok_or_else(|| bad("value is text of at most 2048 characters"))?;
            let sub = crate::util::wide(KVP_HOST);
            let data = crate::util::wide(value);
            let r = unsafe { RegSetKeyValueW(HKEY_LOCAL_MACHINE, PCWSTR(sub.as_ptr()), PCWSTR(name.as_ptr()), REG_SZ.0, Some(data.as_ptr() as *const _), (data.len() * 2) as u32) };
            r.ok().map_err(|e| failed(format!("set {key}: {e}")))?;
            Ok((json!({ "set": key }), None))
        }
        Some("remove") => {
            let sub = crate::util::wide(KVP_HOST);
            let _ = unsafe { RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, PCWSTR(sub.as_ptr()), PCWSTR(name.as_ptr())) };
            Ok((json!({ "removed": key }), None))
        }
        _ => Err(bad("op is get, set or remove")),
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
                // The relay's adapter (net.rs) only exists inside the guest: the host can't reach its address.
                if (*a).FriendlyName.to_string().is_ok_and(|n| n == crate::net::TUN_NAME) {
                    a = (*a).Next;
                    continue;
                }
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
    fn pieces_write_and_read_back() {
        let p = std::env::temp_dir().join(format!("gpuvm-sys-pieces-{}.bin", std::process::id()));
        let p = p.to_string_lossy().to_string();
        handle("sys.write", &json!({ "path": p, "offset": 0 }), Some(b"abc".to_vec())).unwrap();
        handle("sys.write", &json!({ "path": p, "offset": 3 }), Some(b"def".to_vec())).unwrap();
        let (v, b) = handle("sys.read", &json!({ "path": p, "offset": 2, "length": 3 }), None).unwrap();
        assert_eq!((b.unwrap(), v["size"].as_u64()), (b"cde".to_vec(), Some(6)));
        handle("sys.write", &json!({ "path": p, "offset": 0 }), Some(b"x".to_vec())).unwrap();
        assert_eq!(std::fs::read(&p).unwrap(), b"x".to_vec(), "offset 0 starts the file anew");
        let _ = std::fs::remove_file(&p);
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
