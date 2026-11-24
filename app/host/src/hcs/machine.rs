//! One GpuVM machine on HCS: made from a template, started with the GPU and GpuVM's network, stopped, deleted.
//! A compute system only exists while the machine runs, so what defines the machine is its record on disk
//! (`<root>\<name>\hcs-machine.json`) and the system is created from it at every start.

use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{json, Value};

use super::spec::{gpu_request, HvService, MachineSpec, Nic};
use super::{disk, net, ops};

const RECORD: &str = "hcs-machine.json";

#[derive(Debug, Clone, PartialEq)]
pub struct Machine {
    pub name: String,
    pub dir: PathBuf,
    pub memory_mb: u64,
    pub cpus: u32,
    pub mac: String,
    /// Interface path of the GPU to share, or None for Windows' pick.
    pub gpu: Option<String>,
    pub services: Vec<String>,
    /// The network port while the machine runs (kept so a later power-off frees it).
    pub endpoint: Option<String>,
}

impl Machine {
    pub fn disk(&self) -> PathBuf {
        self.dir.join("disk.vhdx")
    }
    fn guest_state(&self) -> PathBuf {
        self.dir.join("vm.vmgs")
    }
    fn runtime_state(&self) -> PathBuf {
        self.dir.join("vm.vmrs")
    }
    /// The compute system's id: prefixed so GpuVM never touches systems it did not make (WSL, Sandbox...).
    pub fn system_id(&self) -> String {
        system_id(&self.name)
    }

    pub fn to_json(&self) -> Value {
        json!({ "name": self.name, "memoryMB": self.memory_mb, "cpus": self.cpus, "mac": self.mac, "gpu": self.gpu, "services": self.services, "endpoint": self.endpoint })
    }

    pub fn from_json(dir: &Path, v: &Value) -> Result<Self, String> {
        let s = |k: &str| v[k].as_str().map(String::from).ok_or_else(|| format!("{RECORD}: missing {k}"));
        let name = s("name")?;
        valid_name(&name)?;
        let services: Vec<String> = v["services"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(String::from)).collect()).unwrap_or_default();
        // A tampered record must not open other Hyper-V socket services to the guest.
        if let Some(bad) = services.iter().find(|s| net::parse_guid(s).is_none()) {
            return Err(format!("{RECORD}: not a service id: {bad}"));
        }
        Ok(Machine {
            name,
            dir: dir.to_path_buf(),
            memory_mb: v["memoryMB"].as_u64().ok_or(format!("{RECORD}: missing memoryMB"))?,
            cpus: v["cpus"].as_u64().ok_or(format!("{RECORD}: missing cpus"))? as u32,
            mac: s("mac")?,
            gpu: v["gpu"].as_str().map(String::from),
            services,
            endpoint: v["endpoint"].as_str().filter(|e| net::parse_guid(e).is_some()).map(String::from),
        })
    }

    pub fn spec(&self, endpoint: Option<&net::Endpoint>) -> MachineSpec {
        MachineSpec {
            name: self.system_id(),
            memory_mb: self.memory_mb,
            cpus: self.cpus,
            disk: self.disk(),
            guest_state: self.guest_state(),
            runtime_state: self.runtime_state(),
            secure_boot: true,
            tpm: false,
            nic: endpoint.map(|e| Nic { endpoint: e.id.clone(), mac: e.mac.clone() }),
            services: self.services.iter().map(|id| HvService { id: id.clone() }).collect(),
        }
    }

    pub fn save(&self) -> Result<(), String> {
        let tmp = self.dir.join(format!("{RECORD}.tmp"));
        fs::write(&tmp, serde_json::to_vec_pretty(&self.to_json()).unwrap()).map_err(|e| format!("save {}: {e}", tmp.display()))?;
        fs::rename(&tmp, self.dir.join(RECORD)).map_err(|e| format!("save {RECORD}: {e}"))
    }
}

pub fn system_id(name: &str) -> String {
    format!("gpuvm-{name}")
}

pub fn valid_name(name: &str) -> Result<(), String> {
    let ok = !name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
    if ok { Ok(()) } else { Err(format!("invalid machine name: {name:?}")) }
}

pub fn load(root: &Path, name: &str) -> Result<Machine, String> {
    valid_name(name)?;
    let dir = root.join(name);
    let text = fs::read_to_string(dir.join(RECORD)).map_err(|e| format!("no HCS machine {name}: {e}"))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("{RECORD} of {name}: {e}"))?;
    Machine::from_json(&dir, &v)
}

/// Every HCS machine under `root` (folders with a machine record).
pub fn list(root: &Path) -> Vec<Machine> {
    let Ok(entries) = fs::read_dir(root) else { return Vec::new() };
    entries.flatten().filter_map(|e| {
        let name = e.file_name().to_string_lossy().into_owned();
        valid_name(&name).ok()?;
        load(root, &name).ok()
    }).collect()
}

/// The disk chain a machine needs to read: its own disk and every parent, newest first.
pub fn disk_chain(disk_path: &Path) -> Result<Vec<PathBuf>, String> {
    let mut chain = vec![disk_path.to_path_buf()];
    while let Some(parent) = disk::parent_of(chain.last().unwrap())? {
        if chain.len() > 64 {
            return Err(format!("disk chain of {} is too long", disk_path.display()));
        }
        chain.push(parent);
    }
    Ok(chain)
}

/// A machine copied from a template layer: its own differencing disk, guest state files and record.
pub fn create(root: &Path, name: &str, template_layer: &Path, memory_mb: u64, cpus: u32, gpu: Option<String>, services: Vec<String>) -> Result<Machine, String> {
    valid_name(name)?;
    let dir = root.join(name);
    if dir.exists() {
        return Err(format!("{} already exists", dir.display()));
    }
    fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    let m = Machine { name: name.into(), dir: dir.clone(), memory_mb, cpus, mac: net::new_mac(), gpu, services, endpoint: None };
    let made = (|| {
        disk::create_differencing(&m.disk(), template_layer)?;
        ops::create_guest_state_file(&m.guest_state()).map_err(|e| e.to_string())?;
        ops::create_runtime_state_file(&m.runtime_state()).map_err(|e| e.to_string())?;
        m.save()
    })();
    if let Err(e) = made {
        let _ = fs::remove_dir_all(&dir);
        return Err(e);
    }
    Ok(m)
}

fn grant_all(m: &Machine) -> Result<Vec<PathBuf>, String> {
    let mut files = disk_chain(&m.disk())?;
    files.push(m.guest_state());
    files.push(m.runtime_state());
    for f in &files {
        ops::grant_access(&m.system_id(), f).map_err(|e| format!("{}: {e}", f.display()))?;
    }
    Ok(files)
}

fn revoke_all(m: &Machine) {
    let mut files = disk_chain(&m.disk()).unwrap_or_else(|_| vec![m.disk()]);
    files.push(m.guest_state());
    files.push(m.runtime_state());
    for f in &files {
        let _ = ops::revoke_access(&m.system_id(), f);
    }
}

/// The running compute system of a machine, if any (also after GpuVM's service restarted: machines outlive it).
pub fn running(m: &Machine) -> Option<ops::System> {
    let sys = ops::System::open(&m.system_id()).ok()?;
    matches!(sys.state(), Ok(Some(s)) if s == "Running" || s == "Paused").then_some(sys)
}

pub struct Started {
    pub system: ops::System,
    pub endpoint: net::Endpoint,
    pub gpu: Result<(), String>,
}

/// Starts a machine: GpuVM's network and a port for it, the compute system from its record, then the GPU.
pub fn start(m: &mut Machine) -> Result<Started, String> {
    if running(m).is_some() {
        return Err(format!("{} is already running", m.name));
    }
    // A system left Stopped by a crash still holds the id, and its port may still exist.
    if let Ok(stale) = ops::System::open(&m.system_id()) {
        let _ = stale.terminate();
    }
    if let Some(old) = m.endpoint.take() {
        let _ = net::delete_endpoint(&old);
    }
    grant_all(m).inspect_err(|_| revoke_all(m))?;
    let endpoint = match net::ensure_network().and_then(|_| net::create_endpoint(&m.mac)) {
        Ok(e) => e,
        Err(e) => {
            revoke_all(m);
            return Err(e);
        }
    };
    m.endpoint = Some(endpoint.id.clone());
    m.save()?;
    let started = (|| {
        let system = ops::System::create(&m.system_id(), &m.spec(Some(&endpoint)).document()).map_err(|e| e.to_string())?;
        if let Err(e) = system.start() {
            let _ = system.terminate();
            return Err(e.to_string());
        }
        Ok(system)
    })();
    let system = match started {
        Ok(s) => s,
        Err(e) => {
            let _ = net::delete_endpoint(&endpoint.id);
            m.endpoint = None;
            let _ = m.save();
            revoke_all(m);
            return Err(e);
        }
    };
    let gpu = system.modify(&gpu_request(m.gpu.as_deref())).map_err(|e| e.to_string());
    Ok(Started { system, endpoint, gpu })
}

/// Turns the machine off at once (like pulling the plug) and frees its network port.
pub fn power_off(m: &mut Machine) -> Result<(), String> {
    let mut result = Ok(());
    if let Ok(sys) = ops::System::open(&m.system_id()) {
        if let Err(e) = sys.terminate() {
            // A system that already stopped by itself is off: only a machine still running is a failure.
            if matches!(sys.state(), Ok(Some(ref s)) if s == "Running" || s == "Paused") {
                result = Err(e.to_string());
            }
        }
    }
    if let Some(id) = m.endpoint.take() {
        let _ = net::delete_endpoint(&id);
        m.save()?;
    }
    result
}

/// Deletes a machine that is off: its folder, disk and the access its disks gave it.
pub fn delete(m: &Machine) -> Result<(), String> {
    if running(m).is_some() {
        return Err(format!("{} is running; turn it off first", m.name));
    }
    if let Ok(stale) = ops::System::open(&m.system_id()) {
        let _ = stale.terminate();
    }
    if let Some(id) = &m.endpoint {
        let _ = net::delete_endpoint(id);
    }
    revoke_all(m);
    fs::remove_dir_all(&m.dir).map_err(|e| format!("delete {}: {e}", m.dir.display()))
}

/// Writes a file into a Windows volume of a machine that is off. The guest controls its own disk and could point a
/// junction at a host folder, so the path is walked by handle without following links (`safe::write_file`).
pub fn write_offline(volume: &Path, relative: &Path, bytes: &[u8]) -> Result<(), String> {
    super::safe::write_file(volume, relative, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(dir: &Path) -> Machine {
        Machine { name: "m1".into(), dir: dir.into(), memory_mb: 4096, cpus: 4, mac: "00-15-5D-01-02-03".into(), gpu: Some(r"\\?\PCI#x".into()),
            services: vec!["0651ab67-7c1e-4b0a-9a65-065065065067".into()], endpoint: Some("833a570d-b7d1-42d7-b1bf-516561468fd4".into()) }
    }

    #[test]
    fn records_with_bad_ids_are_refused_or_dropped() {
        let v = json!({ "name": "m1", "memoryMB": 1, "cpus": 1, "mac": "m", "services": ["not-a-guid"] });
        assert!(Machine::from_json(Path::new("x"), &v).is_err());
        let v = json!({ "name": "m1", "memoryMB": 1, "cpus": 1, "mac": "m", "endpoint": "x" });
        assert_eq!(Machine::from_json(Path::new("x"), &v).unwrap().endpoint, None);
    }

    #[test]
    fn record_round_trips() {
        let dir = PathBuf::from(r"C:\GpuVM\m1");
        let m = sample(&dir);
        assert_eq!(Machine::from_json(&dir, &m.to_json()).unwrap(), m);
    }

    #[test]
    fn names_that_could_escape_the_root_are_refused() {
        for bad in ["", "..", "a/b", r"a\b", "a b", "x".repeat(41).as_str(), "c:"] {
            assert!(valid_name(bad).is_err(), "{bad:?}");
        }
        assert!(valid_name("win-gpu_2").is_ok());
        let v = json!({ "name": "..", "memoryMB": 1, "cpus": 1, "mac": "m" });
        assert!(Machine::from_json(Path::new("x"), &v).is_err());
    }

    #[test]
    fn spec_uses_the_machine_files_and_prefixed_id() {
        let m = sample(Path::new(r"C:\GpuVM\m1"));
        let d = m.spec(None).document();
        assert_eq!(d["VirtualMachine"]["Devices"]["Scsi"]["Primary"]["Attachments"]["0"]["Path"], json!(r"C:\GpuVM\m1\disk.vhdx"));
        assert_eq!(d["VirtualMachine"]["GuestState"]["GuestStateFilePath"], json!(r"C:\GpuVM\m1\vm.vmgs"));
        assert_eq!(m.system_id(), "gpuvm-m1");
    }

    #[test]
    fn offline_writes_refuse_links_and_escapes() {
        let root = std::env::temp_dir().join(format!("gpuvm-offline-{}", std::process::id()));
        let outside = root.join("outside");
        let vol = root.join("vol");
        fs::create_dir_all(&outside).unwrap();
        fs::create_dir_all(vol.join("Windows")).unwrap();
        write_offline(&vol, Path::new(r"GpuVM\setup\a.txt"), b"ok").unwrap();
        assert_eq!(fs::read(vol.join(r"GpuVM\setup\a.txt")).unwrap(), b"ok");
        assert!(write_offline(&vol, Path::new(r"..\outside\x.txt"), b"no").is_err());
        assert!(write_offline(&vol, Path::new(r"C:\x.txt"), b"no").is_err());
        // A junction planted by the guest (needs no privilege to create).
        let junction = vol.join("Planted");
        let made = std::process::Command::new("cmd").args(["/c", "mklink", "/J"]).arg(&junction).arg(&outside).output().map(|o| o.status.success()).unwrap_or(false);
        if made {
            assert!(write_offline(&vol, Path::new(r"Planted\x.txt"), b"no").is_err());
            assert!(!outside.join("x.txt").exists());
        }
        let _ = fs::remove_dir_all(&root);
        assert!(made, "the test could not create a junction");
    }
}
