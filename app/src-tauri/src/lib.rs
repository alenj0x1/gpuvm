//! Connects the UI to the GpuVM module (PowerShell 7). The app runs without administrator: installed, the
//! GpuVM service does the elevated work (backend.rs).
//! - Quick queries go through one persistent connection, one at a time.
//! - Long jobs (create VM, start and open) use a connection each and emit "job" events with their progress,
//!   so they don't block the stats.
//! - Deleting machines or disks asks for a UAC confirmation first (the service requires it).

mod backend;
mod notices;
mod capture;
mod prompt;
mod service;
mod lowbox;
mod overlay;
mod dropzone;
mod clipboard;
mod viewer;
#[cfg(debug_assertions)]
mod direct;
mod dock;
mod agent;
mod status;
mod mcp;

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
    /// "GpuVM service" preference is "with GpuVM": the service stops when the app quits.
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
        Err("GpuVM stopped responding.".to_string())
    });
    match tokio::time::timeout(std::time::Duration::from_secs(180), work).await {
        Ok(Ok(result)) => result,
        Ok(Err(_)) => Err("GpuVM stopped responding.".into()),
        Err(_) => {
            if let Some(a) = aborter.lock().unwrap().take() {
                a.abort();
            }
            Err("That took too long; try again.".into())
        }
    }
}

fn recv_result(conn: &mut backend::Conn, request: &Value) -> Result<Value, String> {
    loop {
        let event = conn.next_event().ok_or("GpuVM stopped responding.")?;
        if event["type"] == "result" && event["id"] == request["id"] {
            return Ok(event);
        }
    }
}

pub(crate) fn into_data(result: Value) -> Result<Value, String> {
    if result["ok"] == json!(true) {
        Ok(result["data"].clone())
    } else {
        Err(result["error"].as_str().unwrap_or("Unknown error").to_string())
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
        backend::run_elevated(&exe, &parameters, "You canceled the administrator permission; nothing was deleted.")
    })
    .await
    .map_err(|e| e.to_string())??;
    if exit != 0 {
        return Err("Couldn't confirm the administrator permission; nothing was deleted.".into());
    }
    into_data(query(&state, json!({ "id": next_id(&state), "cmd": cmd, "args": args, "consent": code })).await?)
}

/// Starts a long job; progress arrives as "job" events with the same jobId.
#[tauri::command]
async fn job(app: AppHandle, job_id: String, cmd: String, args: Option<Value>) -> Result<(), String> {
    let mut args = args.unwrap_or(json!({}));
    // With GpuVM's viewer installed, the module gets the machine ready and this app opens the viewer itself.
    let with_viewer = cmd == "Connect-GpuVM" && viewer::viewer_path().is_some();
    if with_viewer {
        args["Viewer"] = json!(true);
    }
    let vm_name = args["Name"].as_str().unwrap_or("").to_string();
    let request = json!({ "id": job_id, "cmd": cmd, "args": args });
    let mut conn = tauri::async_runtime::spawn_blocking(backend::connect).await.map_err(|e| e.to_string())??;
    std::thread::spawn(move || {
        let emit = |mut event: Value| {
            event["jobId"] = json!(job_id);
            let _ = app.emit("job", event);
        };
        let mut outcome = conn.call(&request, |event| emit(event.clone()));
        // A job that destroys data (going back to a restore point, deleting one) waits for a UAC confirmation, as
        // ps does; the same request goes again with the code.
        if let Some(code) = outcome.as_ref().ok().and_then(|r| r["consent"].as_str()).map(str::to_string) {
            let confirmed = std::env::current_exe().map_err(|e| e.to_string()).and_then(|exe| {
                backend::run_elevated(&exe, &format!("--consent {code}"), "You canceled the administrator permission; nothing was deleted.")
            });
            outcome = match confirmed {
                Ok(0) => {
                    let mut again = request.clone();
                    again["consent"] = json!(code);
                    conn.call(&again, |event| emit(event.clone()))
                }
                Ok(_) => Ok(json!({ "type": "result", "ok": false, "error": "Couldn't confirm the administrator permission; nothing was deleted." })),
                Err(error) => Ok(json!({ "type": "result", "ok": false, "error": error })),
            };
        }
        match outcome {
            Ok(result) if with_viewer && result["ok"] == true && viewer::launch_in(&result["data"]).is_some() => {
                let launch = viewer::launch_in(&result["data"]).unwrap_or_default();
                let outcome = viewer::open_and_wait(&app, &vm_name, &launch);
                match outcome {
                    Ok(()) => emit(json!({ "type": "result", "ok": true, "data": null })),
                    Err(error) => emit(json!({ "type": "result", "ok": false, "error": error })),
                }
            }
            Ok(result) => emit(result),
            Err(_) => emit(json!({ "type": "result", "ok": false, "error": "The job ended without an answer." })),
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
    let host = exe.parent().map(|d| d.join("gpuvm-host.exe")).ok_or("no folder")?;
    if !host.exists() {
        return Err("Some GpuVM files are missing. Install it again.".into());
    }
    let exit = tauri::async_runtime::spawn_blocking(move || backend::run_elevated(&host, "install", "You canceled the administrator permission."))
        .await
        .map_err(|e| e.to_string())??;
    if exit == 0 { Ok(()) } else { Err("Couldn't repair the GpuVM service. Install GpuVM again.".into()) }
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

/// "GpuVM service" preference: `app` (starts with GpuVM, stops when it quits), `windows` (starts with
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
    let host = exe.parent().map(|d| d.join("gpuvm-host.exe")).ok_or("no folder")?;
    let mode = if with_windows { "startup auto" } else { "startup demand" };
    let exit = tauri::async_runtime::spawn_blocking(move || backend::run_elevated(&host, mode, "You canceled the administrator permission."))
        .await
        .map_err(|e| e.to_string())??;
    if exit == 0 { Ok(()) } else { Err("Couldn't change how the GpuVM service starts.".into()) }
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
pub(crate) fn show_main(app: &AppHandle) {
    use tauri::Manager;
    notices::leave(app);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

/// `--view <name>`: open that machine's picture, as its Open button does. Only a valid machine name passes; the page
/// checks it is one of the machines and does nothing else with it.
fn view_arg(args: &[String]) -> Option<String> {
    let i = args.iter().position(|a| a == "--view")?;
    let name = args.get(i + 1)?;
    (!name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')).then(|| name.clone())
}

/// A `--view` GpuVM was started with (no instance was running): the page takes it once it can open machines.
static PENDING_VIEW: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[tauri::command]
fn pending_view() -> Option<String> {
    PENDING_VIEW.lock().unwrap_or_else(|e| e.into_inner()).take()
}

/// The app's language for the few texts drawn by Rust (the tray menu): false Spanish, true English.
pub(crate) static ENGLISH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The app's language changed: the tray menu follows it.
#[tauri::command]
fn set_language(app: AppHandle, lang: String) -> Result<(), String> {
    ENGLISH.store(lang == "en", Ordering::Relaxed);
    if app.tray_by_id(TRAY_ID).is_some() {
        app.remove_tray_by_id(TRAY_ID);
    }
    refresh_tray(&app);
    Ok(())
}

/// The tray icon the app needs now: the notices-only one, the usual one when "When closing the window" keeps GpuVM in
/// the tray, or none.
pub(crate) fn refresh_tray(app: &AppHandle) {
    use tauri::Manager;
    let wanted = if notices::active() { Some(true) } else if app.state::<AppState>().close_to_tray.load(Ordering::Relaxed) { Some(false) } else { None };
    let current = *TRAY_KIND.lock().unwrap_or_else(|e| e.into_inner());
    if app.tray_by_id(TRAY_ID).is_some() && current == wanted {
        return;
    }
    app.remove_tray_by_id(TRAY_ID);
    *TRAY_KIND.lock().unwrap_or_else(|e| e.into_inner()) = None;
    if let Some(notices) = wanted {
        if ensure_tray(app, notices).is_ok() {
            *TRAY_KIND.lock().unwrap_or_else(|e| e.into_inner()) = wanted;
        }
    }
}

/// Which tray icon is up: Some(true) the notices-only one, Some(false) the usual one.
static TRAY_KIND: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);

/// Tray icon with "Open GpuVM" and "Quit" (or their Spanish); a left click opens the window. In notices-only mode
/// its tooltip says GpuVM is watching administrator prompts, and Quit ends GpuVM for good.
fn ensure_tray(app: &AppHandle, notices: bool) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem};
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    if app.tray_by_id(TRAY_ID).is_some() {
        return Ok(());
    }
    let en = ENGLISH.load(Ordering::Relaxed);
    let show = MenuItem::with_id(app, "show", if en { "Open GpuVM" } else { "Abrir GpuVM" }, true, None::<&str>)?;
    let quit = if notices {
        MenuItem::with_id(app, "quit-now", if en { "Stop watching and quit" } else { "Dejar de vigilar y salir" }, true, None::<&str>)?
    } else {
        MenuItem::with_id(app, "quit", if en { "Quit" } else { "Salir" }, true, None::<&str>)?
    };
    let menu = Menu::with_items(app, &[&show, &quit])?;
    let tooltip = match (notices, en) {
        (true, true) => "GpuVM · Watching administrator prompts",
        (true, false) => "GpuVM · Vigilando avisos de administrador",
        _ => "GpuVM",
    };
    let mut tray = TrayIconBuilder::with_id(TRAY_ID)
        .tooltip(tooltip)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => show_main(app),
            "quit" => notices::request_quit(app),
            "quit-now" => app.exit(0),
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

/// "When closing the window" preference: true keeps GpuVM in the tray, false quits completely.
#[tauri::command]
fn set_close_to_tray(app: AppHandle, state: State<'_, AppState>, enabled: bool) -> Result<(), String> {
    state.close_to_tray.store(enabled, Ordering::Relaxed);
    refresh_tray(&app);
    Ok(())
}

/// "When quitting GpuVM" preference: true shuts the GpuVM machines down when the app quits.
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

/// `gpuvm.exe --consent <code>` (elevated, after a UAC "Yes"): confirms a deletion to the service and exits.
pub fn consent(code: &str) -> i32 {
    backend::consent(code)
}

/// `gpuvm.exe --mcp`: the MCP server for agent clients (mcp/), until stdin closes.
pub fn mcp(fake: bool) -> i32 {
    mcp::run(fake)
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // A second launch (e.g. from the Start menu while GpuVM is in the tray) shows the open window instead.
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            show_main(app);
            // `gpuvm.exe --view <name>` (the MCP server's open_viewer) while GpuVM runs: open that machine's picture.
            if let Some(name) = view_arg(&args) {
                use tauri::Manager;
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.emit("open-viewer", name);
                }
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        // Until the page sends its preferences: the default "with GpuVM" (stop the service when the app quits).
        .manage(AppState { stop_service_on_quit: AtomicBool::new(true), ..Default::default() })
        .on_window_event(|window, event| {
            use tauri::Manager;
            // The viewer shown inside the app's window follows it.
            if window.label() == "main" && matches!(event, tauri::WindowEvent::Moved(_) | tauri::WindowEvent::Resized(_)) {
                viewer::follow_main(window.app_handle());
            }

            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    if window.state::<AppState>().close_to_tray.load(Ordering::Relaxed) {
                        let _ = window.hide();
                    } else {
                        // Quitting: GpuVM exits, or stays watching admin prompts (notices.rs).
                        notices::request_quit(window.app_handle());
                    }
                }
            }
        })
        .setup(|app| {
            prompt::start(app.handle().clone());
            agent::start(app.handle().clone());
            status::start(app.handle());
            *PENDING_VIEW.lock().unwrap_or_else(|e| e.into_inner()) = view_arg(&std::env::args().collect::<Vec<_>>());
            clipboard::start(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![ps, job, prompt::admin_prompts, prompt::card_answer, dock::dock_prompt, dock::dock_answer, agent::agent_dock_request, agent::agent_dock_answer, status::status_resize, status::status_state, status::status_action, status::set_status_prefs, agent::set_agent_prefs, agent::mcp_exe_path, agent::agent_recordings, pending_view, viewer::viewer_send, viewer::viewer_is_open, viewer::viewer_home, viewer::viewer_show, viewer::viewer_list, viewer::viewer_reveal, viewer::viewer_covered, overlay::viewer_panel_resize, overlay::viewer_panel_close, overlay::viewer_panel_vm, dropzone::transfer_start, dropzone::transfer_cancel, dropzone::transfer_list, dropzone::viewer_drop_hide, dropzone::viewer_drop_state, clipboard::clipboard_items, clipboard::clipboard_send, clipboard::clipboard_auto, clipboard::clipboard_clear, capture::set_capture_prefs, capture::capture_folders, capture::capture_open, capture::capture_reveal, capture::capture_open_folder, capture::capture_state, capture::capture_get_hevc, open_console, repair_service, relaunch_as_admin, service_status, start_service, stop_service, set_service_mode, set_service_startup, set_close_to_tray, set_stop_vms_on_quit, set_language, notices::set_notices_after_quit])
        .build(tauri::generate_context!())
        .expect("failed to start GpuVM")
        .run(|app, event| {
            use tauri::Manager;
            // The last window closed by notices-only mode is not a quit: only app.exit (a code) ends it.
            if let tauri::RunEvent::ExitRequested { api, code: None, .. } = &event {
                if notices::active() {
                    api.prevent_exit();
                }
            }
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
