---
title: Troubleshooting and known limits
description: Black screen in Moonlight, driver sync, anti-cheat, GPU selection on Windows 10 and other known limits of GPU-P.
---

## Black screen in Moonlight

The usual causes, in order:

1. **Sunshine is capturing the Hyper-V display** instead of the virtual one. **Start and open** (or `./gpuvm.ps1 connect`) points Sunshine at the virtual display every time. If it warns that Sunshine doesn't see the virtual display, check `C:\GpuVM\setup.log` inside the VM.
2. **The VM's driver doesn't match the host's** (after an NVIDIA driver update). Opening from the app syncs it on its own when the VM is off; or run `./gpuvm.ps1 sync-driver -Name <vm>` with the VM off.
3. **Remote Desktop took the session** away from the GPU display. Close Remote Desktop and use **start and open** again: with the guest password saved, GpuVM moves the session back to the console.

To look at the VM's screen without the GPU, open the Hyper-V console (**Ver consola de Hyper-V**, or `vmconnect.exe localhost <vm>`). While the virtual display works, the Hyper-V display is turned off; Remote Desktop still works as a fallback.

Known open issue ([lab 002](/gpuvm/labs/#what-the-labs-found-so-far)): Sunshine can report "Display device configuration API is temporarily unavailable" and not change the resolution.

## A fullscreen program shows a black screen

The desktop streams fine, but a game or program in **exclusive fullscreen** shows black (it may appear when it loses focus). The standard capture can't see exclusive fullscreen on a virtual display ([lab 009](/gpuvm/labs/#what-the-labs-found-so-far)). In **Options → Captura** (Capture) choose **Pantalla completa exclusiva** (Exclusive fullscreen) and save. In that mode Windows' administrator prompts aren't shown in the stream; switch back to **Estándar** (Standard) when you need them. See [Capture modes](/gpuvm/streaming/#capture-modes).

## Windows open where I can't see them

GPU-P VMs have an extra hidden 1024×768 output; if it was the primary display, new windows (Steam, installers) opened there instead of on the streamed display. **Encender y abrir** (Start and open) now fixes it automatically: it keeps the virtual display as the only and primary one. It needs the guest password; if a window is still missing, open the VM again from the app.

## Alt+F4 closed the stream

Not anymore: in fullscreen, Alt+F4, Alt+Tab and the Windows key go to the VM. To quit the stream, press **Ctrl+Alt+Shift+Q**. VMs created before this change get it too the next time they open.

## Driver sync

The guest has to use **the same driver version as the host**. After updating the NVIDIA driver:

- In the app, a notice appears on the VM; it updates on its own the next time you start it from the app, or right away with **Actualizar ahora** / **Apagar y actualizar**.
- From the CLI: `./gpuvm.ps1 sync-driver -Name <vm>` (VM off), or add `-ShutdownIfRunning`.
- `./gpuvm.ps1 list` shows whether each VM's driver is in sync.

## The first start takes a while

The first boot installs Windows and the streaming components, then restarts once. **Start and open** waits for Windows and for Sunshine, and says so on the button. If Sunshine never responds, the error points to `C:\GpuVM\setup.log` inside the VM. If the VM never gets an IP address, check its screen with the Hyper-V console and that the `Default Switch` exists.

## No audio

The VM's sound comes from GpuVM's USB speaker, **Speakers (GpuVM Audio)** ([Streaming](/gpuvm/streaming/#audio)). **Encender y abrir** (Start and open) installs it, plugs it in again and points Sunshine at it (`virtual_sink`) whenever it's missing, as long as the VM's Windows password is saved in GpuVM. Inside the VM, the server's status is in `C:\ProgramData\GpuVM\Audio\status.json`. Without the password, opening the VM shows a warning. If the profile has `"audio": "none"`, no audio device is installed.

## Pairing fails

Use **Volver a emparejar Moonlight** in the menu, or `./gpuvm.ps1 connect -Name <vm> -Pair`. If Moonlight isn't installed, install it ([Install](/gpuvm/install/#install-moonlight)).

## The VM doesn't start: not enough memory

Hyper-V's fixed memory must be free when the VM starts. Close programs, or lower the VM's memory in **Options** (or with `-Override @{ vm = @{ memoryGB = 6 } }`).

## Known limits of GPU-P

- **Display:** the Hyper-V console doesn't show the GPU; streaming is the way to see it. The streaming path is still being validated on a real VM ([lab 002](/gpuvm/labs/)).
- **Audio:** the VM has no sound card; GpuVM's own USB speaker gives it one, verified on a real VM through Moonlight ([lab 012](/gpuvm/labs/)).
- **Driver:** the guest has to use the same version as the host (see above).
- **GPU selection on Windows 10:** you can't choose which GPU the VM gets. If the integrated GPU is also partitionable, the VM may get the wrong one. `check` warns about it; disable the integrated GPU in Device Manager before starting the VM ([lab 001](/gpuvm/labs/)).
- **No checkpoints or saved state:** the VM shuts down instead.
- **Anti-cheat:** some anti-cheat systems block virtual machines.
