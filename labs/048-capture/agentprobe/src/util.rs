use std::io::Write;
use std::time::{SystemTime, UNIX_EPOCH};

pub fn arg(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1).cloned())
}

pub fn arg_or(args: &[String], name: &str, def: &str) -> String {
    arg(args, name).unwrap_or_else(|| def.to_string())
}

pub fn has(args: &[String], name: &str) -> bool {
    args.iter().any(|a| a == name)
}

pub fn parse_wh(s: &str) -> (u32, u32) {
    let mut it = s.split('x');
    (it.next().unwrap().parse().unwrap(), it.next().unwrap().parse().unwrap())
}

pub fn now_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()
}

pub fn wstr(w: &[u16]) -> String {
    let n = w.iter().position(|&c| c == 0).unwrap_or(w.len());
    String::from_utf16_lossy(&w[..n])
}

pub fn jstr(s: &str) -> String {
    let mut o = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

static LOG: std::sync::Mutex<Option<std::fs::File>> = std::sync::Mutex::new(None);

pub fn set_log(path: &str) {
    *LOG.lock().unwrap() = Some(std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap());
}

/// One JSON line to stdout and to the --log file if any.
pub fn emit(line: &str) {
    println!("{line}");
    let _ = std::io::stdout().flush();
    if let Some(f) = LOG.lock().unwrap().as_mut() {
        let _ = writeln!(f, "{line}");
        let _ = f.flush();
    }
}

pub fn pct(v: &[f64], p: f64) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if s.is_empty() {
        return f64::NAN;
    }
    s[((p / 100.0) * (s.len() - 1) as f64).round() as usize]
}
