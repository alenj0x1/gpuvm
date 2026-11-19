# GpuVM's MCP server

`gpuvm.exe --mcp` lets an AI agent client (Claude Code first; any MCP client works the same way) use GpuVM machines
while the person watches in GpuVM's viewer and can take over at any moment. Code: `app/src-tauri/src/mcp/`. Lab:
`labs/053-mcp/`. The guest/host contract it builds on: [protocol.md](protocol.md).

## Connecting Claude Code (README section draft)

> ### Use GpuVM machines from Claude Code
>
> GpuVM can lend Claude Code a Windows machine of its own: Claude sees the screen, clicks and types, runs commands and
> moves files, while you watch in GpuVM and can take over with your mouse at any moment.
>
> 1. Make a template with the GpuVM agent (Agents in the app), or install the agent on a machine.
> 2. Add GpuVM to Claude Code once:
>
>    ```bash
>    claude mcp add gpuvm -- "C:\Program Files\GpuVM\gpuvm.exe" --mcp
>    ```
>
> 3. Ask for it in plain words, for example: *"Take a disposable GpuVM machine from the win11-agent template, install
>    the GpuVM installer from my Downloads folder there, try it and give me a report with screenshots."*
>
> Every connection shows up in GpuVM's Agents page with the client's name. From there you can pause it, stop it (kill
> switch) or change its budget. Moving the mouse or pressing a key over the machine's picture pauses the agent;
> "Return to agent" gives it back. UAC prompts, the lock screen, passwords and payments are always yours: the agent
> asks you with a note in GpuVM. Files reach your PC only when you approve them in GpuVM (Outbox).

The command must point at the installed `gpuvm.exe`: the GpuVM service only accepts its own executable on its pipe.
`--mcp --fake` serves an in-memory machine (no service, no VM) for trying a client.

## Protocol

- stdio, one JSON-RPC message per line; logs on stderr (failures always, every call with `GPUVM_MCP_LOG=1`).
- Dual era: **2026-07-28** (stateless: `_meta` protocol version, client info and capabilities on every request,
  `server/discover`, `resultType`, `serverInfo` in `_meta`, `ttlMs`/`cacheScope` on `tools/list`, approvals as
  `input_required` results) and **2025-11-25 / 2025-06-18 / 2025-03-26 / 2024-11-05** (`initialize`; approvals as
  `elicitation/create` requests). An unknown modern version gets `-32022` with the supported list. Claude Code
  2.1.316 negotiates 2026-07-28.
- Tools only (no resources or prompts). The list is fixed and in a fixed order.

## Tools

| Plane | Tool | Annotations |
| --- | --- | --- |
| create | `list_templates`, `create_disposable` | read-only / additive |
| get | `list_machines`, `take_machine`, `release_machine` | read-only / idempotent |
| do: screen | `screenshot` (`maxWidth`/`maxHeight`, `zoom`, `format`) | read-only |
| do: input | `click`, `type`, `key`, `scroll`, `drag`, `act` (batch, ≤50) — all take `screenshot` (id) and `screenshotAfter` | not destructive |
| do: UI | `ui_tree`, `ui_invoke` | read-only / not destructive |
| do: commands, files | `run` (PowerShell, cmd or a program, as the standard user `agent`), `read_file`, `write_file` (under `C:\Users\agent`), `send_file` (host → `Desktop\Received`), `offer_file` + `offer_status` (Outbox → the person approves) | `run` and `write_file` destructive; `run` open-world |
| do: lifetime | `restore_point_create`, `restore_point_revert` (normal machines only; the person allows it in GpuVM; current state kept first), `destroy` (disposables only) | revert and destroy destructive |
| see / take control | `open_viewer`, `request_human` (human-only steps), `request_approval` (admin, network, other: answered in GpuVM) | – |

`create_disposable` and `take_machine` take an optional `task` (shown to the person); every guest request carries a
note (the tool and its arguments, file contents summarized) for the session's action list in the app.

Screenshots: WebP (PNG on request) as MCP image content, sized inside a `maxWidth`×`maxHeight` box (default
1280×800) and always within Anthropic's limits (long edge ≤ 2576 px, ≤ 3.75 MP). Each screenshot gets an id and
keeps its own mapping; actions use the latest full screenshot of that machine unless they name one. A screenshot pixel
maps to the desktop pixel at the centre of its footprint (exact: every desktop pixel → screenshot → desktop stays in
the same screenshot pixel, tested on every pixel at 5 desktop sizes × 5 boxes and in zoomed regions). `ui_tree` boxes
and centres come in the same pixels. A zoom is for looking; it does not become the coordinate space.

Errors are tool results (`isError`) with one plain sentence the model can act on, e.g. `blocked_elevated` → "An
administrator window is in front; ask the person with request_human."; `paused` → "The person took control of t1.
Wait until they hand it back ("Return to agent" in GpuVM), then take a fresh screenshot before acting."

## Behaviour

- **Identity.** The client's name and version (from `initialize` or `_meta` clientInfo) register the connection with
  the broker (`Connect-GpuVMAgentClient`); the app shows it. The registration ends with the pipe.
- **Approvals.** Off by default for every connection. When the person turns them on for a connection, only the
  low-risk confirmations go through the client (`run`, `write_file`, `send_file`); the state of an approval is a
  random, single-use, 10-minute nonce bound to the tool and its exact arguments. High-risk and human-only actions
  never go through MCP: high-risk ones are requests the person answers in GpuVM (`New-GpuVMAgentRequest`, kinds
  admin/network/revert/delete/other, within the person's approval timeout); a revert passes the allowed request to
  `Restore-GpuVMRestorePoint` as `Approval`, which the service checks (same machine and kind, once, 10 minutes).
- **Pause / take control.** The broker refuses calls on a paused machine; the server turns that into the sentence
  above. `request_human` pauses on purpose and can wait (cancellable) until the person hands the machine back.
- **Budgets.** Steps and minutes per machine come from the connection's settings; the server counts them and the
  broker enforces them too. The kill switch makes every later call fail without reaching the broker.
- **Audit.** Every guest request goes through `Invoke-GpuVMAgent`, which the broker logs per VM.
- **Ownership.** Only machines taken by this connection can be destroyed or get restore points; only disposable ones
  can be destroyed; restore points refuse disposables (turning them off deletes them).

## Security impact

- **No new privilege.** The server is the installed, unelevated `gpuvm.exe`; it can only send the service the commands
  any GpuVM window could. The broker, not the MCP process, enforces taking, pause, budgets, kill and offers; the MCP
  side repeats the checks because it acts for a model.
- **Untrusted model input.** Every argument is validated (types, ranges, path prefixes, no `..`, name patterns),
  coordinates are bounds-checked against the screenshot they refer to, text sizes are capped (type 5,000 chars,
  write 10 MB, results 20,000 chars), and guest output is treated as data (cut, never interpreted).
- **Prompt injection from the guest.** Screen text and command output reach the model. Mitigations: the agent runs
  as a standard user in a VM, files leave only through the person's approval, UAC/lock screen/passwords are refused
  (`blocked_elevated`, `secure_desktop`), and the person can pause or kill at any time.
- **Host files into the VM.** `send_file` reads a host path the person's account can read (the service checks it
  as that user). Anything a client could already read can be copied into a VM; nothing leaves a VM without approval.
- **Viewer.** `open_viewer` starts `gpuvm.exe --view <name>` with a validated machine name only.
- **Names.** `list_machines` shows every GpuVM machine's name and state (not their contents) so the model can ask for
  one; machines without the agent can't be used.
- **Open risks.** One pipe connection serializes the calls of a client (a 60 s `run` delays a parallel screenshot);
  a service restart drops the registration, so machines must be taken again (the error says so); creation from a
  template relies on `Install-GpuVMAgent` succeeding in the clone.
