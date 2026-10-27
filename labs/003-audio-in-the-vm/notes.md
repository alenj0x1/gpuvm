# Audio in the VM

**Hypothesis:** Hyper-V Gen 2 has no sound card; without a virtual audio device, Sunshine streams video with no sound. A virtual audio driver solves it.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile balanced`
2. Measure and record with `Add-GpuVMLabResult -Lab 003 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 003 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations

### Options evaluated (Oct 26, 2026)

| Option | Result |
|---|---|
| Virtual Audio Driver (VDD project) | Rejected: beta and requires test signing. |
| Scream | Rejected: requires Secure Boot off (and test signing on Windows 11). |
| Steam Streaming Speakers | Rejected: requires installing Steam and its installer has no pinned version. |
| **VB-CABLE Pack45 (3.3.1.7)** | **Chosen.** `vbMmeCable64_win10.inf`, hardware ID `VBAudioVACWDM`, catalog with a Microsoft WHQL signature, so Windows shows no prompt. The license allows silent installation if the source is credited and the user can donate (https://vb-audio.com/Services/licensing.htm). |

### Implementation

- `guest/streaming.ps1` → `Install-GpuVMAudio`: `nefconw install vbMmeCable64_win10.inf VBAudioVACWDM`, `LEEME.txt` with credit, and the `GpuVM-Audio` task.
- After the automatic restart, `guest/audio.ps1` sets `virtual_sink = <CABLE Input…>` in `sunshine.conf`.

### Still to verify on a real VM

- That "CABLE Input (VB-Audio Virtual Cable)" shows up after the restart.
- That Moonlight receives the sound and audio latency is acceptable.

