# Lab 051: the guest agent, end to end

Machine: i5-12400, RTX 4060 host; test VM `agent051` (Windows 10 Pro 22H2 es-MX, 4 GB static, 4 threads, GPU-P,
GpuVM's virtual display), Nov 18, 2026. Agent: `guest/agent` (gpuvm-agent 0.1.0, Rust, one static 0.9 MB exe).
Harness: `labs/051-guest-agent/harness` (host side, a stand-in for the broker until it lands).

## Hypothesis

The agent of docs/agents/protocol.md (a SYSTEM service that dials the host + a helper in the signed-in user's
session) can be installed over PowerShell Direct in seconds, signs the VM in as the standard user `agent`, answers
every method fast enough for an AI loop (screenshot + action well under 100 ms), and refuses (never injects) when the
person must act: elevated windows, the secure desktop, system error boxes. Protocol abuse closes the connection.

## Method

- `make-vm.ps1`: disposable VM from the Windows 10 ISO with New-GpuVM (4.5 min to a signed-in desktop).
- `prepare.ps1`: what the broker will do: 32-byte secret, copy the exe over PowerShell Direct, run `install.ps1` as a
  script block with `-Secret`, keep the returned password with DPAPI (`out/agent.xml`), restart from inside.
- `install-cycle.ps1`: `-SignInAs previous` / `agent` (and `-Uninstall`) without restarting, reporting Winlogon, which
  LSA secrets exist (never their values), the backup key and policies after each step.
- `run.ps1` + `harness serve`: takes the lab lock, registers the service GUID on the host if nobody did, listens on
  the VM's id, does the host side of the handshake (it checks the guest's proof) and runs the scenarios; raw data in
  `out/run-*/results.jsonl` (git-ignored) with sample screenshots. Times are host round trips (what the broker will
  see) and the guest's own `ms` fields. Scenarios:
  - `info`: agent.info / screen.state, 200 round trips each.
  - `capture`: 40 interleaved rounds of WebP 1280x800, PNG 1280x800, WebP native, WebP region 400x300.
  - `latency`: Notepad focused by a click on its UIA box; 40 alternating `m` / Backspace; after each action the host
    polls a 320x60 PNG region of the text box until > 40 pixels differ (the caret is steady: `CursorBlinkRate -1`).
    This is the agent loop as the AI lives it: action -> screenshot that shows it.
  - `uia`: ui.tree x6 on Notepad, Explorer (C:\Windows), Settings (Display), Edge with a local page; on Edge, input and
    ui.invoke are checked through the page's title (it echoes the field, a click counter and scrollY).
  - `exec`: 40 x `cmd /c echo`, whoami (+ groups: integrity), stdin, a timeout, a 1 MiB+ output, a missing program.
  - `files`: 1 and 10 MiB write + read back, list, path escapes (`..`, outside, `\\?\`, UNC, junction to another
    profile, hard links, alternate stream, device names, a Unicode case-folding trick), Outbox offers.
  - `secure`: a UAC credential prompt raised by the agent user; then capture, click, type, ui.tree must all be refused;
    the prompt is closed from outside (PowerShell Direct kills consent.exe).
  - `elevated`: a SYSTEM notepad on the agent's desktop (one-shot task + `harness guest-system-window`): click on it,
    Alt+Tab to it, then capture/click/type/ui.tree.
  - `errorbox`: a csrss hard-error box raised by the agent user (`harness guest-errorbox`, NtRaiseHardError).
  - `abuse`: wrong challenge MAC, wrong frame MAC, replayed seq, missing MAC, JSON > 64 KiB, blob > 16 MiB, unknown
    kind, unannounced blob, blob hash mismatch, heartbeat silence; soft errors that must not close.
  - `acl`: the secret made readable by Users -> the service must stop dialing; reverted -> it reconnects.
  - `reboot`: restart from inside; drop noticed, reconnection, `signed_in`, first screenshot.
