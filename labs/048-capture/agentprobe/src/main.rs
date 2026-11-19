//! agentprobe: guest-side probe for GpuVM labs 048 (capture), 049 (input + UI Automation) and 050 (access).
//! Every command prints one JSON document (or JSON lines for watchers); `--out file` writes it to a file instead and
//! `--log file` mirrors JSON lines. Runs with whatever token it was started with; `launch` (from SYSTEM) starts it in
//! the interactive session.
mod capture;
mod hv;
mod input;
mod token;
mod uia;
mod util;

use util::*;
use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
    if let Some(l) = arg(&args.iter().take_while(|a| *a != "--").cloned().collect::<Vec<_>>(), "--log") {
        set_log(&l);
    }
    let out = match args.get(1).map(|s| s.as_str()) {
        Some("whoami") => {
            let d = match capture::input_desktop() { Ok(n) => jstr(&n), Err(e) => format!("\"error {e}\"") };
            let w = token::whoami_json();
            format!("{},\"inputDesktop\":{d}}}", &w[..w.len() - 1])
        }
        Some("outputs") => match capture::enumerate() {
            Ok(l) => capture::outputs_json(&l),
            Err(e) => format!("{{\"error\":{}}}", e.code().0),
        },
        Some("capture") => capture::cmd_capture(&args),
        Some("watch") => {
            // A watcher's lines go to --out too (a launched probe has no console to print to).
            if let Some(o) = arg(&args, "--out") {
                set_log(&o);
            }
            capture::cmd_watch(&args);
            return;
        }
        Some("launch") => token::cmd_launch(&args),
        Some("launch-as") => token::cmd_launch_as(&args),
        Some("focus") => input::cmd_focus(&args),
        Some("focused") => uia::cmd_focused(),
        Some("fg") => input::fg_json(&input::foreground()),
        Some("act") => input::cmd_act(&args),
        Some("latency") => input::cmd_latency(&args),
        Some("uia") => uia::cmd_uia(&args),
        Some("hv") => hv::cmd_hv(&args),
        Some("read") => hv::cmd_read(&args),
        Some("regread") => hv::cmd_regread(&args),
        _ => {
            eprintln!("usage: agentprobe whoami|outputs|capture|watch|launch ...");
            std::process::exit(2);
        }
    };
    // `launch ... -- <inner args>`: --out after "--" belongs to the inner probe, not to launch.
    let own: Vec<String> = args.iter().take_while(|a| *a != "--").cloned().collect();
    match arg(&own, "--out") {
        Some(p) => std::fs::write(p, out).unwrap(),
        None => println!("{out}"),
    }
}
