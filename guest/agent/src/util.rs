//! Small shared helpers: wide strings, a size-capped log file, time.
use std::io::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain([0]).collect()
}

pub fn wstr(w: &[u16]) -> String {
    let n = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..n])
}

pub fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

pub fn iso_now() -> String {
    // UTC, second resolution, without pulling a date crate: days -> civil date (Howard Hinnant's algorithm).
    let s = (now_ms() / 1000) as i64;
    let (days, rem) = (s.div_euclid(86400), s.rem_euclid(86400));
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem / 60 % 60, rem % 60)
}

/// Log file capped at `MAX` bytes: when full it is renamed to `.old` (one generation kept).
pub struct Log {
    path: Option<std::path::PathBuf>,
    file: Option<std::fs::File>,
    size: u64,
}

const MAX: u64 = 1 << 20;

pub static LOG: Mutex<Log> = Mutex::new(Log { path: None, file: None, size: 0 });

pub fn log_to(path: &std::path::Path) {
    let mut l = LOG.lock().unwrap();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    l.size = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    l.file = std::fs::OpenOptions::new().create(true).append(true).open(path).ok();
    l.path = Some(path.to_path_buf());
}

pub fn log(msg: &str) {
    let line = format!("{} {}\n", iso_now(), msg.chars().take(2000).collect::<String>());
    let mut l = match LOG.lock() {
        Ok(l) => l,
        Err(p) => p.into_inner(),
    };
    if l.path.is_none() {
        eprint!("{line}");
        return;
    }
    if l.size + line.len() as u64 > MAX {
        let p = l.path.clone().unwrap();
        l.file = None;
        let _ = std::fs::rename(&p, p.with_extension("old"));
        l.file = std::fs::OpenOptions::new().create(true).append(true).open(&p).ok();
        l.size = 0;
    }
    if let Some(f) = l.file.as_mut() {
        let _ = f.write_all(line.as_bytes());
        l.size += line.len() as u64;
    }
}

#[macro_export]
macro_rules! logf {
    ($($a:tt)*) => { $crate::util::log(&format!($($a)*)) };
}

/// A REG_SZ / REG_DWORD value under HKLM as text.
pub fn reg_hklm(key: &str, value: &str) -> Option<String> {
    use windows::core::PCWSTR;
    use windows::Win32::System::Registry::*;
    let k = wide(key);
    let v = wide(value);
    let mut buf = vec![0u16; 512];
    let mut len = (buf.len() * 2) as u32;
    let mut ty = REG_VALUE_TYPE::default();
    unsafe {
        RegGetValueW(HKEY_LOCAL_MACHINE, PCWSTR(k.as_ptr()), PCWSTR(v.as_ptr()), RRF_RT_REG_SZ | RRF_RT_REG_DWORD, Some(&mut ty), Some(buf.as_mut_ptr() as *mut _), Some(&mut len))
            .ok()
            .ok()?;
    }
    if ty == REG_DWORD {
        return Some(u32::from_le_bytes([buf[0] as u8, (buf[0] >> 8) as u8, buf[1] as u8, (buf[1] >> 8) as u8]).to_string());
    }
    Some(wstr(&buf))
}

/// "Windows 10 Pro 22H2 (19045.4291)" and the UI language ("es-MX").
pub fn os_info() -> (String, String) {
    const CV: &str = r"SOFTWARE\Microsoft\Windows NT\CurrentVersion";
    let product = reg_hklm(CV, "ProductName").unwrap_or_else(|| "Windows".into());
    let build = reg_hklm(CV, "CurrentBuild").unwrap_or_default();
    // Windows 11 still says "Windows 10" in ProductName; the build number tells.
    let product = if build.parse::<u32>().unwrap_or(0) >= 22000 { product.replace("Windows 10", "Windows 11") } else { product };
    let os = format!(
        "{} {} ({}.{})",
        product,
        reg_hklm(CV, "DisplayVersion").unwrap_or_default(),
        build,
        reg_hklm(CV, "UBR").unwrap_or_default()
    );
    let lang = unsafe {
        use windows::Win32::Globalization::*;
        let lcid = GetUserDefaultUILanguage() as u32;
        let mut b = [0u16; 85];
        let n = LCIDToLocaleName(lcid, Some(&mut b), 0);
        if n > 0 { wstr(&b) } else { String::new() }
    };
    (os, lang)
}

/// Random bytes from the OS (BCryptGenRandom, system-preferred RNG).
pub fn random<const N: usize>() -> [u8; N] {
    use windows::Win32::Security::Cryptography::*;
    let mut b = [0u8; N];
    unsafe {
        BCryptGenRandom(None, &mut b, BCRYPT_USE_SYSTEM_PREFERRED_RNG).ok().expect("BCryptGenRandom");
    }
    b
}
