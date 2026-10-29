# Changelog

All notable changes to GpuVM are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

[Español](CHANGELOG.es.md)

Changes waiting for the next version sit under **Unreleased** at the top (this section only exists while there are some, and the docs site doesn't show it); `scripts/release.py` turns it into the new version.

## [0.4.1] - 2026-10-28

### Added
- A website at [alenj0x1.github.io/gpuvm](https://alenj0x1.github.io/gpuvm/): the app itself, live and clickable on sample data (Home, a machine, templates, shared disks, clean Windows), the patterns and profiles, what's new in the latest version (read from this changelog) and the install. The documentation moves to [/gpuvm/docs](https://alenj0x1.github.io/gpuvm/docs/).
- Three quick clicks on any machine's pattern switch every pattern to purple, black and blue; three more switch them back.

### Changed
- The machine's header wraps onto two lines in a narrow window instead of squeezing its buttons.

### Fixed
- Choosing an option in a switch inside a form (such as **Desde plantilla** in **Crear máquina**) no longer submits the form and creates the machine.

## [0.4.0] - 2026-10-28

### Added
- **Home.** The app opens on **Inicio** (Home), with your last machine, the free memory and what needs attention. It shows the last machine you opened, ready to open again; how much memory the PC has free, what is using the most, and whether each machine fits; and what needs attention across all of them (a GPU driver out of date, Moonlight not paired, apps waiting, the Windows password missing, little disk space left), each with the button that fixes it.
- **Memory before the click.** A machine that doesn't fit in memory says so before you open it, with how much is missing, and offers to open it with the memory that does fit in one click, on the machine and on Home.
- **Templates.** Save a VM's Windows, with its apps, cleanup level and password, as a read-only base disk (**⋯ → Crear plantilla**). A VM created from it gets a differencing disk that only stores what changes: it is ready in seconds and takes a few GB. Each copy gets its own Sunshine identity (Moonlight pairs with it as a new host) and computer name. A **Plantillas** tab in the library lists them and the machines built on each; one can't be deleted while a machine depends on it (lab 016).
- **Shared disks.** A data disk (a game library, for example) that moves between VMs: create it in the library's **Compartidos** tab, attach or detach it from the VM's **Discos compartidos** card, also while it runs. Inside it gets a drive letter, and a games disk gets `SteamLibrary` added to Steam (GpuVM closes Steam for it and opens it again). **Importar carpeta** copies a folder of this PC into it, such as a Steam library, so games don't download again in the VM (lab 017).
- **Clean Windows.** Choose how clean Windows is when creating a VM, in a profile, or later in each VM's **Windows** card: *Privacidad* (diagnostic data at the minimum the edition allows, no advertising ID, activity history, suggestions, Spotlight, Bing in Start, Copilot or Recall), *Sin apps de más* (also removes preinstalled apps such as News, Weather, Solitaire, Clipchamp, personal Teams and the new Outlook, plus OneDrive and widgets) or *Mínimo* (also turns off the telemetry, error reporting and unneeded services). Each level includes the previous ones, and a lower level undoes the settings of the higher ones; removed apps come back from Microsoft Store. Microsoft Defender, Windows Update, SmartScreen, UAC, the firewall, the Store and Xbox are never touched (a test enforces it). On Pro, Windows doesn't allow diagnostic data below "Required".
- Nine more apps in the catalog: Battle.net, EA app, GOG Galaxy, Ubisoft Connect, VLC, OBS Studio, Spotify, 7-Zip and WinRAR, each checked against its publisher's signature and, for pinned versions, its hash. 7-Zip isn't signed by its author, so it is pinned by hash only; Spotify refuses to install as administrator, so it installs as the VM's user.
- The app picker has a search box and category tabs, keeps to four rows and shows each app's own icon in color.

### Security
- Shared-disk imports only copy from this PC to the disk and fail closed: a link anywhere under the target, or a folder that can't be checked, stops the copy, and GpuVM's folders, Windows and folders containing them can't be imported. Steam is never pointed at a `SteamLibrary` that is a link.
- Templates and shared disks are readable only by Administrators and SYSTEM (Hyper-V grants each VM its own disks), not by every VM's worker process.
- App installers stay open, read-only for others, from their signature and hash checks until they have run, so nothing inside the VM can swap them in between.

### Changed
- Machine icons show an animal or an object (a fox, an owl, a planet, a rocket...) inside the square of the machine's color, instead of an abstract pattern; **Otro patrón** moves to the next one. The sidebar logo is the app's own icon.
- Moonlight's resolution, FPS and window mode sit side by side in one row in **Options**.
- Dialogs keep their header and buttons in place and scroll only their content, once (the app list no longer scrolls inside them). **Crear máquina** uses two columns, and its button, like **Guardar perfil**, stays disabled until the form is complete, with errors shown next to each field as you type.
- Buttons, checkboxes, sliders and focus use one fixed blue accent instead of each machine's color, so an action never looks red like a warning; red is kept for deleting and errors. The machine's color stays in its pattern.

## [0.3.0] - 2026-10-28

### Changed
- **Real audio without Steam.** VB-CABLE's output reached Sunshine as silence inside the VM; the sound that seemed to work came from Steam Streaming Speakers (lab 011). The VM now has GpuVM's own USB speaker, **Speakers (GpuVM Audio)**: a server inside the VM presents a USB audio device, usbip-win2 (Microsoft-signed drivers) plugs it in and Windows drives it with its built-in driver. It reaches Moonlight louder than Steam's speakers, needs no restart, comes back on its own after every restart and never leaves the VM (`127.0.0.1`, `LOCAL SERVICE`). Existing VMs move to it the next time they are opened (lab 012).
- The first boot no longer restarts the VM for audio.
- `components-update` skips components on hold; usbip-win2 stays on 0.9.8.0 until a lab proves a newer one.

### Security
- **The VM is isolated from your network by default.** It keeps internet, but reaches neither this PC nor your local network, except for the Default Switch's DHCP and DNS and the replies to the connections Moonlight opens. The rules live on the VM's virtual switch port, enforced by the host, so a damaged or infected VM can't remove them; they are refreshed before every start because the Default Switch changes the host's address. Turn it off per VM in **Options → Red** (for example, to reach a NAS). Not applied on an external switch, with a warning (lab 010).

## [0.2.0] - 2026-10-27

### Added
- **Library** (layers icon in the title bar) with three tabs:
  - **Profiles**: create, edit, duplicate and delete your own profiles on top of the built-in ones. Each keeps processors, memory, GPU share, disk size and type, Windows ISO, apps to install and how Moonlight opens (resolution, FPS, fullscreen or window). "Create machine" fills everything in from the chosen profile.
  - **Disks**: see which VM uses each disk, recreate a VM from a disk that was kept when its VM was removed, or delete free disks.
  - **ISOs**: the ISOs you used are remembered (with the machines that used them) and offered first; add or remove them from the list.
- **Apps to install in the VM**: Steam, Epic Games, Discord, Chrome, Proton VPN and Firefox. Chosen when creating a machine (installed the first time it opens) or later from the VM's Apps card. Each installer is downloaded inside the VM and only runs if Windows confirms it is signed by its publisher; pinned versions are also checked by SHA-256.
- **Paste into the VM**: a button copies the text on this PC to the VM's clipboard, ready for Ctrl+V. It only goes from the PC to the VM; the VM never reads this PC's clipboard.
- **Capture option** per VM (Options → Capture): "Standard" (default) or "Exclusive fullscreen", which also shows programs in exclusive fullscreen at any resolution. In that mode Windows' administrator prompts are not shown in the stream.
- **Grow the disk** from Options; the VM's C: drive grows on its own the next time it opens.
- **Open in a window**: Moonlight can open the VM fullscreen or in a window the size of the chosen resolution.
- **Preference "When quitting GpuVM"**: keep the machines running or shut them down cleanly.
- Click a machine's or profile's pattern to change it; the new one shows everywhere at once.
- Labs 008 (stream start time) and 009 (capture of exclusive fullscreen programs), and an end-to-end latency meter in `tools/latency`.

### Changed
- **Opening a VM is much faster**: when GpuVM has already turned the Hyper-V display off, Sunshine no longer reconfigures the display on every session, which made it re-test all its encoders. The first frame now arrives in about 2 s instead of 22–27 s (lab 008).
- The virtual display is kept as the only and primary display of the VM, so new windows always open where the stream shows them; nothing is changed when it's already set.
- In fullscreen, Alt+F4, Alt+Tab and the Windows key go to the VM instead of closing or leaving Moonlight (Ctrl+Alt+Shift+Q quits the stream).
- Windows Update no longer installs GPU drivers in the VM (they would replace the one copied from the host).
- The VM's CPU no longer hides features such as AVX2 (migration compatibility off).
- Labs 006 and 007 were rewritten: the host uses Hyper-V's root scheduler, where CPU reserve and weight have no effect, and the NVENC candidate equalled Sunshine's defaults.
- Waiting messages say what is happening (a Sunshine restart is no longer reported as a first boot).

### Fixed
- Applying Options failed on every VM with a virtual TPM (Hyper-V refuses to change the Secure Boot template once the TPM is initialized).
- Windows and programs could open on a hidden 1024×768 output of the shared GPU instead of the streamed display.
- Loading placeholders that were almost invisible or stacked without spacing; dialogs overflowing in narrow windows; misaligned app icons.

### Security
- Moonlight runs without administrator rights, so a compromised VM talking to it cannot reach an elevated process on the host.
- The VM's address is only trusted if it is inside the host's Hyper-V network, and the Sunshine API does not follow redirects.
- When the host must open a VM disk (driver update), it is mounted without a drive letter and links planted inside it are refused, so a VM cannot redirect writes to host files.
- `C:\GpuVM` and `%ProgramData%\GpuVM` are checked and restricted to Administrators and SYSTEM every time (VM processes get read-only access); the elevated process ignores modules and settings from the user's environment, and the release build has no development fallbacks.
- VMs cannot pose as a DHCP server or router on the network (DHCP and router guards on).

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

[0.4.1]: https://github.com/alenj0x1/gpuvm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/alenj0x1/gpuvm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alenj0x1/gpuvm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alenj0x1/gpuvm/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alenj0x1/gpuvm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alenj0x1/gpuvm/tree/v0.1.0
