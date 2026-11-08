# Unelevated window, elevated service

**Hypothesis:** GpuVM's window can run without administrator (so programs like Console UI can drive it: Windows blocks input into elevated windows, UIPI) if the Hyper-V work moves to a Windows service that runs `bridge.ps1` behind a named pipe. The pipe adds no noticeable latency to the app's queries, and only GpuVM, run by the signed-in user, can use it.

## Procedure

`gpuvm-host-lab.exe` (Rust, `windows-sys`) has every role:

- **service**: registered by `install.ps1` from `C:\Program Files\GpuVM-lab` (never from a user folder), two instances side by side:
  - `GpuVMLab018-user`: the bridge runs with the signed-in user's elevated token (`WTSQueryUserToken` + `TokenLinkedToken`): same profile, DPAPI and paths as the app today.
  - `GpuVMLab018-system`: the bridge runs as LocalSystem.
- **Pipe**: `\\.\pipe\gpuvm-lab-018-<mode>`, DACL `D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;0x00100083;;;<user SID>)(D;;GA;;;NU)`. The user gets read, write and synchronize only. `GENERIC_WRITE` would include `FILE_CREATE_PIPE_INSTANCE` and let any user program open instances of the name. The pipe is created with `FILE_FLAG_FIRST_PIPE_INSTANCE` and `PIPE_REJECT_REMOTE_CLIENTS`.
- **Client check**: before starting a bridge, the service reads the client's PID from the pipe and checks its image path against an allow list and its token's SID against the installing user.
- **Server check**: the client compares the pipe server's PID with the service's PID from the Service Control Manager, so it detects a program that took the name first.
- **Bridges**: one per connection, in a job object with `KILL_ON_JOB_CLOSE` (they die with the service). Same request/response protocol as today.
- **bench-direct**: baseline. Spawns the bridge directly from an elevated process, as `gpuvm.exe` does now.

Scripts: `install.ps1`, `use-local-pwsh.ps1`, `update.ps1`, `bench-all.ps1` and `uninstall.ps1` run elevated; `run.ps1` runs unelevated. The installed GpuVM 0.4.1 is the code root. Measured query: 30 × `Get-GpuVMOverview` (what the app polls), with `win10` running.

## Observations

### Runs of Nov 8, 2026

**Identity of the bridge**

| Mode | Bridge runs as |
|---|---|
| user | the signed-in user, elevated, session 1 |
| system | `NT AUTHORITY\SYSTEM` |

**PowerShell from the Store fails in user mode.** The bridge exited at once with `0x80008082`: `hostfxr.dll` failed with access denied (`0x80070005`). Files under `WindowsApps` let users execute them only through a conditional ACE, `WIN://SYSAPPID Contains "MICROSOFT.POWERSHELL_8WEKYB3D8BBWE"`. A process created by a service with `CreateProcessAsUser` does not get the package identity; SYSTEM has its own full-access ACE, so system mode worked. A copy of the same signed files in `Program Files\GpuVM-lab\pwsh` (signature `Valid`) works in user mode.

**Latency**: 3 interleaved rounds, same pwsh copy, ms.

| Round | Direct (today) median / p95 | Service user median / p95 | Service system median / p95 |
|---|---|---|---|
| 1 | 212 / 399 | 161 / 207 | 112 / 127 |
| 2 | 114 / 134 | 150 / 158 | 150 / 167 |
| 3 | 150 / 168 | 148 / 163 | 143 / 201 |

- Connecting to the pipe takes 0.5-0.8 ms.
- The first request (pwsh start and module import) takes 1.5-1.8 s through the service, against 1.1-7.5 s direct. The 7.5 s came right after the pwsh copy, with a cold disk cache.
- The variation between rounds is the query itself (GPU counters with a VM on), not the pipe.

**Security checks (unelevated)**

| Test | Result |
|---|---|
| Unelevated program creates the service's pipe name | refused, error 5 (access denied) |
| Same program from the user's folder (not in the allow list) | `rejected: programa no permitido` |
| .NET `NamedPipeClientStream` asking for generic read/write | access denied by the pipe's DACL |
| Guest password (DPAPI, CurrentUser) decrypted by the bridge as SYSTEM | `Error occurred during a cryptographic operation.` |

**Side findings**

- `bridge.ps1` parses each request outside its `try`: one malformed JSON line ends the bridge. With a service between the window and the bridge, it should answer with an error instead.
- `Stop-Service` reports an error if the service handler exits the process before answering the SCM. The handler now answers first and exits from a thread.

## Conclusion

Adopted as the design, with conditions. The pipe costs nothing measurable (under 1 ms to connect, same query times) and the checks hold.

- **Run as the user's elevated token, not as SYSTEM.** As SYSTEM the saved guest passwords cannot be decrypted, and the module's per-user paths (Moonlight, profile) would point to the wrong account.
- **Don't run PowerShell from WindowsApps from the service.** GpuVM must carry its own PowerShell 7 in Program Files: the official zip, pinned with SHA-256, MIT license. That also removes the Store lookup in `lib.rs`.

**Security impact.** Today a program running as the user needs a UAC click to make GpuVM do anything elevated. With the service:

- Such a program can drive GpuVM's unelevated window, or inject into `gpuvm.exe`, and the service will obey. That is the same thing Console UI needs to do, and it lowers security.
- Path checks and the allow list only limit what can be asked.

Before taking this to the app:

- Every command that takes a host path (ISO, folder to import, disk) must be checked with the client's own unelevated identity (`ImpersonateNamedPipeClient`), so the service never reads, for the user, files the user could not read.
- Keep the command allow list. Consider asking for UAC again for destructive commands (delete VM or disks).
