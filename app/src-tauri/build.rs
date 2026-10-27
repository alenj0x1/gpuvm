fn main() {
    // Hyper-V requires administrator. In release the app requests it on launch; in development it starts normally
    // so the UI can be iterated on, and the app offers to relaunch as administrator.
    let manifest = if std::env::var("PROFILE").as_deref() == Ok("release") {
        include_str!("manifests/admin.manifest")
    } else {
        include_str!("manifests/invoker.manifest")
    };
    let windows = tauri_build::WindowsAttributes::new().app_manifest(manifest);
    tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(windows))
        .expect("Tauri build script failed");
}
