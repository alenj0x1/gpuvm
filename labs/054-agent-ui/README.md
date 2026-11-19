# Lab 054: the app's agent screens

Agents in the app (`app/src/Agents.tsx`, `AgentDock.tsx`, `app/src-tauri/src/agent.rs`): the Agents page, a machine's
Agent section, the Agent widget of the viewer's panel, the agent dock and the take-control notch over the picture,
Settings › Agents, the usage type Agent and For AI agents in Create machine.

## Mock states

The dev server shows every screen with sample agents (`app/src/mockAgents.ts`): `?agents=none | working (default) |
paused | control | waiting | human | many`. Working agents take a step every 3 s. The windows over the picture open
alone with `?agent-dock=network|deliver|revert|human` and `?agent-banner`.

## How to run

With the dev server up (`npm --prefix app run dev`, or the `gpuvm-ui-agent` preview on 1440):

```
node labs/054-agent-ui/shots.mjs 1440
node labs/040-viewer-widgets/run.mjs 1440 '{"spec":{"agent":[2,3,1,4]},"vm":"win-agent","query":"agents=many","skipDrags":true}'
```

`shots.mjs` saves 70 screenshots in `out/shots` (git-ignored): each screen empty and crowded, light and dark, 760 and
1400 px wide, in Spanish; the dock and notch at two picture sizes; the widget at 2×1, 2×2, 3×3 and 2×4. Lab 040's
check takes `spec`, `vm`, `query` and `skipDrags` now, so it checks the agent widget in each mock state.

## Results (2026-11-18, mock data)

- Widget sizes (lab 040 check): first run 76 of 336 cases failed: at 2 columns the third button (Stop) stuck out, and
  at 2×3 with requests waiting the note clipped 4 px. Fix: the secondary buttons go to icon only when the widget is
  narrower than 340 px (container query), and the note takes the room of one action. Second run 336/336 (7 states ×
  4 widths × 2 themes × 6 sizes).
- By eye: at 760 px the requests' titles were cut to a few words; they now wrap by the width of their card (actions on
  a second line). The per-client approvals switch repeated a long sentence in every card; it is one short line now.
- Deliveries showed twice (as a request and as an Outbox file): deliveries now come only as Outbox offers.

## Pending (needs the broker installed)

- Take-control latency in the real viewer: input over the picture → `agent take-control <vm> paused in N ms` (agent.rs
  logs it to stderr) and → `Get-GpuVMAgent` shows `control`. Target: under 150 ms to the broker's answer.
- The Windows notification with the installed app's id (`dev.alejandro.gpuvm`): shown, and its button opens Agents.
