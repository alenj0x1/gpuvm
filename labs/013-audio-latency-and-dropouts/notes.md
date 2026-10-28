# Audio latency and dropouts

**Hypothesis:** GpuVM's USB speaker (lab 012) adds no more delay than Steam Streaming Speakers on the way to Moonlight and keeps the sound clean over a 10-minute session.

## Method

`lab.ps1` (elevated, PowerShell 7) opens the VM with `Connect-GpuVM`, then for each sink (the speaker, and Steam Streaming Speakers as the control):

- **Latency.** The VM plays a 100 ms, 1 kHz burst every second for 30 s, in the signed-in user's session, and notes the precise moment it asked to play. This PC samples the peak of Moonlight's own audio session every 2 ms. Each burst's arrival minus the moment it was played is the end-to-end latency: Windows' audio engine in the VM, the sink, Sunshine's capture and encoding, the network and Moonlight's buffer. Clocks are aligned through PowerShell Direct; half of the shortest round trip bounds the error. The peak meter works in ~10 ms periods, so single values are ±10 ms.
- **Dropouts.** The VM plays a steady 440 Hz tone (a 60 s file whose loop is seamless) for 10 minutes. Every stretch of 15 ms or more where Moonlight's level falls under 30 % of the tone counts as a dropout; the first and last seconds and ±300 ms around each loop of the file are left out.
- **Speaker counters** (`C:\ProgramData\GpuVM\Audio\status.json`): underruns (the queue ran dry while audio kept coming, which a real device would play as a click) and how much audio is queued when a transfer arrives (the latency the speaker itself adds).

## Observations

### Short run, Oct 28, 2026 (1 minute per sink)

| | GpuVM Audio | Steam Streaming Speakers |
|---|---|---|
| Latency to Moonlight (median of 30) | not measured: Moonlight failed to connect ("RTSP handshake failed: Error -1") | 63.2 ms (p90 64.8) |
| Dropouts ≥ 15 ms | not measured (same reason) | 0 in 0.97 min |
| Speaker underruns | 0 (5996 transfers) | — |
| Audio queued in the speaker | 9.2 ms average, 9.9 ms max | — |

- Moonlight failed once right after Sunshine had been restarted twice in a row (audio update, then the sink change); the next Moonlight connected. The lab now reopens Moonlight once when no burst arrives.

### 10-minute run, Oct 28, 2026 (`out/lab-full.json`)

The speaker was reinstalled first, which also checked that the outputs of the earlier server are removed: Windows named it "Altavoces (GpuVM Audio)" again (the short run had "2- GpuVM Audio").

| | GpuVM Audio (10 min) | Steam Streaming Speakers (3 min) |
|---|---|---|
| Latency to Moonlight, median (p90) | **63.4 ms** (64.9) | 59.8 ms (60.8) |
| Dropouts ≥ 15 ms | **0** | 0 |
| Speaker underruns | 7, 15.2 ms in total | — |
| Audio queued in the speaker | 9.4 ms average, 10.0 max | — |

- Clock error ±1.8 ms, drift under 0.2 ms during each measurement; Moonlight connected at the first attempt for both sinks.
- The 7 underruns (about 2 ms each) are too short to reach Moonlight as dropouts of 15 ms or more; they may be audible as tiny clicks. Queuing 2-3 ms more would remove them at that cost in latency: a candidate for a later lab.
- Audio arrives about 60 ms after it plays in the VM; video took 34-39 ms end to end in lab 004, so sound trails the picture by roughly 25 ms.

**Conclusion:** adopted. The speaker adds about 4 ms over Steam Streaming Speakers and plays a 10-minute session without dropouts.
