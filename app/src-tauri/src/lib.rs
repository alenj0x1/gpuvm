//! Connects the UI to the GpuVM module (PowerShell 7). The app runs without administrator: installed, the
//! GpuVM service does the elevated work (backend.rs).
//! - Quick queries go through one persistent connection, one at a time.
//! - Long jobs (create VM, start and open) use a connection each and emit "job" events with their progress,
//!   so they don't block the stats.
//! - Deleting machines or disks asks for a UAC confirmation first (the service requires it).

mod backend;
mod prompt;
mod service;
#[cfg(debug_assertions)]
mod direct;

use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, State};

#[link(name = "kernel32")]
extern "system" {
    fn GetSystemDirectoryW(buffer: *mut u16, size: u32) -> u32;
}

pub(crate) fn wide_to_path(wide: &[u16]) -> PathBuf {
    use std::os::windows::ffi::OsStringExt;
    PathBuf::from(std::ffi::OsString::from_wide(wide))
}

// System folders come from Windows itself, never from environment variables, which any program of the user can
// change to point at its own files.
fn system_directory() -> PathBuf {
    let mut buffer = [0u16; 260];
    // SAFETY: the buffer holds 260 UTF-16 units and Windows writes at most that many.
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if len == 0 || len >= buffer.len() { PathBuf::from(r"C:\Windows\System32") } else { wide_to_path(&buffer[..len]) }
}

/// Windows tools by absolute path in System32, never a copy found earlier in the PATH.
pub(crate) fn system32(exe: &str) -> PathBuf {
    system_directory().join(exe)
}

#[derive(Default)]
pub(crate) struct AppState {
    conn: Arc<std::sync::Mutex<Option<backend::Conn>>>,
    counter: std::sync::atomic::AtomicU64,
    close_to_tray: AtomicBool,
    stop_vms_on_quit: AtomicBool,
    /// "Servicio de GpuVM" preference is "with GpuVM": the service stops when the app quits.
    stop_service_on_quit: AtomicBool,
}

pub(crate) fn next_id(state: &AppState) -> String {
    format!("q{}", state.counter.fetch_add(1, Ordering::Relaxed) + 1)
}

/// One request on the persistent connection (opened again if it was lost). Gives up after 180 s.
pub(crate) async fn query(state: &AppState, request: Value) -> Result<Value, String> {
    let conn = state.conn.clone();
    let aborter: Arc<std::sync::Mutex<Option<backend::Aborter>>> = Arc::default();
    let waiting = aborter.clone();
    let work = tauri::async_runtime::spawn_blocking(move || {
        let mut guard = conn.lock().unwrap_or_else(|e| e.into_inner());
        for attempt in 0..2 {
            if guard.is_none() {
                *guard = Some(backend::connect()?);
            }
            let c = guard.as_mut().unwrap();
            if c.send(&request).is_err() {
                // The connection was lost while idle: open it again once. Once the request is sent it is not
                // retried: it may already have been applied (shutdown, delete…).
                *guard = None;
                if attempt == 0 { continue; }
                break;
            }
            *waiting.lock().unwrap() = Some(c.aborter());
            let result = recv_result(c, &request);
            *waiting.lock().unwrap() = None;
            if result.is_err() {
                *guard = None;
            }
            return result;
        }
        Err("GpuVM dejó de responder.".to_string())
    });
    match tokio::time::timeout(std::time::Duration::from_secs(180), work).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err("GpuVM dejó de responder.".into()),
        Err(_) => {
            if let Some(a) = aborter.lock().unwrap().take() {
                a.abort();
            }
            Err("La operación tardó demasiado; vuelve a intentarlo.".into())
        }
    }
}

fn recv_result(conn: &mut backend::Conn, request: &Value) -> Result<Value, String> {
    loop {
        let event = conn.next_event().ok_or("GpuVM dejó de responder.")?;
        if event["type"] == "result" && event["id"] == request["id"] {
            return Ok(event);
        }
    }
}

pub(crate) fn into_data(result: Value) -> Result<Value, String> {
    if result["ok"] == json!(true) {
        Ok(result["data"].clone())
    } else {
        Err(result["error"].as_str().unwrap_or("Error desconocido").to_string())
    }
}

/// Runs a module function and returns its result (list of objects).
#[tauri::command]
async fn ps(state: State<'_, AppState>, cmd: String, args: Option<Value>) -> Result<Value, String> {
    let args = args.unwrap_or(json!({}));
    let result = query(&state, json!({ "id": next_id(&state), "cmd": cmd, "args": args })).await?;
    let Some(code) = result["consent"].as_str().map(str::to_string) else { return into_data(result) };
    // The service asks for a UAC confirmation (deleting machines or disks): the elevated copy of this program
    // confirms it, and the same request goes again with the code.
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let parameters = format!("--consent {code}");
    let exit = tauri::async_runtime::spawn_blocking(move || {
        backend::run_elevated(&exe, &parameters, "Cancelaste el permiso de administrador; no se borró nada.")
    })
    .await
    .map_err(|e| e.to_string())??;
    if exit != 0 {
        return Err("No se pudo confirmar el permiso de administrador; no se borró nada.".into());
    }
    into_data(query(&state, json!({ "id": next_id(&state), "cmd": cmd, "args": args, "consent": code })).await?)
}

/// Starts a long job; progress arrives as "job" events with the same jobId.
#[tauri::command]
async fn job(app: AppHandle, job_id: String, cmd: String, args: Option<Value>) -> Result<(), String> {
    let request = json!({ "id": job_id, "cmd": cmd, "args": args.unwrap_or(json!({})) });
    let mut conn = tauri::async_runtime::spawn_blocking(backend::connect).await.map_err(|e| e.to_string())??;
    std::thread::spawn(move || {
        let emit = |mut event: Value| {
            event["jobId"] = json!(job_id);
            let _ = app.emit("job", event);
        };
        match conn.call(&request, |event| emit(event.clone())) {
            Ok(result) => emit(result),
            Err(_) => emit(json!({ "type": "result", "ok": false, "error": "El trabajo terminó sin respuesta." })),
        }
    });
    Ok(())
}

/// Opens the VM's Hyper-V console.
#[tauri::command]
fn open_console(name: String) -> Result<(), String> {
    std::process::Command::new(system32("vmconnect.exe"))
        .args(["localhost", &name])
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Installs the GpuVM service again and starts it (UAC prompt): the fix when it was removed or stopped.
#[tauri::command]
async fn repair_service() -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let host = exe.parent().map(|d| d.join("gpuvm-host.exe")).ok_or("sin carpeta")?;
    if !host.exists() {
        return Err("Faltan archivos de GpuVM. Vuelve a instalarlo.".into());
    }
    let exit = tauri::async_runtime::spawn_blocking(move || backend::run_elevated(&host, "install", "Cancelaste el permiso de administrador."))
        .await
        .map_err(|e| e.to_string())??;
    if exit == 0 { Ok(()) } else { Err("No se pudo reparar el servicio de GpuVM. Vuelve a instalar GpuVM.".into()) }
}

/// State of the GpuVM service: `{ state, withWindows }` (state: running, starting, stopping, stopped, missing).
#[tauri::command]
fn service_status() -> Value {
    let s = service::status();
    json!({ "state": s.state, "withWindows": s.with_windows })
}

#[tauri::command]
async fn start_service() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(service::start).await.map_err(|e| e.to_string())?
}

#[tauri::command]
async fn stop_service(state: State<'_, AppState>) -> Result<(), String> {
    // Close the app's own idle connection, so nothing of GpuVM keeps the service busy.
    *state.conn.lock().unwrap_or_else(|e| e.into_inner()) = None;
    tauri::async_runtime::spawn_blocking(service::stop).await.map_err(|e| e.to_string())?
}

/// "Servicio de GpuVM" preference: `app` (starts with GpuVM, stops when it quits), `windows` (starts with
/// Windows) or `manual` (only from Preferences).
#[tauri::command]
fn set_service_mode(state: State<'_, AppState>, mode: String) {
    backend::AUTO_START.store(mode != "manual", Ordering::Relaxed);
    state.stop_service_on_quit.store(mode == "app", Ordering::Relaxed);
}

/// Makes the service start with Windows, or only on demand (UAC prompt: it changes the service's settings).
#[tauri::command]
async fn set_service_startup(with_windows: bool) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let host = exe.parent().map(|d| d.join("gpuvm-host.exe")).ok_or("sin carpeta")?;
    let mode = if with_windows { "startup auto" } else { "startup demand" };
    let exit = tauri::async_runtime::spawn_blocking(move || backend::run_elevated(&host, mode, "Cancelaste el permiso de administrador."))
        .await
        .map_err(|e| e.to_string())??;
    if exit == 0 { Ok(()) } else { Err("No se pudo cambiar cómo inicia el servicio de GpuVM.".into()) }
}

/// Development only: relaunches the app as administrator (it starts the bridge itself) and closes this instance.
#[tauri::command]
fn relaunch_as_admin(app: AppHandle) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    std::thread::spawn(move || backend::run_elevated(&exe, "", ""));
    std::thread::sleep(std::time::Duration::from_millis(500));
    app.exit(0);
    Ok(())
}

/// Brings the main window back (from the tray, minimized or behind other windows).
fn show_main(app: &AppHandle) {
    use tauri::Manager;
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// Tray icon with "Abrir GpuVM" and "Salir"; a left click opens the window.
fn ensure_tray(app: &AppHandle) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    if app.tray_by_id(TRAY_ID).is_some() {
        return Ok(());
    }
    let show = MenuItem::with_id(app, "show", "Abrir GpuVM", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Salir", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&show, &quit])?;
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip("GpuVM")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => show_main(app),
            "quit" => app.exit(0),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        tray = tray.icon(icon.clone());
    }
    tray.build(app)?;
    Ok(())
}

const TRAY_ID: &str = "main";

/// "Al cerrar la ventana" preference: true keeps GpuVM in the tray, false quits completely.
#[tauri::command]
fn set_close_to_tray(app: AppHandle, state: State<'_, AppState>, enabled: bool) -> Result<(), String> {
    state.close_to_tray.store(enabled, Ordering::Relaxed);
    if enabled {
        ensure_tray(&app).map_err(|e| e.to_string())
    } else {
        app.remove_tray_by_id(TRAY_ID);
        Ok(())
    }
}

/// "Al cerrar GpuVM" preference: true shuts the GpuVM machines down when the app quits.
#[tauri::command]
fn set_stop_vms_on_quit(state: State<'_, AppState>, enabled: bool) {
    state.stop_vms_on_quit.store(enabled, Ordering::Relaxed);
}


/// Shuts the running GpuVM machines down: the request is sent and the app quits at once; the service finishes it
/// (each VM still gets a clean Windows shutdown).
fn stop_vms_in_background() {
    let Ok(mut conn) = backend::connect() else { return };
    if conn.send(&json!({ "id": "quit", "cmd": "Stop-GpuVMAll", "args": {} })).is_ok() {
        conn.detach();
    }
}

/// Asks the service to stop once GpuVM's last connection closes: requests still running (shutting the machines
/// down, a VM being created) finish first.
fn stop_service_when_idle() {
    let Some(mut conn) = backend::connect_existing() else { return };
    if conn.send(&json!({ "control": "stop-when-idle" })).is_ok() {
        let _ = conn.next_event();
    }
}

use std::sync::atomic::{AtomicBool, Ordering};

/// `gpuvm.exe --consent <code>` (elevated, after a UAC "Sí"): confirms a deletion to the service and exits.
pub fn consent(code: &str) -> i32 {
    backend::consent(code)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // A second launch (e.g. from the Start menu while GpuVM is in the tray) shows the open window instead.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_dialog::init())
        // Until the page sends its preferences: the default "with GpuVM" (stop the service when the app quits).
        .manage(AppState { stop_service_on_quit: AtomicBool::new(true), ..Default::default() })
        .on_window_event(|window, event| {
            use tauri::Manager;
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.state::<AppState>().close_to_tray.load(Ordering::Relaxed) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .setup(|app| {
            prompt::start(app.handle().clone());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![ps, job, prompt::admin_prompts, prompt::admin_prompt_answered, open_console, repair_service, relaunch_as_admin, service_status, start_service, stop_service, set_service_mode, set_service_startup, set_close_to_tray, set_stop_vms_on_quit])
        .build(tauri::generate_context!())
        .expect("failed to start GpuVM")
        .run(|app, event| {
            use tauri::Manager;
            // Quitting from the window or the tray; hiding to the tray does not get here.
            if let tauri::RunEvent::Exit = event {
                let state = app.state::<AppState>();
                if state.stop_vms_on_quit.load(Ordering::Relaxed) {
                    stop_vms_in_background();
                }
                if state.stop_service_on_quit.load(Ordering::Relaxed) {
                    stop_service_when_idle();
                }
            }
        });
}
