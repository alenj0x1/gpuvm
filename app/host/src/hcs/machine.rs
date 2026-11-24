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
    /// Network isolation like GpuVM's Hyper-V machines (on unless turned off): its own isolated network and the
    /// relay instead of the ICS network.
    pub isolated: bool,
    /// The machine's address on its isolated network (.2; no DHCP there, the agent sets it). Kept so the next start
    /// tries the same subnet.
    pub ip: Option<String>,
    /// The network port while the machine runs (kept so a later power-off frees it).
    pub endpoint: Option<String>,
    /// The id the host sees for the machine (its compute system's RuntimeId), once GpuVM's agent is installed.
    pub vm_id: Option<String>,
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
        json!({ "name": self.name, "memoryMB": self.memory_mb, "cpus": self.cpus, "mac": self.mac, "gpu": self.gpu, "services": self.services, "endpoint": self.endpoint, "vmId": self.vm_id, "isolated": self.isolated, "ip": self.ip })
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
            isolated: v["isolated"].as_bool().unwrap_or(true),
            ip: v["ip"].as_str().filter(|i| i.parse::<std::net::Ipv4Addr>().is_ok()).map(String::from),
            endpoint: v["endpoint"].as_str().filter(|e| net::parse_guid(e).is_some()).map(String::from),
            vm_id: v["vmId"].as_str().filter(|e| net::parse_guid(e).is_some()).map(String::from),
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
            services: self.services.iter().cloned()
                .chain(self.isolated.then(|| super::relay::SERVICE.to_string()))
                .map(|id| HvService { id })
                .collect(),
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

/// The HCS machine in `dir` whose agent has id `vm_id`, if it still exists.
pub fn owner(dir: &Path, vm_id: &str) -> Option<Machine> {
    let m = load(dir.parent()?, dir.file_name()?.to_str()?).ok()?;
    m.vm_id.as_deref().is_some_and(|v| v.eq_ignore_ascii_case(vm_id)).then_some(m)
}

/// What `sys.net` tells the agent of the HCS machine in `dir` whose id is `vm_id`: on the isolated network its fixed
/// address (the relay gives it internet), otherwise DHCP. None when `dir` holds no such machine.
pub fn guest_network(dir: &Path, vm_id: &str) -> Option<Value> {
    let m = owner(dir, vm_id)?;
    Some(match (&m.isolated, &m.ip) {
        (true, Some(ip)) => json!({ "mode": "isolated", "mac": m.mac, "ip": ip, "prefixLength": 24 }),
        // Isolated but no address yet (never started on the isolated network): leave the guest as it is.
        (true, None) => return None,
        (false, _) => json!({ "mode": "dhcp", "mac": m.mac }),
    })
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
/// Where a new machine's disk comes from: a copy of a template layer, or a disk made for it (moved into its folder).
pub enum DiskSource<'a> {
    Template(&'a Path),
    Own(&'a Path),
}

pub fn create(root: &Path, name: &str, template_layer: &Path, memory_mb: u64, cpus: u32, gpu: Option<String>, services: Vec<String>) -> Result<Machine, String> {
    create_from(root, name, DiskSource::Template(template_layer), memory_mb, cpus, gpu, services)
}

pub fn create_from(root: &Path, name: &str, source: DiskSource, memory_mb: u64, cpus: u32, gpu: Option<String>, services: Vec<String>) -> Result<Machine, String> {
    valid_name(name)?;
    let dir = root.join(name);
    if dir.exists() {
        return Err(format!("{} already exists", dir.display()));
    }
    fs::create_dir_all(&dir).map_err(|e| format!("create {}: {e}", dir.display()))?;
    // The service writes logs here as SYSTEM: nobody but SYSTEM and administrators may plant links in it.
    super::safe::protect_folder(&dir, "O:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)")?;
    let m = Machine { name: name.into(), dir: dir.clone(), memory_mb, cpus, mac: net::new_mac(), gpu, services, isolated: true, ip: None, endpoint: None, vm_id: None };
    let made = (|| {
        match source {
            DiskSource::Template(layer) => disk::create_differencing(&m.disk(), layer)?,
            DiskSource::Own(file) => fs::rename(file, m.disk()).map_err(|e| format!("move {} into the machine: {e}", file.display()))?,
        }
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
        drop(stale);
        wait_gone(&m.system_id());
    }
    if let Some(old) = m.endpoint.take() {
        let _ = net::delete_endpoint(&old);
    }
    grant_all(m).inspect_err(|_| revoke_all(m))?;
    let made = if m.isolated {
        let preferred = m.ip.as_deref().and_then(|i| i.parse::<std::net::Ipv4Addr>().ok()).map(|a| {
            let o = a.octets();
            [o[0], o[1], o[2]]
        });
        net::create_isolated_network(&m.name, preferred).and_then(|subnet| {
            net::create_isolated_endpoint(&m.mac, &m.name, subnet)
                .map(|e| (e, Some(net::host_part(subnet, 2))))
                .inspect_err(|_| {
                    let _ = net::delete_isolated_network(&m.name);
                })
        })
    } else {
        let _ = net::delete_isolated_network(&m.name);
        net::ensure_network().and_then(|_| net::create_endpoint(&m.mac)).map(|e| (e, None))
    };
    let endpoint = match made {
        Ok((e, ip)) => {
            m.ip = ip;
            e
        }
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
            let _ = net::delete_isolated_network(&m.name);
            m.endpoint = None;
            let _ = m.save();
            revoke_all(m);
            return Err(e);
        }
    };
    // While another GPU machine runs, Windows sometimes holds the GPU's device about two minutes before this one
    // boots (lab 076); adding it before the start doesn't change that.
    let gpu = if m.gpu.as_deref() == Some(super::cli::NO_GPU) {
        Err("no GPU (set so)".to_string())
    } else {
        system.modify(&gpu_request(m.gpu.as_deref())).map_err(|e| e.to_string())
    };
    Ok(Started { system, endpoint, gpu })
}

/// Turns the machine off at once (like pulling the plug) and frees its network port.
/// HCS releases a terminated compute system a moment later; until then its id can't be used again (a start right
/// after a power-off failed with "already exists", lab 076).
fn wait_gone(id: &str) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
    while ops::System::open(id).is_ok() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}

pub fn power_off(m: &mut Machine) -> Result<(), String> {
    let mut result = Ok(());
    if let Ok(sys) = ops::System::open(&m.system_id()) {
        if let Err(e) = sys.terminate() {
            // A system that already stopped by itself is off: only a machine still running is a failure.
            if matches!(sys.state(), Ok(Some(ref s)) if s == "Running" || s == "Paused") {
                result = Err(e.to_string());
            }
        }
        drop(sys);
        if result.is_ok() {
            wait_gone(&m.system_id());
        }
    }
    if let Some(id) = m.endpoint.take() {
        let _ = net::delete_endpoint(&id);
        m.save()?;
    }
    if let Err(e) = net::delete_isolated_network(&m.name) {
        result = result.and(Err(e));
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
        drop(stale);
        wait_gone(&m.system_id());
    }
    if let Some(id) = &m.endpoint {
        let _ = net::delete_endpoint(id);
    }
    net::delete_isolated_network(&m.name)?;
    if let Some(id) = &m.vm_id {
        let _ = crate::agent::unregister(id);
    }
    revoke_all(m);
    fs::remove_dir_all(&m.dir).map_err(|e| format!("delete {}: {e}", m.dir.display()))
}

/// Writes a file into a Windows volume of a machine that is off. The guest controls its own disk and could point a
/// junction at a host folder, so the path is walked by handle without following links (`safe::write_file`).
pub fn write_offline(volume: &Path, relative: &Path, bytes: &[u8]) -> Result<(), String> {
    super::safe::write_file(volume, relative, bytes)
}

/// Changes what a stopped machine gets at its next start.
pub fn set(m: &mut Machine, memory_mb: Option<u64>, cpus: Option<u32>, gpu: Option<Option<String>>, isolated: Option<bool>) -> Result<(), String> {
    if let Some(i) = isolated {
        m.isolated = i;
    }
    if let Some(v) = memory_mb {
        if !(1024..=1 << 20).contains(&v) {
            return Err(format!("memory {v} MB is out of range"));
        }
        m.memory_mb = v;
    }
    if let Some(v) = cpus {
        if !(1..=256).contains(&v) {
            return Err(format!("{v} processors is out of range"));
        }
        m.cpus = v;
    }
    if let Some(g) = gpu {
        m.gpu = g;
    }
    m.save()
}

/// The Hyper-V socket service GpuVM's agent uses (the same id as under Hyper-V).
pub const AGENT_SERVICE: &str = "94aca5ef-a5b6-45a9-8c15-c7724a63f3da";
const AGENT_EXE: &str = r"Program Files\GpuVM Agent\gpuvm-agent.exe";
const AGENT_IMAGE: &str = r#""C:\Program Files\GpuVM Agent\gpuvm-agent.exe" service"#;
/// The agent refuses its secret unless SYSTEM or Administrators own it and nobody else is in its ACL.
const AGENT_DATA_SDDL: &str = "O:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)";

/// The RuntimeId HCS gives this machine's compute system: it depends only on the system's id, so a system created
/// for a moment (never started) tells it.
pub fn learn_vm_id(m: &Machine) -> Result<String, String> {
    if let Ok(existing) = ops::System::open(&m.system_id()) {
        if let Ok(p) = existing.properties() {
            if let Some(id) = p["RuntimeId"].as_str() {
                return Ok(id.to_ascii_lowercase());
            }
        }
    }
    grant_all(m)?;
    let sys = ops::System::create(&m.system_id(), &m.spec(None).document()).map_err(|e| e.to_string())?;
    let id = sys.properties().ok().and_then(|p| p["RuntimeId"].as_str().map(str::to_ascii_lowercase));
    let _ = sys.terminate();
    id.ok_or_else(|| "HCS reported no RuntimeId".into())
}

/// Installs GpuVM's agent into a stopped machine's disk: the program, its secret and machine id (SYSTEM and
/// Administrators only) and its service in the offline SYSTEM hive; then registers it with the host's broker.
const WINTUN_DLL: &str = r"Program Files\GpuVM Agent\wintun.dll";
/// Wintun 0.14.1, amd64 (wintun.net, signed by WireGuard LLC): the adapter isolated machines reach the internet through.
const WINTUN_SHA256: &str = "e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce";

/// The Wintun library that ships next to the agent, only if it is exactly the release GpuVM was tested with.
fn read_wintun(agent_exe: &Path) -> Result<Vec<u8>, String> {
    let path = agent_exe.with_file_name("wintun.dll");
    let bytes = fs::read(&path).map_err(|e| format!("read {}: {e}", path.display()))?;
    let hash: String = crate::wire::sha256(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    if hash != WINTUN_SHA256 {
        return Err(format!("{} is not the Wintun release GpuVM ships", path.display()));
    }
    Ok(bytes)
}

pub fn install_agent(m: &mut Machine, agent_exe: &Path) -> Result<String, String> {
    if running(m).is_some() {
        return Err(format!("{} is running; the agent is installed with it off", m.name));
    }
    let exe = fs::read(agent_exe).map_err(|e| format!("read {}: {e}", agent_exe.display()))?;
    let wintun = read_wintun(agent_exe)?;
    let secret: [u8; 32] = crate::wire::random();
    let vm_id = learn_vm_id(m)?;
    {
        let attached = disk::attach(&m.disk(), false)?;
        let volume = attached.windows_volume(std::time::Duration::from_secs(15)).ok_or("no Windows volume on the machine's disk")?;
        let vol = Path::new(&volume);
        super::safe::write_file(vol, Path::new(AGENT_EXE), &exe)?;
        super::safe::write_file(vol, Path::new(WINTUN_DLL), &wintun)?;
        super::safe::write_file_protected(vol, Path::new(r"ProgramData\GpuVM\Agent\secret"), &secret, Some(AGENT_DATA_SDDL))?;
        super::safe::write_file_protected(vol, Path::new(r"ProgramData\GpuVM\Agent\vmid"), vm_id.as_bytes(), Some(AGENT_DATA_SDDL))?;
        let hive = Path::new(r"Windows\System32\config\SYSTEM");
        drop(super::safe::existing_plain(vol, hive)?);
        super::offline::add_service(&vol.join(hive), "GpuVMAgent", "GpuVM Agent", AGENT_IMAGE)?;
    }
    crate::agent::register_installed(&vm_id, &m.name, &m.dir, &secret)?;
    if !m.services.iter().any(|s| s.eq_ignore_ascii_case(AGENT_SERVICE)) {
        m.services.push(AGENT_SERVICE.into());
    }
    m.vm_id = Some(vm_id.clone());
    m.save()?;
    Ok(vm_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(dir: &Path) -> Machine {
        Machine { name: "m1".into(), dir: dir.into(), memory_mb: 4096, cpus: 4, mac: "00-15-5D-01-02-03".into(), gpu: Some(r"\\?\PCI#x".into()),
            services: vec!["0651ab67-7c1e-4b0a-9a65-065065065067".into()], isolated: true, ip: None, endpoint: Some("833a570d-b7d1-42d7-b1bf-516561468fd4".into()), vm_id: Some("c4db4891-b8bd-52a3-8e0f-c1831f1a6050".into()) }
    }

    #[test]
    fn guest_network_follows_the_record() {
        let root = std::env::temp_dir().join(format!("gpuvm-guestnet-{}", std::process::id()));
        let dir = root.join("m1");
        fs::create_dir_all(&dir).unwrap();
        let vm = "c4db4891-b8bd-52a3-8e0f-c1831f1a6050";
        let mut m = sample(&dir);
        m.save().unwrap();
        assert!(guest_network(&dir, vm).is_none(), "isolated without an address yet");
        m.ip = Some("192.168.185.10".into());
        m.save().unwrap();
        let v = guest_network(&dir, vm).unwrap();
        assert_eq!((v["mode"].as_str(), v["ip"].as_str(), v["mac"].as_str()), (Some("isolated"), Some("192.168.185.10"), Some("00-15-5D-01-02-03")));
        assert!(guest_network(&dir, "00000000-0000-0000-0000-000000000001").is_none(), "another machine's id");
        m.isolated = false;
        m.save().unwrap();
        assert_eq!(guest_network(&dir, vm).unwrap()["mode"], json!("dhcp"));
        let _ = fs::remove_dir_all(&root);
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
