# Audible underruns

**Hypothesis:** the speaker's short underruns (lab 013: 7 of about 2 ms in 10 minutes) do not reach Moonlight, because Sunshine captures Windows' mix before it goes to the speaker.

## Method

`lab.ps1` (elevated, PowerShell 7; keep this PC otherwise silent) opens the VM with `Connect-GpuVM`, which updates the speaker so it logs each underrun with its UTC time. For each sink, the VM plays a steady 440 Hz tone (60 s file, seamless loop) while this PC records its own output by WASAPI loopback, Moonlight being what plays there. The recording is analysed in 1 ms windows:

- **Gaps:** windows whose level is under 30 % of the tone.
- **Breaks:** the predictor `x[n] = 2cos(w)x[n-1] - x[n-2]` is exact for a pure sine, so a skipped, repeated or silenced stretch leaves a spike in its error well above the Opus coding noise.
- Each underrun is moved to the host's timeline (clocks aligned through PowerShell Direct, plus lab 013's 63 ms latency) and counts as heard when a gap or break falls within 150 ms of it.

The first and last seconds and ±300 ms around each loop of the file are left out.

## Observations

### Run of Oct 28, 2026 (`out/lab-full.json`)

| | GpuVM Audio (9.97 min) | Steam Streaming Speakers (4.97 min) |
|---|---|---|
| Speaker underruns | 15 (0.0-6.2 ms) | — |
| Gaps on the host | **2, 9 ms each** | 0 |
| Breaks in the wave | 2 (at the same gaps) | 0 |
| Underruns heard | **2 of 15** | — |
| Events on the host with no underrun nearby | 0 | — |

- Opus coding noise is tiny on a pure tone (error 4e-5 against a 0.28 RMS level), so the detector sees a break down to a fraction of a millisecond; the other 13 underruns left no trace.
- This run had more underruns than lab 013's (15 vs 7): the spread between runs is large.
- The output only has counts, so which underruns were heard isn't paired; both gaps are 9 ms.

**Conclusion:** rejected. The underruns are rare and mostly silent, but some reach the host as 9 ms gaps (two clicks in ten minutes). Next step: complete each transfer a few milliseconds early so Windows sends the next one sooner, and measure whether that removes them and what it does to latency.
