# Completing transfers early

**Hypothesis:** if the speaker completes each transfer 5 ms before its last packet's time, Windows sends the next one sooner, so the queue no longer runs dry and the audible gaps of lab 014 disappear. Sunshine captures Windows' mix, not the speaker's output, so this might not add latency.

## Method

`lab.ps1` (elevated, PowerShell 7; keep this PC otherwise silent) opens the VM with `Connect-GpuVM` and, for each lead (the server's optional fourth argument), restarts the speaker's server with it, sets the speaker as Sunshine's sink and reopens Moonlight. It records this PC's output with lab 014's recorder (1 ms windows) and measures:

- **Latency:** 30 bursts of 1 kHz; each one's first window above 30 % of their level, minus the moment the VM played it.
- **Clicks:** 10 minutes of a steady 440 Hz tone; gaps, breaks in the wave and the speaker's underruns, as in lab 014.

At the end the server goes back to its installed arguments.

## Observations

### Run of Oct 28, 2026, evening (`out/lab-full.json`)

| | Lead 0 (installed) | Lead 5 ms |
|---|---|---|
| Latency to this PC, median (range) | 84 ms (74-84) | 86 ms (81-86) |
| Gaps in 10 min | **1** (9 ms) | 18 (1-84 ms) |
| Breaks in the wave | 2 | 10 535 |
| Speaker underruns | 5 (26.9 ms) | 36 (345.7 ms) |
| Audio queued in the speaker | 9.4 ms | 14.3 ms |

- The lead made everything worse. The likely reason is that `usbaudio.sys` follows the speaker's clock from when transfers complete, so completing them early disturbs that clock instead of giving it slack (not verified further).
- Latency here is measured on this PC's output in 1 ms windows, not with the session peak meter of lab 013, and the VM had just started after a host restart: 84 ms is not comparable with lab 013's 63 ms, only with the other variant of this run.
- With lead 0 this run had 1 audible gap in 10 minutes (lab 014: 2).

**Conclusion:** rejected. The lead stays at 0; the server keeps it as an optional argument for later labs.
