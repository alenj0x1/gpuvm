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

## Part 2: real machines (pending integration)

Needs the broker (claude/agent-broker-*), the guest agent and a template with it, in an installed build. Plan:
`python drive.py --exe "C:\Program Files\GpuVM\gpuvm.exe" --template <t> --phases latency,coords,misuse`
(coords: random screenshot pixels at five sizes → `act move` → the VM's real cursor position read with `run`),
then Claude Code end to end: create a disposable, screenshot, Notepad click/type, run, write + offer a file.
