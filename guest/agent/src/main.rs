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
