//! gpuvm-host: GpuVM's elevated half. The GpuVM window runs without administrator (so other programs, like
//! Console UI, can drive it); this Windows service does the Hyper-V work for it. See server.rs.
//!
//!   gpuvm-host service     run by the Service Control Manager
//!   gpuvm-host install     register (or update) the service; the installer calls it
//!   gpuvm-host stop        stop it, so the installer can replace its files
//!   gpuvm-host startup auto|demand   start it with Windows, or only when the app does (UAC from the app)
//!   gpuvm-host uninstall   stop and remove it

#![windows_subsystem = "windows"]

mod agent;
mod agent_log;
mod agent_pipe;
mod hv;
mod offer;
mod server;
mod win;
mod wire;

use std::ffi::c_void;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::time::Duration;

use windows_sys::core::PWSTR;
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Security::Authorization::*;
use windows_sys::Win32::Security::DACL_SECURITY_INFORMATION;
use windows_sys::Win32::System::Services::*;

use win::{last_error, wide};

const SERVICE: &str = "GpuVM";

// ---------------------------------------------------------------- running as a service

static STATUS: AtomicPtr<c_void> = AtomicPtr::new(std::ptr::null_mut());

fn set_state(state: SERVICE_STATUS_CURRENT_STATE, checkpoint: u32) {
    let status = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS,
        dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING { SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN } else { 0 },
        dwWin32ExitCode: 0,
        dwServiceSpecificExitCode: 0,
        dwCheckPoint: checkpoint,
        dwWaitHint: if state == SERVICE_STOP_PENDING { 30_000 } else { 0 },
    };
    unsafe { SetServiceStatus(STATUS.load(Ordering::SeqCst), &status) };
}

/// Ends the service now; the bridges' job object takes them with it.
pub fn stop_now() -> ! {
    set_state(SERVICE_STOPPED, 0);
    std::thread::sleep(Duration::from_millis(100));
    std::process::exit(0);
}

unsafe extern "system" fn control(code: u32, _: u32, _: *mut c_void, _: *mut c_void) -> u32 {
    if code == SERVICE_CONTROL_SHUTDOWN {
        // Windows is shutting down: Hyper-V shuts the machines down by itself.
        std::thread::spawn(|| stop_now());
    } else if code == SERVICE_CONTROL_STOP {
        // Stopping from the app or Windows: a job that changes machines (a VM being created, shutting them down)
        // finishes first, up to 10 minutes; reading requests and agent requests get 5 s (a hung Get-* or a long
        // agent request no longer holds the stop). New requests are refused meanwhile. Then the service ends and
        // its job object ends every bridge with it, idle or hung. The installer bounds it further (stop_and_wait).
        server::STOPPING.store(true, Ordering::SeqCst);
        let long = 600;
        std::thread::spawn(move || {
            let start = std::time::Instant::now();
            let mut checkpoint = 1;
            let mut wait = |counter: &std::sync::atomic::AtomicUsize, limit: u64| {
                let since = std::time::Instant::now();
                while counter.load(Ordering::SeqCst) > 0 && since.elapsed() < Duration::from_secs(limit) {
                    set_state(SERVICE_STOP_PENDING, checkpoint);
                    checkpoint += 1;
                    std::thread::sleep(Duration::from_millis(250));
                }
            };
            wait(&server::BUSY, long);
            wait(&server::QUICK, 5);
            let (busy, quick) = (server::BUSY.load(Ordering::SeqCst), server::QUICK.load(Ordering::SeqCst));
            if busy + quick > 0 {
                server::log(&format!("stopping after {:.1} s with {busy} job(s) and {quick} request(s) still running: ended", start.elapsed().as_secs_f64()));
            }
            stop_now();
        });
    }
    NO_ERROR
}

unsafe extern "system" fn service_main(_: u32, _: *mut PWSTR) {
    let name = wide(SERVICE);
    STATUS.store(RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(control), std::ptr::null()), Ordering::SeqCst);
    set_state(SERVICE_RUNNING, 0);
    std::thread::spawn(server::serve);
}

// ---------------------------------------------------------------- install / stop / uninstall

struct ScHandle(SC_HANDLE);
impl Drop for ScHandle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CloseServiceHandle(self.0) };
        }
    }
}

fn manager() -> Result<ScHandle, String> {
    let h = unsafe { OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_ALL_ACCESS) };
    if h.is_null() { Err(last_error("OpenSCManagerW")) } else { Ok(ScHandle(h)) }
}

fn open_service(scm: &ScHandle) -> Option<ScHandle> {
    let h = unsafe { OpenServiceW(scm.0, wide(SERVICE).as_ptr(), SERVICE_ALL_ACCESS) };
    (!h.is_null()).then_some(ScHandle(h))
}


fn stop_and_wait(svc: &ScHandle) {
    let process_info = || {
        let mut info: SERVICE_STATUS_PROCESS = unsafe { std::mem::zeroed() };
        let mut needed = 0;
        let ok = unsafe {
            QueryServiceStatusEx(svc.0, SC_STATUS_PROCESS_INFO, &mut info as *mut _ as *mut u8, std::mem::size_of::<SERVICE_STATUS_PROCESS>() as u32, &mut needed)
        };
        (ok != 0).then_some(info)
    };
    // The process asked to stop: a service started again meanwhile (another process id) is never touched.
    let asked = process_info().map(|i| i.dwProcessId).unwrap_or(0);
    let mut status: SERVICE_STATUS = unsafe { std::mem::zeroed() };
    unsafe { ControlService(svc.0, SERVICE_CONTROL_STOP, &mut status) };
    // The installer (and install/uninstall) waits 30 s for what is running to finish, then ends the service's
    // process: its job object takes every bridge with it. An upgrade never hangs on a stuck PowerShell.
    for _ in 0..300 {
        match process_info() {
            Some(i) if i.dwCurrentState == SERVICE_STOPPED || i.dwProcessId != asked => return,
            None => return,
            _ => {}
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let info = process_info().filter(|i| i.dwProcessId == asked && i.dwCurrentState != SERVICE_STOPPED);
    if let Some(info) = info.filter(|i| i.dwProcessId != 0) {
        end_process(info.dwProcessId);
        server::log(&format!("the service didn't stop in 30 s (state {}); its process {} was ended", info.dwCurrentState, info.dwProcessId));
    }
    // Windows restarts a service whose process ended without stopping (its recovery actions, 2 s later). That new
    // instance is stopped too, and ended if it doesn't stop within 5 s: returning while one runs leaves the installer
    // unable to replace gpuvm-host.exe, and in silent mode the old service just stays (lab 053 part 7, 2026-11-20).
    let mut other: Option<(u32, std::time::Instant)> = None;
    for _ in 0..450 {
        match process_info() {
            Some(i) if i.dwCurrentState == SERVICE_STOPPED => return,
            None => return,
            Some(i) if i.dwProcessId != asked && i.dwProcessId != 0 => {
                let since = match other {
                    Some((pid, t)) if pid == i.dwProcessId => t,
                    _ => {
                        let t = std::time::Instant::now();
                        other = Some((i.dwProcessId, t));
                        t
                    }
                };
                if i.dwCurrentState == SERVICE_RUNNING {
                    unsafe { ControlService(svc.0, SERVICE_CONTROL_STOP, &mut status) };
                }
                if since.elapsed() > Duration::from_secs(5) {
                    end_process(i.dwProcessId);
                    server::log(&format!("the restarted service (process {}) didn't stop in 5 s; it was ended", i.dwProcessId));
                    other = None;
                }
            }
            _ => {}
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    server::log("the service is still running after 75 s of stopping it; its files may not be replaced");
}

/// Ends a process and waits (up to 10 s) until it is gone, so its exe can be replaced.
fn end_process(pid: u32) {
    use windows_sys::Win32::System::Threading::{OpenProcess, TerminateProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE};
    let process = unsafe { OpenProcess(PROCESS_TERMINATE | PROCESS_SYNCHRONIZE, 0, pid) };
    if process.is_null() {
        return;
    }
    unsafe {
        TerminateProcess(process, 1);
        WaitForSingleObject(process, 10_000);
        CloseHandle(process);
    }
}

fn install() -> Result<(), String> {
    let scm = manager()?;
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let bin = wide(&format!("\"{}\" service", exe.display()));
    let svc = match open_service(&scm) {
        Some(svc) => {
            stop_and_wait(&svc);
            // The start type stays as the user chose it in GpuVM's preferences.
            if unsafe { ChangeServiceConfigW(svc.0, SERVICE_WIN32_OWN_PROCESS, SERVICE_NO_CHANGE, SERVICE_ERROR_NORMAL, bin.as_ptr(),
                std::ptr::null(), std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), wide("GpuVM").as_ptr()) } == 0
            {
                return Err(last_error("ChangeServiceConfigW"));
            }
            svc
        }
        None => {
            // LocalSystem (no account): it needs to start each user's bridge with their own elevated token.
            // On demand: the app starts it when it opens and stops it when it quits.
            let h = unsafe {
                CreateServiceW(scm.0, wide(SERVICE).as_ptr(), wide("GpuVM").as_ptr(), SERVICE_ALL_ACCESS, SERVICE_WIN32_OWN_PROCESS,
                    SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL, bin.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null(),
                    std::ptr::null(), std::ptr::null())
            };
            if h.is_null() {
                return Err(last_error("CreateServiceW"));
            }
            ScHandle(h)
        }
    };
    let mut description = wide("Does the Hyper-V work for the GpuVM app, which opens without administrator rights.");
    let info = SERVICE_DESCRIPTIONW { lpDescription: description.as_mut_ptr() };
    unsafe { ChangeServiceConfig2W(svc.0, SERVICE_CONFIG_DESCRIPTION, &info as *const _ as *const c_void) };
    // If it ever crashes, Windows starts it again (after 2 s, then 10 s; the counter resets after a day).
    let mut actions = [
        SC_ACTION { Type: SC_ACTION_RESTART, Delay: 2000 },
        SC_ACTION { Type: SC_ACTION_RESTART, Delay: 10000 },
        SC_ACTION { Type: SC_ACTION_RESTART, Delay: 10000 },
    ];
    let failure = SERVICE_FAILURE_ACTIONSW {
        dwResetPeriod: 86400,
        lpRebootMsg: std::ptr::null_mut(),
        lpCommand: std::ptr::null_mut(),
        cActions: actions.len() as u32,
        lpsaActions: actions.as_mut_ptr(),
    };
    unsafe { ChangeServiceConfig2W(svc.0, SERVICE_CONFIG_FAILURE_ACTIONS, &failure as *const _ as *const c_void) };
    // Users signed in at this PC may start and stop it (the app does, without a UAC prompt), nothing more:
    // changing or removing it stays with administrators.
    let sddl = wide("D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWRPWPLOCRRC;;;IU)(A;;CCLCSWLOCRRC;;;SU)");
    let mut sd = std::ptr::null_mut();
    if unsafe { ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut sd, std::ptr::null_mut()) } == 0
        || unsafe { SetServiceObjectSecurity(svc.0, DACL_SECURITY_INFORMATION, sd) } == 0
    {
        return Err(last_error("SetServiceObjectSecurity"));
    }
    unsafe { LocalFree(sd) };
    // The agent channel's Hyper-V socket name (guests can only dial registered names). The service checks it too.
    agent::register_service_id()?;
    Ok(())
}

/// `startup auto|demand`: with Windows, or only when the app starts it.
fn startup(mode: Option<&str>) -> Result<(), String> {
    let start = match mode {
        Some("auto") => SERVICE_AUTO_START,
        Some("demand") => SERVICE_DEMAND_START,
        _ => return Err("usage: gpuvm-host startup auto|demand".into()),
    };
    let svc = open_service(&manager()?).ok_or("The GpuVM service isn't installed.")?;
    let n = std::ptr::null();
    if unsafe { ChangeServiceConfigW(svc.0, SERVICE_NO_CHANGE, start, SERVICE_NO_CHANGE, n, n, std::ptr::null_mut(), n, n, n, n) } == 0 {
        return Err(last_error("ChangeServiceConfigW"));
    }
    Ok(())
}

fn stop() -> Result<(), String> {
    if let Some(svc) = open_service(&manager()?) {
        stop_and_wait(&svc);
    }
    Ok(())
}

fn uninstall() -> Result<(), String> {
    if let Some(svc) = open_service(&manager()?) {
        stop_and_wait(&svc);
        if unsafe { DeleteService(svc.0) } == 0 {
            return Err(last_error("DeleteService"));
        }
    }
    agent::unregister_service_id();
    Ok(())
}

fn main() {
    let result = match std::env::args().nth(1).as_deref() {
        Some("service") => {
            let mut name = wide(SERVICE);
            let table = [
                SERVICE_TABLE_ENTRYW { lpServiceName: name.as_mut_ptr(), lpServiceProc: Some(service_main) },
                SERVICE_TABLE_ENTRYW { lpServiceName: std::ptr::null_mut(), lpServiceProc: None },
            ];
            if unsafe { StartServiceCtrlDispatcherW(table.as_ptr()) } == 0 { Err(last_error("StartServiceCtrlDispatcherW")) } else { Ok(()) }
        }
        Some("install") => install(),
        Some("stop") => stop(),
        Some("startup") => startup(std::env::args().nth(2).as_deref()),
        Some("uninstall") => uninstall(),
        // Removes the agent registrations and secrets of VMs that no longer exist (what the service does at start
        // and every hour), from an elevated prompt.
        Some("sweep-agents") => {
            for vm in agent::sweep_registrations() {
                server::log(&format!("sweep-agents: {vm}"));
            }
            Ok(())
        }
        // Debug builds only (lab 052): the agent broker alone, run as SYSTEM next to an installed service that
        // doesn't have it yet. Release builds don't have this command.
        #[cfg(debug_assertions)]
        Some("broker") => {
            agent::start();
            loop {
                std::thread::sleep(Duration::from_secs(3600));
            }
        }
        _ => Err("usage: gpuvm-host install | stop | uninstall".into()),
    };
    if let Err(e) = result {
        server::log(&e);
        std::process::exit(1);
    }
}
