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

## Results so far (Nov 18)

The harness scenarios (capture, latency, UIA, refusals, abuse, reboot) could not run: GpuVM's broker under test held
`HV_GUID_CHILDREN:{service id}` almost the whole time, and the coordinator then asked to measure through the broker
(the real host side). A host listener on `HV_GUID_CHILDREN` also blocks a bind to one VM's id (10048), so two host
programs can't share the name: good for security (nothing else can squat it), one listener per host. The harness
stays for the abuse cases the broker won't exercise. What was measured:

| step | result |
| --- | --- |
| New-GpuVM from the ISO to a signed-in desktop | 4.5 min |
| install.ps1, first full run over PowerShell Direct | 6.7 s (2.2 s on a re-run) |
| install.ps1, the broker's contract (`-FilePath`, staging, secret in place), version change | 1.7 s |
| same version again (fast path: new password, restart service) | 0.46 s |
| restart -> signed in as `agent` | 15 s |
| service start -> helper running as `AGENT051\agent`, medium, session 1 | < 1 s |
| New-GpuVMTemplate (64 GB dynamic disk) | 90 s |

- **Hard reset loses the install.** The first `prepare.ps1` restarted with `Restart-VM -Force` seconds after
  install.ps1: the files (exe, log) survived, the registry (service, Winlogon) didn't. Restart from inside.
- **Execution policy:** guests keep Restricted; install.ps1 goes as a script block or `Invoke-Command -FilePath`.
- **StrictMode leaked** from install.ps1 into the caller's remote session (removed).
- **Autologon cycle** (`install-cycle.ps1`): agent -> previous -> agent restores Winlogon exactly (AutoAdminLogon,
  DefaultUserName, DefaultDomainName, AutoLogonCount 9999997) and the person's password moves between LSA secrets
  without ever being a plain registry value.
- **VmId:** `getsockname` on the guest side does not return the VM's id that the host sees in `accept()`; the guest
  takes it from KVP `VirtualMachineId` (equal to `Get-VM` Id). The first harness connection failed the handshake
  until this was fixed.
- **Mutual authentication with a foreign host listener:** the broker under test (another secret) closed before the
  challenge; with the harness's wrong secret the guest logged "the host's proof is wrong" and never sent a proof.
- **Display:** in the agent's session the primary monitor reads 1024x768 while WMI reports the virtual display at
  1920x1080; GpuVM's set-resolution runs in the user's session when the viewer connects, so it must run in the
  `agent` session in Agent mode (open, for the broker/app). Input coordinates are now read from the primary monitor
  on every request and the capture reopens when the primary display changes.

### Security review (independent reviewer agent) and fixes, verified in the VM (`security-check.ps1`)

| finding | fix | check in agent051 |
| --- | --- | --- |
| H1 helper pipes inherited by every exec.run child; any `agent` process could open the helper | stdio not inheritable, exec handle list, helper DACL: own user query+synchronize only | as `agent`: all/dupHandle/vmRead/vmWrite/suspend/terminate/writeDac **denied**, queryLimited/synchronize allowed |
| H2 a user could plant `ProgramData\GpuVM(\Agent\logs)` as a junction before install | foreign/link folders removed without following; no recursion through links; service logs only in a checked folder | junction at `logs` -> removed, target folder untouched, log written in the real folder |
| M1 a stalled helper could block the SYSTEM service | bounded queue + writer thread; helper killed after 10 s not reading | (code) |
| M2 person's plain autologon password would land in a Users-readable backup | LSA secret; backup key SYSTEM+Admins | backup key ACL: SYSTEM, Administradores only |
| M3, L1-L4 | seq not consumed by oversized frames; blob size before announcing; cancelable stdin; escaped JSON size; re-checks | (code) |
| L5 one session key for both directions | proposed to the coordinator (protocol change) | — |

## Security impact

The agent adds a SYSTEM service and a standard user to the guest, never touches UAC or the person's account, keeps
the agent's password only as the autologon LSA secret (the host has the copy, DPAPI), and the person's previous
autologon is restored exactly. Everything ran in a disposable VM; the host only got the service GUID registered
(removed again: `service.ps1 -Remove`).
