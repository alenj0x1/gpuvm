#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // `gpuvm.exe --consent <code>`: the elevated copy that confirms a deletion to the GpuVM service (no window).
    let args: Vec<String> = std::env::args().collect();
    if let (Some("--consent"), Some(code)) = (args.get(1).map(String::as_str), args.get(2)) {
        std::process::exit(gpuvm_lib::consent(code));
    }
    gpuvm_lib::run()
}
