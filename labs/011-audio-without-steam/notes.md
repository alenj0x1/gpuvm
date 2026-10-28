# Audio without Steam

**Hypothesis:** The VB-CABLE Pack45 output that accepts WASAPI loopback (`CABLE In 16 Ch`) carries the VM's sound to Moonlight when it is Sunshine's `virtual_sink`. The stereo output GpuVM picks today rejects loopback, which is why there is no sound without Steam Streaming Speakers.

## Why this lab

In lab 010 every run played the sound on the stereo output (`Altavoces (VB-Audio Virtual Cable)`), which rejects loopback with `E_NOTIMPL`. `CABLE In 16 Ch` accepted loopback (500 packets, none flagged silent) but was never the default output, so nothing played on it. VB-CABLE was never really measured.

Sunshine only captures by loopback of a render endpoint (`src/platform/windows/audio.cpp`: `AUDCLNT_STREAMFLAGS_LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY`, shared mode, float32), so the sink has to accept loopback.

## Procedure

`lab-a.ps1` (elevated, PowerShell 7), no questions asked:

1. Inside the VM, each VB-CABLE output as the default while a sound plays; loopback with Sunshine's flags.
2. End to end, each output as `virtual_sink`: peak of Moonlight's audio session on the host, VM silent vs. sound playing.
3. Restores `virtual_sink`, the default output and Sunshine as it was running.

Raw output goes to `out/` (not committed).

## If it fails: option B

GpuVM's own USB/IP server inside the VM presenting a USB Audio Class speaker, attached with usbip-win2 (Microsoft-signed drivers), so Windows' inbox `usbaudio2.sys` creates a normal output that Sunshine can capture. No Steam, no 2014 driver, Secure Boot stays on.

## Observations

### Run of Oct 28, 2026 (`out/lab-a-20261028-023107.json`)

| Sink | Loopback in the VM | Moonlight on the host (silent → sound) |
|---|---|---|
| `Altavoces (VB-Audio Virtual Cable)` (today) | zeros (meter 0.35) | 0 → 0 |
| `CABLE In 16 Ch (VB-Audio Virtual Cable)` | zeros (meter 0.356) | 0 → 0 |
| `Altavoces (Steam Streaming Speakers)` (control) | — | 0.009 → 0.265 |

- The loopback stream runs (499 packets in 5 s, none flagged silent) but every sample is zero: VB-CABLE never hands the mixed audio back to the engine's loopback tap in this VM.
- Opening the second VB-CABLE output while the first was just used returns `AUDCLNT_E_DEVICE_IN_USE`: both outputs are pins of the same cable.
- While Moonlight is connected, Sunshine puts its sink back as the default as soon as it changes, so in-VM tests close Moonlight first.

**Conclusion:** rejected. VB-CABLE cannot be Sunshine's sink in a Hyper-V VM. Option B goes next.
