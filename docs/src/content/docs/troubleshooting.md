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

## Driver sync

The guest has to use **the same driver version as the host**. After updating the NVIDIA driver:

- In the app, a notice appears on the VM; it updates on its own the next time you start it from the app, or right away with **Actualizar ahora** / **Apagar y actualizar**.
- From the CLI: `./gpuvm.ps1 sync-driver -Name <vm>` (VM off), or add `-ShutdownIfRunning`.
- `./gpuvm.ps1 list` shows whether each VM's driver is in sync.

## The first start takes a while

The first boot installs Windows and the streaming components, then restarts once. **Start and open** waits for Windows and for Sunshine, and says so on the button. If Sunshine never responds, the error points to `C:\GpuVM\setup.log` inside the VM. If the VM never gets an IP address, check its screen with the Hyper-V console and that the `Default Switch` exists.

## No audio

Audio (`virtual_sink` in Sunshine) is configured after the VM's first automatic restart, and **Encender y abrir** (Start and open) sets it again if it's missing, as long as the VM's Windows password is saved in GpuVM. Without the password, opening the VM shows a warning. If the profile has `"audio": "none"`, no audio device is installed.

## Pairing fails

Use **Volver a emparejar Moonlight** in the menu, or `./gpuvm.ps1 connect -Name <vm> -Pair`. If Moonlight isn't installed, install it ([Install](/gpuvm/install/#install-moonlight)).

## The VM doesn't start: not enough memory

Hyper-V's fixed memory must be free when the VM starts. Close programs, or lower the VM's memory in **Options** (or with `-Override @{ vm = @{ memoryGB = 6 } }`).

## Known limits of GPU-P

- **Display:** the Hyper-V console doesn't show the GPU; streaming is the way to see it. The streaming path is still being validated on a real VM ([lab 002](/gpuvm/labs/)).
- **Audio:** solved with VB-CABLE; still being checked on a real VM ([lab 003](/gpuvm/labs/)).
- **Driver:** the guest has to use the same version as the host (see above).
- **GPU selection on Windows 10:** you can't choose which GPU the VM gets. If the integrated GPU is also partitionable, the VM may get the wrong one. `check` warns about it; disable the integrated GPU in Device Manager before starting the VM ([lab 001](/gpuvm/labs/)).
- **No checkpoints or saved state:** the VM shuts down instead.
- **Anti-cheat:** some anti-cheat systems block virtual machines.
