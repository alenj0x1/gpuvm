---
title: CLI reference
description: The gpuvm.ps1 commands and the GpuVM PowerShell module cmdlets.
---

`gpuvm.ps1`, at the root of the repository, is a shortcut for the `GpuVM` module. Run it from PowerShell 7 **as administrator** to create and modify VMs. (The app doesn't need this: it carries its own PowerShell 7 and the GpuVM service runs the module for it.)

```powershell
./gpuvm.ps1 <command> [-Parameter value ...]
```

- Without a command (or with an unknown one) it prints the list of commands.
- If it's started from Windows PowerShell 5.1, it runs itself again in PowerShell 7 with the same arguments.
- Parameters are written as in PowerShell: `-Name value`, a switch alone (`-Start`), or `-Name:value` (`-Confirm:$false`). A negative number after a parameter is a value, not another parameter.
- Help for each command: `Get-Help <Cmdlet> -Detailed`.

## Commands

| Command | Cmdlet | What it does |
|---|---|---|
| `check` | `Test-GpuVMHost` | Checks whether the PC is ready to create a VM with the given profile. |
| `new` | `New-GpuVM` | Creates a Windows 10/11 VM with the host GPU, installed unattended from an ISO. |
| `set` | `Set-GpuVM` | Changes an existing VM that is off (profile or override). |
| `list` | `Get-GpuVM` | Lists the VMs created with GpuVM and whether their GPU driver matches the host's. |
| `sync-driver` | `Sync-GpuVMDriver` | Copies the host's GPU driver into the guest. |
| `components-update` | `Update-GpuVMComponent` | Looks for new versions of the streaming components. |
| `remove` | `Remove-GpuVM` | Removes the VM from Hyper-V. |
| `rename` | `Rename-GpuVM` | Renames the VM with its folder and disk. |
| `repair` | `Repair-GpuVMState` | Rebuilds the state file of a VM created with GpuVM. |
| `profiles` | `Get-GpuVMProfile` | Lists profiles, or shows one resolved. |
| `lab-new` | `New-GpuVMLab` | Opens a lab. |
| `lab-add` | `Add-GpuVMLabResult` | Records a measurement in a lab. |
| `lab` | `Get-GpuVMLab` | Lists labs, or shows one with its comparison. |
| `lab-close` | `Close-GpuVMLab` | Closes a lab with its conclusion. |

## Parameters

### check

| Parameter | Default | |
|---|---|---|
| `-Profile` | `balanced` | Profile to check against. |
| `-Override` | | Hashtable merged over the profile. |

Checks Windows edition, administrator rights, virtualization, Hyper-V, partitionable GPUs, GPU selection on Windows 10, network switch, the profile against your hardware, free memory, the GPU, disk space and the streaming components.

### new

| Parameter | Default | |
|---|---|---|
| `-Name` | required | Letters, numbers, `_` or `-`, up to 40 characters. |
| `-IsoPath` | required | Windows 10/11 ISO. |
| `-Profile` | `balanced` | |
| `-Override` | | Hashtable merged over the profile. |
| `-Edition` | profile's `guest.edition` (`Pro`) | Windows edition from the ISO. |
| `-Credential` | asks | Local account of the guest. |
| `-Start` | | Start the VM when it's created. |

### set

`-Name` (required), `-Profile`, `-Override`. The VM must be off. Without `-Profile` it starts from the VM's current settings; with `-Profile` it keeps the disk, folder and picture preferences.

### list

`-Name` (default `*`). Shows name, state, profile, backend, CPU, memory, GPU, driver version, whether the driver is in sync and the edition.

### sync-driver

`-Name` (required), `-ShutdownIfRunning` (shuts the VM down, syncs and starts it again). Use it after updating the NVIDIA driver.

### components-update

`-Name` (one or more components: `sunshine`, `vdd`, `nefcon`, `usbip`, `vigembus`; all by default, except those on hold). Supports `-WhatIf`. See [Streaming](/docs/streaming/#updating-components).

### remove

`-Name` (required), `-DeleteDisk` (also deletes the VM folder and disk; can't be undone).

### rename

`-Name` and `-NewName` (required). The VM must be off. Renames it in Hyper-V, its folder and disk, and keeps its settings, the viewer's pairing and shared disks. The new name follows the same rules as `new`; if a step fails, what was already renamed is undone.

### repair

`-Name` (required), `-Profile` (default `balanced`), `-Override`. Rebuilds `gpuvm.json` of a VM created with GpuVM whose state was lost. The VM must be off. If the guest hasn't booted yet, it also recovers the Sunshine password from its disk.

### profiles

`-Name`, `-Override`. Without a name it lists the profiles; with a name it shows the profile with inheritance and override applied.

### lab-new

| Parameter | Default |
|---|---|
| `-Title` | required |
| `-Hypothesis` | required |
| `-VM` | |
| `-BaselineProfile` | `balanced` |
| `-BaselineOverride` | |
| `-CandidateProfile` | |
| `-CandidateOverride` | |

### lab-add

`-Lab`, `-Variant` (`baseline` or `candidate`), `-Metric`, `-Value` (all required), `-Unit`, `-LowerIsBetter`, `-Notes`.

### lab

`-Lab` (optional).

### lab-close

`-Lab`, `-Status` (`adopted`, `rejected` or `inconclusive`), `-Conclusion` (all required).

## Examples

```powershell
./gpuvm.ps1 check -Profile max-performance          # check the PC
./gpuvm.ps1 new -Name win11 -IsoPath D:\Win11.iso -Profile max-performance -Start
./gpuvm.ps1 list                                     # VMs and whether their driver matches the host's
./gpuvm.ps1 sync-driver -Name win11                  # after updating the NVIDIA driver (VM off)
./gpuvm.ps1 set -Name win11 -Profile balanced        # switch profile (VM off)
./gpuvm.ps1 rename -Name win11 -NewName games        # rename (VM off)
./gpuvm.ps1 remove -Name win11                       # add -DeleteDisk to delete the disk too
```

## Module

```powershell
Import-Module ./src/GpuVM/GpuVM.psd1
```

Besides the cmdlets above, the module exports these, used mainly by the app:

| Cmdlet | What it does |
|---|---|
| `Get-GpuVMOverview` | Every Hyper-V VM with its state and live usage (CPU, memory, GPU), created with GpuVM or not. For GpuVM machines, `options.diskBudget` says how far its disk can grow, counting the room promised to the other machines on that drive. |
| `Get-GpuVMHostInfo` | Host threads, memory and GPU name, and as `disk` the room a new machine's disk has on GpuVM's drive once every machine's disk there is full, keeping 20 GB for Windows. |
| `Get-GpuVMIsoList` | Windows ISOs in Downloads and Desktop. |
| `Invoke-GpuVMPower` | `-Action` `Start`, `Shutdown`, `TurnOff`, `Restart`, `Pause` or `Resume` on any VM. |
| `Set-GpuVMGuestCredential` | Saves the guest account (DPAPI) so GpuVM can fix things inside the VM through PowerShell Direct. |
| `Set-GpuVMStreamingClient` | Changes how the VM's picture opens. Doesn't need the VM off. See [below](#set-gpuvmstreamingclient). |
| `Connect-GpuVM` | `-Name`, `-Pair`, `-Monitor`, `-MemoryGB`. Gets a machine ready for GpuVM's viewer (driver, start, Windows, session, display, pairing) and returns the stream arguments (`viewerLaunch`); the app opens the viewer itself. See [Streaming](/docs/streaming/#from-powershell). |
| `Get-GpuVMAdminPrompt` | The Windows administrator prompts open in running GpuVM machines: `name`, `id`, `app`, `publisher`. Reads Hyper-V's data exchange only (about 100 ms, no PowerShell Direct); the app polls it every second. |
| `Resolve-GpuVMAdminPrompt` | `-Name`, `-Answer` `Allow` or `Deny`, `-PromptId` (the `id` from `Get-GpuVMAdminPrompt`). Presses Yes or No in the VM, only if that prompt is still the one open; otherwise it fails and presses nothing. Needs the guest password. See [Administrator prompts](/docs/streaming/#administrator-prompts). |
| `Update-GpuVMSettings` | Applies processor, memory or GPU even if the VM is running: validates, shuts it down, applies and starts it again; restores the previous settings if it can't start. |
| `Get-GpuVMHome` | What the app's Home shows: the last machine opened, which machines fit in memory and what needs attention. |
| `Stop-GpuVMAll` | Shuts down every running GpuVM machine cleanly, all at once. |
| `Send-GpuVMClipboard` | Puts text into the VM's clipboard (only from the PC to the VM). |
| `Set-GpuVMNetworkIsolation` | Turns the VM's network isolation on (the default) or off. |
| `Get-GpuVMCleanup` / `Set-GpuVMCleanup` | The Windows cleanup levels / applies one to a VM. |
| `Get-GpuVMMonitor` | This PC's monitors, left to right (`id`, name, size, refresh rate, which one is primary), to choose where a VM opens. |
| `Get-GpuVMApp` / `Install-GpuVMApp` | The app catalog / installs apps in a VM (starts it if needed). Apps already installed are left as they are; `-Reinstall` uninstalls them first and installs them again. |
| `Get-GpuVMInstalledApp` | `-Name`. The catalog apps installed in a VM: checked inside Windows while it runs, the last ones seen while it is off. |
| `Uninstall-GpuVMApp` | `-Name`, `-App`. Uninstalls apps with each one's own uninstaller, silently (starts the VM if needed). Battle.net's has no silent mode: it opens on the VM's desktop to finish there. |
| `Add-GpuVMIso` / `Remove-GpuVMIso` | Remembers an ISO in the library / forgets it (the file stays). |
| `Get-GpuVMDisk` / `Restore-GpuVM` / `Remove-GpuVMDisk` | The disks in the GpuVM folder / creates a VM again from a kept disk / deletes a free disk. |
| `Get-GpuVMBase` / `Remove-GpuVMBase` | The prepared Windows bases (one per ISO and edition) / deletes one; the next VM with that Windows prepares it again. |
| `Save-GpuVMProfile` / `Remove-GpuVMProfile` | Creates or updates a user profile / deletes it. |
| `New-GpuVMTemplate` / `Get-GpuVMTemplate` / `Remove-GpuVMTemplate` | Saves a stopped VM as a template / lists templates (with `stale`, `updating` and `layers`) / deletes one no VM is built on. |
| `Update-GpuVMTemplate` | `-Name` or `-Stale` (every template that needs it), `-Force`. Brings a template up to this GpuVM's Sunshine (and agent, for an agent template) as a read-only layer on top of it: a temporary copy gets the install once, shuts down cleanly and its disk becomes the newest layer, so copies don't install them one by one. Copies made before keep their layer. The app runs `-Stale` when it starts and every hour. |
| `New-GpuVMSharedDisk` / `Get-GpuVMSharedDisk` / `Connect-GpuVMSharedDisk` / `Disconnect-GpuVMSharedDisk` / `Import-GpuVMSharedDisk` / `Remove-GpuVMSharedDisk` | Shared disks: create, list, attach, detach, copy a folder of this PC into one, delete. |
| `Get-GpuVMRestorePoint` / `New-GpuVMRestorePoint` / `Restore-GpuVMRestorePoint` / `Remove-GpuVMRestorePoint` | Restore points of a stopped VM: list, save, go back (`-SaveCurrent` keeps how it is now as a new point first), delete. |
| `Export-GpuVM` / `Get-GpuVMImportInfo` / `Import-GpuVM` | Saves a stopped VM to one `.gpuvm` file, without its Windows password / reads what a file holds / creates a VM from it, with its own streaming identity. |
| `Set-GpuVMDisposable` / `Remove-GpuVMDisposable` | Keeps a disposable machine as a regular one / deletes the disposable machines that are off. |
| `Send-GpuVMFile` / `Get-GpuVMExplorerSelection` | Copies files and folders from this PC, or from another running VM, into a VM's `Desktop\Received` / what is selected in a VM's File Explorer. |
| `Set-GpuVMUse` / `Install-GpuVMAgent` / `Uninstall-GpuVMAgent` | Makes a VM an agent machine or a person's again / installs or removes GpuVM's agent inside it. The other `*-GpuVMAgent*` cmdlets serve the [Agents](/docs/agents/) section and the MCP server. |

Through the app, `Remove-GpuVM`, `Remove-GpuVMDisk`, `Remove-GpuVMBase`, `Remove-GpuVMSharedDisk` and `Remove-GpuVMTemplate` also need a UAC confirmation ([Architecture](/docs/architecture/#bridge-between-the-app-and-powershell)).

### Set-GpuVMStreamingClient

| Parameter | |
|---|---|
| `-Name` | Required. |
| `-Resolution` | For example `2560x1440`. |
| `-Fps` | 10–480, or `0` for the host monitor's refresh rate, read every time the VM opens. |
| `-BitrateKbps` | 0–500000; `0` lets the viewer choose it from the resolution and FPS. |
| `-Codec` | `auto`, `H.264`, `HEVC` or `AV1`. |
| `-DisplayMode` | `fullscreen`, `windowed` (a resizable window the size of the resolution) or `borderless`. |
| `-VSync` | `$true` or `$false`. Unset leaves it as is. |
| `-FramePacing` | `$true` or `$false`. Turned off whenever V-Sync is off. |
| `-Mouse` | `capture` (the VM takes the mouse, for games) or `absolute` (the pointer moves freely, as in remote desktop). |
| `-Monitor` | The monitor the VM opens on: an `id` from `Get-GpuVMMonitor`, `primary`, or `default` to follow the app's choice in Settings. |

```powershell
Set-GpuVMStreamingClient -Name win11 -Fps 0 -VSync $true -FramePacing $false -Mouse capture   # the "Games" use
```
