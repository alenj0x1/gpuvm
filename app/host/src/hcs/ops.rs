use std::fmt;
use std::path::Path;

use serde_json::Value;
use windows_sys::core::{GUID, PWSTR};
use windows_sys::Win32::Devices::DeviceAndDriverInstallation::*;
use windows_sys::Win32::Foundation::{LocalFree, HCS_E_OPERATION_TIMEOUT, HCS_E_SYSTEM_NOT_FOUND};
use windows_sys::Win32::System::HostComputeSystem::*;

use crate::win::{wide, wide_path};

#[derive(Debug)]
pub struct HcsError {
    pub hr: i32,
    pub detail: String,
}

impl fmt::Display for HcsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "0x{:08X}", self.hr as u32)?;
        if !self.detail.is_empty() {
            write!(f, " {}", self.detail)?;
        }
        Ok(())
    }
}

pub type Result<T> = std::result::Result<T, HcsError>;

fn check(hr: i32, what: &str) -> Result<()> {
    if hr < 0 { Err(HcsError { hr, detail: what.into() }) } else { Ok(()) }
}

fn take(p: PWSTR) -> String {
    if p.is_null() {
        return String::new();
    }
    unsafe {
        let len = (0..).take_while(|&i| *p.add(i) != 0).count();
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, len));
        LocalFree(p.cast());
        s
    }
}

// HCS reports failures as a JSON document; only its message is worth keeping.
fn error_message(doc: &str) -> String {
    match serde_json::from_str::<Value>(doc) {
        Ok(v) => v["ErrorEvents"][0]["Message"].as_str().or(v["ErrorMessage"].as_str()).unwrap_or(doc).to_string(),
        Err(_) => doc.to_string(),
    }
}

struct Operation(HCS_OPERATION);

impl Operation {
    fn new() -> Result<Self> {
        let op = unsafe { HcsCreateOperation(std::ptr::null(), None) };
        if op.is_null() { Err(HcsError { hr: -2147024882, detail: "HcsCreateOperation".into() }) } else { Ok(Self(op)) }
    }

    fn run(what: &str, call: impl FnOnce(HCS_OPERATION) -> i32, timeout_ms: u32) -> Result<String> {
        let op = Self::new()?;
        let hr = call(op.0);
        let mut doc: PWSTR = std::ptr::null_mut();
        let waited = if hr >= 0 { unsafe { HcsWaitForOperationResult(op.0, timeout_ms, &mut doc) } } else { hr };
        let text = take(doc);
        if waited < 0 {
            let detail = if waited == HCS_E_OPERATION_TIMEOUT {
                format!("{what}: no answer in {} s", timeout_ms / 1000)
            } else if text.is_empty() {
                what.to_string()
            } else {
                format!("{what}: {}", error_message(&text))
            };
            return Err(HcsError { hr: waited, detail });
        }
        Ok(text)
    }
}

impl Drop for Operation {
    fn drop(&mut self) {
        unsafe { HcsCloseOperation(self.0) }
    }
}

/// A handle to one compute system; closing it does not stop the machine unless its document asks for that.
pub struct System(HCS_SYSTEM);

unsafe impl Send for System {}

const GENERIC_ALL: u32 = 0x1000_0000;

impl System {
    pub fn create(id: &str, document: &Value) -> Result<Self> {
        let wid = wide(id);
        let doc = wide(&document.to_string());
        let mut handle: HCS_SYSTEM = std::ptr::null_mut();
        let result = Operation::run("create", |op| unsafe { HcsCreateComputeSystem(wid.as_ptr(), doc.as_ptr(), op, std::ptr::null(), &mut handle) }, 60_000);
        // A handle can come back even when the operation fails: close it and end the half-made system so the id is free again.
        let system = (!handle.is_null()).then(|| Self(handle));
        match result {
            Ok(_) => system.ok_or(HcsError { hr: -2147467259, detail: "create: no handle".into() }),
            Err(e) => {
                if let Some(s) = system {
                    let _ = s.terminate();
                }
                Err(e)
            }
        }
    }

    pub fn open(id: &str) -> Result<Self> {
        let id = wide(id);
        let mut handle: HCS_SYSTEM = std::ptr::null_mut();
        check(unsafe { HcsOpenComputeSystem(id.as_ptr(), GENERIC_ALL, &mut handle) }, "HcsOpenComputeSystem")?;
        Ok(Self(handle))
    }

    pub fn start(&self) -> Result<()> {
        Operation::run("start", |op| unsafe { HcsStartComputeSystem(self.0, op, std::ptr::null()) }, 120_000).map(drop)
    }

    pub fn shut_down(&self, timeout_ms: u32) -> Result<()> {
        Operation::run("shut down", |op| unsafe { HcsShutDownComputeSystem(self.0, op, std::ptr::null()) }, timeout_ms).map(drop)
    }

    pub fn terminate(&self) -> Result<()> {
        Operation::run("terminate", |op| unsafe { HcsTerminateComputeSystem(self.0, op, std::ptr::null()) }, 60_000).map(drop)
    }

    pub fn modify(&self, request: &Value) -> Result<()> {
        let doc = wide(&request.to_string());
        Operation::run("modify", |op| unsafe { HcsModifyComputeSystem(self.0, op, doc.as_ptr(), std::ptr::null_mut()) }, 60_000).map(drop)
    }

    pub fn properties(&self) -> Result<Value> {
        let text = Operation::run("properties", |op| unsafe { HcsGetComputeSystemProperties(self.0, op, std::ptr::null()) }, 10_000)?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Null))
    }

    /// Some("Running" / "Paused" / ...), None once the system no longer exists, or the error when HCS didn't answer.
    pub fn state(&self) -> Result<Option<String>> {
        match self.properties() {
            Ok(v) => Ok(v["State"].as_str().map(String::from)),
            Err(e) if e.hr == HCS_E_SYSTEM_NOT_FOUND => Ok(None),
            Err(e) => Err(e),
        }
    }
}

impl Drop for System {
    fn drop(&mut self) {
        unsafe { HcsCloseComputeSystem(self.0) }
    }
}

pub fn enumerate() -> Result<Vec<Value>> {
    let text = Operation::run("enumerate", |op| unsafe { HcsEnumerateComputeSystems(std::ptr::null(), op) }, 10_000)?;
    Ok(serde_json::from_str::<Value>(&text).ok().and_then(|v| v.as_array().cloned()).unwrap_or_default())
}

/// Lets the machine's worker process (running as the machine's own identity) open a file it needs.
pub fn grant_access(vm: &str, file: &Path) -> Result<()> {
    check(unsafe { HcsGrantVmAccess(wide(vm).as_ptr(), wide_path(file).as_ptr()) }, "HcsGrantVmAccess")
}

pub fn revoke_access(vm: &str, file: &Path) -> Result<()> {
    check(unsafe { HcsRevokeVmAccess(wide(vm).as_ptr(), wide_path(file).as_ptr()) }, "HcsRevokeVmAccess")
}

pub fn create_guest_state_file(path: &Path) -> Result<()> {
    check(unsafe { HcsCreateEmptyGuestStateFile(wide_path(path).as_ptr()) }, "HcsCreateEmptyGuestStateFile")
}

pub fn create_runtime_state_file(path: &Path) -> Result<()> {
    check(unsafe { HcsCreateEmptyRuntimeStateFile(wide_path(path).as_ptr()) }, "HcsCreateEmptyRuntimeStateFile")
}

const GPU_PARTITION_ADAPTER: GUID = GUID::from_u128(0x064092b3_625e_43bf_9eb5_dc845897dd59);

/// Interface paths of the GPUs the host can share (the ids a GPU assignment names).
pub fn partitionable_gpus() -> Vec<String> {
    // The list can grow between the size and the read (a GPU re-enumerating): try again a few times.
    for _ in 0..3 {
        unsafe {
            let mut len = 0u32;
            if CM_Get_Device_Interface_List_SizeW(&mut len, &GPU_PARTITION_ADAPTER, std::ptr::null(), CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != CR_SUCCESS || len < 2 {
                return Vec::new();
            }
            let mut buf = vec![0u16; len as usize];
            match CM_Get_Device_Interface_ListW(&GPU_PARTITION_ADAPTER, std::ptr::null(), buf.as_mut_ptr(), len, CM_GET_DEVICE_INTERFACE_LIST_PRESENT) {
                CR_SUCCESS => return buf.split(|&c| c == 0).filter(|s| !s.is_empty()).map(String::from_utf16_lossy).collect(),
                CR_BUFFER_SMALL => continue,
                _ => return Vec::new(),
            }
        }
    }
    Vec::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_message_prefers_the_event_text() {
        let doc = r#"{"Error":-1,"ErrorMessage":"generic","ErrorEvents":[{"Message":"Unknown object field 'x'"}]}"#;
        assert_eq!(error_message(doc), "Unknown object field 'x'");
        assert_eq!(error_message(r#"{"ErrorMessage":"generic"}"#), "generic");
        assert_eq!(error_message("not json"), "not json");
    }

    #[test]
    fn error_shows_the_code_in_hex() {
        let e = HcsError { hr: 0x8037010Du32 as i32, detail: "invalid".into() };
        assert_eq!(e.to_string(), "0x8037010D invalid");
    }
}
