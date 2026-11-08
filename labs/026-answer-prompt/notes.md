# Answering administrator prompts from GpuVM

**Hypothesis:** With WGC capture the Windows administrator prompt can't be streamed, and the Hyper-V console can't show it either (lab 025). A helper in the guest, running as SYSTEM on the secure desktop, can read the prompt (program, publisher) and press Yes or No on the host's order, so the person answers from GpuVM in one click without lowering security.

## Procedure

- `helper.ps1` + `launcher.ps1` (first pass): a SYSTEM task in session 0 copies its own token, moves it to the console session (`SetTokenInformation TokenSessionId`, SeTcbPrivilege) and starts the helper with `CreateProcessAsUser` on `winsta0\winlogon`; the helper reads the prompt with UI Automation (class `Credential Dialog Xaml Host`) and invokes `OkButton` or `CancelButton`. `run.ps1` raises a prompt that tries to write `C:\Windows\lab026-yes.txt` (only an elevated process can).
- `e2e.ps1`: the same through GpuVM's own code (`guest\admin-prompt.ps1` installed by `Install-GuestAdminPrompt`, `Get-GuestAdminPrompt`, `Resolve-GpuVMAdminPrompt`).

## Observations

### Runs of Nov 8, 2026 (win10)

| Step | Result | Time |
|---|---|---|
| Read with no prompt | no window on the secure desktop | 4.3 s |
| Read with a prompt | "Control de cuentas de usuario", program "Procesador de comandos de Windows", "Editor comprobado: Microsoft Windows", buttons `CloseButton`, `OkButton` (Sí), `CancelButton` (No) | 3.6 s |
| Yes | prompt closed, the elevated program ran | 3.1 s |
| No | prompt closed, the program didn't run | 3.1 s |

End to end with GpuVM's code: the prompt is listed on the host 1.1-1.2 s after it opens; Allow answered in 4.9 s (program ran), Deny in 5 s (didn't); an answer for another prompt id is refused ("El aviso ya cambió o se cerró"). Most of each answer is starting a one-time SYSTEM task in the guest. The data exchange still listed the closed prompt a few seconds after answering, so the app forgets answered ids and closes its card at once.

- A local variable named like a validated parameter (`$answer` / `$Answer`) broke the first end-to-end run: PowerShell ignores case.

## Conclusion

Confirmed and adopted: WGC is the default capture; the guest watcher runs as SYSTEM from boot; the app polls `Get-GpuVMAdminPrompt` every 2 s from Rust and shows an always-on-top card (program, publisher, Permitir / Rechazar); the card takes the focus so Moonlight releases the mouse, and gives it back after the answer; `Resolve-GpuVMAdminPrompt` presses the button only if the prompt open is still the one shown. Only the host can order it; nothing in the guest can answer for itself.
