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

The harness ran once in a 30-min slot the broker gave (`out/run-20261118-220543`, agent 0.3.0). A host listener on
`HV_GUID_CHILDREN` blocks a bind to one VM's id too (10048): one listener per host, nothing else can squat it. Capture
failed in that run (see "regression" below), so capture, action -> screen latency and the Edge checks are still to be
measured, through the broker (`Invoke-GpuVMAgent`) once the installed build bundles 0.3.1.

| harness case (agent 0.3.0, n) | result |
| --- | --- |
| agent.info round trip (200) | p50 0.29 / p95 0.40 ms |
| screen.state round trip (200) | p50 0.24 / p95 0.32 ms |
| exec.run `cmd /c echo hi` (40) | p50 26.6 / p95 42.1 ms |
| exec.run whoami | `agent051\agent`, Medium (S-1-16-8192) |
| exec.run stdin / timeout 1.5 s / 1 MiB output / missing program | ok / `timedOut` + partial output at 1.51 s / blob, truncated / `not_found` |
| ui.tree, warm (5): Notepad, Settings, Explorer | 18.5 / 22.7 / 163 ms (17 / 19 / 186 interactive nodes) |
| UAC credential prompt raised by `agent` | `secure_desktop` event 1.8 s after; capture, click, type, ui.tree all refused `secure_desktop` |
| SYSTEM notepad on the agent's desktop, Alt+Tab to it | click, type, ui.tree refused `blocked_elevated` |
| wrong challenge MAC | no proof sent, closed |
| wrong frame MAC, replayed seq, no MAC, JSON > 64 KiB, blob > 16 MiB, unknown kind, unannounced blob, blob hash mismatch | closed in <= 0.2 ms |
| heartbeat silence | closed at 7.0 s |
| unknown method, params not an object, click outside the screen | `bad_request`, connection kept |
| secret readable by Users | no dialing (15 s); reverted -> reconnected in 1.9 s |
| restart from inside | drop seen in 3.3 s; reconnected 14.7 s after the call (7.0 s after boot) |

Not conclusive: the csrss error box (NtRaiseHardError from the agent user) produced no `error_box` event and no
visible box was found; the `secure_desktop{on:false}` event didn't arrive within 10 s after consent.exe was killed;
`signed_in` after the restart was logged by the guest but not seen by the harness. All three need screenshots, i.e.
the 0.3.1 capture, and are re-checked through the broker.

**Regression found by the harness:** the security fix that restricted the helper's process DACL (own user: query and
wait only) made Windows.Graphics.Capture fail with E_ACCESSDENIED (the process opens itself by id). Reverted in 0.3.1;
the handle-inheritance part of that fix stays.

**Real sign-in cycle on a fresh VM** (`signin-cycle.ps1`, agent 0.3.1): install -> signed in as `agent` 23 s after the
restart call; `-SignInAs previous` -> the person (`gpuvm`) 45 s; `-SignInAs agent` (fast path) -> `agent` 47 s;
profile `C:\Users\agent`. On the first VM the person's sign-in did NOT come back: its first install had been
hard-reset (below), which left an orphan `C:\Users\agent` (profile became `agent.000`) and a wrong password backup.
install.ps1 now moves an orphan folder aside; agent.info returns `home`.

Other measurements:

| step | result |
| --- | --- |
| New-GpuVM from the ISO to a signed-in desktop | 4.5 min |
| install.ps1, first full run over PowerShell Direct | 6.7 s (2.2 s on a re-run) |
| install.ps1, the broker's contract (`-FilePath`, staging, secret in place), version change | 1.7 s |
| same version again (fast path: new password, restart service) | 0.46 s |
| restart -> signed in as `agent` | 15 s |
| service start -> helper running as `AGENT051\agent`, medium, session 1 | < 1 s |
| New-GpuVMTemplate (64 GB dynamic disk) | 27-90 s; `agent-tpl` = 14.4 GB |

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
| H1 helper pipes inherited by every exec.run child; any `agent` process could open the helper | stdio not inheritable, exec handle list (kept); helper DACL own-user query+synchronize only (**reverted in 0.3.1**: broke WGC) | 0.3.0: as `agent` all/dupHandle/vmRead/vmWrite/suspend denied. Residual: programs run as `agent` can open the helper (same user); they no longer inherit its pipes |
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

### Agent-mode displays (agent 0.3.3, `display-test.ps1`, disposable from agent-tpl, no viewer connected)

A GPU-P guest has an extra "Microsoft Basic Display" (1024x768) that is the PRIMARY display, and GpuVM's virtual
display is a secondary 800x600 until a viewer connects. With 0.3.2 Notepad opened by the agent landed on the basic
display at x = -972 relative to the agent's screen: only its taskbar button was visible in the screenshot
(`out/display-20261119-012802/before.png`). 0.3.3's session helper makes the virtual display the only (hence primary)
display at startup and re-checks every 5 s (GpuVM's own MakeOnlyDisplay technique), and raises it to the first size
it offers of 1280x800, 1366x768, ... only while it is below 1280x720 (a viewer's size is never overridden). After:
one display, 1366x768 (the virtual display offers no 1280x800), Notepad at [78,78] fully inside the screenshot
(`after.png`). First version re-applied 1366x768 every 5 s (768 < 800): fixed, a change makes Sunshine re-test its
encoders. Template build with the installed broker: clone ready + agent connected in 37-38 s.

### Through the real host side (installed broker, `measure-broker.ps1`, disposable from agent-tpl, agent 0.3.3)

`out/broker-20261119-013616` (results.json lost the capture stats to a `$R`/`$r` name clash, fixed; the p50s are in
`measure-broker.log`). Clone created + agent ready: 35 s / 36.5 s. Screen 1366x768 (virtual display only).

| | result |
| --- | --- |
| screen.capture WebP fit 1280x800 (n=40) | host p50 20.9 ms (guest 17.7 ms), 200 KB |
| screen.capture PNG fit 1280x800 | host p50 19.5 ms (guest 15.7 ms), 254 KB |
| screen.capture WebP native 1366x768 | host p50 13.8 ms (guest 10.5 ms, no scaling), 197 KB |
| screen.capture WebP region 400x300 | host p50 6.5 ms (guest 3.9 ms), 5 KB |
| action -> screen (type `m` / Backspace in Notepad, host polls a 320x60 PNG region, n=40) | **p50 19.8 / p95 29.7 ms**, max 43, 3 captures per sample, 0 timeouts |
| Edge, local page: click+type (with ñ), key repeat, ui.invoke on a button, click, ui.invoke setValue, scroll | all 6 confirmed through the page title |
| ui.tree Edge | ~300 ms per call (queried twice every time: 0.3.4 queries twice only the first time a window is seen, not yet measured) |
| UAC prompt from `agent` | desktop `secure` seen 2.5 s after exec; capture/click/type/ui.tree all refused `secure_desktop`; default again 2 ms after consent.exe was killed; capture works after |
| csrss hard-error box from `agent` | its window comes to the front (title "GpuVM lab 051", owner unreadable) and a click is refused `blocked_elevated`; not visible in the screenshot and not listed in `errorBoxes` (open) |

**csrss error box, analysis (0.3.6):** two causes, both from the lab's setup and one real bug. (1) `errorBoxes` came back
empty for the `agent` user: the session filter opened each csrss.exe (ProcessIdToSessionId), which a standard user
can't do (csrss is protected, SYSTEM-only); lab 049's helper was a filtered admin. Now csrss is found by name in a
process snapshot without opening it. (2) The box wasn't in the screenshot because `exec.run`'s 3 s timeout killed the
process that raised it: csrss withdraws the box when its raiser dies, leaving an invisible foreground window with the
title (hence `blocked_elevated` and nothing on screen). measure-broker.ps1 now starts the raiser detached so the box
persists, like lab 049's box from a process that failed to start. To verify in the next run.

**Rerun with the installed build, agent 0.3.6** (`out/broker-20261119-040959`): clone + agent ready 29/30.5 s, and
agent.info at ready already reports 1366x768 with only the virtual display (no transient 800x600). Capture host p50:
WebP 1280 21.6 ms, PNG 19.7, native 14.5, region 6.9 ms. Action -> screen p50 23.5 / p95 34.2 ms (n=39, 1 timeout).
Edge ui.tree warm 158 ms (was 300: double query only once). Edge input/ui.invoke 6/6. Secure desktop: all refused.
Error box (raiser detached): now listed in `errorBoxes` and the click refused `blocked_elevated`, but still NOT in the
screenshot although user32 calls it visible and foreground. Hypothesis: csrss placed it by the old layout (the
basic display the helper turned off), i.e. off-screen; 0.3.7 adds `errorBoxRects` (bbox relative to the agent's
screen) to screen.state to check.

**Error box, closed** (`errorbox-check.ps1`, `out/errorbox-20261119-064710`, installed agent 0.3.7): with the raiser
detached the box is listed in `errorBoxes`, `errorBoxRects` puts it ON the screen (bbox 501,325 379x140 in 1366x768),
it IS in the screenshot (`box-0.3.7.png`, over the raiser's black console window) and a click is refused. The
"off-screen" hypothesis was wrong; the earlier invisible box was the killed raiser (first run) and, in the second, a
screenshot taken before the box was painted. 0.3.8 words the refusal as "a system error box '…' is open: only the
person can close it" (and adds "outside the visible screen" when that is the case). screen.refresh couldn't be
called through the installed broker yet: it rejects unknown method names (broker allowlist).

### Second security review, verified (`security-check2.ps1`, `out/security2-20261119-070213`, agent 0.4.0)

| finding | check in a disposable from agent-tpl | result |
| --- | --- | --- |
| install.ps1 followed links in the agent's profile | `agent` planted Desktop\Outbox -> C:\Program Files\GpuVM Agent, then a full install | link removed ("removed a link at ...\Outbox"), Outbox a real folder owned by agent, Program Files still owned by Administradores, no desktop.ini there |
| helper in any session / by name | install records the agent SID + mode in HKLM; helper started (agent SID matches) | 0.4.0 helper up as agent; person-mode refusal of an admin's filtered token: unit test |
| displays persisted for every user | only the agent's helper arranges them, with SetDisplayConfig without SDC_SAVE_TO_DATABASE | only the virtual display active, Notepad at [78,78] inside the screenshot |
| UIAccess windows | osk.exe started by the agent, click on its window | refused `blocked_elevated` ("Teclado en pantalla (osk.exe) ... runs elevated") |
| passwords in templates | -PrepareTemplate | no LSA DefaultPassword, no backed-up person password (both kinds), only the two machine-policy backups left, AutoAdminLogon 0, secret overwritten + deleted |
| a copy's first install | fast path with a new secret | rebootNeeded = true; after the restart the copy signed in as agent |

Not changed: the MAC is still checked after parsing the (<= 64 KiB) JSON to read `seq` (a key `seq` can also appear
nested in params, so a scan can't find it without parsing; moving it would change the wire format on both sides).
0.4.1 (code review): requests reach the helper under ids unique for the service's life (the host restarts at 1 per
connection: a late result could answer a new request with the same number), the old connection's work is cancelled
in the helper on disconnect and on timeout, and input.act's deadline follows its own waits (or the host's timeoutMs,
max 10 min; waits up to 5 min per request).

### screen.refresh and ddx: not measurable from inside the guest (Nov 19)

`dup-refresh-test.ps1` (`out/dup-refresh-20261119-085528`, agent 0.4.2 on copies of agent-tpl): DXGI Desktop
Duplication opened as the agent user on the agent's display, 20 still rounds per variant: none 0/20, screen.refresh's
RedrawWindow 0/20, and the positive control (a real, invisible 1x1 alpha-1 window shown for 50 ms) ALSO 0/20. The
instrument sees no frames at all from that session (same family as lab 048: duplication on GpuVM's virtual display
doesn't deliver frames), so it can't judge screen.refresh. The repaint's effect on Sunshine's ddx stays unproven; it
needs the viewer path (agent-ui's luma method through an MCP session, 10+ connects per variant). Kept, since it costs
nothing and can't hurt.

0.4.2 readiness: on 3 of 5 copies agent.info at "ready" already reported only the virtual display at 1366x768 (the
layout applied before hello). On 2 of 5 (both early, 08:45 and 08:50) the agent reported NO display for 60 s after
the install's restart, while a diagnosis copy in between was fine; the failing runs had no dump (added afterwards):
open, intermittent.

### Copies with no display: the VM's GPU partition, not the helper (Nov 19)

agent-broker saw 4 of 13 copies of agent-tpl whose agent reported `displays: []` for good. Reproduced the claim way
(copy, start, Install-GpuVMAgent with its in-guest restart): 2 of 10 (`race-repro.ps1`), then 2 of 10, 2 of 14, 1 of 8,
2 of 9 in the later runs, about 1 copy in 5. A first repro run said 0 of 8: it skipped the install + restart and
counted `@($null)` as a display (tool-pitfalls 9h, lab-craft rule added).

What a bad copy looks like (`ccd-test.ps1`, harness `guest-ccd`, as the agent user in its console session):
- the helper is in `WinSta0\Default`, session 1 = the console session, local (protocol 0, SM_REMOTESESSION 0), dwm,
  explorer, sihost running, both monitors OK in PnP, display-off timeout 0 (never);
- Windows gives the session NO display path at all: QDC_ONLY_ACTIVE_PATHS and even QDC_ALL_PATHS size 0 (query 87),
  both display devices detached (flags 0x0), a 1024x768 stand-in desktop with 1 "monitor";
- the agent never got to touch it: its first layout call already found 0 paths (helper's first run on that boot).

What did NOT bring it back, each on 2 bad copies: SDC_TOPOLOGY_EXTEND (once, or every 3 s for 30 s: 2 of 4 copies
came back, 2 never did), waking the display (ES_DISPLAY_REQUIRED + a 1 px mouse move), restarting the virtual display
device, restarting the Hyper-V video device, `tscon` to the console, signing out (autologon did not sign in again),
restarting Windows (Restart-VM). Good vs bad registry (GraphicsDrivers), devices and System/DxgKrnl logs
(`diff-test.ps1`): the same, except the GPU-P device's instance id (new on every copy).

What did (`readd-test.ps1`): removing and adding the GPU partition adapter on the host (2 of 2), and the control
alone, a cold stop + start of the VM with the same adapter (2 of 2); both stayed good across a restart. So the state
lives in the running VM's GPU partition and only a power cycle resets it; in-guest restarts and Restart-VM keep it.

Fix (`coldcycle-test.ps1`, `out/coldcycle-20261119-115734.json`): the claim path plus Stop-VM + Start-VM once the
agent's install restarted: 12 of 12 copies had their display 12-23 s after the start (stop 4-9 s, cycle 17-28 s);
in the same run 2 of 12 had none before the cycle. The repair belongs to the host (Install-GpuVMAgent / the broker:
shut Windows down instead of restarting it from inside, then start the VM), not to the agent. The agent 0.4.5 says it
plainly: `agent.info.noDisplay` is a reason when QDC_ALL_PATHS is empty (null otherwise), and the periodic layout
error is logged once per new error instead of every 5 s.
