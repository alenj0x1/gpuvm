# Lab 042: administrator-prompt dock, faster answers and notices-only mode

Run elevated, with the shared lab lock (`take-lock.ps1 -What "..."`, delete `C:\GpuVM\.lab-lock` when done).

| Script | What it measures |
| --- | --- |
| `kvp-latency.ps1 -Name <vm> [-Count 40]` | A host -> guest data exchange item (`AddKvpItems`/`ModifyKvpItems`): the host call, when the guest sees it (guest clock mapped to the host's), and the round trip back through the guest's own items. |
| `answer.ps1 -Name <vm> [-Rounds 2] [-PerRound 10]` | Real administrator prompts end to end with the module's code, before (0.9.0 watcher, PowerShell Direct answer) and after (one-time code, helper waiting on the secure desktop, answer through the data exchange), interleaved: open -> listed on the host, open -> program known, answer time, and whether Allow/Deny did what was asked. Also: an old prompt id is refused, and a guest program without elevation can't write the host's key. |
| `dock-smooth.ps1` | The viewer's presents (PresentMon) with the dock down vs not shown, full screen and inside the app. |
| `notices.ps1` | The app's footprint in notices-only mode (working set of gpuvm.exe and its WebView2 processes) and that it ends when no machine is on. |
| `dock-options.html` | The three dock designs shown to the person (not part of the app). |

Raw data goes to `out/` (git-ignored); conclusions in `notes.md`.
