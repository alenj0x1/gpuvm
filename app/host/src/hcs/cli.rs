//! `gpuvm-host hcs ...`: drives HCS machines from an elevated shell (labs, diagnostics). Prints one JSON line.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{json, Value};

use super::{disk, machine, ops};

const USAGE: &str = "usage: gpuvm-host hcs create <root> <name> <template-layer> <memoryMB> <cpus> [--gpu nvidia|intel|default|none] [--service <guid>]...
       gpuvm-host hcs start|state|off|delete <root> <name>
       gpuvm-host hcs write <root> <name> <path-in-guest> <host-file>
       gpuvm-host hcs list <root>
       gpuvm-host hcs gpus | network-delete";

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
