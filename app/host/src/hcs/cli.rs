//! `gpuvm-host hcs ...`: drives HCS machines from an elevated shell (labs, diagnostics). Prints one JSON line.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

use super::{disk, machine, ops};

const USAGE: &str = "usage: gpuvm-host hcs create <root> <name> <template-layer> <memoryMB> <cpus> [--gpu nvidia|intel|default|none] [--service <guid>]...
       gpuvm-host hcs start|state|off|delete <root> <name>
       gpuvm-host hcs write <root> <name> <path-in-guest> <host-file>
       gpuvm-host hcs list <root>
       gpuvm-host hcs install-agent <root> <name> <gpuvm-agent.exe>
       gpuvm-host hcs ask <machine> <method> [<params-json>] [--blob <file>] [--out <file>] [--timeout <s>]
       gpuvm-host hcs gpus | network-delete";

/// Sends one command to the host service's administrative pipe (SYSTEM and administrators only) and reads the reply.
fn admin_pipe(cmd: &str, args: Value) -> Result<Value, String> {
    use std::io::{BufRead, BufReader, Write};
    let pipe = std::fs::OpenOptions::new().read(true).write(true).open(crate::agent_pipe::PIPE)
        .map_err(|e| format!("GpuVM's service pipe: {e} (is the service running, and this shell elevated?)"))?;
    let mut w = &pipe;
    writeln!(w, "{}", json!({ "id": 1, "cmd": cmd, "args": args })).map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(&pipe).read_line(&mut line).map_err(|e| e.to_string())?;
    serde_json::from_str(&line).map_err(|e| format!("reply: {e}"))
}

fn ask(args: &[String]) -> Result<Value, String> {
    let machine = arg(args, 1)?;
    let method = arg(args, 2)?;
    let mut params = json!({});
    let (mut blob, mut out, mut timeout) = (None, None, 60u64);
    let mut i = 3;
    if let Some(p) = args.get(3).filter(|a| !a.starts_with("--")) {
        params = serde_json::from_str(p).map_err(|e| format!("params: {e}"))?;
        i = 4;
    }
    while i < args.len() {
        match args[i].as_str() {
            "--blob" => { blob = Some(std::fs::read(arg(args, i + 1)?).map_err(|e| e.to_string())?); i += 2; }
            "--out" => { out = Some(PathBuf::from(arg(args, i + 1)?)); i += 2; }
            "--timeout" => { timeout = arg(args, i + 1)?.parse().map_err(|_| "timeout must be seconds")?; i += 2; }
            _ => return Err(USAGE.into()),
        }
    }
    let mut a = json!({ "Name": machine, "Method": method, "Params": params, "TimeoutSec": timeout });
    if let Some(b) = blob {
        a["Blob"] = json!(crate::wire::base64(&b));
    }
    let reply = admin_pipe("Invoke-GpuVMAgent", a)?;
    if reply["ok"] != json!(true) {
        return Err(format!("{} {}", reply["code"].as_str().unwrap_or(""), reply["error"].as_str().unwrap_or("the service refused the request")));
    }
    // The pipe answers {ok, data: [<the agent's reply>]}: hand back the agent's reply itself.
    let mut inner = reply["data"][0].clone();
    if let Some(path) = out {
        // Small results come inline as base64; larger ones the service leaves in a file of its own.
        let bytes = if let Some(b64) = inner["blob"].as_str() {
            crate::wire::unbase64(b64).ok_or("the reply's blob is not base64")?
        } else if let Some(saved) = inner["blobPath"].as_str() {
            std::fs::read(saved).map_err(|e| format!("{saved}: {e}"))?
        } else {
            return Err("the reply carries no file".into());
        };
        std::fs::write(&path, bytes).map_err(|e| format!("{}: {e}", path.display()))?;
        inner["blob"] = json!(format!("saved to {}", path.display()));
    }
    Ok(inner)
}

fn arg(args: &[String], i: usize) -> Result<&str, String> {
    args.get(i).map(String::as_str).ok_or_else(|| USAGE.to_string())
}

pub fn gpu_choice(choice: &str, gpus: &[String]) -> Result<Option<String>, String> {
    let vendor = match choice {
        "default" | "none" => return Ok(None),
        "nvidia" => "VEN_10DE",
        "intel" => "VEN_8086",
        "amd" => "VEN_1002",
        other => return Err(format!("unknown GPU choice {other}")),
    };
    gpus.iter().find(|g| g.to_ascii_uppercase().contains(vendor)).cloned().map(Some).ok_or_else(|| format!("no shareable {choice} GPU"))
}

fn run(args: &[String]) -> Result<Value, String> {
    let action = arg(args, 0)?;
    if action == "gpus" {
        return Ok(json!({ "gpus": ops::partitionable_gpus() }));
    }
    if action == "ask" {
        return ask(args);
    }
    if action == "network-delete" {
        if super::net::network_exists() {
            super::net::delete_network()?;
        }
        return Ok(json!({ "network": "deleted" }));
    }
    let root = PathBuf::from(arg(args, 1)?);
    if action == "list" {
        return Ok(json!({ "machines": machine::list(&root).iter().map(|m| {
            let mut v = m.to_json();
            v["running"] = json!(machine::running(m).is_some());
            v
        }).collect::<Vec<_>>() }));
    }
    let name = arg(args, 2)?;
    match action {
        "create" => {
            let layer = PathBuf::from(arg(args, 3)?);
            let memory: u64 = arg(args, 4)?.parse().map_err(|_| "memoryMB must be a number")?;
            let cpus: u32 = arg(args, 5)?.parse().map_err(|_| "cpus must be a number")?;
            let (mut gpu, mut services) = (None, Vec::new());
            let mut i = 6;
            while i < args.len() {
                match args[i].as_str() {
                    "--gpu" => { gpu = gpu_choice(arg(args, i + 1)?, &ops::partitionable_gpus())?; i += 2; }
                    "--service" => { services.push(arg(args, i + 1)?.to_string()); i += 2; }
                    _ => return Err(USAGE.into()),
                }
            }
            let m = machine::create(&root, name, &layer, memory, cpus, gpu, services)?;
            Ok(m.to_json())
        }
        "start" => {
            let mut m = machine::load(&root, name)?;
            let t = std::time::Instant::now();
            let started = machine::start(&mut m)?;
            let props = started.system.properties().unwrap_or(Value::Null);
            Ok(json!({ "started": true, "ms": t.elapsed().as_millis() as u64, "gpu": started.gpu.err().unwrap_or_else(|| "shared".into()),
                "runtimeId": props["RuntimeId"], "endpoint": started.endpoint.id }))
        }
        "state" => {
            let m = machine::load(&root, name)?;
            let state = ops::System::open(&m.system_id()).ok().and_then(|s| s.state().ok().flatten());
            Ok(json!({ "name": m.name, "state": state.unwrap_or_else(|| "Off".into()) }))
        }
        "off" => {
            let mut m = machine::load(&root, name)?;
            machine::power_off(&mut m)?;
            Ok(json!({ "off": true }))
        }
        "install-agent" => {
            let mut m = machine::load(&root, name)?;
            let t = std::time::Instant::now();
            let vm_id = machine::install_agent(&mut m, Path::new(arg(args, 3)?))?;
            Ok(json!({ "vmId": vm_id, "ms": t.elapsed().as_millis() as u64 }))
        }
        "delete" => {
            let m = machine::load(&root, name)?;
            machine::delete(&m)?;
            Ok(json!({ "deleted": true }))
        }
        "write" => {
            let m = machine::load(&root, name)?;
            if machine::running(&m).is_some() {
                return Err(format!("{} is running; offline writes need it off", m.name));
            }
            let inside = Path::new(arg(args, 3)?);
            let bytes = std::fs::read(arg(args, 4)?).map_err(|e| format!("read {}: {e}", arg(args, 4).unwrap_or("")))?;
            let attached = disk::attach(&m.disk(), false)?;
            let volume = attached.windows_volume(Duration::from_secs(15)).ok_or("no Windows volume on the machine's disk")?;
            machine::write_offline(Path::new(&volume), inside, &bytes)?;
            Ok(json!({ "written": inside, "bytes": bytes.len() }))
        }
        _ => Err(USAGE.into()),
    }
}

pub fn main(args: &[String]) -> Result<(), String> {
    let out = match run(args) {
        Ok(v) => json!({ "ok": true, "result": v }),
        Err(e) => json!({ "ok": false, "error": e }),
    };
    println!("{out}");
    if out["ok"] == json!(true) { Ok(()) } else { Err(out["error"].as_str().unwrap_or("failed").to_string()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gpu_choice_matches_vendor_ids() {
        let gpus = vec![r"\\?\PCI#VEN_10DE&DEV_2882#x".to_string(), r"\\?\PCI#VEN_8086&DEV_4692#y".to_string()];
        assert_eq!(gpu_choice("nvidia", &gpus).unwrap().unwrap(), gpus[0]);
        assert_eq!(gpu_choice("intel", &gpus).unwrap().unwrap(), gpus[1]);
        assert_eq!(gpu_choice("default", &gpus).unwrap(), None);
        assert!(gpu_choice("amd", &gpus).is_err());
        assert!(gpu_choice("x", &gpus).is_err());
    }

    #[test]
    fn unknown_or_short_commands_print_usage() {
        assert!(run(&[]).unwrap_err().starts_with("usage"));
        assert!(run(&["start".into()]).unwrap_err().starts_with("usage"));
    }
}
