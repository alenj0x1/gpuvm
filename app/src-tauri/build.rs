fn main() {
    // The app runs without administrator: the GpuVM service (app/host) does the Hyper-V work for it, so other
    // programs (Console UI, for example) can drive its window. In development the app offers to relaunch as
    // administrator and starts the bridge itself.
    let windows = tauri_build::WindowsAttributes::new().app_manifest(include_str!("manifests/invoker.manifest"));
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows))
        .expect("Tauri build script failed");
}
