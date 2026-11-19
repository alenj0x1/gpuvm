import type { AgentAction, AgentClient, AgentOffer, AgentRequest } from "./types";

// Agents in the browser (no broker there): ?agents=none | working (default) | paused | control | waiting | human | many.
// The working ones keep acting while the page is open, so the live state can be designed.
const params = new URLSearchParams(location.search);
const scenario = params.get("vms") === "0" || params.get("mock") === "empty" ? "none" : params.get("agents") ?? "working";

const ago = (s: number) => new Date(Date.now() - s * 1000).toISOString();
const later = (s: number) => new Date(Date.now() + s * 1000).toISOString();

// What a test of the GpuVM installer in a clean Windows looks like, step by step (the goal demo).
const SCRIPT: [string, string][] = [
  ["screen.capture", "Took a screenshot"],
  ["exec.run", "Downloaded GpuVM-setup.exe"],
  ["input.act", "Double-clicked GpuVM-setup.exe"],
  ["ui.tree", "Read the installer window"],
  ["input.act", "Clicked Next"],
  ["input.act", "Typed C:\\Program Files\\GpuVM"],
  ["input.act", "Clicked Install"],
  ["screen.capture", "Took a screenshot"],
  ["input.act", "Scrolled the license down"],
  ["ui.invoke", "Checked I accept the terms"],
  ["input.act", "Clicked Finish"],
  ["exec.run", "Ran gpuvm.exe --version"],
  ["files.write", "Saved report.md"],
];

let nextAction = 1;
const action = (k: number, secondsAgo: number, ok = true): AgentAction => {
  const [method, text] = SCRIPT[((k % SCRIPT.length) + SCRIPT.length) % SCRIPT.length];
  return { id: nextAction++, method, text, ok, at: ago(secondsAgo), thumb: null };
};
const history = (from: number, n: number) => Array.from({ length: n }, (_, i) => action(from - i, 2 + i * 7));

const claude = (over: Partial<AgentClient> = {}): AgentClient => ({
  id: "c1", name: "Claude Code", version: "2.4.1", connectedAt: ago(380), machine: "win-agent", state: "working",
  task: "Test the GpuVM installer in a clean Windows", reason: null, steps: 42, maxSteps: 200, minutes: 6, maxMinutes: 60,
  actions: history(41, 8), clientApprovals: false, ...over,
});

let clients: AgentClient[] = [];
let requests: AgentRequest[] = [];
let offers: AgentOffer[] = [];

const deliver = (id: string, name: string, sizeBytes: number, note: string | null, secondsAgo: number, state: AgentOffer["state"] = "pending", machine = "win-agent"): AgentOffer =>
  ({ id, machine, client: "c1", clientName: "Claude Code", name, sizeBytes, note, createdAt: ago(secondsAgo), state });

switch (scenario) {
  case "none":
    break;
  case "paused":
    clients = [claude({ state: "paused", reason: "Paused by you" })];
    break;
  case "control":
    clients = [claude({ state: "control", reason: "You took control" })];
    break;
  case "human":
    clients = [claude({ state: "human", reason: "Windows asks for a password" })];
    requests = [{ id: "r-human", client: "c1", clientName: "Claude Code", machine: "win-agent", kind: "admin", title: "Windows asks for a password", reason: null,
      createdAt: ago(4), expiresAt: later(300), human: true }];
    break;
  case "waiting":
    clients = [claude({ state: "waiting", reason: "Waiting for your approval" })];
    requests = [{ id: "r-net", client: "c1", clientName: "Claude Code", machine: "win-agent", kind: "network", title: "Connect to github.com",
      reason: "Download the latest release of GpuVM to test it", createdAt: ago(6), expiresAt: later(54) }];
    offers = [deliver("o1", "report.md", 18_432, "Results of the installer test, with 6 screenshots", 40)];
    break;
  case "many":
    clients = [
      claude(),
      claude({ id: "c2", name: "Claude Code", version: "2.4.1", machine: "lab-02", state: "waiting", reason: "Waiting for your approval", task: "Install Visual Studio Build Tools and build the viewer", steps: 131, maxSteps: 400, minutes: 22, maxMinutes: 90, actions: history(9, 8) }),
      claude({ id: "c3", name: "Cursor", version: "1.9.0", machine: "lab-03", state: "paused", reason: "Paused by you", task: "Check the settings page in Windows 10", steps: 12, maxSteps: 100, minutes: 2, maxMinutes: 30, actions: history(4, 5) }),
      claude({ id: "c4", name: "Claude Code", version: "2.3.9", machine: "lab-04", state: "human", reason: "Windows asks for a password", task: null, steps: 77, maxSteps: 200, minutes: 41, maxMinutes: 60, actions: history(12, 8) }),
      claude({ id: "c5", name: "Visual Studio Code", version: "1.106.2", machine: null, state: "idle", reason: null, task: null, steps: 0, maxSteps: 200, minutes: 0, maxMinutes: 60, actions: [] }),
      claude({ id: "c6", name: "A client with a very long name that goes on and on", version: "0.0.1-preview.20261118", machine: "lab-05", state: "control", reason: "You took control", task: "A task described in many words, longer than any line can hold, to see that it never leaves its box", steps: 199, maxSteps: 200, minutes: 59, maxMinutes: 60, actions: history(2, 8), clientApprovals: true }),
    ];
    requests = [
      { id: "r1", client: "c2", clientName: "Claude Code", machine: "lab-02", kind: "admin", title: "Install Visual Studio Build Tools as administrator", reason: "The build needs MSVC", createdAt: ago(8), expiresAt: later(52) },
      { id: "r3", client: "c2", clientName: "Claude Code", machine: "lab-02", kind: "revert", title: "Go back to the restore point Before installing", reason: "The build tools left the machine broken", createdAt: ago(1), expiresAt: later(119) },
    ];
    offers = [
      deliver("o1", "report.md", 18_432, "Results of the installer test, with 6 screenshots", 40),
      deliver("o2", "installer-test-screenshots.zip", 4_831_221, "Screenshots of every step", 3),
      deliver("o3", "a-file-with-a-very-long-name-that-should-never-leave-its-row-in-the-review-list.log", 1_203_399_000, null, 900, "pending", "lab-02"),
      deliver("o4", "viewer-build.log", 381_220, "The build output", 1800, "accepted", "lab-02"),
      deliver("o5", "settings.png", 241_002, "The settings page after the change", 3600, "refused", "lab-03"),
      deliver("o6", "notes.txt", 812, "Two things to check by hand", 7200, "expired"),
      ...Array.from({ length: 8 }, (_, i) => deliver(`ox${i}`, `step-${String(i + 1).padStart(2, "0")}.png`, 180_000 + i * 9_000, `Step ${i + 1}`, 4000 + i * 60, i % 3 ? "accepted" : "pending", "lab-04")),
    ];
    break;
  default: // working
    clients = [claude()];
    offers = [deliver("o1", "report.md", 18_432, "Results of the installer test, with 6 screenshots", 40)];
}
offers = offers.map((o) => o.state === "accepted" ? { ...o, savedTo: `Downloads\\GpuVM\\${o.machine}\\${o.name}` } : o);

// The working ones take a step every few seconds while the page is open.
let k = 42;
setInterval(() => {
  clients = clients.map((c) => {
    if (c.state !== "working") return c;
    k++;
    return { ...c, steps: Math.min(c.maxSteps, c.steps + 1), minutes: c.minutes + (k % 12 === 0 ? 1 : 0), actions: [action(k, 0), ...c.actions].slice(0, 20) };
  });
}, 3200);

const want = (args: Record<string, unknown>) => (c: AgentClient) => args.Id === "*" || c.id === args.Id;

/** The agent commands the mock answers (null: not one of them). */
export function agentCommand(cmd: string, args: Record<string, unknown>): unknown[] | null {
  switch (cmd) {
    case "Get-GpuVMAgent":
      return clients;
    case "Get-GpuVMAgentRequest":
      return requests;
    case "Get-GpuVMAgentOffer":
      return args.Name ? offers.filter((o) => o.machine === args.Name) : offers;
    case "Suspend-GpuVMAgent":
      clients = clients.map((c) => want(args)(c) && c.state !== "idle" ? { ...c, state: args.Reason === "control" ? "control" : "paused", reason: args.Reason === "control" ? "You took control" : "Paused by you" } : c);
      return [];
    case "Resume-GpuVMAgent":
      clients = clients.map((c) => want(args)(c) && (c.state === "paused" || c.state === "control") ? { ...c, state: "working", reason: null } : c);
      return [];
    case "Stop-GpuVMAgent":
      // Stopping cuts the client's work: it stays connected, without a machine, until it asks again.
      clients = clients.map((c) => want(args)(c) ? { ...c, state: "idle", machine: null, reason: null, task: null } : c);
      requests = requests.filter((r) => !(args.Id === "*" || r.client === args.Id));
      return [];
    case "Set-GpuVMAgentClient":
      clients = clients.map((c) => c.id === args.Id ? { ...c, clientApprovals: Boolean(args.ClientApprovals) } : c);
      return [];
    case "Resolve-GpuVMAgentRequest": {
      const r = requests.find((x) => x.id === args.Id);
      requests = requests.filter((x) => x.id !== args.Id);
      if (r) clients = clients.map((c) => c.id === r.client && c.state === "waiting" && !requests.some((x) => x.client === c.id) ? { ...c, state: "working", reason: null } : c);
      if (r?.kind === "deliver" && r.file && args.Allow) offers = [deliver(`o${Date.now()}`, r.file.name, r.file.sizeBytes, r.reason, 0, "accepted", r.machine), ...offers];
      return [];
    }
    case "Resolve-GpuVMAgentOffer":
      offers = offers.map((o) => o.id === args.Id ? { ...o, state: args.Accept ? "accepted" : "refused", savedTo: args.Accept ? `Downloads\\GpuVM\\${o.machine}\\${o.name}` : null } : o);
      return [];
    default:
      return null;
  }
}

/** The machines the agents work on, so their pages exist in the mock. */
export const agentMachines = scenario === "none" ? [] : scenario === "many" ? ["win-agent", "lab-02", "lab-03", "lab-04", "lab-05"] : ["win-agent"];
