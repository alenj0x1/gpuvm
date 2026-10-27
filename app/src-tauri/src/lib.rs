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
static CODE_ROOT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

fn repo_root() -> PathBuf {
    CODE_ROOT
        .get()
        .cloned()
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join(".."))
}

/// Strips the `\\?\` prefix Tauri leaves on the resource folder: `pwsh -File` rejects those paths and exits.
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

fn resolve_code_root(app: &tauri::App) -> PathBuf {
    use tauri::Manager;
    if !cfg!(debug_assertions) {
        if let Ok(dir) = app.path().resource_dir() {
            let bundled = without_verbatim(dir).join("gpuvm");
            if bundled.join("src").join("bridge.ps1").exists() {
                return bundled;
            }
        }
    }
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
}

/// pwsh by absolute path inside Program Files (only administrators can write there): the app runs elevated and
/// must not run a pwsh.exe that appears earlier in the PATH from a user folder.
/// - MSI installer: Program Files\PowerShell\7.
/// - Microsoft Store: Program Files\WindowsApps\Microsoft.PowerShell_…; its alias in the user's PATH does not
///   start from an elevated process, so the package's real folder is used.
static PWSH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

fn pwsh_path() -> PathBuf {
    PWSH.get_or_init(|| {
        let program_files = PathBuf::from(std::env::var("ProgramFiles").unwrap_or_else(|_| r"C:\Program Files".into()));
        let msi = program_files.join("PowerShell").join("7").join("pwsh.exe");
        if msi.exists() {
            return msi;
        }
        let system_root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
        let windows_ps = PathBuf::from(system_root).join(r"System32\WindowsPowerShell\v1.0\powershell.exe");
        let store_root = program_files.join("WindowsApps");
        let found = std::process::Command::new(windows_ps)
            .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                "(Get-AppxPackage -Name Microsoft.PowerShell | Sort-Object Version -Descending | Select-Object -First 1).InstallLocation"])
            .creation_flags(CREATE_NO_WINDOW)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .ok()
            .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()).join("pwsh.exe"))
            .filter(|p| p.starts_with(&store_root) && p.exists());
        found.unwrap_or_else(|| PathBuf::from("pwsh.exe"))
    })
    .clone()
}

fn bridge_command(once: bool) -> Command {
    let script = repo_root().join("src").join("bridge.ps1");
    let mut cmd = Command::new(pwsh_path());
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
    cmd
}

struct Bridge {
    _child: Child,
    stdin: ChildStdin,
    lines: Lines<BufReader<ChildStdout>>,
}

impl Bridge {
    fn spawn() -> Result<Self, String> {
        let mut child = bridge_command(false)
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
    let mut child = bridge_command(true)
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
    std::process::Command::new("vmconnect.exe")
        .args(["localhost", &name])
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Relaunches the app requesting administrator rights and closes this instance.
#[tauri::command]
fn relaunch_as_admin(app: AppHandle) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    std::process::Command::new("powershell.exe")
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
        .invoke_handler(tauri::generate_handler![ps, job, open_console, relaunch_as_admin, set_close_to_tray])
        .run(tauri::generate_context!())
        .expect("failed to start GpuVM");
}
