# Lab 053: the MCP server (`gpuvm.exe --mcp`)

Driver: `drive.py` (a minimal MCP client over stdio, both eras; phases `latency`, `coords`, `misuse`; raw data in
`out/`). Unit/integration tests: `cargo test --lib mcp` (18 tests against the fake broker).

## Part 1: MCP layer alone (fake broker), 2026-11-18

- **Client compatibility.** Claude Code 2.1.316 (`claude -p --mcp-config`, server `gpuvm.exe --mcp --fake`):
  connected in 124 ms, `protocolEra: modern`, `negotiatedProtocolVersion: 2026-07-28`, registered itself as
  `claude-code 2.1.316`, listed all 25 tools. The model part of the run didn't happen: the headless CLI's OAuth
  session had expired (needs `claude` sign-in once). Claude Code logs everything a server writes to stderr as
  `[ERROR]`, so the server only logs failures unless `GPUVM_MCP_LOG=1`.
- **Overhead per call** (release build, 40 interleaved rounds, request written → reply parsed by the driver):
  p50 0.6-1.1 ms, p95 1-3 ms for every non-image tool in both eras (modern 2026-07-28 and legacy 2025-11-25 alike).
  Screenshots 36 ms p50 at 1280x720 and 13 ms at 640x360 are the fake's own PNG drawing (the instrument), not the
  server: the real numbers come from the guest's WebP (lab 048: ~32 ms for 1280x720 lossless WebP).
  One `read_file` error per run = a round where the read came before the first write (expected `not_found`).
- **Coordinate round trip** (tests): every desktop pixel → screenshot pixel → desktop pixel lands in the same
  screenshot pixel and within ⌈desktop/sent⌉ px, for 1920x1080, 2560x1440, 1366x768, 3840x2160 and 1280x720 desktops
  at boxes 1280x800, 1024x768, 640x400, 2576x2576 and 333x222, plus zoomed regions. The first mapping (plain centre
  of the footprint) failed at 1366→1280 (scale 1.067): a footprint narrower than 2 px can hold one integer that the
  rounded centre misses; the centre is now clamped into the footprint.
- **Misuse** (all plain one-sentence tool errors, ~1 ms, never a protocol error): unknown tool, missing/unknown
  machine, non-number and out-of-range coordinates (the message gives the valid range and the screenshot id), unknown
  screenshot id, bad zoom, a 10000 px box, paths outside `C:\Users\agent` or with `..`, an offer outside Outbox, a
  6,000-char `type`, a bad item inside `act` ("Action 2: …"), arguments that aren't an object. A 1 MiB command output
  comes back as ~15,000 chars, head and tail, with "[n characters cut]". Paused machine, `blocked_elevated`,
  `secure_desktop`, kill switch (later calls fail without reaching the broker), destroyed machine, budget used up and
  someone else's machine: covered by the tests with the broker's codes.

- **Real model, fake machine** (after the `claude` sign-in; `claude -p` with only the gpuvm server, 2026-11-18):
  asked to create a disposable, screenshot, click the centre, type, run a command, write and offer a file. 9 turns,
  24.5 s, USD 0.25, every call succeeded first time. Claude Code loaded the tools through its tool search
  (`select:mcp__gpuvm__…`), passed the image content to the model (it described the fake desktop's colours and grid
  correctly, so image results reach the model), clicked (640, 360) on the 1280x720 screenshot = the centre, and
  wrote the offer note itself. The only odd result it reported was the fake's `run`, which echoes the command line
  instead of running it (expected for the fake).
- **Protocol updates from main** (typed actions, exec output in the blob, timeouts as results, ranged reads) are
  followed since 3a8a950; tests cover the blob output and a timed-out command.

## Part 2: real machines, installed build main 758eb70 (agent 0.3.3), 2026-11-19 01:36-01:46

`pwsh -NoProfile -File labs/053-mcp/part2.ps1 -Template agent-tpl` (lab lock as `agent-mcp`; three disposables from
`agent-tpl`, 4 GB each, all deleted at the end). Raw data: `out/20261119-0137*-run.json`, `out/20261119-014011-run.json`,
`out/part2-20261119-013655-*`.

Earlier attempts and what they taught (each fixed in the MCP or reported): template deleted under the run; disk check
(a disposable needs 20 GB besides the other machines' reserve; the lab reports it in 5 s); `Install-GpuVMAgent` from
the bridge couldn't write the per-VM secret (broker fixed it; the MCP now deletes a half-created disposable and stops
after the same error three times); a mixed install. Stopping another session's VM broke its first setup: never touch
a VM another session made (lab-craft).

**Create.** `create_disposable` (New-GpuVM + claim + Install-GpuVMAgent fast path + lock + ready): 31.0 s (modern),
27.4 s (legacy), 3 of 3 succeeded. The first one reported "ready (screen 800x600)" and the desktop became 1366x768
moments later (the guest's virtual display): the server followed it because every capture carries the screen size.

**Latency through the whole chain** (MCP stdio → service pipe → broker → Hyper-V socket → guest), 40 interleaved
rounds, modern era (legacy, 10 rounds: same within noise):

| Tool | p50 | p95 | Notes |
| --- | --- | --- | --- |
| list_machines | 1.4 ms | 1.9 ms | in-process broker |
| screenshot 1280 box, WebP | 105 ms | 116 ms | 139 KB; desktop 800x600 then 1366x768 |
| screenshot 640 box | 46 ms | 62 ms | 61 KB |
| screenshot PNG | 125 ms | 134 ms | 179 KB |
| click | 10 ms | 20 ms | one 2.1 s outlier |
| key | 2.4 ms | 4.6 ms | |
| ui_tree | 13 ms | 174 ms | p50 12-116 ms depending on the window in front |
| run (cmd echo) | 26 ms | 36 ms | process start in the guest |
| write_file / read_file 1 KB | 3.1 / 2.7 ms | 3.5 / 3.0 ms | |

**Coordinates against the real cursor** (`act move`, then `[Cursor]::Position` read in the VM with `run`), five boxes
(1280x800, 1024x768, 640x400, 2576x2576, 333x222), 60 random points: 59 in the expected screenshot pixel, max error
1 desktop px. The one miss (1366x768 sent as 1023x575, y=1) is the server's pixel 2 landing at 1: the guest's
absolute-input rounding near the edge (reported to agent-guest).

**Misuse** (real broker/guest): all 15 cases came back as one clear sentence in ≤ 2 ms, except the 1 MiB command
output (1.6 s, cut to head + tail with the count); `destroy` 3.1 s, and the next call on it says
"No agent on 'agent-tpl-c5bbf4'".

**Real model: "test GpuVM's installer in a clean Windows"** (Claude Code, 17 turns, 349 s, USD 0.70). It created
`lab053-demo` with a task, opened the viewer, sent `GpuVM_0.9.0_x64-setup.exe` (106 MB) — `send_file` said "Copied"
— and `Start-Process` found no file. It checked `Desktop\Received` (only `desktop.ini`, created by the copy's receiver
at 01:40:50), sent again ("Copied" again), searched all of C:, wrote a report to Outbox, offered it, waited 2 minutes,
destroyed the machine and reported honestly that the installer never arrived and why. No UAC step was reached.
Findings: (1) `Send-GpuVMFile` reports success for a file that never arrives (files/transfer owners);
(2) the viewer opened by `open_viewer` stayed on "Waiting for Sunshine" for the whole 5 minutes
(`out/demo-viewer-waiting.png`); (3) destroying a machine whose offer waits loses the file. MCP fixes: `send_file`
now checks the file inside the machine by size and says "checked" or a plain error (dac7fc8); `destroy` refuses
while an offer waits unless `force` (this commit).

Screenshots: `out/demo-agent-view.webp` (what the agent saw, 1279x719), `out/demo-viewer-waiting.png` (the person's
viewer), `out/20261119-013727-modern-first.webp` (800x600 right after ready).

## Part 3: where the screenshot time goes (installed main 218c3f0, 2026-11-19 04:13)

`overhead.py` times each call twice: at the client (request written → reply parsed) and in the server's own log
(`GPUVM_MCP_LOG=1`). `overhead-real.ps1` runs it on one real disposable from agent-tpl, 30 rounds per client mode.

| Client | Tool | Client p50 / p95 | Server p50 / p95 | stdio transfer p50 | base64 |
| --- | --- | --- | --- | --- | --- |
| unbuffered (`bufsize=0`) | screenshot 1280 | 143.9 / 155.0 ms | 22 / 26 ms | 121.9 ms | 269 KB |
| buffered | screenshot 1280 | 6.7 / 10.3 ms | 6 / 9 ms | 0.8 ms | 16 KB |
| unbuffered | ui_tree | 35.2 / 41.5 ms | 34 / 40 ms | 1.7 ms | – |
| buffered | ui_tree | 17.5 / 55.9 ms | 17 / 55 ms | 0.7 ms | – |

- The "105 ms" screenshots of part 2 were the lab's own client: Python's `readline()` on an unbuffered pipe makes one
  system call per byte (0.45 ms per KB here). Server side, a ~200 KB WebP takes 22 ms p50 through gpuvm.exe → service
  pipe → broker → guest and back, against 20.9 ms measured at the broker (agent-guest): the MCP layer, the pipe and the
  base64 round trip add ~1 ms. drive.py reads buffered since e082009. (The two sessions' screens differed: 269 vs
  16 KB of base64, so their server times aren't comparable to each other; each row's transfer is.)
- ui_tree is all guest time (UI Automation), 17-34 ms p50 here; the 174 ms p95 of part 2 depended on the window in front.
- Destroy check: right after the MCP's `destroy`, the disposable was already gone from Hyper-V (Remove-GpuVMDisposable
  -Name, no fallback to the 30-minute sweep).

## Part 4: the installer demo again (installed main 10c7525, 2026-11-19 05:04-05:22)

`part2.ps1 -Template agent-tpl -ModelOnly -HumanWaitSeconds 600`; Claude Code, 11 turns, 1,054 s (most of it waiting
for the person), USD 0.60. Steps: create `lab053-demo` (4 GB, task set) → open the viewer → `send_file` of the 106 MB
installer: "Copied … (106755484 bytes, checked)", i.e. it arrived (the send fix works) → `run Start-Process` started
it; the call timed out at 60 s because Start-Process waits while the UAC prompt is up → `screenshot` refused with
`secure_desktop` (the agent can't see UAC, by design) → `request_human` with an exact instruction ("Pulsa Sí … y
después Return to agent"), waited 600 s, nobody answered → it stopped installing, tried to write the report
(refused: the machine stays paused for the person), asked again for 300 s, then ended without destroying the machine
because the person might be mid-install, and asked what to do. The lab's cleanup deleted it.

Findings: (1) the viewer opened by `open_viewer` showed "Sunshine is restarting with the new settings" and fell back
to the app's machine page within ~40 s, never streaming, so the person couldn't see the UAC prompt without pressing
Open (`out/demo2-viewer-sunshine-restarting.png`); (2) while the agent waited, the app's machine page showed nothing
saying the agent was asking for help (`out/demo2-app-while-agent-waits.png`); (3) a machine paused by the agent's own
`request_human` stays paused after the agent gives up, so it can't even write its report: a way for a session to
withdraw its own pending human request (not the person's take-control) would help (broker); (4) the MCP said "the
person took control" for that pause: now it says the machine is waiting for the person to do what was asked.

## Part 5: cancel_request on a real disposable (installed main 0d88da6+, 2026-11-19 06:46)

`cancel-real.ps1` → `cancel.py`: session A (direct MCP client) creates a disposable (36.8 s); the person's side is
the module's own Suspend/Resume-GpuVMAgent (what the app calls); session B is a second MCP client.

| Case | Result |
| --- | --- |
| request_human, then acting | refused: "waiting for the person … use cancel_request" |
| cancel_request (own request) | "Withdrew your request; … is yours again" |
| acting after it | no pause any more (that one screenshot met a secure screen in the just-started clone: guest state, not the pause) |
| cancel_request with nothing pending | refused locally |
| person takes control on top of the request, then cancel_request | refused: "The person took control … themselves" (broker not_found), and acting stays refused until the person resumes |
| request answered by the person (resumed), then cancel_request | refused by the broker (not_found); the installed MCP called it "took control" — wrong. Fixed: on not_found the MCP looks at the machine and says "already answered and handed back" when it isn't paused |
| session B: cancel_request on A's machine | refused (B has no request of A's: the tool takes no request id, so a session can't name another's) |
| session B: take A's machine | refused: "being used by another agent connection" |
| A withdraws, destroy | deleted; the VM was gone from Hyper-V 3 s later |

## Part 6: the security fixes on the installed build (main 7b0b170, agent 0.4.2, 2026-11-19 08:07-08:18)

`security-real.ps1` -> `security.py`, direct MCP client, one disposable (cpu 2, 4 GB); the person's side through
the module, as the app does. 14 of 14 cases passed:

| Case | Result |
| --- | --- |
| create_disposable with only cpu/memoryGB | created (no Profile or other override sent) |
| screenshot, click, run | 1279x719 of 1366x768; click done; `echo lab053` exit 0 |
| open_viewer on a machine that isn't ours (win-gpu) | refused |
| send_file of a 1 MB file | a pending `send` request with the service's own title ("Send <path> to '<machine>': 1 file, 1.0 MB") and measure (1 file, 1,048,576 bytes); nothing copied while it waited |
| the person says no | "The person said no in GpuVM to: Copy … Don't try again"; the file isn't in the machine |
| destroy while the person has control | refused ("The person took control"); the VM still exists |
| after the person hands it back, destroy | deleted; gone from Hyper-V within 3 s |

Findings: (1) the broker's `agent` snapshot is taken when the agent connects and isn't refreshed by later events:
`signedIn:false`, `screen:null` stayed after the `signed_in` event (AGENT-BASEgent) 10 s later, so
create_disposable waited its full 600 s for "ready". Fixed in the MCP: it also accepts a `signed_in` event with a
user newer than the connection (agent-broker should refresh the snapshot). (2) With the app in the tray, nothing
appeared on screen while the `send` request waited 25 s (no window, no notification): the person wouldn't know they
were being asked (agent-ui).


## Part 6: again with GpuVM's Sunshine fork (installed build of 2026-11-20 14:43, agent 0.4.6)

`part2.ps1 -Template agent-tpl -SkipModel -Rounds 20 -Samples 6` (raw: `out/part2-20261120-213055-*`,
`out/20261120-214318-run.json`), plus one `Install-GpuVMAgent` on a fresh copy, timed step by step.

| Tool (modern era) | p50 | p95 |
| --- | --- | --- |
| create_disposable | **333 s** (legacy era: 325 s) | – |
| screenshot 1280 WebP / 640 / PNG | 24 / 15 / 25 ms | 31 / 19 / 29 ms |
| click / key | 6.6 / 2.7 ms | 10.6 / 9.6 ms |
| ui_tree / run / write / read | 15 / 32 / 3.8 / 2.2 ms | 140 / 60 / 13 / 9 ms |

Coordinates 30/30 in the same pixel. The tools are as fast as before (faster: the buffered client of part 3).
Creation went from 31 s to ~330 s. Where it goes (copy of agent-tpl, `Install-GpuVMAgent`):

| step | s |
| --- | --- |
| new copy + start + Windows ready | 24 |
| agent copy + install (template has an older agent: `exeSent`, no fast path, `rebootNeeded`) | 6 |
| fork copy (69 MB) + three Sunshine restarts (`Initialize-GuestStreamingForAgent`) | 136 |
| cold cycle: Windows never shuts down in 90 s, turn-off 31 s, start | 133 |

Causes: agent-tpl was made before agent 0.4.6 and before the fork, so every copy redoes the full install; and the
graceful shutdown of agent copies fails every time (5 of 5 now), adding 2 min to every cold cycle.

## Part 7: templates kept current (Update-GpuVMTemplate, same night)

`Update-GpuVMTemplate -Name agent-tpl`: a temporary copy gets the full install, a power cycle, a clean shutdown,
and its disk becomes `agent-tpl.1.vhdx` (2.4 GB, read-only, on top of the base). 5.4 min, once per GpuVM release;
GpuVM's service runs `-Stale` 2 min after it starts and every hour. agent059 (made before) stays on the base.

| create_disposable (MCP, installed module) | time |
| --- | --- |
| stale template (part 6) | 325-333 s |
| current template, fast path | 68-70 s |
| + Sunshine's start not waited for when nothing changed (`streamingFromTemplate`) | 54-57 s |

Install-GpuVMAgent on a copy of the current template, profiled: Windows ready 8 s, agent install 3 s (fast path,
no exe sent, no restart), display/VDD settings ~5 s, fork check 2 s, capture mode 5 s; it used to wait 21 s for
Sunshine's first start (identity regenerated). Viewer on such a copy (lab 055 open.ps1): desktop 3/3, 0 capture
restarts, first frame 19.6 s on the first open (Sunshine settling, as before) and 5.4 s after.

Found on the way: (1) right after the install Windows logs its shutdown 3 s in, but the VM never turns off (90 s +
forced, 5/5); after one more boot it shuts down in seconds. Copies no longer power-cycle, so only the template update
pays it. (2) `destroy` said "couldn't be deleted" when the app's own sweep had deleted the machine first: now done.
(3) Hyper-V only opens disks named `*.vhdx` (the first layer attempt used `.vhdx.building`).
