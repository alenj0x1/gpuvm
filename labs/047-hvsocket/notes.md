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

## Part B: reboot, turn-off, clean shutdown (`reboot.ps1`, test VM `agentlab`, 4 GB, 2 cycles)

Guest side: two boot-time SYSTEM scheduled tasks (stand-in for the service): `hvlab watch` dials the parent every
200 ms and holds a connection; `hvlab listen` answers host dials. Host side: listener + watcher dialing the VM. Times
from the moment the host's power-on (or guest restart) call returned.

| event (2 cycles) | host notices the drop | guest agent connected to host again | host connected to guest listener | PowerShell Direct answers |
| --- | --- | --- | --- | --- |
| guest restart (`Restart-Computer`) | 5.3 / 13.0 s (reset 10054) | 11.6 / 20.1 s | 11.6 / 20.1 s | 16.3 / 26.3 s |
| turn off + start | 0.09 / 0.17 s | 8.6 / 7.5 s | 8.6 / 7.6 s | 13.1 / 12.1 s |
| clean shutdown + start | 2.2 / 2.3 s | 6.9 / 7.7 s | 6.9 / 7.7 s | 12.5 / 11.2 s |

- The connection never survives a guest restart or power cycle: the host gets 10054 (reset) on the next send, then
  10060 (timeout) / 10049 / 10051 / 10004 while the VM is down, and 10061 (refused) from the guest side until the host
  listener is up. A watcher with a 200 ms retry reconnects without any help.
- The guest agent is connected **4.5-6 s before PowerShell Direct answers** (lower bound: the PowerShell Direct check
  started only after the hvsocket reconnect), so "agent connected" is a faster "VM ready" signal than today's.
- The accepted peer VmId stays the VM's Id across every restart (6/6 reconnections).
- **`Save-VM` is refused for a VM with a GPU-P partition** ("assigned one or more GPU partitions"), so save/restore
  can't happen with GpuVM machines; nothing to design for.
- First run: the host had ~2.2 GB available next to win-gpu and Hyper-V refused even 2 GB ("unable to allocate",
  0x800705AA); win-gpu was shut down cleanly for the rest of phase 0 (coordinator/the person approved).

## Security impact

The lab registers one service GUID on the host (reverted with `service.ps1 -Remove`) and runs a probe from a temp
folder in the guest; nothing else changes. What registration means for who can connect is lab 050.

## Conclusion

Adopt hvsocket for the agent channel: guest agent (a SYSTEM service) dials the host (host listens on
`HV_GUID_CHILDREN`, one service GUID), keeps one long-lived connection (new connections cost ~1 ms, p95 ~4 ms) and
redials every ~200 ms when it breaks; the host uses the accepted peer VmId to tell VMs apart and treats "agent
connected" as the VM-ready signal. Frames up to a few MB are fine as single messages. Keep a heartbeat: a dead guest
is only noticed on the next send (up to 13 s on a guest restart otherwise).
