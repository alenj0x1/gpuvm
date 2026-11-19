#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    // `gpuvm.exe --consent <code>`: the elevated copy that confirms a deletion to the GpuVM service (no window).
    let args: Vec<String> = std::env::args().collect();
    if let (Some("--consent"), Some(code)) = (args.get(1).map(String::as_str), args.get(2)) {
        std::process::exit(gpuvm_lib::consent(code));
    }
    // `gpuvm.exe --mcp [--fake]`: the MCP server for agent clients, over stdin/stdout (no window).
    if args.get(1).map(String::as_str) == Some("--mcp") {
        std::process::exit(gpuvm_lib::mcp(args.get(2).map(String::as_str) == Some("--fake")));
    }
    gpuvm_lib::run()
}
