# Administrator prompts with WGC capture

**Hypothesis:** With WGC capture (lab 023), Windows administrator prompts in the VM don't reach Moonlight. GpuVM can tell, cheaply and quickly, when a prompt is open and let the person answer it in one or two clicks through the Hyper-V console, without lowering security.

## Procedure

`run.ps1`, `diag.ps1` and `diag2.ps1` (elevated) on win10 raise a harmless prompt (`cmd.exe` run as administrator from the user's session), check `consent.exe` in the guest, publish a value through Hyper-V's data exchange (KVP) and read it on the host (`Msvm_KvpExchangeComponent.GuestExchangeItems`), and open the console (`vmconnect.exe localhost win10`) with screenshots.

## Observations

### Runs of Nov 8, 2026

- The prompt opens as expected: one `consent.exe` in the guest; `PromptOnSecureDesktop = 1`.
- KVP: a value written under `HKLM\SOFTWARE\Microsoft\Virtual Machine\Auto` never reaches the host (that key holds the guest's intrinsic data, shown in `GuestIntrinsicExchangeItems`). Under `...\Virtual Machine\Guest` it shows in `GuestExchangeItems` within 5 s, and a change within 3 s; a host read takes ~100 ms. The guest service is `vmickvpexchange`.
- Console with enhanced session on (host default): it first asks for a display size ("Connect to win10"), and connecting in enhanced mode would take the user's session away from Moonlight. Turning off `vmicrdv` in the guest does not stop that question.
- Console with enhanced session off on the host (`Set-VMHost -EnableEnhancedSessionMode $false`, turned back on afterwards): it opens straight away, but **black**: the basic console only shows Hyper-V's own video adapter, which GpuVM turns off in the guest so the picture comes from the GPU's virtual display. The prompt is drawn there too, so the console can't show it.

## Conclusion

Partly rejected. Detecting the prompt works (KVP under `Guest`, ~3 s, ~100 ms per read). Answering it through the Hyper-V console doesn't: the console can't see the GPU display of a GpuVM VM. Next: answer from GpuVM, with a guest helper that presses Yes or No on the secure desktop only on the host's order (lab 026).
