# USB audio over USB/IP

**Hypothesis:** A USB Audio Class 1 speaker served by GpuVM's own USB/IP server inside the VM, attached with usbip-win2, is driven by Windows' inbox `usbaudio.sys` like real hardware. WASAPI loopback captures it, so Sunshine carries the VM's sound without Steam, VB-CABLE or test signing.

## How it works

```
apps in the VM -> Windows audio engine -> "Altavoces (GpuVM Audio)" (usbaudio.sys, Microsoft)
                        |                          |
                 loopback (Sunshine)       usbip-win2 UDE driver (Microsoft-signed)
                        |                          |  TCP 127.0.0.1:3240, inside the VM only
                    Moonlight              UsbAudioServer.cs (ours): USB/IP 1.1.1, UAC1 descriptors,
                                           isochronous packets completed one per 1 ms frame, audio discarded
```

- `UsbAudioServer.cs`: the whole device. UAC1, 48 kHz 16-bit stereo, full speed, adaptive isochronous OUT endpoint, no feature unit (Windows uses software volume). Test VID/PID `1209:0001` from pid.codes.
- Completing each URB at real-time pace (1 packet per ms) is what gives Windows a correct audio clock; completing at once would drain the buffer.
- Nothing leaves the VM: the server listens on 127.0.0.1 and the host is not involved.

## Procedure

`lab-b.ps1` (elevated, PowerShell 7): downloads usbip-win2 0.9.8.0 (SHA-256 pinned), installs only its client silently, checks signatures and the root store, starts the server as a SYSTEM task, attaches, then runs lab 011's measurement (`-Match '*GpuVM Audio*'`, Steam as control). `lab-b-revert.ps1` removes everything.

Version choice: 0.9.8.0. 0.9.7.8 has a known BSOD bug; 0.9.8.1 is a 100-commit AI-assisted rewrite whose author warns of regressions.

## Observations

### Run of Oct 28, 2026 (`out/lab-b-20261028-024324*.json`)

| Sink | Loopback in the VM | Moonlight on the host (silent → sound) |
|---|---|---|
| VB-CABLE (lab 011) | zeros | 0 → 0 |
| **GpuVM Audio** | **0.356 (meter 0.356)** | **0.049 → 0.351** |
| Steam Streaming Speakers (control) | — | 0 → 0.265 |

- Install: exit 0, drivers `usbip2_ude` and `usbip2_filter` signed by *Microsoft Windows Hardware Compatibility Publisher*, no certificate added to the root store, no restart needed to attach.
- Windows enumerated a USB composite device and the media function "GpuVM Audio"; the endpoint showed up in a few seconds.
- Server over the whole run: 2726 URBs, 5.17 MB of audio, 0 unlinks, 0 transport errors, 1 stall (string descriptor 0xEE, Microsoft OS descriptors, expected).
- Sunshine switched the sink to 16-bit to match the new default device; capture stays F32 48 kHz.

**Conclusion:** adopted. Before shipping: the server as a service that survives restarts and re-attaches, its own PID, and latency and glitch measurements over a long session.
