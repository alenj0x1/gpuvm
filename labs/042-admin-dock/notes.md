# Lab 042: administrator-prompt dock, faster answers, notices-only mode

Machine: i5-12400, RTX 4060, Windows 10 host; guest `win-gpu` (Windows, WGC capture). Nov 18, 2026.

## Hypotheses

1. The host can carry the person's answer to the guest through Hyper-V's data exchange (host -> guest KVP item, read
   by the SYSTEM watcher that already runs) instead of PowerShell Direct + a one-time SYSTEM task, taking the answer
   from seconds to under one, with the same guarantees: only the prompt the person saw is answered, and nothing in
   the guest without elevation can forge an answer.
2. Publishing the prompt as soon as `consent.exe` appears (program and publisher follow) and polling every second
   instead of two shortens the time before the dock drops.
3. A dock drawn by GpuVM over the picture only costs while it is down; the picture goes back to presenting directly
   once it lifts.
4. Notices-only mode costs little in the background (no page, no viewer).

## 1. Host -> guest data exchange (`kvp-latency.ps1`)

First try (n=5, while another session's lab copied files into the same VM, so only indicative): the host call
(`ModifyKvpItems`, with its CIM lookups) median 378 ms; the guest sees the item right as the call returns (median
363 ms after it started); the guest's echo is read on the host 408 ms after the start. The guest -> host direction,
which lab 025 found taking up to 3 s, came back in ~50 ms here.

Security: in the guest, `HKLM\SOFTWARE\Microsoft\Virtual Machine\External` (where host items land) and `...\Guest`
(where the guest publishes) are writable only by SYSTEM, Administrators (elevated), the KVP service and sppsvc;
Authenticated Users can only read.

## 2. Prompts end to end (`answer.ps1`, 2 rounds x 10 prompts per variant, interleaved, Allow/Deny alternating)

| | baseline (0.9.0 watcher, PowerShell Direct answer) | candidate (one-time code, waiting helper, KVP answer) |
| --- | --- | --- |
| prompt open -> listed on the host (dock can drop) | median 710 ms, p95 839, max 1003 | median 582 ms, p95 661, max 692 |
| prompt open -> program and publisher known | median 710 ms, p95 839 | median 633 ms, p95 775, max 904 |
| answer (`Resolve-GpuVMAdminPrompt`) | median 2140 ms, p95 2396, max 4098 | **median 369 ms, p95 685, max 884** |
| did what was asked (Allow ran the program, Deny didn't, prompt closed) | 20 / 20 | 20 / 20 |

- An answer for an old prompt id is refused in both ("El aviso ya cambió o se cerró").
- The 0.9.0 answer here took 2.1 s, not lab 026's ~5 s on win10: this guest starts its one-time task faster.
- These times are measured at the host polling the data exchange every 20 ms; in the app, add the poll (now 1 s,
  mean 0.5 s) to "listed".

`forge.ps1`: a program run by the signed-in guest user with a limited token tried to write both keys: `External`
denied, `Guest` denied (SecurityException). So an answer can only come from the host (or from something already
elevated in the guest, which could press the button itself anyway). The one-time code (16 random bytes from the
SYSTEM watcher, per prompt) keeps a stale or replayed host item from answering a later prompt with a reused id
(ids are `consent.exe` process ids), and the host removes its item right after the guest acknowledges it.

Poll cost (`Get-GpuVMAdminPrompt -WithWatched`, in-process, 30 calls, one watched machine): median 43 ms, p95 54 ms,
~28 ms of CPU per call. At one call a second that is ~0.2 % of this PC's 12 threads. Adopted: poll every 1 s.

## 3. Dock smoothness (`dock-smooth.ps1`, PresentMon 2.6.0, 3 rounds, viewer full screen, lab 041's moving bar)

| round | before (no prompt) | prompt open, dock down | after (answered, dock gone) |
| --- | --- | --- | --- |
| 1 | 94 frames, Independent Flip (bar still starting) | **0 frames** | 0 frames |
| 2 | 911 frames, 152/s, Independent Flip, between 5.5 / p99 9.2 ms | **0 frames** | 1075 frames, 179/s, Independent Flip, until displayed 0.9 ms |
| 3 | 1076 frames, 179/s, Independent Flip, until displayed 1.6 ms | **0 frames** | 581 frames, 97/s, Independent Flip (stream resuming) |

While Windows shows an administrator prompt, the viewer presents nothing at all: the guest is on the secure desktop
and WGC sends no new picture, with the dock or without it (the 0.9.0 card had the same picture). So the dock can't cost
smoothness while it is down. Once it lifts, the window is destroyed and the full-screen viewer goes straight back to
hardware independent flip at the monitor's rate; the first seconds after a prompt the stream itself is still resuming
(rounds 1 and 3 "after"), which is Windows/Sunshine, not the dock. The GPU was at 28 % before the run (the stream
itself and another session's work); the before/after numbers match lab 041's full-screen baseline.

Tested by hand in the installed app (film in `out/film-dock3`, `out/film-deny`): the dock drops 0.3 s at the top center
over the darkened picture, a real click on Rechazar closed the prompt and the dock lifted about a second later. With the
button fix installed, a real click on Permitir answered it too (the elevated program ran, the prompt closed) and the
keyboard went back to the viewer (foreground process GpuVMViewer afterwards).

## 4. Notices-only mode (`notices.ps1`, installed app)

Closing GpuVM's window (Al salir: Dejarlas encendidas, the new option on) with win-gpu on: the viewer and every window
close, the app stays with only its tray icon.

| | processes | working set | private | CPU |
| --- | --- | --- | --- | --- |
| open, picture full screen (reference) | 8 (gpuvm, viewer, 6 WebView2) | 159 MB | 445 MB | 21 % of one thread |
| notices-only mode | **1 (gpuvm)** | **10 MB** | **6 MB** | **0.07 % of one thread** |

Plus the service's poll (section 2, ~0.2 % of the PC). A prompt raised meanwhile showed the corner card ~0.5 s later
(its WebView2 starts only then), without taking the keyboard from the window in front; Rechazar on the card answered
it and the card's WebView2 closed again. Opening GpuVM again (Start menu / second launch) brings the main window back
in the same process and ends the mode.

Ending by itself (`notices-exit.ps1`, inside front 4's window that shut win-gpu down cleanly): GpuVM in notices-only
mode since 09:55:31; Hyper-V logged win-gpu shut down (event 18504) at 09:56:03.345 and gpuvm.exe was already gone at
the next check, 09:56:03.494. So it ended within the same second, as soon as no watched machine was on. (The script's
own 0.5 s `Get-VM` check still read Running just before and labelled it "unexpected": the instrument, not the app;
Hyper-V's event log is the reference.)

## Decision

1. Adopted: answers through the data exchange with a one-time code and a helper waiting on the secure desktop
   (2.1 s -> 0.37 s median, same correctness). PowerShell Direct stays as the fallback for watchers from before this
   lab (updated by hash on the next connect).
2. Adopted: publish at once, read after; poll every second.
3. Adopted: the dock overlays the picture (no inset: rescaling the picture would jump, and during a prompt there is
   no picture to keep anyway). The mouse is released with the viewer's existing `capture off`; the dock takes the
   keyboard so nothing typed meanwhile goes into the machine, and no key answers. The answer is decided in the dock
   (GpuVM, Medium): its window may call only `dock_prompt` and `dock_answer(allow)`, and the machine and prompt id
   come from Rust, not the page; answers in its first 0.7 s are refused (a click meant for the picture).
4. Adopted: notices-only mode (~10 MB, nothing elevated or new).

## Security

- No new elevated code or privilege. The guest watcher already ran as SYSTEM; it now also reads one host item and
  writes in its own admin-only folder (Program Files\GpuVM\AdminPrompt).
- A guest program without elevation can't forge an answer (`forge.ps1`); the one-time code stops replays; the host
  item is removed after each answer.
- The viewer (Low) can't click the dock (UIPI); the dock's capability has no `ps`.
- Residual (same as the 0.9.0 card): a compromised viewer could draw a fake prompt-like picture; it still can't
  answer anything, and the real dock always comes from GpuVM.

## Lessons (folded into the skills)

- The service returns a list for every command; the dock never dropped until `notices::poll` took the first item.
- A new Tauri window label needs its own capability, or every `invoke` fails silently (empty window).
- `.main` is the app's layout class: the dock's button reused it and its text wrapped under the icon.
- Installing with `install-build.ps1` kills the viewer mid-session; Sunshine then hung on "resume" for 2+ min until
  restarted. Never kill `consent.exe` in a lab; answer the prompt instead (`raise-prompt.ps1 -Deny`).
