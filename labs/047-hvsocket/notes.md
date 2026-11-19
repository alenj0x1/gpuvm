# Lab 047: Hyper-V sockets between the host and a guest agent

Machine: i5-12400, RTX 4060, Windows 10 Pro for Workstations host; guest `win-gpu` (Windows 10, GPU-P), Nov 18, 2026.
Probe: `hvlab` (Rust, windows-sys only), same binary on both sides (`hvlab listen|bench|watch|once`).

## Hypothesis

A host listener on `HV_GUID_CHILDREN` and a guest client dialing `HV_GUID_PARENT` (and the reverse: guest listener on
`HV_GUID_WILDCARD`, host dialing the VM's Id) give sub-millisecond request/response, hundreds of MB/s for screenshot-
sized frames, and the host learns which VM is talking from the accepted peer address, so the agent channel needs no
PowerShell Direct, no guest password and no network.

## Method

- `service.ps1` registers the service GUID `b1c0a047-6a5e-4c4b-9e47-047047047047` under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices` with a marker value;
  it refuses to touch a key it didn't create and `-Remove` deletes only its own key.
- `run.ps1` (2 rounds, directions interleaved): 60 new connections (connect time + first 100-byte round trip), then
  on one connection 50 warm-up + 600 round trips of 100 bytes (200-2000 us random pauses), then 60 frames each of
  1, 2, 4 MB in both directions. Against: an open PowerShell Direct session doing the same 100-byte echo (500 per
  round), a new PowerShell Direct session per call (10 per round), and KVP (lab 042's `kvp-latency.ps1`, 60 samples:
  host item -> guest poll 5 ms -> guest item -> host poll 20 ms).
- Nothing installed in the guest: the exe ran from `C:\GpuVMLab047` through PowerShell Direct and was removed.
- `summarize.ps1` pools the rounds.

## Results (p50 / p95 / p99)

| | guest -> host (host listens) | host -> guest (guest listens) |
| --- | --- | --- |
| 100 B round trip, open connection (n=1200) | **92 / 163 / 229 us** | 108 / 205 / 312 us |
| new connection: connect() (n=120) | 0.97 / 4.2 / 6.9 ms | 0.72 / 3.9 / 7.0 ms |
| first 100 B round trip on a new connection | 0.43 / 0.70 ms | 0.61 / 0.85 ms |
| 1 MB guest -> host (n=120) | 2.4 / 3.0 ms (417 MB/s) | 2.0 / 2.4 ms (500 MB/s) |
| 4 MB guest -> host | 8.8 / 9.8 ms (455 MB/s) | 7.6 / 8.3 ms (526 MB/s) |
| 1 MB host -> guest | 2.8 / 3.4 ms (357 MB/s) | 3.3 / 3.8 ms (303 MB/s) |
| 4 MB host -> guest | 14.1 / 15.3 ms (284 MB/s) | 15.3 / 16.8 ms (261 MB/s) |

| Same 100-byte round trip by other channels | p50 / p95 |
| --- | --- |
| PowerShell Direct, open session (n=1000) | 4.4 / 6.0 ms |
| PowerShell Direct, new session each call (n=20) | 177 / 185 ms |
| KVP host item -> guest echo read on host (n=60) | 83 / 94 ms |

- hvsocket is ~45x faster than an open PowerShell Direct session and ~900x faster than KVP for a small request.
- Data from the guest to the host (screenshots) runs at ~420-530 MB/s; a 1280x720 lossless screenshot (~0.8 MB,
  lab 048) crosses in ~2 ms. Host -> guest is slower (~260-360 MB/s), enough for files.
- Loopback on the host alone (instrument reference): 100 B 40 us, 4 MB 2-5 GB/s; so most of the cost is VMBus.
- **Peer identity:** the host's accept() returned the VM's real Id (`Get-VM).Id`) in 241/241 connections; the guest
  sees the host as `HV_GUID_PARENT`. The client's service id is a random per-connection GUID.
- 0 failed connections or requests in either run.

## Part B: reboot, turn-off, save/restore (pending)

`reboot.ps1` (boot-time SYSTEM tasks in the guest, host listener + watcher, 2 cycles of guest restart, turn off/on,
save/restore) needs a disposable VM. Blocked: the host has ~2.2 GB available next to win-gpu (6 GB) and Hyper-V
refused to start even a 2 GB test VM ("unable to allocate 2048 MB", 0x800705AA).

## Security impact

The lab registers one service GUID on the host (reverted with `service.ps1 -Remove`) and runs a probe from a temp
folder in the guest; nothing else changes. What registration means for who can connect is lab 050.

## Conclusion (so far)

Adopt hvsocket for the agent channel: guest agent dials the host (host listens on `HV_GUID_CHILDREN`, one service
GUID), keep one long-lived connection (new connections cost ~1 ms, p95 ~4 ms), and use the accepted peer VmId to tell
VMs apart. Frames up to a few MB are fine as single messages.
