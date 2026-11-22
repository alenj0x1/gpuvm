mod backend;
mod diag;
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
mod claude;
mod live;
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

// System folders come from Windows, never from environment variables any program of the user can change.
fn system_directory() -> PathBuf {
    let mut buffer = [0u16; 260];
    // SAFETY: the buffer holds 260 UTF-16 units and Windows writes at most that many.
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if len == 0 || len >= buffer.len() { PathBuf::from(r"C:\Windows\System32") } else { wide_to_path(&buffer[..len]) }
}

pub(crate) fn system32(exe: &str) -> PathBuf {
    system_directory().join(exe)
}

#[derive(Default)]
pub(crate) struct AppState {
    conn: Arc<std::sync::Mutex<Option<backend::Conn>>>,
    counter: std::sync::atomic::AtomicU64,
    close_to_tray: AtomicBool,
    stop_vms_on_quit: AtomicBool,
    stop_service_on_quit: AtomicBool,
}

pub(crate) fn next_id(state: &AppState) -> String {
    format!("q{}", state.counter.fetch_add(1, Ordering::Relaxed) + 1)
}

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
                // Lost while idle: reopen once. Once sent it is never retried: it may already have been applied.
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

pub(crate) fn recv_result(conn: &mut backend::Conn, request: &Value) -> Result<Value, String> {
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

// The side panel sits over a machine an agent may drive: nothing that creates, deletes, changes a machine or answers a request.
const PANEL_PS: &[&str] = &[
    "Get-GpuVMOverview", "Get-GpuVMExplorerSelection",
    "Get-GpuVMAgentClient", "Get-GpuVMAgentRequest", "Get-GpuVMAgentOffer", "Get-GpuVMAgentSettings", "Get-GpuVMAgentBroker",
    "Get-GpuVMAgentCapture", "Suspend-GpuVMAgent", "Resume-GpuVMAgent", "Stop-GpuVMAgentClient",
];

fn ps_allowed(window: &str, cmd: &str) -> bool {
    match window {
        "main" => true,
        overlay::LABEL => PANEL_PS.contains(&cmd),
        _ => false,
    }
}

#[tauri::command]
async fn ps(webview: tauri::WebviewWindow, state: State<'_, AppState>, cmd: String, args: Option<Value>) -> Result<Value, String> {
    let result = ps_run(webview, state, &cmd, args).await;
    // Reads that fail are logged by the page if it shows them: one in flight while a machine is renamed isn't an error.
    if let (Err(e), false) = (&result, cmd.starts_with("Get-")) {
        diag::log_error(&cmd, e);
    }
    result
}

async fn ps_run(webview: tauri::WebviewWindow, state: State<'_, AppState>, cmd: &str, args: Option<Value>) -> Result<Value, String> {
    if !ps_allowed(webview.label(), &cmd) {
        return Err("This window can't do that.".into());
    }
    let args = args.unwrap_or(json!({}));
    let result = query(&state, json!({ "id": next_id(&state), "cmd": cmd, "args": args })).await?;
    let Some(code) = result["consent"].as_str().map(str::to_string) else { return into_data(result) };
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

#[tauri::command]
async fn job(app: AppHandle, job_id: String, cmd: String, args: Option<Value>) -> Result<(), String> {
    let mut args = args.unwrap_or(json!({}));
    let with_viewer = cmd == "Connect-GpuVM" && viewer::viewer_path().is_some();
    if with_viewer {
        args["Viewer"] = json!(true);
    }
    let vm_name = args["Name"].as_str().unwrap_or("").to_string();
    let request = json!({ "id": job_id, "cmd": cmd, "args": args });
    let mut conn = tauri::async_runtime::spawn_blocking(backend::connect).await.map_err(|e| e.to_string())??;
    std::thread::spawn(move || {
        let emit = |mut event: Value| {
            if event["type"] == "result" && event["ok"] == false {
                diag::log_error(request["cmd"].as_str().unwrap_or("job"), event["error"].as_str().unwrap_or("Unknown error"));
            }
            event["jobId"] = json!(job_id);
            let _ = app.emit("job", event);
        };
        let lock = with_viewer.then(|| viewer::opening_lock(&vm_name));
        let _opening = lock.as_ref().map(|l| l.lock().unwrap_or_else(|e| e.into_inner()));
        if with_viewer && request["args"]["Pair"] != true && viewer::viewer_is_open(vm_name.clone()) {
            emit(json!({ "type": "result", "ok": true, "data": null }));
            return;
        }
        if with_viewer {
            viewer::publish_state(&vm_name, "preparing");
        }
        let mut outcome = conn.call(&request, |event| emit(event.clone()));
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
            Ok(result) => {
                if with_viewer && result["ok"] != true {
                    viewer::publish_state(&vm_name, "failed");
                }
                emit(result)
            }
            Err(_) => {
                if with_viewer {
                    viewer::publish_state(&vm_name, "failed");
                }
                emit(json!({ "type": "result", "ok": false, "error": "The job ended without an answer." }))
            }
        }
    });
    Ok(())
}

#[tauri::command]
fn open_console(name: String) -> Result<(), String> {
    std::process::Command::new(system32("vmconnect.exe"))
        .args(["localhost", &name])
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

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
    *state.conn.lock().unwrap_or_else(|e| e.into_inner()) = None;
    tauri::async_runtime::spawn_blocking(service::stop).await.map_err(|e| e.to_string())?
}

#[tauri::command]
fn set_service_mode(state: State<'_, AppState>, mode: String) {
    backend::AUTO_START.store(mode != "manual", Ordering::Relaxed);
    state.stop_service_on_quit.store(mode == "app", Ordering::Relaxed);
}

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

#[tauri::command]
fn relaunch_as_admin(app: AppHandle) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    std::thread::spawn(move || backend::run_elevated(&exe, "", ""));
    std::thread::sleep(std::time::Duration::from_millis(500));
    app.exit(0);
    Ok(())
}

// Must match the main window's WebView2 options or WebView2 refuses the window; no occlusion tracking, which stops drawing over a full-screen picture.
pub(crate) const BROWSER_ARGS: &str = "--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection,CalculateNativeWinOcclusion --autoplay-policy=no-user-gesture-required";

pub(crate) fn show_main(app: &AppHandle) {
    use tauri::Manager;
    notices::leave(app);
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}

// Windows won't give a background program the foreground: raised without it.
pub(crate) fn raise_main_quietly(app: &AppHandle) {
    use tauri::Manager;
    let Some(window) = app.get_webview_window("main") else { return };
    let Ok(hwnd) = window.hwnd() else { return };
    viewer::raise_without_focus(hwnd.0 as isize, !window.is_visible().unwrap_or(true) || window.is_minimized().unwrap_or(false));
    let _ = window.emit("app-raised", ());
}

// Only a valid machine name passes; the page checks it is one of the machines.
fn view_arg(args: &[String]) -> Option<String> {
    let i = args.iter().position(|a| a == "--view")?;
    let name = args.get(i + 1)?;
    (!name.is_empty() && name.len() <= 40 && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')).then(|| name.clone())
}

pub(crate) static ENGLISH: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[tauri::command]
fn set_language(app: AppHandle, lang: String) -> Result<(), String> {
    ENGLISH.store(lang == "en", Ordering::Relaxed);
    if app.tray_by_id(TRAY_ID).is_some() {
        app.remove_tray_by_id(TRAY_ID);
    }
    refresh_tray(&app);
    Ok(())
}

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

static TRAY_KIND: std::sync::Mutex<Option<bool>> = std::sync::Mutex::new(None);

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
    apply_tray_mark(app);
    Ok(())
}

static TRAY_WAITING: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

pub(crate) fn set_tray_waiting(app: &AppHandle, count: u32) {
    TRAY_WAITING.store(count, Ordering::Relaxed);
    apply_tray_mark(app);
}

fn apply_tray_mark(app: &AppHandle) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else { return };
    let Some(icon) = app.default_window_icon() else { return };
    let count = TRAY_WAITING.load(Ordering::Relaxed);
    let en = ENGLISH.load(Ordering::Relaxed);
    if count == 0 {
        let _ = tray.set_icon(Some(icon.clone()));
        let base = if notices::active() { if en { "GpuVM · Watching administrator prompts" } else { "GpuVM · Vigilando avisos de administrador" } } else { "GpuVM" };
        let _ = tray.set_tooltip(Some(base));
        return;
    }
    let marked = tauri::image::Image::new_owned(with_dot(icon.rgba(), icon.width(), icon.height()), icon.width(), icon.height());
    let _ = tray.set_icon(Some(marked));
    let text = match (count, en) {
        (1, true) => "GpuVM · An agent waits for you".to_string(),
        (n, true) => format!("GpuVM · {n} agent requests wait for you"),
        (1, false) => "GpuVM · Un agente te espera".to_string(),
        (n, false) => format!("GpuVM · {n} solicitudes de agentes te esperan"),
    };
    let _ = tray.set_tooltip(Some(text));
}

fn with_dot(rgba: &[u8], width: u32, height: u32) -> Vec<u8> {
    let mut out = rgba.to_vec();
    let size = width.min(height) as f32;
    let r = size * 0.24;
    let (cx, cy) = (width as f32 - r - 0.5, height as f32 - r - 0.5);
    for y in 0..height {
        for x in 0..width {
            let d = ((x as f32 + 0.5 - cx).powi(2) + (y as f32 + 0.5 - cy).powi(2)).sqrt();
            let i = ((y * width + x) * 4) as usize;
            if i + 3 >= out.len() {
                continue;
            }
            let px = if d <= r - size * 0.06 { Some([0xE7, 0xB4, 0x5E]) } else if d <= r { Some([0x1C, 0x1C, 0x1C]) } else { None };
            if let Some([red, g, b]) = px {
                out[i] = red;
                out[i + 1] = g;
                out[i + 2] = b;
                out[i + 3] = 0xFF;
            }
        }
    }
    out
}

const TRAY_ID: &str = "main";

#[tauri::command]
fn set_close_to_tray(app: AppHandle, state: State<'_, AppState>, enabled: bool) -> Result<(), String> {
    state.close_to_tray.store(enabled, Ordering::Relaxed);
    refresh_tray(&app);
    Ok(())
}

#[tauri::command]
fn set_stop_vms_on_quit(state: State<'_, AppState>, enabled: bool) {
    state.stop_vms_on_quit.store(enabled, Ordering::Relaxed);
}

fn stop_vms_in_background() {
    let Ok(mut conn) = backend::connect() else { return };
    if conn.send(&json!({ "id": "quit", "cmd": "Stop-GpuVMAll", "args": {} })).is_ok() {
        conn.detach();
    }
}

fn stop_service_when_idle() {
    let Some(mut conn) = backend::connect_existing() else { return };
    if conn.send(&json!({ "control": "stop-when-idle" })).is_ok() {
        let _ = conn.next_event();
    }
}

use std::sync::atomic::{AtomicBool, Ordering};

pub fn consent(code: &str) -> i32 {
    backend::consent(code)
}

pub fn mcp(fake: bool) -> i32 {
    mcp::run(fake)
}

fn log_to_file() {
    use std::os::windows::io::IntoRawHandle;
    // Elevated, a path under the user's own folder could be redirected to any file.
    if elevated() {
        return;
    }
    let Some(dir) = std::env::var_os("LOCALAPPDATA").map(|d| std::path::PathBuf::from(d).join("GpuVM")) else { return };
    let _ = std::fs::create_dir_all(&dir);
    let path = dir.join("app.log");
    let fresh = std::fs::metadata(&path).map(|m| m.len() > 2 * 1024 * 1024).unwrap_or(false);
    let file = std::fs::OpenOptions::new().create(true).append(!fresh).write(true).truncate(fresh).open(&path);
    if let Ok(file) = file {
        // SAFETY: the handle is this process's own, kept open for its whole life as its stderr.
        unsafe { windows_sys::Win32::System::Console::SetStdHandle(windows_sys::Win32::System::Console::STD_ERROR_HANDLE, file.into_raw_handle() as _) };
        eprintln!("---- GpuVM {} started (pid {})", env!("CARGO_PKG_VERSION"), std::process::id());
    }
}

fn elevated() -> bool {
    use windows_sys::Win32::Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY};
    use windows_sys::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
    // SAFETY: queries this process's own token into a local struct; the handle is closed.
    unsafe {
        let mut token = std::ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return true;
        }
        let mut e = TOKEN_ELEVATION { TokenIsElevated: 0 };
        let mut len = 0u32;
        let ok = GetTokenInformation(token, TokenElevation, (&mut e as *mut TOKEN_ELEVATION).cast(), std::mem::size_of::<TOKEN_ELEVATION>() as u32, &mut len);
        windows_sys::Win32::Foundation::CloseHandle(token);
        ok == 0 || e.TokenIsElevated != 0
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    #[cfg(not(debug_assertions))]
    log_to_file();
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, args, _cwd| {
            match view_arg(&args) {
                Some(name) => agent::request_view(app, &name),
                None => show_main(app),
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState { stop_service_on_quit: AtomicBool::new(true), ..Default::default() })
        .on_window_event(|window, event| {
            use tauri::Manager;
            if window.label() == "main" && matches!(event, tauri::WindowEvent::Moved(_) | tauri::WindowEvent::Resized(_)) {
                viewer::follow_main(window.app_handle());
            }

            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.label() == "main" {
                    api.prevent_close();
                    if window.state::<AppState>().close_to_tray.load(Ordering::Relaxed) {
                        let _ = window.hide();
                    } else {
                        notices::request_quit(window.app_handle());
                    }
                }
            }
        })
        .setup(|app| {
            crate::overlay::mark_main_thread();
        crate::viewer::reset_states();
            prompt::start(app.handle().clone());
            agent::start(app.handle().clone());
            status::start(app.handle());
            #[cfg(not(debug_assertions))]
            live::start(app.handle());
            if let Some(name) = view_arg(&std::env::args().collect::<Vec<_>>()) {
                agent::request_view(app.handle(), &name);
            }
            clipboard::start(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![ps, job, prompt::admin_prompts, prompt::card_answer, dock::dock_prompt, dock::dock_answer, agent::agent_dock_request, agent::agent_dock_answer, agent::agent_dock_resume, status::status_resize, status::status_state, status::status_action, status::set_status_prefs, agent::set_agent_prefs, agent::mcp_exe_path, agent::agent_recordings, agent::pending_agent_view, agent::agent_view_taken, claude::claude_code_state, claude::connect_claude_code, agent::agent_settings_changed, viewer::viewer_send, viewer::viewer_is_open, viewer::viewer_home, viewer::viewer_show, viewer::viewer_list, viewer::viewer_gone, viewer::viewer_reveal, viewer::viewer_covered, overlay::viewer_panel_resize, overlay::viewer_panel_close, overlay::viewer_panel_vm, dropzone::transfer_start, dropzone::transfer_cancel, dropzone::transfer_list, dropzone::viewer_drop_hide, dropzone::viewer_drop_state, clipboard::clipboard_items, clipboard::clipboard_send, clipboard::clipboard_auto, clipboard::clipboard_clear, capture::set_capture_prefs, capture::capture_folders, capture::capture_open, capture::capture_reveal, capture::capture_open_folder, capture::capture_state, capture::capture_get_hevc, open_console, repair_service, relaunch_as_admin, service_status, start_service, stop_service, set_service_mode, set_service_startup, set_close_to_tray, set_stop_vms_on_quit, set_language, notices::set_notices_after_quit, diag::log_ui_error, diag::save_diagnostics])
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


#[cfg(test)]
mod tray_tests {
    use super::with_dot;

    #[test]
    fn the_mark_is_a_dot_in_the_corner_and_leaves_the_rest() {
        let (w, h) = (32u32, 32u32);
        let icon = vec![10u8; (w * h * 4) as usize];
        let out = with_dot(&icon, w, h);
        let px = |x: u32, y: u32| { let i = ((y * w + x) * 4) as usize; [out[i], out[i + 1], out[i + 2], out[i + 3]] };
        assert_eq!(px(0, 0), [10, 10, 10, 10]);
        assert_eq!(px(w - 8, h - 8), [0xE7, 0xB4, 0x5E, 0xFF]);
        assert_eq!(out.len(), icon.len());
        assert_eq!(with_dot(&[0u8; 8], 32, 32).len(), 8);
    }
}

#[cfg(test)]
mod ps_tests {
    use super::ps_allowed;

    #[test]
    fn each_window_runs_only_its_commands() {
        assert!(ps_allowed("main", "Remove-GpuVM"));
        assert!(ps_allowed("main", "Resolve-GpuVMAgentRequest"));
        assert!(ps_allowed("viewer-panel", "Get-GpuVMOverview"));
        assert!(ps_allowed("viewer-panel", "Suspend-GpuVMAgent"));
        assert!(ps_allowed("viewer-panel", "Resume-GpuVMAgent"));
        assert!(!ps_allowed("viewer-panel", "Remove-GpuVM"));
        assert!(!ps_allowed("viewer-panel", "Start-GpuVM"));
        assert!(!ps_allowed("viewer-panel", "Connect-GpuVM"));
        assert!(!ps_allowed("viewer-panel", "Resolve-GpuVMAgentRequest"));
        assert!(!ps_allowed("viewer-panel", "Resolve-GpuVMAgentOffer"));
        assert!(!ps_allowed("viewer-panel", "Invoke-GpuVMAgent"));
        assert!(!ps_allowed("viewer-panel", "get-gpuvmoverview "));
        for w in ["agent-dock", "status-notch", "prompt-dock", "drop-zone", ""] {
            assert!(!ps_allowed(w, "Get-GpuVMOverview"), "{w}");
        }
    }
}