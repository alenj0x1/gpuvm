//! Notices-only mode ("Administrator prompts after quitting", lab 042). When the person quits GpuVM while machines it can
//! watch are still on ("When quitting GpuVM": Leave them on), the app closes every window and viewer and stays in
//! the background with only its tray icon, polling for Windows administrator prompts in those machines; when one opens
//! it shows the prompt card (without taking the keyboard, nothing of GpuVM's is in front). It ends by itself once no
//! watched machine is on, or from the tray ("Quit completely"); opening GpuVM again brings the window back.
//!
//! Least privilege: nothing new runs or is elevated for it. The app keeps its usual Medium-integrity process and its
//! one connection to the GpuVM service (which already runs while the machines are on), and asks it only for the
//! prompts. The main window's page is destroyed, not hidden, so the background costs little memory.

use serde_json::Value;
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{AppHandle, Manager};

/// The preference (on unless turned off in Settings).
static ENABLED: AtomicBool = AtomicBool::new(true);
/// The app is in notices-only mode now.
static ACTIVE: AtomicBool = AtomicBool::new(false);

pub fn active() -> bool {
    ACTIVE.load(Ordering::Relaxed)
}

/// "Administrator prompts after quitting" preference.
#[tauri::command]
pub fn set_notices_after_quit(enabled: bool) {
    ENABLED.store(enabled, Ordering::Relaxed);
}

/// Machines the prompt watch covers, and their open prompts: { watched, prompts }.
pub async fn poll(app: &AppHandle) -> Option<Value> {
    let state = app.state::<crate::AppState>();
    let request = serde_json::json!({ "id": crate::next_id(&state), "cmd": "Get-GpuVMAdminPrompt", "args": { "WithWatched": true } });
    let data = crate::query(&state, request).await.and_then(crate::into_data).ok()?;
    // The service always answers with the list of what the command wrote: here, one object.
    match data {
        Value::Array(mut items) if !items.is_empty() => Some(items.swap_remove(0)),
        Value::Object(_) => Some(data),
        _ => None,
    }
}

/// Quitting GpuVM (the window's close button with "Quit completely", or the tray's Quit): into notices-only mode
/// when it applies, else the app exits as before.
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
        // An open prompt card stays: the person may be about to answer it.
        if label != crate::prompt::LABEL {
            let _ = window.destroy();
        }
    }
    crate::refresh_tray(app);
}

/// Opening GpuVM again (tray, Start menu): the window comes back and the mode ends.
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

/// No watched machine is on any more: GpuVM ends.
pub fn finish(app: &AppHandle) {
    if active() {
        ACTIVE.store(false, Ordering::Relaxed);
        app.exit(0);
    }
}
