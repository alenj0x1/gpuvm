//! gpuvm-agent service   run by the Service Control Manager as `GpuVMAgent` (SYSTEM)
//! gpuvm-agent run       the same loop in a console (diagnostics; must run as SYSTEM to start helpers)
//! gpuvm-agent helper    the session helper (started by the service with inherited pipes)
//! gpuvm-agent check     checks the secret's ACL and prints what the service would do
//! gpuvm-agent version
#![windows_subsystem = "windows"]
use gpuvm_agent::*;

fn console() {
    unsafe {
        use windows::Win32::System::Console::*;
        let _ = AttachConsole(ATTACH_PARENT_PROCESS);
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(String::as_str) {
        Some("service") => {
            if let Err(e) = service::run_as_service() {
                console();
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        Some("run") => {
            console();
            service::run();
        }
        Some("helper") => helper::run(),
        Some("check") => {
            console();
            match secret::load() {
                Ok(_) => println!("secret: ok (32 bytes, SYSTEM + Administrators only)"),
                Err(e) => println!("secret: refused: {e}"),
            }
            println!("active console session: {:?}", session::active_session());
        }
        Some("diag") => {
            console();
            unsafe {
                let _ = windows::Win32::UI::HiDpi::SetProcessDpiAwarenessContext(windows::Win32::UI::HiDpi::DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
                let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
            }
            let cap = capture::screen_capture(&serde_json::json!({"format": "png"}));
            let r = serde_json::json!({
                "displays": capture::displays_json(),
                "outputRect": capture::output_rect().map(|r| vec![r.left, r.top, r.right - r.left, r.bottom - r.top]),
                "capture": match &cap { Ok((v, b)) => serde_json::json!({"result": v, "bytes": b.as_ref().map(|b| b.len())}), Err((c, m)) => serde_json::json!({"error": c, "message": m}) },
            });
            println!("{r}");
        }
        Some("version") => {
            console();
            println!("{}", util::VERSION);
        }
        _ => {
            console();
            eprintln!("gpuvm-agent {}: service | run | helper | check | version", util::VERSION);
            std::process::exit(2);
        }
    }
}
