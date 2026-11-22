use std::path::PathBuf;

fn stamp() -> (String, String) {
    use windows_sys::Win32::System::SystemInformation::GetLocalTime;
    // SAFETY: fills a local SYSTEMTIME.
    let t = unsafe {
        let mut t = std::mem::zeroed();
        GetLocalTime(&mut t);
        t
    };
    (
        format!("{:04}-{:02}-{:02} {:02}:{:02}:{:02}", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond),
        format!("{:04}{:02}{:02}-{:02}{:02}{:02}", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond),
    )
}

/// One line in app.log (the app's stderr): what failed and where, for the person's diagnostics report and the e2e suite.
pub(crate) fn log_error(context: &str, message: &str) {
    let message: String = message.chars().take(4000).collect::<String>().replace(['\r', '\n'], " ");
    eprintln!("{} ERROR {context}: {message}", stamp().0);
}

#[tauri::command]
pub fn log_ui_error(webview: tauri::WebviewWindow, message: String) {
    log_error(&format!("ui {}", webview.label()), &message);
}

fn tail(path: &PathBuf, lines: usize) -> String {
    match std::fs::read(path) {
        Ok(bytes) => {
            let text = String::from_utf8_lossy(&bytes);
            let all: Vec<&str> = text.lines().collect();
            all[all.len().saturating_sub(lines)..].join("\n")
        }
        Err(e) => format!("(couldn't read it: {e})"),
    }
}

/// A text file in Downloads with the app's and the service's logs, for the person to look at and attach to a report.
#[tauri::command]
pub async fn save_diagnostics() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(|| {
        use windows_sys::Win32::UI::Shell::FOLDERID_Downloads;
        let dir = crate::capture::known_folder(&FOLDERID_Downloads).ok_or("Couldn't find the Downloads folder.")?;
        let (now, file_stamp) = stamp();
        let path = dir.join(format!("GpuVM-report-{file_stamp}.txt"));
        let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default().join("GpuVM");
        let data = std::env::var_os("ProgramData").map(PathBuf::from).unwrap_or_else(|| PathBuf::from(r"C:\ProgramData")).join("GpuVM");
        let mut out = format!(
            "GpuVM {} diagnostics report\nCreated {now}\nWindows build {}\nService: {}\n",
            env!("CARGO_PKG_VERSION"),
            windows_build(),
            crate::service::status().state,
        );
        for (title, file) in [("App (app.log)", local.join("app.log")), ("Service (host.log)", data.join("host.log")), ("Power (power.log)", data.join("power.log"))] {
            out.push_str(&format!("\n===== {title}: {} =====\n{}\n", file.display(), tail(&file, 3000)));
        }
        std::fs::write(&path, out).map_err(|e| format!("Couldn't save the report: {e}"))?;
        let explorer = std::env::var_os("SystemRoot").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("C:\\Windows")).join("explorer.exe");
        use std::os::windows::process::CommandExt;
        let mut arg = std::ffi::OsString::from("/select,\"");
        arg.push(path.as_os_str());
        arg.push("\"");
        let _ = std::process::Command::new(explorer).raw_arg(arg).spawn();
        Ok(path.display().to_string())
    })
    .await
    .map_err(|e| e.to_string())?
}

fn windows_build() -> String {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_LOCAL_MACHINE, RRF_RT_REG_SZ};
    let key: Vec<u16> = "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\0".encode_utf16().collect();
    let value: Vec<u16> = "CurrentBuild\0".encode_utf16().collect();
    let mut buf = [0u16; 32];
    let mut size = (buf.len() * 2) as u32;
    // SAFETY: reads a string value into a local buffer of the given size.
    let ok = unsafe { RegGetValueW(HKEY_LOCAL_MACHINE, key.as_ptr(), value.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr().cast(), &mut size) } == 0;
    if !ok {
        return "?".into();
    }
    String::from_utf16_lossy(&buf[..(size as usize / 2).saturating_sub(1)])
}
