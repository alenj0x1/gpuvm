# Lab 058: look and act while a command runs; delayMs

Question: can an agent take screenshots and act while a `run` is in flight, and does `delayMs` wait what it says?
Follows lab 057's session (`labs/057-capture-broker/notes.md` section 4: screenshots 3-9 s "behind" a run, 28 runs of
`Start-Sleep` used as a wait, a 290 s drawing script run blind).

## 1. What lab 057's transcript shows (the cause)

Every slow screenshot was sent in the same message as a `run "Start-Sleep N"`, on purpose (wait, then look):

| calls in one message | answered after (from the message) |
| --- | --- |
| run `Start-Sleep 4`, screenshot | 9.4 s, 9.5 s |
| run `Start-Sleep 4`, screenshot | 6.3 s, 6.3 s |
| run `Start-Sleep 3`, screenshot | 5.5 s, 5.5 s |
| key, run `Start-Sleep 3`, screenshot | 1.3 s, 6.1 s, 6.2 s |

Claude Code runs a call that isn't read-only on its own and in order (only read-only calls run together), and a model
can send nothing while a call is open. So the screenshot waited for the sleep, and during a 290 s `run` nothing at all
could be sent. GpuVM itself did not serialize them: the MCP server runs each call on its own thread and gives a run
its own pipe connection, the host broker sends requests concurrently, the guest service relays them concurrently.
In the guest helper, captures and UI Automation ran on the frame-reading thread (a slow `ui.tree` held screenshots
and cancels), and `input.act` took a mutex that is not first in first out.

## 2. What changed (commit 752a2ad)

- `run` `background: true` → answers at once with `run-N`; `run_result {machine, runId, waitSeconds}` (read-only, so a
  client runs it next to screenshots) gives exit code + output once. Max 4 per connection, kept 30 min.
- `delayMs` 0-10000: `screenshot` waits before capturing; input tools wait after acting, before answering and before
  `screenshotAfter`. Cancellable.
- MCP: input calls on a machine take a ticket when read and run in that order (unit test: without it 30 calls arrived
  scrambled; with it, in order).
- Guest agent 0.4.7: helper lanes (commands/files: a thread each; input: one FIFO thread; captures + cheap reads: one
  thread; UI Automation: one thread). The reading thread only routes.

Unit tests: `cargo test --lib` in `app/src-tauri` (49 pass, 5 new/changed) and `guest/agent` (13 pass, 4 new).

## 3. The real-machine check (to run after installing the build)

Not measured in this session: only the installed `C:\Program Files\GpuVM\gpuvm.exe` may talk to the service, and the
PC had 3.6 GB free while a 4 GB copy needs 4.3 GB (`memoryGB` 3 is refused: Windows 11 needs 4).

### How to run

Preconditions:
- The new app installed (MCP server with `delayMs` / `background`) and guest agent 0.4.7 built into
  `guest\agent\dist` and shipped with it (templates get it as a layer; check the copy reports 0.4.7, see below).
- Template `agent-tpl` exists; ~4.3 GB of RAM free (no other running VM besides the one with the GPU is fine only if
  memory allows; the copy may get the Intel iGPU: no stream, but screenshots, input and run work, which is all this
  needs).
- Nobody else using the copy (the script creates its own `c058-xxxx` disposable and destroys it at the end).

```powershell
cd labs\058-agent-concurrency
python -I concurrency.py --memory 4 --new
```

Arguments: `--exe` (default the installed gpuvm.exe), `--template agent-tpl`, `--memory 4`, `--rounds 5`,
`--machine NAME` (use an existing machine you can take instead of creating one), `--new` (the delayMs and background
phases: needs the new build), `--keep` (don't destroy the copy). Raw results: `out\<time>.json` (git-ignored).
It speaks MCP over stdio to `gpuvm.exe --mcp` with several calls in flight at once (the server allows it; Claude
Code itself would serialize them, see section 1). Takes ~4 min plus the copy's creation.

To check the copy's agent version: `run` with command `& 'C:\Program Files\GpuVM Agent\gpuvm-agent.exe' version`.
To try a locally built agent in a lab copy without a new app: `.\swap-agent.ps1 -Name c058-xxxx` (elevated; only
`c058-*` machines; replaces the exe and restarts the service).

### Expected numbers (done = these hold)

| line printed | expected |
| --- | --- |
| `screenshot alone` | median 0.2-0.6 s (lab 057) |
| `screenshot during run` | each < 1.5 s while `Start-Sleep 30` runs (every one, not the median) |
| `key during run` | each < 1.5 s |
| `run Start-Sleep 30` | ~30-31 s, no error |
| `screenshot delayMs 2000` | ~2.0 s + the alone time (2.2-2.6 s) |
| `key delayMs 1000 + after` | ~1.0 s + one screenshot |
| `run background (start)` | < 1 s, text names `run-N` |
| `screenshot during bg run`, `key during bg run` | each < 1.5 s |
| `run_result` | answers when the 30 s are up, `Exit code 0` and `slept` |

If `screenshot during run` is slow with the old guest agent but fast with 0.4.7, the guest lanes were the cause; if it
is fast with both, the guest was already fine for captures next to `exec.run` (it ran exec.run off the reading
thread) and the gain is ordered input and captures next to UI Automation.

Results: _to be filled by whoever runs it._

## Lessons

- Read the client's transcript before blaming the server: "waits behind" was the client's own ordering of a call
  that isn't read-only, plus a deliberate sleep.
- Disposable agent copies need 4 GB (4.3 GB free) on this PC; `memoryGB` 3 is refused by the Windows 11 check.
