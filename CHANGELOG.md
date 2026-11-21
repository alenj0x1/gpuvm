# Changelog

All notable changes to GpuVM are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

[Español](CHANGELOG.es.md)

Changes waiting for the next version sit under **Unreleased** at the top (this section only exists while there are some, and the docs site doesn't show it); `scripts/release.py` turns it into the new version.

## [Unreleased]

### Added
- **Agents can look while a command runs.** `run` takes `background: true`: it answers at once with a run id, the agent keeps taking screenshots and acting while the command works, and the new `run_result` tool gives the exit code and output. Inside the machine, screenshots, input, UI Automation and each command now run side by side, so a screenshot never waits behind any of them, and input actions always arrive in the order they were sent.
- **`delayMs` on screenshots and input.** `screenshot` waits that long before capturing; `click`, `type`, `key`, `scroll`, `drag` and `act` wait after acting, before answering and before `screenshotAfter` (up to 10 seconds). Agents no longer need a `run` of `Start-Sleep` just to wait for a window.
- **Agents can draw.** An agent's `drag` also follows a `path` of points, or several `strokes` that are each pressed and released on their own (a circle, a spiral and a star in one call), with the `button` and the time it takes (`durationMs`) of its choice. Moves are added in between so apps like Paint get smooth lines. Agents no longer have to write mouse scripts inside the machine to draw; the person taking control still stops them mid-stroke, with the button released.
- **winget in agent machines.** Agents can install apps with `winget` as their own standard user (`--scope user`), without the Microsoft Store. GpuVM brings App Installer from Microsoft's official release, pinned by its SHA-256 and checked for Microsoft's signature on this PC and again inside the machine, and provisions it for every user. Settings that would weaken winget's checks are locked by policy, and the Microsoft Store source is off, so a `winget` command never stops at its agreement prompt. Agent templates get it with their next update; other agent machines the next time their agent is installed.

### Changed
- **GpuVM's own Sunshine on every machine.** Machines stream with GpuVM's fork of Sunshine ([gpuvm-sunshine](https://github.com/alenj0x1/gpuvm-sunshine)), always as a Windows service, whatever they are used for. With the default **Fast** capture a small helper captures as the signed-in user and passes the frames to the service, so the picture shows where desktop duplication stayed black on the virtual display, and Sunshine's settings and keys are no longer readable by that user. Machines created before get it the next time they are opened; the old setup that ran Sunshine as the user is removed. Agent machines and the rest now work the same way, and agent machines can choose their capture like any other.
- **Recordings of agents' work take 10 to 35 times less space.** The viewer re-encodes them as it records, as H.264 at 30 frames per second and constant quality, instead of keeping the 180 fps stream: about 0.3 to 1 GB per hour of agent work instead of nearly 10 GB. Text and menus stay sharp, every Windows player opens them, and what you see live doesn't change; your own recordings keep the full stream. Needs the updated viewer.
- **Templates stay up to date.** When GpuVM brings a newer Sunshine or agent, its templates get it once, as a layer on top of them, in the background (the app checks when it starts and every hour). Copies of an agent template are ready in under a minute instead of about five; machines already made from a template keep theirs untouched.

### Fixed
- Updating GpuVM no longer leaves the old service installed when it was slow to stop.
- Opening a fresh copy of an agent template by hand no longer waits up to 15 minutes on "Signing in to Windows".
- An agent's `destroy` no longer reports a failure when GpuVM had already deleted the machine.
- The picture no longer freezes for good when Windows' capture service crashes inside the machine: it comes back by itself in about 2 seconds, instead of staying on the last frame until the machine is reopened.
- Far fewer black flashes over the picture (half-drawn frames of the machine's desktop), about half as many as before.
- Recordings open in Windows' own player on PCs without Microsoft's HEVC extension: with the codec on automatic, those PCs stream in H.264.

## [0.9.0] - 2026-11-18

### Added
- **GpuVM's own viewer.** Machines open inside the app, in GpuVM's viewer (built on Moonlight): the machine's cube moves to the center with the steps while it connects, then the picture fills the window under the title bar. **Home** (in the title bar, the side panel or Ctrl+Alt+Shift+H) zooms out to Home and keeps the machine connected, so opening it again goes straight back to its picture; **Settings → Window** can disconnect it instead. A machine set to full screen goes full screen when its picture is ready, and full screen can be toggled from the panel. Switching machines zooms out of one and brings the other to the center, and waits show tips.
- **Side panel beside the picture.** Ctrl+Alt+Shift+G opens a panel that pushes the picture aside. It is a board of widgets you arrange: machines with their cubes, actions (Home, full screen, stats on the picture, disconnect), the picture's numbers with their history, a clock, a shelf with every machine's figures, the games and the weather. **Edit** adds, removes, moves and resizes them, and the layout is remembered; each widget shows more as it grows. Its edge is dragged to make it wider. The weather stays off until a city is typed, and only the city's name goes to Open-Meteo.
- **Animation smoothness and quality.** **Settings → Appearance** limits the frames per second of the holograms and scenes (15, 30, 60, 120 or as many as the monitor shows) and the resolution they are drawn at (25 to 100 %), leaving more of the GPU to the machines. By default nothing changes.

### Changed
- **The app gives the GPU back to the machines.** The holograms and scenes stop while a machine's picture is shown, inside the app or full screen, and draw at 30 frames per second while GpuVM doesn't have the focus. The cube's screen and scan lines cost less to draw.
- **Lower streaming latency.** NVIDIA machines encode in a single pass, about 1 ms less per frame (input latency from about 13.4 to 11.4 ms on average). Machines already created get it the next time they are opened.
- **Home loads** as the machines' own cubes joined by lines where light travels, instead of a ring.

### Fixed
- Changing the virtual display or the audio sink of a machine that captures with Windows Graphics Capture no longer leaves its streaming host stopped, which made the next open fail.
- Opening a machine whose viewer closed in the meantime opens it again instead of showing a dark screen.
- The Settings card no longer flashes when switching sections, and Home's cards are no longer cut between 1100 and 1300 px wide.

### Security
- **The viewer runs isolated.** It reads what the machine's streaming host sends, so it runs at Low integrity with a restricted token (no administrator rights even when GpuVM runs elevated) inside a job: one process, ended with the app, without switching desktops, logging off, changing system parameters or display modes, or writing the clipboard. It can't write your files or registry, open GpuVM's process or message its windows. The app talks to it over a private pipe only your user can open, with a one-time token, and tracks it by its process handle.
- The viewer's window is used only if it belongs to the viewer's own process, it is brought to the front only right after the app asked for the picture, and one machine opens at a time.
- Each of the app's windows may call only its own commands: the side panel can't touch the service or relaunch GpuVM as administrator.

## [0.8.0] - 2026-11-16

### Added
- **English.** GpuVM speaks English as well as Spanish. **Settings → Appearance → Language** follows Windows (Spanish when Windows is in Spanish, English otherwise) or stays on one; every screen, the tray menu and what the module reports (steps, warnings and errors) switch at once.
- **Reorder by dragging.** Drag a machine in the sidebar to another place, in its space or in another one: the others make room as it passes, and it shows faded where it would land. Spaces are reordered the same way, by dragging their name.
- **New logo.** A GPU chip split in four with one part in color: the share of the GPU each machine gets. It is the app icon, the installer's and the one in the sidebar.
- **Accent color.** **Settings** lets you pick the accent (blue, violet, teal, green or amber), shown as half light, half dark; the light/dark switch moved there too.
- **Choose the Windows user name** when creating a machine (it was always `gpuvm`), with the names Windows reserves rejected as you type.
- **New template from the Library.** Pick the machine whose Windows it saves and name it, as from the machine's own menu.
- **Personalize a machine.** A new **Customize** section decorates its cube: its own color for the hologram, the lightning and its icon (the accent if none is picked); an LED sign whose text runs around the glass, in amber, red, green, white or the machine's color, optionally with its GPU and processor use; stickers for the glass (GpuVM, star, lightning, heart, cat, dog, spider, ghost, rocket, fire, gem, moon, controller, or an image of your own); and figures of toy bricks that stand on top, drawn on the GPU (lucky cat, plant, duck, robot, cactus, mushrooms, controller, mug, penguin, rocket, bonsai, dog, cat, spider, magic cube, bunny, bear, unicorn, tiger, fawn). **Decorate at random** fills it all in one click, also when creating a machine, which has its own Customize section. Dragging shows the face's cells lit in the accent and things snap to them; the LED sign is dragged up and down too. Drag them onto the cube and around it, hold the right button and drag sideways to turn them (settling every 15°), right-click to resize, duplicate or remove them, or pick and remove them from the list of what the machine has. Several can be picked at once (Shift or Ctrl and click, a box drawn with Shift on empty space, or Ctrl+A) and are moved, turned, duplicated (Ctrl+D) or removed together; the arrows move them one cell at a time. What is picked shows under a soft layer of the accent. Each machine keeps its decoration, also when renamed, and it shows on Home too. With no machines yet, Home shows machines decorated at random, a new one every few seconds.
- **Games in the space of machines.** **Play** over Home's space opens a gallery of games, each on a card where the game itself plays on its own, with its best score. Before playing, a screen shows the game running with the machine and mode you pick (in a team, your other machines fly beside you; changing the machine or the mode sends the ones leaving off and flies the new ones in), the controls drawn as keys and mouse buttons, a few tips and your record. *Overclock*: your machine flies through bricks and rival machines, moving with the keys and aiming with the mouse anywhere; stickers bring weapons (faster, triple, bursts, all around), a shield or a life; taking things down fills a frenzy where everything speeds up and your figures come out huge and go through everything. Shooting and taking things down charge an ability used with the right button (or E): a pulse at first, and cores that drift by swap it for a laser, slow time, clones or a magnet. It starts in the world of the space it is played in and every 40 seconds crosses into another zone (the studio, a motherboard, a world of blocks), and what comes at you is made of that zone: hologram slabs, chips, capacitors and resistors, or bricks and brick figures. You pick the machine you play with (it flies with its color and its figure on top) and a mode: **Solo**, or **Team**, where your other machines fly with you and shoot on their own against a thicker, tougher stream. *Bit a bit*: your machine jumps through the gaps between columns, in the studio (hologram pillars), on a motherboard or among blocks, with bits that count double. Each game and mode keeps its best score. *Stack*: a block slides over the tower and one click drops it; what hangs over falls off and the tower narrows, a drop right on top is a Perfect worth double and three in a row grow the block back. Your machine is the base and its figure rides the top; every 8 floors the tower climbs into another world (blocks, a motherboard, the studio, then space) and gets harder. *Cache*: brick figures rain down and your machine catches them along the floor with the mouse (or A/D); each one that reaches the floor costs a heart. Golden figures are worth five, spiders cost a heart if caught, and stickers bring a clone that catches beside you, a wider catcher, slow time, a magnet, a shield or a heart.
- **Wider cube.** On a machine's page, drag the edge of the cube's panel to make it wider (it never squeezes the options, and it is remembered).
- **Rename a machine.** **Rename** in a machine's menu (when it is off) checks the new name as you type, while the cube beside engraves it on the board's serial plate. The machine is renamed in Hyper-V along with its folder and disk; its settings, Moonlight pairing, shared disks, last opened and the banner design picked for it stay with it. If a step fails, what was already renamed is undone. The module adds `Rename-GpuVM` (`./gpuvm.ps1 rename`).
- **Spaces.** Group machines by what they are for (work, games, AI tests…). Home shows one space at a time, picked from tabs over the stage that scroll with the wheel, with only its machines; the sidebar lists the machines under their space; a new machine goes into the space it is created from; a machine's **Customize** section moves it to another space, or to a new one. Machines can also be dragged from the sidebar or from Home's cards onto another space, and glide to their new place. A space with no machines offers a **New machine** card and the machines of other spaces to bring in.
- **Worlds for the spaces.** Each space has its world: **Motherboard** (chips, capacitors, connectors, traces with data running in the accent, and the space's and machine's names printed on the board by its socket) or **Blocks** (a baseplate of studs with paths, a pond, trees, houses and the brick figures, by day, in the evening, at night or following the clock), or the plain **Studio**. The world turns and zooms with the cube, covers the whole view, has a light that shades every piece and casts shadows (the machines' too) and the hologram lights the floor under each machine. Among blocks, the machine itself is built of bricks, its lightning is a chain of small blocks and its screen a mosaic of tiles with a landscape of the same time of day.
- **Fixed views while customizing.** A panel on the cube shows it from the front, either side, the back or the top and keeps it still there.
- **Copy, cut and paste decorations.** Ctrl+C, Ctrl+X and Ctrl+V (also in the right-click menu) copy stickers and figures, also from one machine to another.
- **Smaller touches.** Switching to another machine keeps the same section and place on its page; Home's row of machines moves by dragging it; dragging with the wheel pressed moves the cube around; selected text takes the accent color; folding the sidebar closes the room of the space names so the machines slide up together.

### Changed
- **A new interface.**
  - Dark theme in neutral graphite grays, no blue tint; the sidebar and the title bar are one surface and the content sits on it with a rounded corner. Home, Library and Settings live in the sidebar; drag its edge to resize it, and click the line on the edge (or drag it narrow) to fold it.
  - Each machine's icon shows the logo's four cells with its own part in its color. Its banner is a scene of chips that moves with the GPU, flickers with the processor and fills with memory; **Another banner** in its menu switches between three.
  - Beside a machine's options, always in view, the machine is a hologram inside a glass cube: motherboard, processor (one cell per thread), memory (one module per 4 GB), graphics card (its GPU share as a strip of lights) and disk, the apps floating around and its screen projected above. Lightning reaches each piece as often as it works; what the cleanup keeps out bounces off the glass. Drag to turn it any way, scroll to zoom, double-click to go back. It follows what you change before saving: the camera closes in on the piece you change and then eases back, and a profile that changes several at once runs through them while the hologram rebuilds. Creating a machine shows the same cube, built as you choose.
  - The cube shares its space with your other machines, drawn small under it; left alone for a while, the machine floats and then joins them as a constellation, and coming back to it brings it to the front. Opening another machine continues the same space: the one you were looking at goes back among the others and the new one comes forward. Every app gets its place inside the cube, however many there are.
  - The board has a serial plate with the machine's name; typing the name when creating a machine takes the camera there while it is engraved letter by letter.
  - The machine's header and its usage strip are one panel; its Windows, GPU and profile (by its name, Balanced) show as small labeled pieces.
  - Switching machines is quick, like a cut: the camera whips around while they trade places.
  - The logo's colored part follows the accent color.
  - A machine's page is one page with a bar that marks the section in view (machine, picture and control, Windows). Processor, memory, GPU and uptime sit in one strip with their last five minutes as small charts.
  - Options are rows with an icon and a line that explains them. Sliders show their scale and what is left for the PC; lists and the monitor choice use the app's own drop-down.
  - Frame rates are offered for the monitor the machine opens on (its own rate, the ones that keep even with it and the ones that may stutter), plus a custom value.
  - **Use type** heads its group and sets the frame rate, V-Sync, frame pacing and mouse under it; changing one by hand switches it to **Custom**.
  - Windows cleanup lists everything Windows comes with (tracking, ads, Bing, Copilot, preinstalled apps, OneDrive, widgets, background services) each saying what it does now or, when the chosen level removes it, how Windows ends up without it, next to a scene where those pieces stop reaching Windows.
  - Apps: the catalog by category as tiles or a list on the left, with installed apps marked; the search and this machine's apps on the right.
  - Shared disks say what they are for.
  - Home opens on the space of machines: the one in use (or the last one opened) in its cube with the others beside it, and next to it its processor, memory and GPU use, the free memory and its actions. Below, every other machine with its action, the Library at a glance with **Create machine**, and what needs attention.
  - The Library is one page with all its sections. At the top, where GpuVM's space on the drive goes (machine disks, templates, shared disks and ISOs, each in its color) and how much is free. Profiles are cards with a small cube of what they give, the grid grows with however many there are, and its last card creates a new one. Templates, shared disks, machine disks and ISOs are cards the same way, each with a drawing of what it is (a template's Windows, a disk filled as far as it is used, an install disc). Editing a profile shows the machine it makes beside the form.
  - Settings: the sections on the left (Appearance, Window, Machines, Service) switch what is shown in the middle, with a live preview of the theme and accent on the right.
  - Notices (a driver to update, apps missing) sit on the card surface with only their icon in the warning color.
  - Home fits the window without scrolling, and the Library opens at the top. On Home, drag the lines between its parts to resize them (the stage and the row under it, the stage's panel, the machines, the Library and the notices; double-click one to reset it); the row of machines scrolls sideways when there are many. Cards glide to their new places when the window changes size or one comes or goes.
  - In the sidebar, a running machine shows a tiny chart of its last minute: processor, memory and GPU in their colors.
  - Many machines stay smooth: scenes out of view don't draw, and Home redraws only the cards that changed.
  - With no machines, Home shows an empty machine in the cube with what the Library has ready and **Create machine**; an empty Library shows, in each section, the card to add the first one.
  - Creating a machine is one large dialog: sections on the left, a summary always in view on the right. A profile fills everything in, and what you change can be saved as a new profile.
- **Disk sizes count the room other machines are promised.** A dynamic disk grows up to its size as the machine writes, so the free space on the drive was not the real limit: several machines could be given more than the drive can hold. Creating a machine, a profile's **Disk** slider and the machine's **Disk** option now stop at what fits once every machine's disk on that drive is full, keeping 20 GB for Windows. The **Disk** option shows a bar with this machine's disk, the room reserved for the others and what would be left. `Get-GpuVMHostInfo` reports it as `disk` and `Get-GpuVMOverview` as `options.diskBudget`.
- **The world of blocks stays smooth with the camera low.** The baseplate's studs are drawn on the GPU in one go (thousands of them near the ground), so turning the camera close to the floor no longer stutters.
- **Drag the cube's edge all the way.** On a machine's page the line between the options and the cube goes from edge to edge: at the right the cube folds into a rail, at the left it takes the whole width; double-click puts it back. A narrow options column puts each control under its text.
- **Section tabs glide** to their section in the Library and on a machine's page, and stop just under the bar.
- **A cleaner light theme.** Secondary text reads better on white, banners show more, hover and selection in lists are a barely gray white, options go without lines between them, what sits under an option uses the card's whole width, machine icons are tones of their own color, tiles and stickers go without a gray edge, and the cube's corners are square.

### Fixed
- **Menus opened inside a dialog show above it.**
- **The name is engraved on the plate again** while you type it when creating a machine, and the rename dialog sits beside the cube instead of under it.

## [0.7.0] - 2026-11-09

### Added
- **Choose the monitor a machine opens on.** **Preferences → Open machines on** sets it for all machines (**Primary**, the default, follows Windows' primary monitor) and each machine's **Options → Open on** can override it. Moonlight has no setting for this, so GpuVM keeps Moonlight's windows on that monitor while it opens; the choice is saved, and an unplugged monitor falls back to the primary one. With the frame rate on **Monitor**, the stream uses that monitor's refresh rate. The module adds `Get-GpuVMMonitor`, `Connect-GpuVM -Monitor` and `Set-GpuVMStreamingClient -Monitor`.
- **Apps already in a machine.** The **Apps** card shows them with a check mark instead of a checkbox, so they can't be chosen again. Clicking one, or right-clicking it, offers **Reinstalar** (Reinstall) and **Desinstalar** (Uninstall), which runs the app's own uninstaller after asking. The module adds `Get-GpuVMInstalledApp`, `Uninstall-GpuVMApp` and `Install-GpuVMApp -Reinstall`; templates and their copies keep the list.

### Fixed
- **Opening from off waits for Windows to sign in.** The display, Sunshine's capture and the sound are prepared once Windows has signed in, with **Iniciando sesión en Windows** on the button meanwhile; before, they failed with warnings and left the picture at the wrong resolution. GpuVM also says when Windows is finishing updates or restarting to finish them.
- **Shutting down says when Windows installs updates.** That can take minutes, and the next start says Windows is finishing them; quitting GpuVM with **Shut them down** remembers it too. The machine's main button is wider so its steps fit.

## [0.6.0] - 2026-11-09

### Added
- **Library → Disks** lists each prepared Windows (**Windows preparado**) with the space it takes, and can delete it after a UAC confirmation. The module adds `Get-GpuVMBase` and `Remove-GpuVMBase`.

### Changed
- Creating a machine takes about 1 minute instead of nearly 3, and the PC no longer slows down meanwhile. Windows is applied once per ISO and edition (about 12.5 GB, kept in the VM folder) and every new machine copies it; the first machine with a new ISO takes about 6 minutes, also without slowing the PC.
- Applying Windows runs at low priority, and the copy paces its own writes so other programs' saves don't stall while it runs.
- Disks are mounted without a drive letter while a machine is created, so no drive appears in File Explorer.
- The list of the GPU driver's files is remembered per driver version, so creating a machine or updating its driver skips about 30 s of searching.
- `max-performance` uses a dynamic disk: a fixed one was not faster inside the VM, and writing its 96 GB at creation took minutes. **Fixed** stays available in custom profiles.

## [0.5.0] - 2026-11-08

### Added
- Gamepads work in the machines: GpuVM installs the virtual gamepad driver (ViGEmBus) in the VM, and a controller on this PC reaches Windows in the VM as an Xbox 360 controller.
- Each machine has a **Tipo de uso** (Use) that tunes Moonlight for what you do in it. **Juegos** (Games), **Películas y video** (Movies and video) or **Trabajo** (Work) set Moonlight's frame rate, V-Sync, frame pacing and mouse for that use; changing any of them by hand shows **Personalizado** (Custom). Library profiles carry it too.
- V-Sync, frame pacing and, under **Avanzado** (Advanced), the mouse (for games, or free as in remote desktop), codec and image quality can be set per machine.
- A machine can stream at your monitor's refresh rate with the **Monitor** frame rate. It is read on every open, and GpuVM adds that rate to the VM's virtual display when it lacks it. At the monitor's own rate V-Sync adds no latency and stutters halve. New machines use it, with V-Sync on.
- When Windows in a machine asks for administrator permission, GpuVM shows a small card over everything, Moonlight included, with the program and its publisher; **Permitir** (Allow) and **Rechazar** (Deny) answer it. Only this PC can answer: a program inside the machine can't approve itself.
- You can choose when the GpuVM service runs, in **Preferences**. **Con GpuVM** (With GpuVM, the default) starts the service when the app opens and stops it when the app quits, once what it was doing is finished; **Con Windows** (With Windows) starts it with Windows; **Manual** starts and stops it only from **Preferences**, which also shows its state.
- If the GpuVM service is stopped or missing, the app says so with a button to start it or repair it.

### Changed
- Opening a machine that is on takes 7-10 s to the picture instead of about 25 s: GpuVM does each preparation once per Windows boot over a single connection, and the **Abrir** (Open) button waits until the picture shows. Clicking it again brings the open Moonlight window to the front instead of opening a second one.
- The default capture is now **Rápida** (fast, Windows.Graphics.Capture): the picture shows about 2.6 s after connecting, where desktop duplication could stay black until something on screen changed, and games in exclusive fullscreen are shown too. **Clásica** (classic, desktop duplication) stays available per machine.
- GpuVM opens without administrator rights, so programs that drive other windows (keyboard, controller or accessibility tools) can drive it too. The new **GpuVM** Windows service does the Hyper-V work with your account's administrator rights.
- Deleting a machine, a disk, a shared disk or a template asks for confirmation in a Windows administrator prompt; if you say no, nothing is deleted.
- GpuVM carries its own PowerShell 7 (7.6.9), so the app no longer needs it installed.
- Choice groups switch to one option per row when the window is narrow, instead of wrapping inside their pill.

### Security
- Only GpuVM's own app, run by an administrator account signed in at the PC, can use the service; other programs and network connections are refused.
- Files and folders a request names (an ISO, a folder to import) are opened first with your own rights, unelevated, and paths that go through a link to another place are refused.

### Fixed
- Opening a machine that is off no longer waits up to 20 minutes for its network address: GpuVM says at once that it is off.
- The memory message says exactly how much free memory the machine needs, including the safety margin.
- A malformed request no longer stops the module's PowerShell process.
- After creating a machine, the app opens it instead of going back to **Inicio** (Home).
- Docs site: the menu button only shows on phones, with one icon (three lines closed, X open) and room next to the language selector; the page outline on the right is narrower.
- Docs site: two-column tables without titles no longer show an empty first row.

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

[0.9.0]: https://github.com/alenj0x1/gpuvm/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/alenj0x1/gpuvm/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/alenj0x1/gpuvm/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/alenj0x1/gpuvm/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/alenj0x1/gpuvm/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/alenj0x1/gpuvm/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/alenj0x1/gpuvm/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/alenj0x1/gpuvm/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/alenj0x1/gpuvm/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alenj0x1/gpuvm/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alenj0x1/gpuvm/tree/v0.1.0
