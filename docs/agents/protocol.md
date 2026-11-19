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
  `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{id}`
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

- Each VM has a 32-byte secret `K`, made by the host when the agent is installed. Host side: stored with DPAPI
  (LocalMachine, SYSTEM-readable only) next to the VM's state. Guest side: copied with `Copy-VMFile` (Guest Service
  Interface) to `C:\ProgramData\GpuVM\Agent\secret` with an ACL of SYSTEM + Administrators only. Never in KVP (any
  guest user can read KVP).
- `G→H {"t":"hello","v":1,"agent":"<version>","ng":"<32 hex>"}`
- `H→G {"t":"challenge","nh":"<32 hex>","mac":HMAC(K,"host|"+vmId+"|"+ng+"|"+nh)}` — the guest checks it (the host
  knows K).
- `G→H {"t":"proof","mac":HMAC(K,"guest|"+vmId+"|"+nh+"|"+ng)}` — the host checks it with the VmId from `accept()`.
- Session key `S = HMAC(K,"session|"+ng+"|"+nh)`. Every later JSON frame carries `"seq"` (strictly increasing per
  direction) and `"m":HMAC(S, seq|payload-without-m)` (hex, first 16 bytes). Wrong `m` or `seq` → close.
- HMAC-SHA256; vmId as lowercase GUID without braces.

## Messages

Requests go host → guest: `{"t":"req","id":<n>,"method":"…","params":{…}}`; replies
`{"t":"res","id":<n>,"ok":true,"result":{…}}` or `{"ok":false,"error":{"code":"…","message":"…"}}`. Events go guest →
host: `{"t":"evt","event":"…","data":{…}}`. Error codes: `blocked_elevated`, `secure_desktop`, `no_foreground`,
`not_signed_in`, `too_large`, `timeout`, `not_found`, `denied`, `bad_request`, `internal`.

| Method | Params | Result |
| --- | --- | --- |
| `agent.info` | – | `{version, os, user, session, screen:{w,h}, signedIn}` |
| `screen.capture` | `{maxW?:1280, maxH?:800, format?:"webp"\|"png", region?:[x,y,w,h]}` | `{w,h,scale,format}` + blob (lossless). Coordinates everywhere are the full desktop's pixels; `scale` = sent/full. `region` = zoom at native resolution. Refused with `secure_desktop` when the input desktop isn't `Default`. |
| `screen.state` | – | `{desktop:"default"\|"secure"\|"locked", foreground:{title, process, integrity, blocked}}` |
| `input.act` | `{actions:[…], stopOnError?:true}` | `{done:<n>}`. Actions: `click{x,y,button?,count?,mods?}`, `move{x,y}`, `drag{x,y,toX,toY}`, `scroll{x,y,dx,dy}`, `type{text}`, `key{keys:"ctrl+shift+end", repeat?}`, `wait{ms≤5000}`. Checked before each action: foreground elevated → `blocked_elevated`; no foreground > 500 ms → `no_foreground`; secure desktop → `secure_desktop`. Nothing is injected then. |
| `ui.tree` | `{scope?:"foreground", maxNodes?:300, visibleOnly?:true, interactiveOnly?:true}` | `{nodes:[{id,role,name,bbox:[x,y,w,h],enabled,patterns:[…]}]}` (UIA control view, CacheRequest; queries Chromium twice) |
| `ui.invoke` | `{id, action:"invoke"\|"toggle"\|"select"\|"expand"\|"setValue", value?}` | `{}` |
| `exec.run` | `{file, args?:[…], cwd?, timeoutMs?≤600000, stdin?}` | `{exitCode, stdout, stderr, truncated}` (each capped at 1 MiB). Runs as the signed-in standard user `agent`, never elevated. |
| `files.list` / `files.read` / `files.write` | `{path}` under `C:\Users\agent` only (no links, no `..`) | list / blob / `{}` |
| `outbox.offer` | `{path, note}` (path inside `Desktop\Outbox`) | `{offerId}` — the host asks the person; files leave only after approval |

Guest events: `secure_desktop{on}`, `signed_in{user}`, `foreground{…}` (rate-limited to 4/s), `error_box{title}`
(a system error dialog blocks input, lab 049).

## Host side (broker → MCP)

The broker exposes the connected agents to the app and to `gpuvm.exe --mcp` over the existing service pipe as new
module/service commands (named `Get-GpuVMAgent`, `Invoke-GpuVMAgent -Name -Method -Params`), with every request
logged (method, params minus blobs, result code, time) in the VM's folder.
