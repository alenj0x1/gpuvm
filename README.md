English | [Español](README.es.md)

<p align="center">
  <img src="docs/src/assets/logo.svg" width="72" alt="GpuVM logo">
</p>

<h1 align="center">GpuVM</h1>

<p align="center">
  Windows 10/11 virtual machines that use your own GPU — created, started and streamed in one click.
</p>

<p align="center">
  <a href="https://github.com/alenj0x1/gpuvm/releases"><img src="https://img.shields.io/github/v/release/alenj0x1/gpuvm?include_prereleases&label=version" alt="Version"></a>
  <a href="https://alenj0x1.github.io/gpuvm/"><img src="https://img.shields.io/badge/website-alenj0x1.github.io%2Fgpuvm-2f5bd3" alt="Website"></a>
  <a href="https://alenj0x1.github.io/gpuvm/docs/"><img src="https://img.shields.io/badge/docs-English%20%7C%20Espa%C3%B1ol-2f5bd3" alt="Documentation"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/changelog-latest-6b6e75" alt="Changelog"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-2f9e6a" alt="MIT license"></a>
</p>

<p align="center">
  <img src=".github/assets/app-light.png" width="49%" alt="GpuVM in light mode">
  <img src=".github/assets/app-dark.png" width="49%" alt="GpuVM in dark mode">
</p>

## What it does

- **Your GPU inside the VM.** Hyper-V GPU partitioning (GPU-P) shares the host GPU with the VM, which runs the same driver as the host. No passthrough, no second GPU.
- **Open it in one click.** "Start and open" starts the VM, waits for Windows, fixes the session and the display, pairs Moonlight and opens the stream, drawn and encoded by the GPU (Sunshine + NVENC), with sound. A VM that is already on shows its picture in about 7–10 s; a second click brings Moonlight to the front.
- **Low latency, at your monitor's rate.** From a key, click, mouse move or gamepad button to the change on screen takes about 16.6 ms at 120 FPS or more, about 11 ms more than playing locally. The VM streams at your monitor's refresh rate, where V-Sync adds no latency and stutters halve.
- **A use for each machine.** Games, Movies and video or Work set the frame rate, V-Sync, frame pacing and mouse; codec, image quality and the rest can be tuned per machine.
- **Gamepads.** Controllers connected to your PC reach the VM as an Xbox 360 controller (ViGEmBus, installed by GpuVM).
- **Fixes itself.** It copies the GPU driver again when the host driver changes, puts the Windows session back on the GPU display and matches the display resolution to Moonlight.
- **Create machines without the installer.** Pick an official Windows ISO and a profile: the image is applied straight to a disk and set up unattended.
- **Stats and options.** Live CPU, memory and GPU usage; processors, memory, GPU share and stream quality for each VM.
- **Library.** Your own profiles (processors, memory, GPU, disk, ISO, apps, how Moonlight opens), the disks kept from deleted VMs to create them again, and the ISOs you used.
- **Templates and shared disks.** Save a VM as a template and create new ones on top of it in seconds; keep your game library on a shared disk that moves between VMs, imported from your PC's Steam library.
- **Clean Windows.** Pick a level (privacy, no extra apps, minimal) to cut telemetry, ads, suggestions, Copilot and preinstalled apps, without touching Defender, Windows Update or the firewall.
- **Apps in one step.** 16 apps (game launchers, browsers, media, Discord, 7-Zip, WinRAR, Proton VPN) with search and categories, installed inside the VM only if signed by their publisher or matching a pinned hash.
- **Fast capture.** The picture shows about 2.6 s after connecting, games in exclusive fullscreen too; Windows' administrator prompts in the VM appear in a card over everything with Allow and Deny, answerable only from your PC. Paste text from the PC into the VM with one button.
- **Keeps the host apart.** The app and Moonlight run without administrator rights; a Windows service that only GpuVM's own app can use does the Hyper-V work, and deleting asks for a Windows administrator prompt. The clipboard only goes from the PC to the VM, never back.
- **Labs.** Every performance idea is measured (baseline vs candidate) before it becomes a default.

<p align="center">
  <img src=".github/assets/create-light.png" width="49%" alt="Create a machine">
  <img src=".github/assets/empty-light.png" width="49%" alt="First machine">
</p>

## Requirements

- Windows 10/11 Pro, Enterprise, Education or Pro for Workstations, with Hyper-V enabled.
- A GPU that supports partitioning (tested with an NVIDIA GeForce RTX 4060).
- An administrator account on the PC.
- An official Windows 10 or 11 ISO.

Enable Hyper-V once, as administrator, then restart:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All
```

## Install

Download `GpuVM_x.y.z_x64-setup.exe` from [Releases](https://github.com/alenj0x1/gpuvm/releases) and run it. GpuVM installs for every user in Program Files, with its own PowerShell 7 and the **GpuVM** service, which does the Hyper-V work. The app opens without administrator rights; deleting a machine or a disk asks for confirmation in a Windows administrator prompt. Data that changes (labs, downloads) lives in `%ProgramData%\GpuVM`.

## Quick start

1. Open GpuVM and choose **Crear máquina** (Create machine): name, Windows ISO, profile and the Windows password.
2. Wait until it's ready; Windows finishes its setup on its own in a few minutes.
3. Press **Abrir** (Open). Moonlight opens with the VM once its picture is ready.

The interface is in Spanish for now.

## Documentation

Full guide, CLI reference, architecture and troubleshooting: **[alenj0x1.github.io/gpuvm/docs](https://alenj0x1.github.io/gpuvm/docs/)** (English and Spanish).

## How it works

| Piece | Role |
|---|---|
| `app/` | Desktop app (Tauri 2 + React), unelevated. `app/host` is the GpuVM service (`gpuvm-host.exe`): it runs `src/bridge.ps1` for the app behind a named pipe. |
| `src/GpuVM/` | PowerShell 7 module: creation, profiles, driver sync, streaming, labs. Backends are swappable (`Backends/`). |
| `guest/` | Scripts that run inside the VM: first boot, optimizations, streaming, display resolution, administrator prompts. |
| `profiles/` | JSON profiles with inheritance (`balanced`, `max-performance`). |
| `streaming/components.json` | Third-party components pinned by version and SHA-256. |
| `labs/` | Measurements behind each decision. |

## Development

```powershell
npm --prefix app install
npm --prefix app run dev          # UI with sample data in the browser (?mock=empty, ?mock=noservice)
npm --prefix app run tauri build  # installer in app/src-tauri/target/release/bundle/nsis/
Invoke-Pester ./tests             # module tests, no administrator needed
npm --prefix docs run dev         # documentation site
node scripts/site/changelog.mjs   # website (site/): what's new, from the changelogs
npm --prefix app run build:embed  # website: the app's live components (site/assets/embed.js)
python scripts/release.py 0.4.1   # release: changelog, versions, commit and tag (--dry-run, --next)
```

Changes go under **Unreleased** in `CHANGELOG.md` and **Sin publicar** in `CHANGELOG.es.md` until they are released.

The CLI covers the same features: `./gpuvm.ps1 check`, `new`, `connect`, `list`, `sync-driver`, `set`, `remove`, `lab-*` (see the docs).

## Third-party components

The installer carries [PowerShell 7](https://github.com/PowerShell/PowerShell) (MIT), pinned by version and SHA-256, to run the module.

GpuVM downloads and installs these inside the VM, verified by SHA-256:

- [Sunshine](https://github.com/LizardByte/Sunshine) (GPL-3.0) — game stream host.
- [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) — virtual monitor drawn by the GPU.
- [nefcon](https://github.com/nefarius/nefcon) — driver installer.
- [usbip-win2](https://github.com/vadimgrn/usbip-win2) (BSD-2-Clause) — USB/IP client with Microsoft-signed drivers; it plugs in GpuVM's own USB speaker inside the VM.
- [ViGEmBus](https://github.com/nefarius/ViGEmBus) (BSD-3-Clause) — virtual gamepad bus driver, for the controllers Moonlight forwards.

On the host it uses [Moonlight](https://moonlight-stream.org) (GPL-3.0), installed with winget.

The app catalog shows each app's own icon, taken from its official installer or website; the icons and names are trademarks of their owners and only identify their apps.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

[MIT](LICENSE). Third-party components keep their own licenses.
