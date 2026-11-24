---
title: Troubleshooting and known limits
description: Black screen, a picture that stutters, administrator prompts, gamepads, driver sync, Virtual Machine Platform, anti-cheat, GPU selection on Windows 10 and other known limits of GPU-P.
---

## Black screen

The usual causes, in order:

1. **Sunshine is capturing the Hyper-V display** instead of the virtual one. **Start and open** points Sunshine at the virtual display every time. If it warns that Sunshine doesn't see the virtual display, check `C:\GpuVM\setup.log` inside the VM.
2. **The VM's driver doesn't match the host's** (after an NVIDIA driver update). Opening from the app syncs it on its own when the VM is off; or run `./gpuvm.ps1 sync-driver -Name <vm>` with the VM off.
3. **Remote Desktop took the session** away from the GPU display. Close Remote Desktop and use **start and open** again: with the guest password saved, GpuVM moves the session back to the console.

To look at the VM's screen without the GPU, open the Hyper-V console (**View Hyper-V console** in the machine's **⋯** menu, or `vmconnect.exe localhost <vm>`). While the virtual display works, the Hyper-V display is turned off; Remote Desktop still works as a fallback. Machines without Hyper-V have no Hyper-V console.

Known open issue: Sunshine can report "Display device configuration API is temporarily unavailable" and not change the resolution.

## The picture stutters or slows down

The machines share this PC's GPU through GPU-P. When another program uses the GPU heavily (a game, 3D work, many videos), the machine has less left to draw and encode its picture, and it can stutter. Close that program or lower what it draws.

GpuVM's own holograms and scenes stop while a machine's picture is shown, and draw at 30 FPS while GpuVM doesn't have the focus. While a machine stays connected and you are on Home, they still draw:

- Lower **Animation smoothness** and **Animation quality** in **Settings → Appearance** ([Settings](/docs/using-the-app/#settings)).
- Or set **Settings → Window → Going back to Home from a machine** to **Disconnect it**.

## A program waits for administrator permission

Windows' administrator prompts aren't drawn in the machine's picture; GpuVM shows them itself, dropping from the top of the picture or in a card over everything, with **Allow** and **Deny** ([Administrator prompts](/docs/using-the-app/#administrator-prompts)). If none appears:

- GpuVM must be running (the window, the tray, or the notices-only mode after quitting): the prompts come from the app.
- GpuVM needs the VM's Windows password; without it, the VM shows a banner asking for it.
- The watcher is installed the first time the VM is opened from GpuVM; open it once with **Open**.

## Windows open where I can't see them

GPU-P VMs have an extra hidden 1024×768 output; if it was the primary display, new windows (Steam, installers) opened there instead of on the streamed display. **Start and open** fixes it automatically: it keeps the virtual display as the only and primary one. It needs the guest password; if a window is still missing, open the VM again from the app.

## Alt+F4 closed the stream

Not anymore: in fullscreen, Alt+F4, Alt+Tab and the Windows key go to the VM. To quit the stream, press **Ctrl+Alt+Shift+Q**. VMs created before this change get it too the next time they open.

## The gamepad doesn't work

GpuVM installs the gamepad driver (ViGEmBus) the first time it opens the VM, with the guest password saved; Sunshine then restarts to use it. If a controller doesn't respond, open the VM again from GpuVM, and check that the controller works on this PC.

## Driver sync

The guest has to use **the same driver version as the host**. After updating the NVIDIA driver:

- In the app, a notice appears on the VM; it updates on its own the next time you start it from the app, or right away with **Update now** / **Shut down and update**.
- From the CLI: `./gpuvm.ps1 sync-driver -Name <vm>` (VM off), or add `-ShutdownIfRunning`.
- `./gpuvm.ps1 list` shows whether each VM's driver is in sync.

## The first start takes a while

The first boot installs Windows and the streaming components, then restarts once. **Start and open** waits for Windows and for Sunshine, and says so on the button. If Sunshine never responds, the error points to `C:\GpuVM\setup.log` inside the VM. If the VM never gets an IP address, check its screen with the Hyper-V console and that the `Default Switch` exists (Hyper-V machines). If the VM is off, saved or paused, opening it says so at once instead of waiting for an address.

## A second machine takes two minutes to start (without Hyper-V)

On a PC without Hyper-V, while one machine with the GPU is running, starting a second one sometimes waits about two minutes before Windows boots: Windows' GPU sharing retries the GPU's device. The machine then works normally. The first machine and machines without a GPU aren't affected.

## Virtual Machine Platform is off

On a PC without Hyper-V (Windows Home, or an edition with Hyper-V off), GpuVM runs machines on Windows' Virtual Machine Platform. If it is off, the app shows **Turn on Virtual Machine Platform**:

1. Press **Turn on**.
2. Press **Restart now** (save your work first): Windows finishes turning it on when the PC starts again. Restarting later the usual way works too.

From the CLI, as administrator: `Enable-GpuVMPlatform`, then `Restart-GpuVMHost`. `Get-GpuVMPlatform` shows the state; `restartPending` means it is on and waiting for the restart. If the app says Virtual Machine Platform isn't available, this Windows can't run virtual machines: check that it is Windows 10 or 11, 64-bit, and that virtualization is on in the BIOS/UEFI.

## The app says the GpuVM service is stopped or missing

The app runs without administrator rights and asks the **GpuVM** service to run the machines. With the service set to **Manual**, start it with **Start service**, or change it to **With GpuVM** in **Settings → Service** ([Settings](/docs/using-the-app/#settings)). If it is missing (for example, after a failed update), **Repair** registers it again after a UAC prompt; reinstalling GpuVM does the same.

## No audio

The VM's sound comes from GpuVM's USB speaker, **Speakers (GpuVM Audio)** ([Streaming](/docs/streaming/#audio)). **Start and open** installs it, plugs it in again and points Sunshine at it (`virtual_sink`) whenever it's missing, as long as the VM's Windows password is saved in GpuVM. Inside the VM, the server's status is in `C:\ProgramData\GpuVM\Audio\status.json`. Without the password, opening the VM shows a warning. If the profile has `"audio": "none"`, no audio device is installed.

## Pairing fails

Use **Pair the viewer again** in the **⋯** menu. If the viewer is missing, the app says so: install GpuVM again.

## The VM doesn't start: not enough memory

A VM's fixed memory must be free when it starts. Close programs, or lower the VM's memory in its **Machine** section, or open it with **Open with N GB** when the app offers it (or with `-Override @{ vm = @{ memoryGB = 6 } }`).

## Reporting a problem

**Settings → Service → Diagnostics report → Save report** saves a text file in Downloads with the app's and the service's logs. Look at it, then attach it to the report. Every error GpuVM shows, or gets back from the service, is in it with its time.

## Known limits of GPU-P

- **Display:** the Hyper-V console doesn't show the GPU, and machines without Hyper-V have no console at all; streaming is the way to see it.
- **Audio:** the VM has no sound card; GpuVM's own USB speaker gives it one.
- **Driver:** the guest has to use the same version as the host (see above).
- **GPU selection on Windows 10 (Hyper-V):** Windows 10 can't be told which GPU a Hyper-V VM gets: it hands each starting VM to the partitionable GPU with the fewest VMs running. With two partitionable GPUs (an integrated one and the graphics card), GpuVM starts empty VMs for a moment while the machine starts, so it always gets the GPU its profile matches (`gpu.match`). `check` warns whenever there is more than one; with more than two, disable the ones you don't want in Device Manager before starting the VM. Machines without Hyper-V get a GPU of the profile's vendor directly.
- **No checkpoints or saved state:** the VM shuts down instead. GpuVM has its own [restore points](/docs/using-the-app/#restore-points).
- **Anti-cheat:** some anti-cheat systems block virtual machines.
