# GpuVM agent protocol (v1, draft)

The contract between the three agent pieces, built in parallel: the **guest agent** (inside each Windows VM), the
**host broker** (in GpuVM's elevated service, `app/host`) and the **MCP server** (`gpuvm.exe --mcp`). Evidence for
every choice is in labs 047-050. Change this file first (and tell the other pieces) before changing the contract.

## Principles

- The guest is untrusted. Nothing a guest sends can trigger a host action by itself; every size and time is bounded.
- The agent never gains power over the person: UAC, the lock screen, sign-in and any password stay human-only.
  Approvals are given only in GpuVM's own windows (dock, notification), never from the screen or the guest.
- Inside: English, fixed names. `C:\Users\agent\Desktop\Outbox` and `Desktop\Received` (localized display names via
  `desktop.ini`).

## Transport (lab 047)

- Hyper-V sockets, `SOCK_STREAM`. Service id **`94aca5ef-a5b6-45a9-8c15-c7724a63f3da`**, registered on the host under
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\<id>` (the GUID without braces, like Hyper-V's own entries)
  (`ElementName` = `GpuVM agent`) by the installer / service.
- The **host broker listens** on `HV_GUID_CHILDREN:{id}` inside the elevated service (if it can't bind, it alerts: a
  non-elevated process must not get the name first, lab 050). The **guest dials** `HV_GUID_PARENT:{id}`, redialing
  every 200 ms while not connected. The host identifies the VM by the **VmId from `accept()`**, never by anything the
  guest says.
- Frames: `u32 length (LE) | u8 kind | payload`. kind 1 = JSON (UTF-8, max 64 KiB), kind 2 = binary blob (max
  16 MiB) that belongs to the JSON frame sent right before it (`"blob": true`). Anything larger or malformed closes
  the connection.
- Heartbeat: either side sends `{"t":"ping"}` every 2 s; no frame for 6 s = dead connection.

## Handshake (lab 050)

- Each VM has a 32-byte secret `K` (the file holds the 32 raw bytes), made by the host when the agent is installed. Host side: stored with DPAPI
  (LocalMachine, SYSTEM-readable only) next to the VM's state. Guest side: copied with `Copy-VMFile` (Guest Service
  Interface) to `C:\ProgramData\GpuVM\Agent\secret` with an ACL of SYSTEM + Administrators only. Never in KVP (any
  guest user can read KVP).
- `G→H {"t":"hello","v":1,"agent":"<version>","ng":"<32 hex>"}`
- `H→G {"t":"challenge","nh":"<32 hex>","mac":HMAC(K,"host|"+vmId+"|"+ng+"|"+nh)}` — the guest checks it (the host
  knows K).
- `G→H {"t":"proof","mac":HMAC(K,"guest|"+vmId+"|"+nh+"|"+ng)}` — the host checks it with the VmId from `accept()`.
- Session key `S = HMAC(K,"session|"+ng+"|"+nh)`. Every later JSON frame (pings included; not hello/challenge/proof)
  is authenticated, byte-exactly:
  1. The sender serializes the object WITH `"seq"` and WITHOUT `"m"` → bytes `P` (ends with `}`). `seq` starts at 1
     per direction after the handshake and grows by exactly 1.
  2. `mac` = first 16 bytes of `HMAC-SHA256(S, ascii(seq) + "|" + P)`, lowercase hex (32 chars).
  3. Wire frame = `P` without its final `}` + `,"m":"<mac>"}`.
  4. The receiver requires the frame to end with `,"m":"<32 hex>"}` (40 bytes), strips them, appends `}` → `P`,
     recomputes the mac, then parses `P` and requires `seq == last + 1`. Any mismatch → close.
- A JSON frame followed by a blob carries `"blob":true,"blobLen":<n>,"blobSha256":"<64 hex>"` inside its MACed
  bytes; the receiver checks the blob's length and SHA-256 and closes on a mismatch.
- HMAC-SHA256; vmId as lowercase GUID without braces.

## Messages

Requests go host → guest: `{"t":"req","id":<n>,"method":"…","params":{…}}`; replies
`{"t":"res","id":<n>,"ok":true,"result":{…}}` or `{"ok":false,"error":{"code":"…","message":"…"}}`. Events go guest →
host: `{"t":"evt","event":"…","data":{…}}`. The host may cancel a running request with `{"t":"cancel","id":<n>}`;
the guest stops it and replies `ok:false` with code `cancelled`. Error codes: `blocked_elevated`, `secure_desktop`, `no_foreground`,
`not_signed_in`, `too_large`, `timeout`, `cancelled`, `not_found`, `denied`, `bad_request`, `internal`.

| Method | Params | Result |
| --- | --- | --- |
| `agent.info` | – | `{version, os, user, session, screen:{w,h}, signedIn, displays, noDisplay}`; `noDisplay` is null, or a reason when Windows gives the machine no display path at all (lab 051: fixed only by turning the VM off and on, not by a restart) |
| `screen.capture` | `{maxW?:1280, maxH?:800, format?:"webp"\|"png", region?:[x,y,w,h]}` | `{w,h,scale,format}` + blob (lossless). Coordinates everywhere are the full desktop's pixels; `scale` = sent/full. `region` = zoom at native resolution. Refused with `secure_desktop` when the input desktop isn't `Default`. |
| `screen.state` | – | `{desktop:"default"\|"secure"\|"locked", foreground:{title, process, integrity, blocked}, screen:{w,h}}` |
| `screen.refresh` | – (host: `repeatMs?`) | `{ok, ms}`; through the service with `Params.repeatMs` (≤ 15000) the service repaints every 250 ms for that long in the background and answers `{repeating: ms}` at once — what a viewer that just opened needs with ddx (lab 052: one repaint 2/10 opens with a picture, a 10 s burst 9/10). Repaints the whole desktop (no input, no window moved) so a duplication-based stream gets a fresh frame of a still desktop; the host calls it after a viewer connects. The helper also does it when the screen size changes. |
| `input.act` | `{actions:[…], stopOnError?:true}` | `{done:<n>}`. Actions are objects with a `type`: `click{x,y,button?,count?,mods?}`, `move{x,y}`, `drag{x,y,toX,toY}`, `scroll{x,y,dx,dy}` (notches, `dy>0` = down), `type{text}`, `key{keys:"ctrl+shift+end", repeat?}`, `wait{ms≤5000}`. Checked before each action: foreground elevated → `blocked_elevated`; no foreground > 500 ms → `no_foreground`; secure desktop → `secure_desktop`. Nothing is injected then. |
| `ui.tree` | `{scope?:"foreground", maxNodes?:300, visibleOnly?:true, interactiveOnly?:true}` | `{nodes:[{id,role,name,bbox:[x,y,w,h],enabled,patterns:[…]}]}` (UIA control view, CacheRequest; queries Chromium twice) |
| `ui.invoke` | `{id, action:"invoke"\|"toggle"\|"select"\|"expand"\|"setValue", value?}` | `{}` (ids are valid until the next `ui.tree`; a stale id → `not_found`) |
| `exec.run` | `{file, args?:[…], cwd?, timeoutMs?≤600000, stdin?}` | `{exitCode, stdout, stderr, truncated, timedOut}` (each capped at 1 MiB; a timeout is `ok` with `timedOut:true` and the partial output). When the output doesn't fit a 64 KiB JSON frame it goes in the blob (stdout then stderr) with `outputInBlob:true, stdoutBytes, stderrBytes`. Runs as the signed-in standard user `agent`, never elevated. |
| `files.list` / `files.read` / `files.write` | `{path}` under `C:\Users\agent` only (no links, no `..`); `files.read` also takes `offset?`, `length?` | list / `{size}` (whole file) + blob of the bytes from `offset` (≤ `length`, ≤ 16 MiB; without them the whole file, ≤ 16 MiB) / `{}` |

v1: `exec.run` and `files.*` answer `denied` unless the signed-in user is `agent` (a person-mode machine would need
the agent's password or S4U to run commands as `agent`; left for later).

Outbox deliveries are resolved by the host (`New-GpuVMAgentOffer`): it lists `Desktop\Outbox` and, once the person
approves, reads the file with `files.read` in 8 MiB pieces. The guest never pushes files to the host.

Frame `length` counts the payload only. Guest events: `screen{w,h}` (the agent's screen changed size: recapture; in
Agent mode the helper makes GpuVM's virtual display the only display before it announces `signed_in`),
`secure_desktop{on}`, `signed_in{user}` (`user:null` when the
session helper goes away), `foreground{…}` (rate-limited to 4/s), `error_box{title}`
(a system error dialog blocks input, lab 049).

## Host side (broker → app and MCP)

The broker lives in GpuVM's elevated service (`app/host/src/agent.rs`). The app and `gpuvm.exe --mcp` send these
commands on the service pipe like any module command (`{"id","cmd","args"}`, exact-case names and arguments); the
service answers them itself, without PowerShell (~1 ms). The module exports the person's commands (`Get-*`,
`Invoke-GpuVMAgent`, `Suspend-`/`Resume-GpuVMAgent`, `Stop-GpuVMAgentClient`, `Resolve-*`, settings, offers) for
PowerShell and tests, over an administrators-only pipe (`\\.\pipe\gpuvm-agent`). The session commands
(`Connect-`/`Disconnect-GpuVMAgentClient`, `Register-GpuVMAgentPipe`, `Lock-`/`Unlock-GpuVMAgent`,
`Request-GpuVMHuman`, `New-`/`Revoke-GpuVMAgentRequest`) are not exported: they are bound to the MCP server's process
and pipe connection, which a module call doesn't have.

**Trust boundary.** GpuVM's policy (sessions, approvals, budgets, pauses) binds an AI client that reaches GpuVM over
its MCP server (`gpuvm.exe --mcp`). An AI client that also has a shell on this PC (for example Claude Code with its
Bash tool) runs as the person's own Windows user: it can do whatever that user can, GpuVM's app included, and GpuVM
can't tell it from the person. Give such a client only the GpuVM MCP server when it should be held to this policy. Results: `{"type":"result","ok":true,"data":[…]}` (a list;
one object = a one-item list), or `{"ok":false,"error":"<English message>","code":"<code>"}`. Every request to a
guest is logged in the VM's folder (`agent.log`: method, params, code, ms, the step's note); what a model types or
runs is logged as its length only, at any depth (`text`, `value`, `command`, `args`, `stdin`, `data`, `blob`, `password`).

**Agent sessions.** The MCP server registers one session per client with `Connect-GpuVMAgentClient`; the session is
bound to that process and ends when its pipe connection closes. A process with a session acts for a model: the
service never lets it resume, approve, stop or change settings, limits the module commands it may run (below) and
counts its budget. A process that ever registered stays an agent's until it ends (the service holds its handle, so
its pid isn't reused): ending its session doesn't make it the person. Requests without `Connection` are the
person's (the app) or the module's. The MCP server sends
`Register-GpuVMAgentPipe` as the first line of **every** pipe connection it opens (and `Connect-GpuVMAgentClient`
marks its connection too): from then on that connection gets only what an agent session gets, even with no session
(after a service restart, or a connection opened for a long job), and is never taken for the person.

| Command | Args | `data` |
| --- | --- | --- |
| `Get-GpuVMAgent` | `Name?` | machines: `{name, vmId, state: ready\|no-display\|starting\|off\|no-agent (`no-display`: signed in but `agent.displays` empty for over 20 s; `lastError` says so: no screenshots or input until the agent is fixed, so don't wait for `ready`), version, agent: <agent.info>, desktop: default\|secure\|null, events: {<name>: {data, at}}, connectedSince, screen: {w,h} (follows the `screen` event), screenChangedAt?, paused: {by: person\|agent, reason: person\|control\|human, message, since, requestId?}\|null, takenBy: {connection, client: {name, version}, steps, startedAt}\|null, lastError, disposable, template}` |
| `Get-GpuVMAgentBroker` | – | `{listening, since?, error?, code?, connected, serviceId}`; the app shows `error` when not listening |
| `Invoke-GpuVMAgent` | `Name, Method, Params?, TimeoutSec? (30, ≤600), Connection?, Blob? (base64, files.write), Note? (what the step does, for the app)` | `{ok, result?, error?: {code, message}, ms, blob? (base64; the module gives blobPath), blobFormat?, blobBytes?, screenChangedAt?, screen?}` — a guest's failure is `ok:true` outside, `ok:false` inside; `screenChangedAt` (ms) is when the agent last said its screen changed size: newer than the client's last capture → recapture before acting |
| `Register-GpuVMAgentPipe` | `Connection?` | `{agent: true}`; this pipe connection (and its process, until it ends) acts for a model (deny by default); `Connection`, when given, must be a session of that process (`not_found`); the module's pipe gets `denied` |
| `Connect-GpuVMAgentClient` | `Client: {name, version, protocol?, pid?}` | `{connection, settings: {elicitation, maxSteps, maxMinutes, approvalTimeoutSec}}` |
| `Disconnect-GpuVMAgentClient` | `Connection` | `{}` |
| `Get-GpuVMAgentClient` | `Connection?` | sessions: `{id, name, version, connectedAt, machine, task, state: working\|paused\|control\|human\|waiting\|idle\|stopped, reason, steps, maxSteps, minutes, maxMinutes, resumedAt, actions: [{id, at, method, text, ok, code, ms, capture}] newest first (30)}` |
| `Get-GpuVMAgentCapture` | `Connection, Action` | `{action, format, data (base64)}` for a step with `capture:true` (last 10 kept) |
| `Lock-GpuVMAgent` | `Name, Connection, Task?` | `{name, connection}`; one session per machine (`taken`) |
| `Unlock-GpuVMAgent` | `Name, Connection` | `{}` |
| `Request-GpuVMHuman` | `Name, Connection, Message` | `{requestId}`; pauses the machine (`paused.reason = human`) until the person resumes |
| `Suspend-GpuVMAgent` | `Name` or `Connection` (`*` = all), `Reason? person\|control`, `Message?` | `[{name}]`; running requests of sessions end with `paused` |
| `Resume-GpuVMAgent` | `Name`, `Name` + `Connection`, or `Connection` (`*`) | `[{name}]` resumed; sets `resumedAt` (the agent looks at the screen again). `Name` + `Connection`: that machine only if that session holds it (else `not_found`). `Connection` alone never resumes a pause by the person (reason `person` or `control`): only the session's own `human` pause; the person's take-control is given back by `Name` |
| `Stop-GpuVMAgentClient` | `Connection` (`*` = all) or `All` | `{stopped: [ids]}`: kill switch, frees its machines, later calls get `killed` |
| `New-GpuVMAgentRequest` | `Name, Connection, Kind: admin\|network\|revert\|delete\|send\|other, Title?, Reason, TimeoutSec?, Path?, SizeBytes?, Files? (send only)` | `{requestId, expiresAt}`; the session shows `waiting`. `send`: `Path` = one plain local path of this PC or a list (1-20, `C:\…`, no `..`); the service measures them as the session's user without following links (a link anywhere, or more than 100 000 entries, is `bad_request`) and writes the title itself — `Send <paths> to '<machine>': N files, <size>` (the session's `Title` is ignored); `SizeBytes`/`Files`, when given, must equal what it measured (else `bad_request`); it expires in 10 minutes at most |
| `Get-GpuVMAgentRequest` | `Id?` | `{id, connection, clientName, machine, kind, title, reason, createdAt, expiresAt, state: pending\|allowed\|denied\|expired\|withdrawn, forTask, paths?, files?, bytes?}` (`paths/files/bytes` for `send`: show them to the person) |
| `Resolve-GpuVMAgentRequest` | `Id, Allow, ForTask?` | the request (person only); `ForTask` never applies to `send` |
| `Revoke-GpuVMAgentRequest` | `Id, Connection` | `{id, state: withdrawn, resumed?}`; only the session that asked withdraws its own pending request (an approval, or its `Request-GpuVMHuman`, which also resumes the machine). Refused: another session's (`denied`), a connection that isn't the caller's or any pause or take-control by the person, even one that replaced the request (`not_found`, the pause stays), one already answered (`bad_request`) |
| `New-GpuVMAgentOffer` | `Name, Path (a file directly in the agent's Outbox: "Desktop\Outbox\x", or absolute under the agent.info home), Note?, Connection?` | `{offerId}` (`Invoke-GpuVMAgent -Method outbox.offer` does the same) |
| `Get-GpuVMAgentOffer` | `Id?, Name?` | `{id, machine, connection, clientName, name, path, sizeBytes, note, createdAt, expiresAt, state: pending\|copying\|accepted\|refused\|expired\|failed, savedTo, error}` |
| `Resolve-GpuVMAgentOffer` | `Id, Accept` | the offer (person only), `copying` when accepted: created as the person in `Downloads\GpuVM\<machine>\` (`Zone.Identifier` ZoneId=3, never overwriting: `name (2).ext`) and filled in the background; `Get-GpuVMAgentOffer` then says `accepted` (`savedTo`) or `failed` (`error`, and the partial file is deleted). 2 GB cap; a guest slower than 30 s + 1 s per MiB (an hour at most) is stopped. Never offered: `.url .lnk .scf .library-ms .searchConnector-ms .website .appref-ms`, `desktop.ini`, reserved names (`CON`, `COM1`-`COM9`, `COM¹`…) |
| `Get-GpuVMAgentSettings` / `Set-GpuVMAgentSettings` | – / `MaxSteps?, MaxMinutes?, ApprovalTimeoutSec?` | `{maxSteps, maxMinutes, approvalTimeoutSec, clients: {<name>: {clientApprovals}}}` (set: person only) |
| `Set-GpuVMAgentClient` | `Name (client name), ClientApprovals` | settings (person only); MCP elicitation stays off unless turned on here |
| `Install-GpuVMAgent` | `Name, User? agent\|own` | `{name, vmId, version, fastPath, restarted, ms}` (bridge) |
| `Uninstall-GpuVMAgent` | `Name` | `{name}` (bridge, UAC consent) |
| `Remove-GpuVMAgentRegistration` | `VmId` | `{}`; the service (SYSTEM) deletes that VM's registration and secret; administrators' pipe only (the agents' pipe gets `denied`); called by `Remove-GpuVM` and `Uninstall-GpuVMAgent`, and the hourly sweep removes what's left of VMs that no longer exist |

Error codes (`code`, or `error.code` of a guest request) on top of the guest's: `paused`, `killed`, `budget`,
`not_taken`, `taken`, `off` (no agent connected), `busy` (32 requests in flight on a machine, or too many waiting),
`needs_approval`, `denied`, `not_found`, `bad_request`, `too_large`, `timeout`, `cancelled`.

**What a session may run through the service** (everything else is `denied` for it; the person's app is never limited
here): `Get-GpuVM`, `Get-GpuVMOverview`, `Get-GpuVMTemplate`, `Get-GpuVMProfile`, `Get-GpuVMRestorePoint`,
`New-GpuVMRestorePoint`, `New-GpuVM` (only `-Disposable` with `-Template`), `Install-GpuVMAgent`, `Invoke-GpuVMPower`,
`Remove-GpuVMDisposable` (the sweep; with `-Name` only a disposable copy this session made, deleted at once if it is off), `Connect-GpuVM`; with an allowed request passed as `Approval: <requestId>`
(same machine, same kind, used once unless allowed `ForTask`, 10 minutes): `Restore-GpuVMRestorePoint` (`revert`),
`Remove-GpuVM` (`delete`), `Send-GpuVMFile` (`send`: exactly the approved paths, any order or case, used once even if
allowed `ForTask`, and only while they still hold the files and bytes the person saw — anything added, swapped or
linked since is `needs_approval`, ask again); `-FromVM` is `denied` for a session. An approval is held while its
command runs and spent only when it succeeds (a declined UAC or a module error leaves it usable).
Commands naming a machine need it held by the session. `New-GpuVM -Disposable -Template
-Name X` (with `Connection`, removed before PowerShell sees it; optional when the process has one session) makes X
that session's the moment it succeeds: only it may `Install-GpuVMAgent` there and `Lock-GpuVMAgent` it, and the claim
becomes the lock once the agent is registered; the service adds `ForAgent`, so the module copies only a template made
for agents (`template.json` `use: "agent"`) and the copy is an agent machine. Destructive ones still need the person's
UAC consent as before.

Each command also has its arguments and their types checked (anything else is `denied`, another type is
`bad_request`): `Name` is a text; `New-GpuVM` takes `Name, Template, Disposable, Start, Override` with `Override` only
`{vm: {memoryGB, cpu: {count}}}`; `Install-GpuVMAgent` only `User: agent`; `Connect-GpuVM` `Name, Viewer, Resolution,
Fps, BitrateKbps, Codec`; `Send-GpuVMFile` `Name, Path, Folder, TransferId`. A machine paused by the person is
`paused` for these commands too, a stopped session is `killed`, and each one counts as a step of the budget
(`budget`). Agent machines are always isolated, and never run on an external or private switch. A session reads only
its own sessions, screenshots, requests and offers (`Get-GpuVMAgentClient/-Capture/-Request/-Offer`).

**Installing the agent** (`Install-GpuVMAgent`): new 32-byte K kept host-side with DPAPI (machine scope, GpuVM entropy)
in `ProgramData\GpuVM\agents\<vmid>\secret`, SYSTEM-only; over PowerShell Direct, `gpuvm-agent.exe` goes with
`Copy-Item -ToSession` into an Administrators/SYSTEM-only temp folder (skipped when the same build is installed: a
copy of a template), `guest\agent\install.ps1` runs as a script block with `-Source <folder> -Secret <K> -SignInAs
agent|previous`, the returned `agent` password (new every install) is kept with DPAPI in gpuvm.json, and Windows
restarts from inside the guest when the installer asks. Templates and their copies never carry an agent secret.
