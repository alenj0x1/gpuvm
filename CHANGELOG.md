# Changelog

All notable changes to GpuVM are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

[Español](CHANGELOG.es.md)

## [0.1.1] - 2026-10-27

### Fixed
- **Audio on Windows in other languages.** The VM never set up Sunshine's audio when Windows wasn't in English, because the cable's output has a translated name ("Altavoces (VB-Audio Virtual Cable)" in Spanish). It is now found by device type, so streams have sound on Windows in any language.
- **"Start and open" repairs the audio** of VMs created before this fix: when the VM's Windows password is saved, it makes Sunshine capture the cable's output if it isn't already.
- Sunshine only restarts when its settings actually change.

### Added
- MIT license.

## [0.1.0] - 2026-10-27

First version.

### Added
- **Desktop app** (Tauri 2 + React): every Hyper-V VM in one list, "Start and open" in one click, live CPU, memory and GPU stats, options (processors, memory, GPU share, Moonlight resolution and FPS), a create wizard and power actions. Light and dark themes with a custom title bar and window border that follow the theme.
- **Preferences**: theme (system, light or dark, also switchable from the title bar) and what closing the window does (quit completely or stay in the system tray). Opening GpuVM again shows the running window.
- **Windows VMs with the host GPU** through Hyper-V GPU partitioning (GPU-P): the Windows image is applied straight to a VHDX, the host driver is copied into the guest, and setup is unattended (local account, autologon, no OOBE).
- **Streaming**: Sunshine inside the VM captures a virtual display drawn by the GPU and encodes with NVENC; Moonlight on the host opens it. Pairing is automatic (the PIN is handed to Sunshine through its API).
- **Silent audio** with VB-CABLE (WHQL-signed), credited to VB-Audio as its license requires.
- **Self-repair on "Start and open"**: syncs the GPU driver when the host driver changed, waits for Windows and Sunshine, returns the Windows session to the GPU display, picks the virtual display in Sunshine and sets its resolution to match Moonlight.
- **Profiles** in JSON with inheritance (`balanced`, `max-performance`) and per-VM overrides.
- **Labs** to measure each improvement (baseline vs candidate) before adopting it, with seven labs opened.
- **CLI** `gpuvm.ps1` and PowerShell module `GpuVM` with the same features.
- NSIS installer (per machine, Program Files) with the module, profiles and guest scripts bundled.

### Security
- The elevated app only runs scripts from Program Files, and PowerShell 7 only from Program Files (MSI or Microsoft Store package folder).
- Changing data (labs, downloads) lives in `%ProgramData%\GpuVM`, restricted to administrators.
- Third-party installers are pinned by SHA-256 and verified again right before copying them into the VM.
- Streaming and guest credentials are encrypted with DPAPI.

[0.1.1]: https://github.com/alenj0x1/gpuvm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alenj0x1/gpuvm/tree/v0.1.0
