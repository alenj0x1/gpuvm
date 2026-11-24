use std::path::PathBuf;

use serde_json::{json, Map, Value};

/// Microsoft's Windows UEFI certificate template (the one Hyper-V names "MicrosoftWindows").
const SECURE_BOOT_WINDOWS: &str = "1734c6e8-3154-4dda-ba5f-a874cc483422";
const HOST_ADMINS: &str = "D:P(A;;FA;;;SY)(A;;FA;;;BA)";

pub struct Nic {
    pub endpoint: String,
    pub mac: String,
}

/// A Hyper-V socket service between host and guest. Both descriptors judge host processes: only SYSTEM and
/// administrators may listen for the guest or connect to it.
pub struct HvService {
    pub id: String,
}

pub struct MachineSpec {
    pub name: String,
    pub memory_mb: u64,
    pub cpus: u32,
    pub disk: PathBuf,
    pub guest_state: PathBuf,
    pub runtime_state: PathBuf,
    pub secure_boot: bool,
    /// Windows 10 hosts reject this section; only set it where the host's schema accepts it.
    pub tpm: bool,
    pub nic: Option<Nic>,
    pub services: Vec<HvService>,
}

impl MachineSpec {
    pub fn document(&self) -> Value {
        let mut uefi = Map::new();
        uefi.insert("Console".into(), json!("Default"));
        if self.secure_boot {
            uefi.insert("ApplySecureBootTemplate".into(), json!("Apply"));
            uefi.insert("SecureBootTemplateId".into(), json!(SECURE_BOOT_WINDOWS));
        } else {
            uefi.insert("ApplySecureBootTemplate".into(), json!("Skip"));
        }

        let services: Map<String, Value> = self.services.iter().map(|s| {
            (s.id.clone(), json!({
                "BindSecurityDescriptor": HOST_ADMINS,
                "ConnectSecurityDescriptor": HOST_ADMINS,
                "AllowWildcardBinds": true
            }))
        }).collect();

        let mut devices = json!({
            "Scsi": { "Primary": { "Attachments": { "0": { "Type": "VirtualDisk", "Path": self.disk } } } },
            // vmwp crashes without a video monitor even when the picture comes from the GPU.
            "VideoMonitor": { "HorizontalResolution": 1024, "VerticalResolution": 768 },
            "HvSocket": { "HvSocketConfig": { "ServiceTable": services } },
            "Keyboard": {},
            "Mouse": {}
        });
        if let Some(nic) = &self.nic {
            devices["NetworkAdapters"] = json!({ "Default": { "EndpointId": nic.endpoint, "MacAddress": nic.mac } });
        }

        let mut vm = json!({
            // Without this a restart inside the guest ends the compute system.
            "StopOnReset": false,
            "Chipset": { "Uefi": uefi },
            "ComputeTopology": {
                "Memory": { "SizeInMB": self.memory_mb },
                "Processor": { "Count": self.cpus }
            },
            "Devices": devices,
            "GuestState": { "GuestStateFilePath": self.guest_state, "RuntimeStateFilePath": self.runtime_state }
        });
        if self.tpm {
            vm["SecuritySettings"] = json!({ "EnableTpm": true, "Isolation": { "IsolationType": "GuestStateOnly" } });
        }

        json!({
            "SchemaVersion": { "Major": 2, "Minor": 1 },
            "Owner": "GpuVM",
            "ShouldTerminateOnLastHandleClosed": false,
            "VirtualMachine": vm
        })
    }
}

/// The request that shares a GPU with a running machine: one partitionable GPU by interface path, or Windows' pick.
pub fn gpu_request(gpu: Option<&str>) -> Value {
    let settings = match gpu {
        Some(path) => json!({ "AssignmentMode": "List", "AssignmentRequest": { path: 65535 }, "AllowVendorExtension": true }),
        None => json!({ "AssignmentMode": "Default", "AllowVendorExtension": true }),
    };
    json!({ "ResourcePath": "VirtualMachine/ComputeTopology/Gpu", "RequestType": "Update", "Settings": settings })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> MachineSpec {
        MachineSpec {
            name: "m1".into(),
            memory_mb: 4096,
            cpus: 4,
            disk: PathBuf::from(r"C:\GpuVM\m1\disk.vhdx"),
            guest_state: PathBuf::from(r"C:\GpuVM\m1\vm.vmgs"),
            runtime_state: PathBuf::from(r"C:\GpuVM\m1\vm.vmrs"),
            secure_boot: true,
            tpm: false,
            nic: None,
            services: vec![],
        }
    }

    #[test]
    fn document_has_what_lab_065_booted_with() {
        let d = spec().document();
        assert_eq!(d["SchemaVersion"], json!({ "Major": 2, "Minor": 1 }));
        let vm = &d["VirtualMachine"];
        assert_eq!(vm["StopOnReset"], json!(false));
        assert_eq!(vm["ComputeTopology"]["Memory"]["SizeInMB"], json!(4096));
        assert_eq!(vm["ComputeTopology"]["Processor"]["Count"], json!(4));
        assert_eq!(vm["Devices"]["Scsi"]["Primary"]["Attachments"]["0"]["Path"], json!(r"C:\GpuVM\m1\disk.vhdx"));
        assert_eq!(vm["Chipset"]["Uefi"]["SecureBootTemplateId"], json!(SECURE_BOOT_WINDOWS));
        assert!(vm["Devices"]["VideoMonitor"].is_object());
        assert!(vm.get("SecuritySettings").is_none());
        assert!(vm["Devices"].get("NetworkAdapters").is_none());
    }

    #[test]
    fn machine_outlives_the_handle() {
        assert_eq!(spec().document()["ShouldTerminateOnLastHandleClosed"], json!(false));
    }

    #[test]
    fn optional_parts_appear_only_when_asked() {
        let mut s = spec();
        s.tpm = true;
        s.secure_boot = false;
        s.nic = Some(Nic { endpoint: "e1".into(), mac: "00-15-5D-01-02-03".into() });
        s.services = vec![HvService { id: "0651ab65-7c1e-4b0a-9a65-065065065065".into() }];
        let vm = &s.document()["VirtualMachine"];
        assert_eq!(vm["SecuritySettings"]["EnableTpm"], json!(true));
        assert_eq!(vm["Chipset"]["Uefi"]["ApplySecureBootTemplate"], json!("Skip"));
        assert_eq!(vm["Devices"]["NetworkAdapters"]["Default"]["MacAddress"], json!("00-15-5D-01-02-03"));
        let svc = &vm["Devices"]["HvSocket"]["HvSocketConfig"]["ServiceTable"]["0651ab65-7c1e-4b0a-9a65-065065065065"];
        assert_eq!(svc["BindSecurityDescriptor"], json!("D:P(A;;FA;;;SY)(A;;FA;;;BA)"));
        assert_eq!(svc["ConnectSecurityDescriptor"], json!("D:P(A;;FA;;;SY)(A;;FA;;;BA)"));
    }

    #[test]
    fn gpu_request_names_one_gpu_or_lets_windows_pick() {
        let one = gpu_request(Some(r"\\?\PCI#VEN_10DE#x"));
        assert_eq!(one["Settings"]["AssignmentMode"], json!("List"));
        assert_eq!(one["Settings"]["AssignmentRequest"][r"\\?\PCI#VEN_10DE#x"], json!(65535));
        assert_eq!(gpu_request(None)["Settings"]["AssignmentMode"], json!("Default"));
        assert_eq!(one["ResourcePath"], json!("VirtualMachine/ComputeTopology/Gpu"));
    }
}
