# Streaming with Sunshine and a virtual display

**Hypothesis:** With VDD as the only display (Hyper-V Video disabled), Sunshine captures what the RTX 4060 renders and encodes with NVENC; Moonlight on the host shows the VM at 1080p60 with low latency.

## Procedure

1. Apply the baseline: `Set-GpuVM -Name <vm> -Profile balanced`
2. Measure and record with `Add-GpuVMLabResult -Lab 002 -Variant baseline ...`
3. Apply the candidate and repeat with `-Variant candidate`.
4. Close with `Close-GpuVMLab -Lab 002 -Status adopted|rejected|inconclusive -Conclusion '...'`

## Observations


### First real test (Oct 26, 2026, VM win10, Windows 10 22H2 es-MX)

- Sunshine installed fine, paired on its own and detects the RTX 4060 with NVENC (HEVC P1).
- Moonlight showed black: with the Hyper-V display still active (before the setup restart), Sunshine was capturing `\\.\DISPLAY1` (Hyper-V, 1024x768) instead of the virtual display (`\\.\DISPLAY2`, EDID `MTT`).
- Fix: `output_name` = the virtual display's device_id and `dd_configuration_option = ensure_only_display`. `connect` now does this on its own (it reads the display list from the Sunshine log through the API). After the change, Sunshine captures 800x600 from the virtual display.
- Pending: Sunshine says "Display device configuration API is temporarily unavailable" and does not change the resolution. Suspect: the Hyper-V console in enhanced session (RDP) takes over the user's session.
