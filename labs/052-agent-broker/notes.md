# Lab 052: the host agent broker (app/host/src/agent.rs) end to end

Machine: i5-12400, RTX 4060, Windows 10 Pro for Workstations host, Nov 18, 2026. Broker = this branch's
`gpuvm-host broker` (debug-only command: the broker alone as SYSTEM, next to the installed service that doesn't have
it yet; `broker.ps1`). Guest = `stub052` (stub/), a stand-in agent built on the broker's own wire code, until the real
agent (guest/agent) lands. Requests through the module's pipe (`\\.\pipe\gpuvm-agent`), the same code the app's pipe
runs. Raw data in out/ (git-ignored).

## What runs where

- `loopback.ps1` registers Hyper-V's loopback GUID as a fake machine (`loopback052`) so the stub can run on the host
  (`STUB052_TARGET=loopback`): same listener (HV_GUID_CHILDREN accepts loopback dials), handshake, frames and limits,
  no VMBus. `run.ps1 -Loopback` drives it.
- `run.ps1 -Name agent052` against a test VM: `install` uses the real Install-GpuVMAgent with the lab's stand-in
  installer (`guest-install.ps1`, same contract as guest\agent\install.ps1) and the stub as `dist\`.
- Parts: install latency parallel timeout attacks offers restart broker-restart squat uninstall.

## Results over loopback (no VMBus)

Instrument reference: the module pipe alone (`Get-GpuVMAgentBroker`, no guest) p50 0.075 ms / p95 0.12 ms.
Broker built with opt-level 3 (debug assertions on); the test VM was installing Windows at the same time (disk/CPU
busy: the tails, not the medians, carry that).

| request through the module pipe (n=120, 2 rounds) | p50 | p95 | p99 |
| --- | --- | --- | --- |
| agent.info, raw line (the broker's own share: 0.29 ms p50) | 0.97 ms | 1.5 ms | 13.8 ms |
| agent.info through the `Invoke-GpuVMAgent` cmdlet | 1.6 ms | 2.3 ms | 3.5 ms |
| screen.capture 257 KB blob (saved as a file for the module) | 2.0 ms | 5.2 ms | 11.7 ms |
| screen.capture 1 MB | 3.3 ms | 5.3 ms | 12.9 ms |
| screen.capture 4 MB | 7.8 ms | 18.4 ms | 34.3 ms |

- Parallel: 8 clients, 1 360 requests (1 in 9 a 257 KB capture): **1 624 req/s, 0 failed**, p50 3.1 ms, p95 6.7 ms.
- Timeout: a request the guest holds 5 s with `TimeoutSec 1` answers `timeout` at 1 018 ms; the guest gets
  `{"t":"cancel"}`; the next request answers in 1.8 ms. 40 requests at once on one machine: 32 run, 8 get `busy`.
- Handshake: 1.0-1.8 ms on the broker (registration 0.3 ms, DPAPI secret 0.3-0.5 ms).

### Hostile guest (17 cases, `stub052 attack`), each followed by a check that the real agent is (back) connected

| case | host's answer |
| --- | --- |
| wrong secret, wrong VmId binding | closed after the proof (0.3 ms); the guest also sees the host's challenge doesn't verify |
| replayed proof (recorded good handshake, same guest nonce) | new host nonce every time, closed (0.4 ms) |
| hello over 1 KiB, unknown frame kind, malformed hello | closed before reading the payload (0.6-4 ms) |
| connection that never says hello | closed at the 5 s handshake limit |
| after the handshake: JSON frame over 64 KiB, blob over 16 MiB, unsigned frame, malformed JSON, a reply or a blob nobody asked for | closed at once (0.4-0.7 ms) |
| after the handshake: silence | closed at 6 s (no heartbeat) |
| frame flood (4 000 signed pings) | closed after 2 000 in one second (25 ms) |
| event flood (350 events/s of 2 KB) | kept at 10 events/s, closed as "event flood" after 1 000 dropped |
| 100 connections at once saying nothing | 4 held (per-VM handshake limit), 96 closed at once; a good handshake right after: 1 ms |

- Pre-handshake attacks never cost the real agent its connection; anything that passed the handshake (it knows K,
  so it is SYSTEM or an administrator in the guest) replaces the agent's connection until it redials (~250 ms).
- **Bug found and fixed:** the first version limited new connections per VM per 10 s. A flood kept that window full
  and the real agent's redials (every 200 ms) kept it full too: the agent stayed locked out as long as anyone kept
  dialing (`goodHandshakeAfterMs: null` after 30 s). Now the limit is on handshakes in progress (4 per VM, 16 in all).
- Every request, connection and refusal is in the VM's `agent.log` (method, params without blobs, code, ms); failed
  handshakes are logged at most 5 per VM every 10 s.

### Outbox offers (`offers`)

| | result |
| --- | --- |
| report.txt approved twice | `report (2).txt`, `report (3).txt`: never overwrites; same bytes; 6-27 ms |
| big.bin, 20 MiB (3 pieces of 8 MiB) | 47 ms, same SHA-256 |
| marks | `Zone.Identifier`: `ZoneId=3`, `ReferrerUrl=gpuvm://<machine>/` |
| owner | the person (impersonated pipe client), not SYSTEM |
| declined, then approved | "This offer is already declined." |
| `C:\Users\agent\secret.txt`, `Outbox\..\..\secret.txt`, `Outbox\sub\x.txt`, `C:\Windows\win.ini` | refused before reaching the guest (`denied`) |

- **Bug found and fixed:** the Zone.Identifier stream couldn't be opened while the file's own handle (no sharing) was
  open (error 32), and the copy stayed unmarked in Downloads. Now the handle is closed first, and a file that can't be
  marked is deleted.

## Results in a VM

(pending: agent052 is installing Windows)

## Security impact

- New listener on HV_GUID_CHILDREN:{94aca5ef-...} in the elevated service, and its registration under
  GuestCommunicationServices (installer and service start; removed on uninstall). Any guest process can dial it
  (lab 050); only a peer that proves the VM's secret gets past the handshake, and even then it can only answer
  requests the host sends and send bounded, rate-limited events that are stored, never acted on.
- New pipe `\\.\pipe\gpuvm-agent`, SYSTEM and elevated administrators only (`D:P(A;;GA;;;SY)(A;;GA;;;BA)`), first
  instance claimed by the service. An administrator could already drive any VM through Hyper-V; nothing new.
- New commands on the service pipe (only GpuVM's own gpuvm.exe connects). A process that registered as an agent
  client (the MCP server) can't resume, approve offers or stop sessions, and its connection id is bound to its pid.
- Per-VM secret: 32 random bytes, DPAPI machine scope + GpuVM entropy, file readable by SYSTEM only (even an
  elevated administrator gets "access denied" without taking ownership), in ProgramData\GpuVM\agents\<vmid>
  (administrators only, nothing inherited). In the guest, a SYSTEM/Administrators-only folder, never KVP. The Guest
  Service Interface is on only during the copy when it was off. Reinstall rotates it; Remove-GpuVM and
  Uninstall-GpuVMAgent delete it.
- Files leaving a VM: only directly inside `C:\Users\agent\Desktop\Outbox`, only after the person approves (not
  from an agent client), written as the person, never overwriting, always marked as from the internet, 2 GB cap,
  every piece and the total bounded by what the host asked for.
- Known limit: any process in a guest can keep that guest's 4 handshake slots busy (5 s each) and delay its own
  agent's reconnection. It can't affect other VMs or the host; the guest is untrusted anyway.
- Lab only: `make-vm.ps1 -SkipDiskBudget` skips GpuVM's disk budget check for test VMs (they use ~17 GB of a 64 GB
  dynamic disk); the stub, its scheduled task and the `agent` user exist only in the test VM (deleted after).
