# Lab 049: input and UI Automation from the session helper

Test VM `agentlab` (Windows 10 Pro 22H2 es-MX, 4 GB, GPU-P, virtual display 1920x1080), Nov 18, 2026. Probe:
`labs/048-capture/agentprobe` (`act`, `fg`, `focus`, `focused`, `latency`, `uia`, `launch`, `launch-as`).

## Hypothesis

A helper at medium integrity in the person's session, running either as the signed-in user or as a separate standard
user `agent`, can click, type, press keys and scroll with coordinates normalized to the virtual desktop and have them
land; it can tell an elevated foreground window apart instead of failing silently; and it can read the foreground
window's UI Automation tree in one cached call fast enough for an agent loop.

## Method

- Identities: `gpuvm` = the signed-in user's medium token, started from SYSTEM (WTSQueryUserToken +
  CreateProcessAsUser). `agent` = a local standard user (Users only, random password) started on the same desktop by
  the gpuvm helper with `CreateProcessWithLogonW` (what runas does). Both medium integrity, session 1, input desktop
  `Default`.
- `run.ps1`, 2 rounds x {gpuvm, agent}, on a fresh Notepad: click the text box at the center of its UIA box
  (normalized x/y over the virtual desktop -> `MOUSEEVENTF_ABSOLUTE|VIRTUALDESK`), type text (KEYEVENTF_UNICODE),
  select all + Backspace, type 60 lines + Ctrl+Home + wheel -1200, Alt+F4 -> click the save prompt's **Cancelar**
  by its UIA box. Each result is read back through UIA (`ValuePattern`, `ScrollPattern`, foreground title), not
  assumed. Then action -> screen latency: 40 alternating `m` / Backspace, time until a WGC frame differs from the
  frame before by > 40 pixels (the caret alone changes ~20).
- Elevated window: Notepad started by a highest-run-level task of the user (High integrity, no prompt); `fg`, a normal
  `act` (checks first) and a forced one (`--force`, no check) as both identities.
- UIA: foreground window, `CacheRequest` (ControlType, Name, BoundingRectangle, IsEnabled, IsOffscreen, AutomationId;
  TreeScope Element+Descendants; control view; `AutomationElementMode_None`), one `ElementFromHandleBuildCache`,
  6 repetitions per app + 1 raw view; Explorer (C:\Windows), Notepad (120-line file), Settings (Display), Edge (local
  page with 20 fields/buttons/links).

## Results

**Input lands, for both identities** (4/4 runs each): typed text read back exactly, select-all + Backspace emptied the
text, the wheel took the scroll from 0 % to 100 %, the click on Cancelar closed the prompt and gave Notepad back.
`SendInput` itself takes ~0.3 ms. A standard user `agent` can drive the person's medium windows: UIPI only looks at
integrity, not at the user.

**Action -> screen** (gpuvm, n = 80, WGC at 60 Hz): **p50 22.3 ms, p95 31.6 ms**, min 8.2, max 45; 0 timeouts,
0 samples skipped for a lost foreground. Instrument floor ~8 ms (one 16.7 ms frame period granularity + ~7 ms
readback), so the guest shows a keystroke in ~1-2 frames.

**Elevated foreground is detected, not silent** (both identities):

| | result |
| --- | --- |
| `fg` | `verdict: blocked_elevated`, target integrity 0x3000 vs own 0x2000 |
| normal `act --do type` | refused before injecting: `{"result":"blocked_elevated","injected":false}` |
| forced `act` | `SendInput` returns 2 of 2, GetLastError 0: **the silent failure** (title unchanged, no text) |
| UIA tree of the elevated window | only the root element (1 of N): content not readable either |

A second kind of blocked window appeared by accident: a process that failed to start left a **csrss hard-error box**
("agentprobe.exe - Error de la aplicación", SYSTEM) in the middle of the screen. Clicks landed on it, then
`GetForegroundWindow` returned NULL for > 500 ms and nothing could be typed anywhere until the guest restarted. The
agent must treat a persistent `no_foreground` as blocked too, and report it, never keep clicking.

**UI Automation, one cached call** (ms, first call / warm median of 5):

| app | first | warm | elements (control view) | visible | interactive visible | raw view |
| --- | --- | --- | --- | --- | --- | --- |
| Explorer | 133 | 130 | 230 | 223 | 164 | 236 |
| Notepad | 21 | 19.5 | 29 | 29 | 17 | 29 |
| Settings (UWP) | 40 | 29 | 99 | 82 | 30 | 130 |
| Edge (Chromium) | 35 (62 elements) | 31 | 144 | 135 | 80 | 442 |

- Chromium exposes only its frame on the first query and builds its accessibility tree after it (62 -> 144); the
  agent must query twice (or wait) on a fresh Chromium window. As `agent` the first call already saw 144 because gpuvm
  had queried it before.
- The control view cuts Edge's raw tree from 442 to 144 elements at the same cost; filtering to visible + interactive
  (UFO2-style) leaves 17-164 entries, a size a model can take as text.
- The `agent` user reads the same trees as gpuvm (Notepad 29/29, Edge 144/144) at the same speed.

**What doesn't work as `agent`:** screen capture. WGC fails to open with E_OUTOFMEMORY for a process of another user
on the person's desktop (DXGI opens but loses access, as for everyone on this display). Capture must run as the
signed-in user's helper.

**Real-world traps found** (the guest is Windows in Spanish): in Notepad Ctrl+A is *Abrir* (select all is Ctrl+E) and
Ctrl+F isn't Find (Ctrl+B is): the first run opened an Open dialog instead of selecting. Edge shows its welcome dialog
over the page despite `--no-first-run` on a clean install (`out/run-20261118-205043/edge-1280.png`). An agent needs
language-neutral key choices (Ctrl+Home, Ctrl+Shift+End) or the UIA patterns, and a check of what it sees after each
step.

Lab bugs fixed along the way (in the probe): `CreateProcessWithLogonW` must get `lpDesktop = NULL` (with an explicit
`winsta0\default` the child hung in start-up and left the hard-error box above), and its command line is capped at
1024 characters; a process created from SYSTEM needs `CreateEnvironmentBlock` (with SYSTEM's environment Edge never
opened a window).

## Security impact

Test VM only; the `agent` user and its profile were deleted at the end. Nothing in the product changed. The design
keeps UIPI: the helper runs at medium integrity, no `uiAccess`, no virtual HID, and the secure desktop and elevated
windows stay human-only.

## Conclusion

- Inject with `SendInput` from a medium-integrity helper; coordinates normalized to the virtual desktop work as is.
- Before **every** action, check: input desktop is `Default` (else `secure_desktop`), there is a foreground window
  (else `blocked`), and its integrity <= ours (else `blocked_elevated`). Never inject blindly: the forced test proves
  UIPI drops it silently.
- UIA with one CacheRequest (control view, visible + interactive) is 20-130 ms per window; query Chromium twice.
- Identity: a separate standard user `agent` can drive and read the person's medium apps, but **cannot capture the
  screen**. Two options for the real design: (a) the whole helper runs as the signed-in user (simplest, what works
  end to end), or (b) a split: capture in a user-token helper, input + UIA + commands as `agent`. (b) keeps files and
  commands the agent runs out of the person's profile; both stay at medium integrity, so (b) is no stronger against
  the person's own windows. Recommendation for phase 1: (a) for the session helper, with commands launched as
  `agent`; revisit (b) if commands need to run in the session.
