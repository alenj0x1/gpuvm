//! Connects the UI to the GpuVM module (PowerShell 7) through src/bridge.ps1.
//! - Quick queries go through a persistent pwsh process, one at a time.
//! - Long jobs (create VM, start and open) run in their own pwsh and emit
//!   "job" events with their progress, so they don't block the stats.

use serde_json::{json, Value};
use std::path::PathBuf;
use std::process::Stdio;
use tauri::{AppHandle, Emitter, State};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Folder with the module, the profiles and the guest scripts.
/// - Installed: the resources bundled next to the executable, in Program Files (only administrators can
///   modify them; the app runs elevated and must not run scripts that any user program could change).
/// - In development: the repository.
/// - Release builds never fall back to the repository path baked in at compile time (a user folder on the
///   build machine): without the bundled resources, the app reports an error instead.
static CODE_ROOT: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

fn repo_root() -> Result<PathBuf, String> {
    CODE_ROOT.get().cloned().flatten().ok_or_else(|| {
        "No se encontraron los archivos de GpuVM junto a la aplicación. Vuelve a instalar GpuVM.".to_string()
    })
}

// System folders come from Windows itself, never from environment variables: an elevated process inherits the
// user's environment (HKCU\Environment), which any program of that user can change to point at its own files.
#[repr(C)]
struct Guid(u32, u16, u16, [u8; 8]);
const FOLDERID_PROGRAM_FILES: Guid = Guid(0x905e63b6, 0xc1bf, 0x494e, [0xb2, 0x9c, 0x65, 0xb7, 0x32, 0xd3, 0xd2, 0x1a]);

#[link(name = "kernel32")]
extern "system" {
    fn GetSystemDirectoryW(buffer: *mut u16, size: u32) -> u32;
}
#[link(name = "shell32")]
extern "system" {
    fn SHGetKnownFolderPath(id: *const Guid, flags: u32, token: isize, path: *mut *mut u16) -> i32;
}
#[link(name = "ole32")]
extern "system" {
    fn CoTaskMemFree(memory: *mut std::ffi::c_void);
}

fn wide_to_path(wide: &[u16]) -> PathBuf {
    use std::os::windows::ffi::OsStringExt;
    PathBuf::from(std::ffi::OsString::from_wide(wide))
}

fn system_directory() -> PathBuf {
    let mut buffer = [0u16; 260];
    // SAFETY: the buffer holds 260 UTF-16 units and Windows writes at most that many.
    let len = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if len == 0 || len >= buffer.len() { PathBuf::from(r"C:\Windows\System32") } else { wide_to_path(&buffer[..len]) }
}

fn program_files() -> PathBuf {
    let mut raw: *mut u16 = std::ptr::null_mut();
    // SAFETY: Windows allocates the string; it is read up to its terminating zero and freed with CoTaskMemFree.
    unsafe {
        let ok = SHGetKnownFolderPath(&FOLDERID_PROGRAM_FILES, 0, 0, &mut raw) == 0;
        let path = if ok && !raw.is_null() {
            let len = (0..).take_while(|&i| *raw.add(i) != 0).count();
            Some(wide_to_path(std::slice::from_raw_parts(raw, len)))
        } else {
            None
        };
        CoTaskMemFree(raw.cast());
        path.unwrap_or_else(|| PathBuf::from(r"C:\Program Files"))
    }
}

/// Windows tools by absolute path in System32: the elevated app must not run a copy found earlier in the PATH.
fn system32(exe: &str) -> PathBuf {
    system_directory().join(exe)
}

/// Strips the `\\?\` prefix Tauri leaves on the resource folder: `pwsh -File` rejects those paths and exits.
#[cfg_attr(debug_assertions, allow(dead_code))]
fn without_verbatim(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        PathBuf::from(format!(r"\\{rest}"))
    } else if let Some(rest) = text.strip_prefix(r"\\?\") {
        PathBuf::from(rest)
    } else {
        path
    }
}

#[cfg(not(debug_assertions))]
fn resolve_code_root(app: &tauri::App) -> Option<PathBuf> {
    use tauri::Manager;
    let bundled = without_verbatim(app.path().resource_dir().ok()?).join("gpuvm");
    bundled.join("src").join("bridge.ps1").exists().then_some(bundled)
}

#[cfg(debug_assertions)]
fn resolve_code_root(_app: &tauri::App) -> Option<PathBuf> {
    Some(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join(".."))
}

/// pwsh by absolute path inside Program Files (only administrators can write there): the app runs elevated and
/// must not run a pwsh.exe that appears earlier in the PATH from a user folder.
/// - MSI installer: Program Files\PowerShell\7.
/// - Microsoft Store: Program Files\WindowsApps\Microsoft.PowerShell_…; its alias in the user's PATH does not
///   start from an elevated process, so the package's real folder is used.
/// - Development builds may still use pwsh.exe from the PATH; release builds report an error instead.
static PWSH: std::sync::OnceLock<Option<PathBuf>> = std::sync::OnceLock::new();

fn pwsh_path() -> Result<PathBuf, String> {
    PWSH.get_or_init(|| {
        let program_files = program_files();
        let msi = program_files.join("PowerShell").join("7").join("pwsh.exe");
        if msi.exists() {
            return Some(msi);
        }
        let windows_ps = system32(r"WindowsPowerShell\v1.0\powershell.exe");
        let store_root = program_files.join("WindowsApps");
        let found = std::process::Command::new(windows_ps)
            // Its own modules only, not ones from the user's folders.
            .env("PSModulePath", system32(r"WindowsPowerShell\v1.0\Modules"))
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()).join("pwsh.exe"))
            .filter(|p| p.starts_with(&store_root) && p.exists());
        if cfg!(debug_assertions) {
            found.or_else(|| Some(PathBuf::from("pwsh.exe")))
        } else {
            found
        }
    })
    .clone()
    .ok_or_else(|| "No se encontró PowerShell 7 en Program Files. Instálalo desde https://aka.ms/powershell y vuelve a abrir GpuVM.".to_string())
}

fn bridge_command(once: bool) -> Result<Command, String> {
    let script = repo_root()?.join("src").join("bridge.ps1");
    let mut cmd = Command::new(pwsh_path()?);
    cmd.args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
        .arg(script);
    if once {
        cmd.arg("-Once");
    }
    cmd.stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(CREATE_NO_WINDOW)
        .kill_on_drop(true);
    Ok(cmd)
}

struct Bridge {
    _child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
}

impl Bridge {
    fn spawn() -> Result<Self, String> {
        let mut child = bridge_command(false)?
            .spawn()
            .map_err(|e| format!("No se pudo iniciar PowerShell 7 (pwsh.exe): {e}"))?;
        let stdin = child.stdin.take().ok_or("sin stdin")?;
        let stdout = child.stdout.take().ok_or("sin stdout")?;
        Ok(Self { _child: child, stdin, lines: BufReader::new(stdout).lines() })
    }
}

#[derive(Default)]
struct AppState {
    bridge: Mutex<Option<Bridge>>,
    counter: Mutex<u64>,
    close_to_tray: AtomicBool,
    stop_vms_on_quit: AtomicBool,
}

async fn next_id(state: &AppState) -> String {
    let mut c = state.counter.lock().await;
    *c += 1;
    format!("q{c}")
}

/// Runs a module function and returns its result (list of objects).
#[tauri::command]
async fn ps(state: State<'_, AppState>, cmd: String, args: Option<Value>) -> Result<Value, String> {
    let id = next_id(&state).await;
    let request = json!({ "id": id, "cmd": cmd, "args": args.unwrap_or(json!({})) }).to_string();
    let mut guard = state.bridge.lock().await;
    for attempt in 0..2 {
        if guard.is_none() {
            *guard = Some(Bridge::spawn()?);
        }
        let bridge = guard.as_mut().unwrap();
        let sent = async {
            bridge.stdin.write_all(request.as_bytes()).await?;
            bridge.stdin.write_all(b"\n").await?;
            bridge.stdin.flush().await
        }
        .await;
        if sent.is_err() {
            // The process died: restart it once.
            *guard = None;
            if attempt == 0 { continue; }
            return Err("PowerShell dejó de responder.".into());
        }
        // Once the request is sent it is not retried: the command may already have been applied (shutdown, delete…).
        let read = tokio::time::timeout(std::time::Duration::from_secs(180), async {
            loop {
                match bridge.lines.next_line().await {
                    Ok(Some(line)) => {
                        let Ok(event) = serde_json::from_str::<Value>(&line) else { continue };
                        if event["id"] != json!(id) || event["type"] != "result" {
                            continue;
                        }
                        return Ok(if event["ok"] == json!(true) {
                            Ok(event["data"].clone())
                        } else {
                            Err(event["error"].as_str().unwrap_or("Error desconocido").to_string())
                        });
                    }
                    _ => return Err(()),
                }
            }
        })
        .await;
        return match read {
            Ok(Ok(result)) => result,
            Ok(Err(())) => {
                *guard = None;
                Err("PowerShell dejó de responder.".into())
            }
            Err(_) => {
                *guard = None;
                Err("La operación tardó demasiado; vuelve a intentarlo.".into())
            }
        };
    }
    Err("PowerShell dejó de responder.".into())
}

/// Starts a long job; progress arrives as "job" events with the same jobId.
#[tauri::command]
async fn job(app: AppHandle, job_id: String, cmd: String, args: Option<Value>) -> Result<(), String> {
    let mut child = bridge_command(true)?
        .spawn()
        .map_err(|e| format!("No se pudo iniciar PowerShell 7 (pwsh.exe): {e}"))?;
    let mut stdin = child.stdin.take().ok_or("sin stdin")?;
    let stdout = child.stdout.take().ok_or("sin stdout")?;
    let request = json!({ "id": job_id, "cmd": cmd, "args": args.unwrap_or(json!({})) }).to_string();
    stdin.write_all(request.as_bytes()).await.map_err(|e| e.to_string())?;
    stdin.write_all(b"\n").await.map_err(|e| e.to_string())?;
    drop(stdin);

    tauri::async_runtime::spawn(async move {
        let mut lines = BufReader::new(stdout).lines();
        let mut finished = false;
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(mut event) = serde_json::from_str::<Value>(&line) {
                finished |= event["type"] == "result";
                event["jobId"] = json!(job_id);
                let _ = app.emit("job", event);
            }
        }
        let _ = child.wait().await;
        if !finished {
            let _ = app.emit("job", json!({ "jobId": job_id, "type": "result", "ok": false, "error": "El trabajo terminó sin respuesta." }));
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

/// Relaunches the app requesting administrator rights and closes this instance.
#[tauri::command]
fn relaunch_as_admin(app: AppHandle) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    std::process::Command::new(system32(r"WindowsPowerShell\v1.0\powershell.exe"))
        .args(["-NoProfile", "-WindowStyle", "Hidden", "-Command"])
        .arg(format!("Start-Process -FilePath '{}' -Verb RunAs", exe.display().to_string().replace('\'', "''")))
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| e.to_string())?;
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

/// Shuts the running GpuVM machines down in a separate PowerShell that outlives the app, so quitting is instant
/// and each VM still gets a clean Windows shutdown.
fn stop_vms_in_background() {
    let (Ok(root), Ok(pwsh)) = (repo_root(), pwsh_path()) else { return };
    let module = root.join("src").join("GpuVM").join("GpuVM.psd1");
    // Same pinned module path as bridge.ps1: an elevated PowerShell must not load modules from the user's folders.
    let pshome = pwsh.parent().map(|p| p.join("Modules")).unwrap_or_default();
    let modules = format!("{};{};{}", pshome.display(), system32(r"WindowsPowerShell\v1.0\Modules").display(), root.join("src").display());
    let _ = std::process::Command::new(pwsh)
        .env("PSModulePath", modules)
        .args(["-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"])
        .arg(format!("Import-Module '{}'; Stop-GpuVMAll", module.display().to_string().replace('\'', "''")))
        .creation_flags(CREATE_NO_WINDOW)
        .spawn();
}

use std::os::windows::process::CommandExt;
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        // A second launch (e.g. from the Start menu while GpuVM is in the tray) shows the open window instead.
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app)))
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .setup(|app| {
            let _ = CODE_ROOT.set(resolve_code_root(app));
            std::thread::spawn(pwsh_path);
            Ok(())
        })
        .on_window_event(|window, event| {
            use tauri::Manager;
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                if window.state::<AppState>().close_to_tray.load(Ordering::Relaxed) {
                    api.prevent_close();
                    let _ = window.hide();
                }
            }
        })
        .invoke_handler(tauri::generate_handler![ps, job, open_console, relaunch_as_admin, set_close_to_tray, set_stop_vms_on_quit])
        .build(tauri::generate_context!())
        .expect("failed to start GpuVM")
        .run(|app, event| {
            use tauri::Manager;
            // Quitting from the window or the tray; hiding to the tray does not get here.
            if let tauri::RunEvent::Exit = event {
                if app.state::<AppState>().stop_vms_on_quit.load(Ordering::Relaxed) {
                    stop_vms_in_background();
                }
            }
        });
}
