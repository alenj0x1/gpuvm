# Lab 055: why agent machines' viewer is black, and whether Sunshine can capture with WGC without running as `agent`

Machine: i5-12400, RTX 4060 (GPU-P), Windows 10 Pro for Workstations host, Nov 20, 2026. Guest: `agent055`, a copy
of agent-tpl prepared by `setup.ps1` (Install-GpuVMAgent, cold boot, `agent` signed in on the console). Raw data in
out/ (git-ignored). Total time: ~1 h 15 min.

## Scripts

- `setup.ps1`: the agent copy (≈4 min). `open.ps1 -Prepare` runs the real Connect-GpuVM -Viewer once (pairing, args).
- `open.ps1`: one viewer open the way the app starts it (tools/latency: pipe, token, Low integrity). Measures from
  Sunshine's own log (capture restarts = "Desktop resolution") and saves the viewer window itself (PrintWindow) at
  3/8/20 s. The viewer's "first frame" event is NOT proof of a picture: it fires on black frames too (ddx1: 15 s,
  window still black).
- `swap.ps1 -Mode user|service [-High]`: Sunshine as the service (SYSTEM, ddx) or as the standard user
  `gpuvm-stream` in `agent`'s session (`StreamLauncher.cs`: SYSTEM task → SYSTEM in session 1 → batch logon moved
  into the session, desktop ACL, optional high integrity, explicit default DACL).
- `probe-run.ps1` + `Probe055.cs`: the WGC calls Sunshine makes (activation factory, CreateForMonitor) per identity.
- `ddxprobe/`: Sunshine's DDX loop without Sunshine (Rust), as SYSTEM in the console session.

## Results

| test | result |
| --- | --- |
| ddx1, service as today | 20 capture restarts in 20 s, viewer window black (luma 0-1) |
| Sunshine as `gpuvm-stream` + wgc (batch, medium/high, with/without session logon SID, interactive logon) | aborts 0xC0000409 at WGC init, 25-40 s after start |
| WGC probe `CreateForMonitor` as `gpuvm-stream` (all logon variants) | 0x8007000E |
| WGC probe as `agent` (session owner) | 0x00000000 |
| Sunshine as `agent` + wgc (control) | encoder probe passes; then stops: can't read `credentials\cakey.pem` (as it should) |
| ddxprobe as SYSTEM in session 1 | DXGI_ERROR_ACCESS_LOST 6 ms after every first frame: 47 in 20 s; factory always current |
| ddxprobe with the VDD's HardwareCursor off | same (54 lost in 20 s) |

## Conclusions

1. DDX on the virtual display over GPU-P loses access after every frame, below Sunshine (Windows/driver). The
   repaint bursts, resolution fixes and reconnects of lab 052 could never fix it.
2. Windows only lets the session's own user create a WGC capture item. A separate user can't, whatever its logon.
   Sunshine (upstream) only captures WGC in its own process, so it would have to run as `agent` (secrets exposed).
3. The design that fits: Sunshine stays SYSTEM (secrets protected) and a small capturer runs as `agent` in its session,
   holding nothing secret, passing frames through a shared texture. Vibeshine (Nonary/vibeshine, GPL-3.0, a Sunshine
   fork) already does this ("WGC service mode": `tools/sunshine_wgc_capture.exe` started with WTSQueryUserToken,
   keyed-mutex shared texture, DXGI fallback on the secure desktop).
4. Security finding, today's builds: `C:\Program Files\Sunshine\config` inherits `Users:(RX)`, so `agent` can read
   sunshine.conf and the state file. To fix with the capture change.
5. Side finding: during Install-GpuVMAgent's cold cycle Windows didn't shut down in 90 s and vmwp was ended.

## Vibeshine 2.18.9 on the same copy (same day, ~25 min)

Installer from GitHub releases (SHA-256 matches GitHub's digest, Authenticode valid, SignPath Foundation), `/qn
INSTALL_VIRTUAL_GAMEPAD_DRIVER=0`, 28 s, over Sunshine in `C:\Program Files\Sunshine`: config, credentials and the
viewer's pairing carried over. It also installs two more virtual displays (SudoVDA and its own); disabled for the test
so only GpuVM's VDD is attached. `capture = wgc`.

| open (app-like viewer) | first frame | window at 8 s and 20 s | capture restarts | capturer |
| --- | --- | --- | --- | --- |
| 1-5 | 4.6-4.9 s | the guest desktop (lit 98 %, range 15-255) in 5/5 | 0 | `sunshine_wgc_capture.exe` as AGENT-BASE\agent, session 1 |

- Sunshine stays SYSTEM. The capturer gets the session user's plain token (`retrieve_users_token(false)`); its pipe
  allows SYSTEM, Administrators and that SID with data access only; handles are duplicated from the capturer into
  Sunshine, never the other way. Residual: `agent` can feed fake frames (same as drawing on its own screen) or stop
  the capture.
- Shown on `agent`'s desktop: Vibeshine's tray and an update toast (pre-release 2.18.12). For agent machines:
  `system_tray = disabled`, no update notices.
- WGC helper code in Vibeshine: ~6.5k lines core (capturer 2.7k, IPC session 1k, pipes 1.9k, display_wgc 0.9k).

## GpuVM's own fork (gpuvm-sunshine, same day)

Upstream Sunshine v2026.914.233613 + only Vibeshine's WGC helper and IPC (~6.5k lines copied, ~200 changed), built
with MSYS2 UCRT64, no tray. `fork-overlay.ps1` puts its two files over the MSI's install on a clean copy (agent056);
then GpuVM itself does it in Install-GpuVMAgent (agent057).

| run | first frame | window at 8 / 20 s | capture restarts |
| --- | --- | --- | --- |
| agent056, overlay, first build | none | helper: `CreateForMonitor` E_HANDLE | - |
| agent056, helper's process object no longer restricted | 4.0-4.1 s (opens 3-5), 13.1 s (open 2) | desktop | 0 |
| agent056, first open once Sunshine answers after a restart | 16.1 s | desktop at 20 s | 0 |
| agent057, through Install-GpuVMAgent + Connect-GpuVM | 4.7-5.8 s (opens 2-5), 18.5 s (open 1) | desktop 5/5 | 0 |

- E_HANDLE: the port first gave every SYSTEM child a process object only SYSTEM/Administrators may open; WGC in the
  helper then fails. Vibeshine leaves it off for this helper, and it protects nothing there (the helper is the user's).
- No tray icon and no update toast on `agent`'s desktop (tray built out).
- The first open after a Sunshine restart is slow (encoder probe, the helper starts 3 times): 16-18 s.
- Install-GpuVMAgent: 323 s instead of 241 s (69 MB over PowerShell Direct and one more restart).
- `agent` can't read `config\sunshine.conf` any more (UnauthorizedAccessException).

## Lessons for lab-craft

- Prove the layer first: a 60-line probe of the exact API (CreateForMonitor, AcquireNextFrame) answered in minutes
  what 2 days of end-to-end opens couldn't.
- A guest in Spanish: use SIDs, never group names, in icacls/rights.
- Children of a scheduled task die with its job: CREATE_BREAKAWAY_FROM_JOB.
