# Lab 067: the HCS engine in the host service, end to end

Question: does the Rust HCS engine in `gpuvm-host` (`app/host/src/hcs`) make, start and delete a real GpuVM machine
on its own, with the GPU, GpuVM's network, Hyper-V sockets and link-safe offline writes, without PowerShell or the
Hyper-V module?

`run.ps1` drives `gpuvm-host hcs create|write|start|state|off|delete|network-delete` against a copy of `normal-tpl`.
The probe from lab 065 (`guest-probe.ps1`, which reports what the guest sees and shuts the machine down) is written
into the disk with `hcs write` and started from the all-users Startup folder, so no registry edit is needed. `-Keep`
leaves the machine for inspection. Raw output in `out/` (git-ignored).

## Results (2026-11-24, Windows 10 Pro 19045, RTX 4060)

| Step | Result |
| --- | --- |
| `hcs create` (differencing disk, guest state files, record) | ok |
| `hcs write` x4 (probe, hvsock.cs, service id, Startup .cmd) | ok, ~240 ms each (attach + find the Windows volume + write + detach) |
| `hcs start` (grants, network, endpoint, compute system, GPU) | 408-489 ms, GPU "shared" |
| Machine outlives the CLI process that started it | yes: later `hcs state` calls open it by id (10-12 ms each) |
| Guest: logon script | 27.7 s after boot |
| Guest: RTX 4060 | `OK`, `nvidia-smi` 610.88 / 8188 MiB; dxdiag DirectX 12, FL 12_1, 7956 MB dedicated |
| Guest: network | DHCP 192.168.165.x in 0.8 s, internet ok |
| Guest -> host Hyper-V socket (service table entry) | connect 4.4 ms; the peer VM id the host sees = the system's RuntimeId |
| Host -> guest Sunshine | TCP 47989 / 47984 open (0-3 ms) |
| Guest shuts itself down | system gone 54 s after start |
| `hcs delete` + `hcs network-delete` | ok; nothing left (folder, disk, grants, network) |

## Notes

- First run read no `result.json`: the volume path `Get-Volume` gives for a read-only mounted image could not be
  opened. Reading through a drive letter shows the files; the lab now does that. The engine's own writes go through
  `\\?\Volume{...}\` paths of the attached disk and landed where the guest read them.
- Every copy of a template has the same partition GUIDs. The engine matches volumes by disk number, so it never writes
  into another disk; two copies attached at the same time may leave one without a mounted volume (the write then
  fails instead of going elsewhere). Not seen in these runs.
- Host restart, shutdown through the guest and admin commands in the guest are the guest-channel phase's work: HCS
  machines have no shutdown integration service.
