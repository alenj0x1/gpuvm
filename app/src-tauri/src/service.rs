//! The GpuVM service as Windows sees it: its state, and starting or stopping it. The installer lets users signed
//! in at this PC start and stop it (nothing else), so the app does it without a UAC prompt. Changing whether it
//! starts with Windows does need one (`gpuvm-host.exe startup`).

use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::System::Services::*;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

struct Sc(SC_HANDLE);
impl Drop for Sc {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseServiceHandle(self.0) };
        }
    }
}

fn open(access: u32) -> Option<Sc> {
    let scm = Sc(unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT) });
    if scm.0.is_null() {
        return None;
    }
    let svc = unsafe { OpenServiceW(scm.0, wide("GpuVM").as_ptr(), access) };
    (!svc.is_null()).then_some(Sc(svc))
}

pub struct Status {
    /// "running", "starting", "stopping", "stopped" or "missing" (not installed).
    pub state: &'static str,
    #[cfg_attr(debug_assertions, allow(dead_code))]
    pub pid: u32,
    /// Starts with Windows (otherwise only when the app starts it).
    pub with_windows: bool,
}

pub fn status() -> Status {
    let missing = Status { state: "missing", pid: 0, with_windows: false };
    let Some(svc) = open(SERVICE_QUERY_STATUS | SERVICE_QUERY_CONFIG) else { return missing };
    let mut s: SERVICE_STATUS_PROCESS = unsafe { std::mem::zeroed() };
    let mut needed = 0;
    if unsafe { QueryServiceStatusEx(svc.0, SC_STATUS_PROCESS_INFO, &mut s as *mut _ as *mut u8,
        std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32, &mut needed) } == 0
    {
        return missing;
    }
    let mut buf = vec![0u8; 8192];
    let with_windows = unsafe { QueryServiceConfigW(svc.0, buf.as_mut_ptr().cast(), buf.len() as u32, &mut needed) } != 0
        && unsafe { (*(buf.as_ptr() as *const QUERY_SERVICE_CONFIGW)).dwStartType } == SERVICE_AUTO_START;
    let state = match s.dwCurrentState {
        SERVICE_RUNNING => "running",
        SERVICE_START_PENDING => "starting",
        SERVICE_STOP_PENDING => "stopping",
        _ => "stopped",
    };
    Status { state, pid: if state == "running" { s.dwProcessId } else { 0 }, with_windows }
}

pub fn start() -> Result<(), String> {
    let svc = open(SERVICE_START).ok_or("No se pudo iniciar el servicio de GpuVM. Elige «Reparar».")?;
    if unsafe { StartServiceW(svc.0, 0, std::ptr::null()) } == 0 && unsafe { GetLastError() } != ERROR_SERVICE_ALREADY_RUNNING {
        return Err(format!("No se pudo iniciar el servicio de GpuVM (error {}).", unsafe { GetLastError() }));
    }
    Ok(())
}

/// Asks it to stop; it lets what is running finish first.
pub fn stop() -> Result<(), String> {
    let svc = open(SERVICE_STOP).ok_or("No se pudo detener el servicio de GpuVM.")?;
    let mut s: SERVICE_STATUS = unsafe { std::mem::zeroed() };
    if unsafe { ControlService(svc.0, SERVICE_CONTROL_STOP, &mut s) } == 0 && unsafe { GetLastError() } != ERROR_SERVICE_NOT_ACTIVE {
        return Err(format!("No se pudo detener el servicio de GpuVM (error {}).", unsafe { GetLastError() }));
    }
    Ok(())
}
