use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};

static ENABLED: AtomicBool = AtomicBool::new(true);
static ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

#[tauri::command]
pub fn set_notices_after_quit(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}

pub async fn poll(app: &AppHandle) -> Option<Value> {
    let state = app.state::<crate::AppState>();
    let request = serde_json::json!({ "id": crate::next_id(&state), "cmd": "Get-GpuVMAdminPrompt", "args": { "WithWatched": true } });
    let data = crate::query(&state, request).await.and_then(crate::into_data).ok()?;
    match data {
        Value::Array(mut items) if !items.is_empty() => Some(items.swap_remove(0)),
        Value::Object(_) => Some(data),
        _ => None,
    }
}

pub fn request_quit(app: &AppHandle) {
    let stop_vms = app.state::<crate::AppState>().stop_vms_on_quit.load(Ordering::Relaxed);
    if !ENABLED.load(Ordering::Relaxed) || stop_vms || active() {
        app.exit(0);
        return;
    }
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        let watched = poll(&app).await.and_then(|v| v["watched"].as_u64()).unwrap_or(0);
        if watched == 0 {
            app.exit(0);
        } else {
            enter(&app);
        }
    });
}

fn enter(app: &AppHandle) {
    ACTIVE.store(true, Ordering::Relaxed);
    crate::viewer::quit_all();
    crate::overlay::close(app);
    for (label, window) in app.webview_windows() {
        if label != crate::prompt::LABEL {
            let _ = window.destroy();
        }
    }
    crate::refresh_tray(app);
}

pub fn leave(app: &AppHandle) {
    if !ACTIVE.swap(false, Ordering::Relaxed) {
        return;
    }
    if app.get_webview_window("main").is_none() {
        if let Some(config) = app.config().app.windows.first() {
            let _ = tauri::WebviewWindowBuilder::from_config(app, config).and_then(|b| b.build());
        }
    }
    crate::refresh_tray(app);
}

pub fn finish(app: &AppHandle) {
    if active() {
        ACTIVE.store(false, Ordering::Relaxed);
        app.exit(0);
    }
}
