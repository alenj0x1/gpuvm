fn main() {
    // The app runs without administrator: the GpuVM service (app/host) does the Hyper-V work for it, so other
    // programs (Console UI, for example) can drive its window. In development the app offers to relaunch as
    // administrator and starts the bridge itself.
    let windows = tauri_build::WindowsAttributes::new().app_manifest(include_str!("manifests/invoker.manifest"));
    // Each window may call only the app commands its capability lists (capabilities/*.json): the viewer's side
    // panel and the admin-prompt card can't, for example, change the service or relaunch the app as administrator.
    let commands = tauri_build::AppManifest::new().commands(&[
        "ps", "job", "admin_prompts", "card_answer",
        "viewer_send", "viewer_is_open", "viewer_home", "viewer_show", "viewer_list", "viewer_reveal", "viewer_covered",
        "viewer_panel_resize", "viewer_panel_close", "viewer_panel_vm",
        "transfer_start", "transfer_cancel", "transfer_list", "viewer_drop_hide", "viewer_drop_state",
        "clipboard_items", "clipboard_send", "clipboard_auto", "clipboard_clear",
        "open_console", "repair_service", "relaunch_as_admin", "service_status", "start_service", "stop_service",
        "set_service_mode", "set_service_startup", "set_close_to_tray", "set_stop_vms_on_quit", "set_language",
        "set_notices_after_quit", "dock_prompt", "dock_answer",
        "agent_dock_request", "agent_dock_answer", "agent_dock_resume", "status_resize", "status_state", "status_action", "set_status_prefs", "set_agent_prefs", "mcp_exe_path", "agent_recordings", "pending_agent_view", "agent_view_taken", "claude_code_state", "connect_claude_code", "agent_settings_changed", "viewer_gone",
        "set_capture_prefs", "capture_folders", "capture_open", "capture_reveal", "capture_open_folder", "capture_state", "capture_get_hevc",
    ]);
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows).app_manifest(commands))
        .expect("Tauri build script failed");
}
