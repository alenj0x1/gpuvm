# Lab 065: GpuVM machines through HCS instead of Hyper-V (VMMS)

Question: can GpuVM create and run its machines through the Host Compute Service (HCS, `computecore.dll`, what WSL2
uses) instead of the Hyper-V role, keeping the GPU shared (GPU-PV), the agent channel (Hyper-V sockets) and the
network for streaming? HCS only needs the "Virtual Machine Platform" feature, which Windows 10/11 Home include, so a
backend on it would make GpuVM work on every edition.

Reference: App Sandbox (MIT, github.com/jamesstringer90/appsandbox, read at 6c68466, 2026-11-22) creates Windows VMs
with GPU-PV on HCS and says it runs on Windows 11 Home. It needs a self-made "VMMS certificate" for the guest
integration services, and applies the GPU after start (Create -> Start -> Modify Gpu).

`run.ps1` makes a differencing disk over a template, injects a probe offline (HKLM Run key + `guest-probe.ps1`), boots
the machine through HCS, and reads what the guest saw from the disk afterwards. Options: `-Gpu Nvidia|Intel|Default|None`,
`-Network None|ICS`, `-NoTpm`, `-StopOnResetFalse`. Takes `C:\GpuVM\.lab-lock` and leaves nothing behind (compute
system, disk, HCN network, VM access grants). Raw output in `out/` (git-ignored).

## Results (2026-11-23, host Windows 10 Pro for Workstations 19045, RTX 4060 + UHD 730, template normal-tpl)

| Check | Result |
| --- | --- |
| Create + start + GPU-PV through HCS | ok, 0.1 s; GPU picked by its partition-adapter interface path (cfgmgr32, no Hyper-V cmdlet) |
| TPM / guest state isolation (`SecuritySettings`) | rejected by Windows 10's HCS schema (`Unknown object field`); the template boots without it |
| Guest reboot | with the default the compute system ends on reset (sysprep pass ended run 2 at 55 s); `StopOnReset: false` keeps it |
| Boot to logon script | 25.5 s (Hyper-V path for comparison: ~33 s to PowerShell Direct, lab 064) |
| GPU in the guest | RTX 4060 `OK`, `nvidia-smi`: 610.88, 8188 MiB; dxdiag: DirectX 12, FL 12_1, 7956 MB dedicated on the virtual display |
| Sunshine service | Running |
| Integration services | time sync Running; heartbeat, KVP, shutdown, VSS Stopped (no VMMS for these VMs) |
| Hyper-V socket guest -> host (`ServiceTable` entry) | ok, connect 7.6 ms, request/reply works |
| Network, ICS without flags/subnet | adapter Up, no DHCP address in 90 s |
| Network, ICS with `Flags: 11` + `Ipams` subnet (as the Default Switch) | DHCP address in 0.9 s, internet ok, host reaches Sunshine (TCP 47989/47984 open, 1-3 ms); network and endpoint deleted at the end |

## Windows 10 Home (`home.ps1`, 2026-11-23)

A Windows 10 Home 22H2 machine (build 19045, from the Win10 ISO, edition index 1) made with `New-GpuVM`, GPU adapter
removed, nested virtualization on, 6 GB fixed. Inside: no `Microsoft-Hyper-V*` feature at all, no `vmms` service, no
Hyper-V PowerShell module. Only `VirtualMachinePlatform` turned on (+1 restart). `home-probe.ps1` then:

| Step | Result |
| --- | --- |
| Disks with diskpart (dynamic + differencing) | ok, 1.9 s |
| Guest state files, `HcsGrantVmAccess` | ok |
| HCN ICS network (DHCP) + endpoint | ok; the first network took 272 s (HNS/ICS starting for the first time on that machine) |
| HCS create + start (UEFI, Secure Boot, SCSI disk, NIC, Hyper-V sockets, `StopOnReset: false`) | ok, 0.2 s |
| Still Running after 20 s, terminate | ok |
| GPU `Default` assignment | accepted (no partitionable GPU in a nested guest, so GPU-PV itself is not proven on Home here) |

Same probe on **Windows 11 Home build 26300** (`Windows11_Client_x64_en-us_26300_9457.iso`, index 1, run
`out/20261123-223957-home.json`): no Hyper-V feature, no `vmms`; diskpart, guest state files, access grants, HCN ICS
network (1.0 s this time) + endpoint, HCS create/start (0.3 s), Running after 20 s, GPU `Default` accepted, terminate:
all ok. Windows 11 restarts fast enough to cut the PowerShell Direct call that asks for the restart, and GpuVM's setup
restart (`rebootPending`) is now awaited instead of aborted (aborting raced with `setup.ps1` scheduling it).

`HcsGetServiceProperties` with a null query is rejected on Windows 10 (invalid JSON document); not needed.

Four Home runs failed before this one because of the lab, not HCS: PowerShell Direct still answered right after
`Restart-Computer`, and GpuVM's own `guest/setup.ps1` restarts the machine once Sunshine is installed (`shutdown /r /t 15`).
The lab now waits for a new boot time and for `setup.done.json`, and aborts that pending restart.

## Stream smoothness, Hyper-V vs HCS (`stream.ps1`, 2026-11-23)

Two copies of normal-tpl running at once, 4 CPUs and 4 GB each: a GpuVM disposable (Hyper-V, GPU-P, Default Switch)
and an HCS machine (GPU-PV, HCN ICS). Both show `tools/latency/motion-target.ps1`; Moonlight (borderless, 1920x1080)
opens each in turn and `motion-meter.ps1` reads the bar on the host screen (1920x1080 @ 179 Hz). 2 rounds, arms and
variants interleaved, 20 s per sample, host GPU 0.6 % before the run. Run `out/20261123-220631-stream.json`.

| Variant | Arm | Updates/s (r1, r2) | Interval sd, ms | p99, ms | Stutter % (r1, r2) |
| --- | --- | --- | --- | --- | --- |
| auto (180) + V-Sync | Hyper-V | 143.4, 145.7 | 1.38, 2.26 | 11.3, 11.3 | 0.18, 0.72 |
| auto (180) + V-Sync | HCS | *98.7*, 147.7 | 3.04, 0.95 | 16.6, 11.1 | 1.17, 0.10 |
| 120, no V-Sync | Hyper-V | 99.5, 99.0 | 4.10, 3.09 | 11.6, 16.7 | 0.81, 1.98 |
| 120, no V-Sync | HCS | 100.0, 101.2 | 3.11, 2.84 | 16.4, 11.5 | 1.01, 0.30 |
| 60 + V-Sync + pacing | Hyper-V | 41.7, 44.0 | 8.18, 6.03 | 50, 38.9 | 19.8, 21.5 |
| 60 + V-Sync + pacing | HCS | 38.8, 42.5 | 9.14, 7.17 | 50, 49.9 | 32.9, 26.3 |

Reading: at auto and 120 FPS the two arms are within run-to-run noise (HCS's first auto sample was low, its second
the best of all). 60 + pacing is slightly worse on HCS in both rounds, but that mode is broken on both arms: lab 021
measured 59 updates/s and ~1 % stutter for it on Nov 8, so a regression shared by both paths hides there (A/B equal
can hide a shared regression) and 2 rounds are not enough to separate the arms. Host GPU during samples 15-42 % on both.

### 60 FPS follow-up (`stream.ps1 -Set sixty -Rounds 3`, run `out/20261123-232857-stream.json`)

Cause of the bad 60 + pacing numbers above: that run left the VM's display at 179 Hz while streaming 60 FPS. GpuVM
(`Connect-GpuVM` -> `Set-GuestDisplayResolution`) and lab 021 set the VM's display to the stream's rate. The lab now
does the same for both arms (Hyper-V through PowerShell Direct; HCS through the Hyper-V socket, the guest running GpuVM's
own `guest/set-resolution.ps1`). Host GPU 3.4 % before the run.

| Variant | Arm | Updates/s (mean) | Stutter % (r1/r2/r3) |
| --- | --- | --- | --- |
| 60 + pacing, VM display 179 Hz | Hyper-V | 41.9 | 22.5 / 26.0 / 26.8 |
| 60 + pacing, VM display 179 Hz* | HCS | 40.1 | 24.3 / 32.8 / 34.1 |
| 60 + pacing, VM display 60 Hz | Hyper-V | 47.4 | 6.3 / 7.2 / 8.0 |
| 60 + pacing, VM display 60 Hz | HCS | 42.8 | 2.4 / 12.1 / 3.6 |
| 60 + V-Sync, VM display 60 Hz | Hyper-V | 46.4 | 4.9 / 3.2 / 19.4 |
| 60 + V-Sync, VM display 60 Hz | HCS | 47.7 | 2.3 / 14.4 / 3.1 |

\* Going back to 179 Hz the HCS guest got 165 Hz: GpuVM adds the 179 Hz mode through PowerShell Direct
(`Add-GuestRefreshRate`), which the HCS arm cannot call yet.

Reading: matching the VM's display to the stream takes stutter from 22-34 % to mostly 2-8 % on both arms; Hyper-V and
HCS stay within noise of each other (each has one 12-19 % outlier). Still below lab 021 (59 updates/s, ~1 %): both
arms are equally affected, and unlike lab 021 two machines run at once here (the other one keeps drawing its bar).
Not separated yet.

Control with one machine only (`-Arms hyperv`, then `-Arms hcs`, 3 rounds each; runs `out/20261123-235325-stream.json`
and `out/20261124-000016-stream.json`):

| Variant | Hyper-V alone: upd/s, stutter % (r1/r2/r3) | HCS alone: upd/s, stutter % (r1/r2/r3) |
| --- | --- | --- |
| 60 + pacing, display 179 Hz (HCS 165) | 41.4; 22.9 / 29.6 / 29.6 | 37.1; 44.6 / 36.3 / 43.0 |
| 60 + pacing, display 60 Hz | 45.4; 2.9 / 14.1 / 13.3 | 45.6; 23.7 / 11.8 / 1.1 |
| 60 + V-Sync, display 60 Hz | 43.1; 5.1 / 21.4 / 15.5 | 46.1; 17.8 / 9.8 / 3.3 |

Reading: one machine alone is no better than two at once, so the second machine is not why 60 FPS stays below lab 021.
At 60 Hz the two paths are again within noise (both swing 1-24 % between rounds). With the display left at a rate that
is not a multiple of 60, HCS was worse alone (36-45 % vs 23-30 %), but there it ran at 165 Hz, not 179 (see above),
so that row compares different displays. The gap to lab 021 is shared by both paths; lab 021 captured with DDX, and
WGC became the default capture right after it (Nov 8) and is what these template copies use. Suspect, not measured.

Method notes: the first 12-sample run failed entirely (Moonlight not paired with template copies); the lab now pairs
Moonlight with each copy (PIN through Sunshine's API, then closes Moonlight, which stays open after `pair`) and stops if
the first sample of an arm shows no picture. The pairing adds a "<PC> lab065" client to each disposable copy only.

## Verdict

HCS gives GpuVM what it needs on Windows 10 Pro, Windows 10 Home and Windows 11 Home without the Hyper-V role: VM
lifecycle, GPU-PV with the RTX (DirectX 12, CUDA driver, Sunshine running), Hyper-V sockets for the agent and a DHCP
network that Moonlight can reach, with the stream as smooth as through Hyper-V at auto and 120 FPS.
Still open before a backend: GPU-PV on a real Home PC (same `dxgkrnl` paravirtualization WSL2 uses on Home, but not
measured here), the 60 FPS + pacing regression shared by both paths (more rounds), and replacements for KVP,
heartbeat and the shutdown IC (the agent), PowerShell Direct (the agent) and `New-VHD`/`Mount-VHD` (diskpart,
`Mount-DiskImage`). `CreateVirtualDisk` from C# returned 87 with the V2 parameters; diskpart was used instead.

## Notes

- Run 2's `finally` crashed on the same missing `State` property and left the lock, disk and VM access grants;
  cleaned by hand (HcsRevokeVmAccess on every layer). The read-back is now its own helper and every cleanup step is
  guarded.
- What GpuVM uses today that HCS does not give: KVP (admin prompt answers), heartbeat (Windows ready), shutdown IC,
  `Get-VM` and PowerShell Direct. The agent over Hyper-V sockets can replace all of them.
