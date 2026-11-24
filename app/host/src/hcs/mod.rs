//! Machines through the Host Compute Service (computecore.dll), which only needs Windows' "Virtual Machine Platform":
//! the backend for editions without Hyper-V (labs/065-hcs-backend).
#![allow(dead_code)]

mod ops;
pub mod spec;

pub use ops::*;

#[cfg(test)]
mod live {
    use super::*;
    use serde_json::json;

    // Needs an elevated shell and the lab lock; run with `cargo test -- --ignored hcs`.
    #[test]
    #[ignore]
    fn hcs_machine_without_disk_starts_and_terminates() {
        let dir = std::env::temp_dir().join(format!("gpuvm-hcs-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (vmgs, vmrs) = (dir.join("vm.vmgs"), dir.join("vm.vmrs"));
        let id = format!("gpuvm-test-{}", std::process::id());
        create_guest_state_file(&vmgs).unwrap();
        create_runtime_state_file(&vmrs).unwrap();
        grant_access(&id, &vmgs).unwrap();
        grant_access(&id, &vmrs).unwrap();
        let doc = json!({
            "SchemaVersion": { "Major": 2, "Minor": 1 },
            "Owner": "GpuVM-test",
            "ShouldTerminateOnLastHandleClosed": true,
            "VirtualMachine": {
                "StopOnReset": false,
                "Chipset": { "Uefi": { "Console": "Default" } },
                "ComputeTopology": { "Memory": { "SizeInMB": 512 }, "Processor": { "Count": 1 } },
                "Devices": { "VideoMonitor": { "HorizontalResolution": 1024, "VerticalResolution": 768 }, "Keyboard": {}, "Mouse": {} },
                "GuestState": { "GuestStateFilePath": vmgs, "RuntimeStateFilePath": vmrs }
            }
        });
        let system = System::create(&id, &doc).expect("create");
        system.start().expect("start");
        assert_eq!(system.state().as_deref(), Some("Running"));
        assert!(enumerate().unwrap().iter().any(|s| s["Id"].as_str() == Some(id.as_str())));
        system.terminate().expect("terminate");
        drop(system);
        let _ = revoke_access(&id, &vmgs);
        let _ = revoke_access(&id, &vmrs);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[ignore]
    fn hcs_lists_partitionable_gpus() {
        let gpus = partitionable_gpus();
        assert!(!gpus.is_empty(), "this test expects a GPU the host can share");
        assert!(gpus.iter().all(|g| g.ends_with(r"\GPUPARAV")));
    }
}
