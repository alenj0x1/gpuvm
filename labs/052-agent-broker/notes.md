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

## The real GpuVM service, release build (`real-service.ps1`, under the lab lock, original put back after)

This branch's `gpuvm-host.exe` replaced the installed one for one run; `gpuvm-host install` (what the installer
runs) registered the service id (`ElementName = GpuVM agent`); the service listened 40 ms after start.

| through the module pipe, loopback stub (n=120, 2 rounds) | p50 | p95 | p99 |
| --- | --- | --- | --- |
| pipe alone (instrument) | 0.07 ms | 0.13 ms | 0.20 ms |
| agent.info, raw line (broker's share 0.26 ms) | 0.94 ms | 1.38 ms | 2.34 ms |
| agent.info through the cmdlet | 1.6 ms | 2.2 ms | 3.5 ms |
| screen.capture 257 KB | 2.2 ms | 2.8 ms | 3.4 ms |
| screen.capture 1 MB | 4.3 ms | 5.7 ms | 6.7 ms |
| screen.capture 4 MB | 11.5 ms | 13.4 ms | 15.4 ms |

- 8 clients in parallel: **1 667 req/s**, 0 failed, p50 3.2 ms, p95 6.2 ms.
- The 18 attack cases (with `bad-blob-hash`: a blob that isn't the one its signed frame announces) gave the same
  answers as the debug build; frame flood closed after 2 006 frames (9.8 ms).
- Service restarts (`Restart-Service GpuVM`, 3 times): the agent was connected again 268, 723 and 706 ms after the
  restart began (the restart itself 11-525 ms; the agent redials every 200 ms).

## Results in a VM (`integration.ps1`, Nov 18-19, under the lab lock)

The installed GpuVM (integrated build: service, module, guest agent 0.3.1), with this branch's `gpuvm-host.exe` and
`Private\Agent.ps1` put in its place for each run and the originals put back after (`restore.ps1` when a run broke
off). Machine: a copy of the template `agent-tpl` set to 2 GB in Hyper-V (GpuVM asks 4; lab only), deleted at the end.

| | result |
| --- | --- |
| copy made and started | 8.7-10.0 s; PowerShell Direct 2.8-4.5 s later |
| Install-GpuVMAgent (template already has the agent: installer's fast path) | 7.3-9.0 s (PowerShell Direct session 2-3 s, exe copy 2-2.5 s, installer 2.5-3.9 s); agent connected 1.0 s after |
| the same again | 3.2-3.5 s; connected 1.0 s after |
| host secret | stored by the service as SYSTEM; an elevated administrator can't read it |

Through the module pipe (n=120, 2 rounds; pipe alone 0.065 ms):

| method | p50 | p95 | p99 |
| --- | --- | --- | --- |
| agent.info (broker's share 0.53 ms) | 1.24 ms | 1.77 ms | 2.14 ms |
| screen.state | 1.30 ms | 1.83 ms | 2.15 ms |
| input.act move | 1.72 ms | 2.22 ms | 2.47 ms |
| screen.capture 1280x800 (real WebP) | 14.4 ms | 18.6 ms | 44.9 ms |
| ui.tree | 16.3 ms | 22.1 ms | 29.6 ms |

- 8 clients in parallel (1 in 9 a capture): 493 req/s, 0 failed, p50 12.9 ms, p95 49.5 ms (the agent runs captures,
  ui.tree and screen.state on one thread of its helper).
- Timeout: 1 014 ms for a 1 s timeout, next request 1.5 ms. 40 input.act of 2 s at once: 8 `busy` (cap 32), 3 done,
  29 `timeout` at 10 s: the agent runs input.act one at a time on purpose (one pointer and keyboard).
- The 18 hostile cases: same answers as over loopback; the real agent kept its connection through every
  pre-handshake case and was back in ~1 ms (250 ms after the conn flood). Frame flood: the attacker wrote for its
  full 3 s without noticing (VMBus buffers the writes); the close itself was only seen over loopback (9.8 ms).
- Offers from the real agent's Outbox (`Desktop\Outbox\x`): accepted, same bytes, Zone.Identifier ZoneId=3, owner
  the person, never overwriting (`report (2).txt`, `report (3).txt`).
- Guest restart (2 rounds): host saw the drop after 4.7-8.1 s; agent connected again 10.5-12.8 s after
  `Restart-Computer`, PowerShell Direct 16.4-18.6 s (the agent is ~6 s ahead, as in lab 047).
- Service restarts (3): agent back 238, 489 and 971 ms after the restart began.
- **Bounded stop:** with a 60 s agent request running, `gpuvm-host install` (what the installer does) stopped the
  service in 5.0 s; the request ended at 6.8 s ("The GpuVM service closed the connection"); host.log: "stopping after
  5.0 s with 0 job(s) and 1 request(s) still running: ended". The installed (old) service, by contrast, stayed in
  StopPending over 2 minutes once; this branch's `gpuvm-host stop` stopped it in 232 ms.
- **The MCP's own path** (`gpuvm.exe --mcp`, lab 053's drive.py): create_disposable (New-GpuVM -Template -Disposable
  with the session's Connection, then Install-GpuVMAgent from the app's bridge, an elevated user) answered "its agent
  is ready" after 32 s; take, run, write/read file, screenshot worked; some screenshots, clicks and keys were refused
  with `secure_desktop` (the copy showed a secure screen for a while: guest side, not the broker).
- Two machines at once: not run on real VMs: GpuVM's disk check refused the second 64 GB copy (112 GB already set
  aside, 21 GB at most). Over loopback the routing by VmId was checked; left for a run with more room.

### Found and fixed in these runs

1. `Install-GpuVMAgent` from the bridge (elevated user, not SYSTEM) couldn't store the secret: the module made
   `secret.new` SYSTEM-only, then couldn't move or overwrite it. Now the service stores it as SYSTEM
   (`Set-GpuVMAgentSecret`, administrators' pipe only), and the agent cmdlets stop at the first error.
2. A stop could hang for 10 minutes on any running request. Reading and agent requests now get 5 s; the
   installer's stop gives jobs 30 s, then ends the service process (only the one it asked to stop) and stops the
   instance Windows' recovery actions start again 2 s later, which kept the exe in use.
3. 1024x768 in `agent.info`: GpuVM's session tasks already run as the console user (`agent`); the agent's helper
   measured the primary monitor (Hyper-V video). Fixed in the guest agent 0.3.2.

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
