import { useEffect, useSyncExternalStore } from "react";
import { agents, inTauri } from "./api";
import type { AgentAction, AgentClient, AgentOffer, AgentRecording, AgentRequest, AgentState } from "./types";

/** What every agent screen shows, read once for all of them (one poll, however many components look). */
export interface AgentSnapshot {
  clients: AgentClient[]; requests: AgentRequest[]; offers: AgentOffer[];
  /** The broker's channel: null while unknown; `error` when another program holds its name (lab 050). */
  broker: { listening: boolean; error?: string | null } | null;
  /** Recordings of agents' work (agent.rs): machine, session, file. */
  recordings: AgentRecording[];
  /** How long a request waits for an answer, as the service has it (the one source of truth; null while unknown). */
  approvalTimeoutSec: number | null;
  /** The person's limit per session in minutes, 0 = none (the default). */
  maxMinutes: number;
  /** Each machine's agent (Get-GpuVMAgent), by machine name: ready, no-display (signed in but it sees no screen, so no
   *  screenshots or input), starting, off or no-agent, and the service's reason. */
  machineAgents: Record<string, { state: MachineAgentState; error: string | null }>;
  loaded: boolean; error: string | null;
}

export type MachineAgentState = "ready" | "no-display" | "starting" | "off" | "no-agent";

/** What the broker sends (app/host/src/agent.rs on the agent-broker branch): times in ms, the client is a connection. */
export interface BrokerState {
  clients: Record<string, unknown>[]; requests: Record<string, unknown>[]; offers: Record<string, unknown>[];
  settings?: { clients?: Record<string, { clientApprovals?: boolean }>; approvalTimeoutSec?: number; maxMinutes?: number } | null;
  broker?: { listening: boolean; error?: string | null } | null;
  recordings?: Record<string, unknown>[];
  machines?: Record<string, unknown>[];
}

const iso = (v: unknown) => (typeof v === "number" ? new Date(v).toISOString() : typeof v === "string" ? v : new Date().toISOString());
const str = (v: unknown) => (typeof v === "string" && v ? v : null);
const num = (v: unknown) => (typeof v === "number" ? v : 0);
const STATES: AgentState[] = ["working", "paused", "control", "waiting", "human", "idle"];

/** The broker's words for an action when it kept no note: its method, said plainly. */
const methodText = (m: string) => ({
  "screen.capture": "Took a screenshot", "input.act": "Used the mouse and keyboard", "ui.tree": "Read the window",
  "ui.invoke": "Pressed a control", "exec.run": "Ran a command", "files.read": "Read a file", "files.write": "Saved a file",
  "files.list": "Listed a folder", "outbox.offer": "Offered a file",
})[m] ?? m;

/** A copy from this PC into the machine (broker "send": paths, files, bytes). Without a path it can't be shown for
 *  what it is, so there is nothing to allow. */
export function sendOf(r: Record<string, unknown>): AgentRequest["send"] {
  const s = (r.send && typeof r.send === "object" ? r.send : r) as Record<string, unknown>;
  const paths = (Array.isArray(s.paths) ? s.paths : []).filter((p): p is string => typeof p === "string" && p.trim() !== "");
  if (!paths.length) return null;
  return { paths, bytes: num(s.bytes), files: Math.max(1, num(s.files)) };
}

/** A long path with its middle cut ("C:\Users\…\folder\file.exe"): its drive and its name stay; the whole path is
 *  the element's title. */
export function middlePath(path: string, max = 64) {
  if (path.length <= max) return path;
  const tail = Math.ceil((max - 1) * 0.6), head = max - 1 - tail;
  return `${path.slice(0, head)}…${path.slice(path.length - tail)}`;
}

/** One shape for every page, whatever sent it (the broker's poll in agent.rs, a direct read, the browser's mock). */
export function fromBroker(raw: BrokerState): Omit<AgentSnapshot, "loaded" | "error"> {
  const approvals = raw.settings?.clients ?? {};
  const clients: AgentClient[] = (raw.clients ?? []).map((c) => {
    // "stopped" (the person stopped it; it stays listed until its client goes) shows as connected without a machine.
    const state = STATES.includes(c.state as AgentState) ? (c.state as AgentState) : "idle";
    const id = String(c.id ?? c.connection ?? "");
    const name = str(c.name) ?? "Agent";
    const actions: AgentAction[] = ((c.actions as Record<string, unknown>[]) ?? []).map((a) => ({
      id: num(a.id), method: String(a.method ?? ""), text: str(a.text) ?? methodText(String(a.method ?? "")), at: iso(a.at), ok: a.ok !== false,
      thumb: null, capture: a.capture === true,
    }));
    return {
      id, name, version: str(c.version), connectedAt: iso(c.connectedAt), machine: str(c.machine), state,
      task: str(c.task), reason: str(c.reason), steps: num(c.steps), maxSteps: num(c.maxSteps), minutes: num(c.minutes), maxMinutes: num(c.maxMinutes),
      actions, clientApprovals: approvals[name]?.clientApprovals === true,
    };
  });
  const requests: AgentRequest[] = (raw.requests ?? []).filter((r) => (r.state ?? "pending") === "pending").map((r) => ({
    id: String(r.id), client: String(r.connection ?? r.client ?? ""), clientName: str(r.clientName) ?? "Agent", machine: String(r.machine ?? ""),
    kind: (["admin", "network", "revert", "delete", "deliver", "send", "take", "other"].includes(String(r.kind)) ? r.kind : "other") as AgentRequest["kind"],
    title: String(r.title ?? ""), reason: str(r.reason), createdAt: iso(r.createdAt), expiresAt: iso(r.expiresAt),
    send: r.kind === "send" ? sendOf(r as Record<string, unknown>) : null,
  }));
  // What only the person can do (a password, UAC, the lock screen) comes as the agent's state, not as a request.
  for (const c of clients.filter((x) => x.state === "human" && x.machine)) {
    requests.push({ id: `human:${c.id}`, client: c.id, clientName: c.name, machine: c.machine!, kind: "admin", title: c.reason ?? "Windows needs you",
      reason: null, createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 3600e3).toISOString(), human: true });
  }
  const offers: AgentOffer[] = (raw.offers ?? []).map((o) => ({
    id: String(o.id), machine: String(o.machine ?? ""), client: String(o.connection ?? o.client ?? ""), clientName: str(o.clientName) ?? "Agent",
    name: String(o.name ?? o.fileName ?? ""), sizeBytes: num(o.sizeBytes ?? o.size), note: str(o.note), createdAt: iso(o.createdAt ?? o.created),
    state: (["pending", "copying", "accepted", "refused", "expired", "failed"].includes(String(o.state)) ? o.state : "failed") as AgentOffer["state"],
    savedTo: str(o.savedTo ?? o.hostPath), error: str(o.error),
  }));
  const recordings: AgentRecording[] = (raw.recordings ?? []).map((r) => ({
    machine: String(r.machine ?? ""), client: String(r.client ?? ""), clientName: str(r.clientName) ?? "Agent", path: String(r.path ?? ""),
    name: String(r.name ?? ""), durationMs: num(r.durationMs), bytes: num(r.bytes), at: iso(r.at),
  })).reverse();
  const timeout = raw.settings?.approvalTimeoutSec;
  const STATES_M: MachineAgentState[] = ["ready", "no-display", "starting", "off", "no-agent"];
  const machineAgents: AgentSnapshot["machineAgents"] = {};
  for (const m of raw.machines ?? []) {
    const name = str(m.name);
    if (!name) continue;
    machineAgents[name] = { state: STATES_M.includes(m.state as MachineAgentState) ? (m.state as MachineAgentState) : "no-agent", error: str(m.lastError) };
  }
  return { clients, requests, offers, broker: raw.broker ?? null, recordings, approvalTimeoutSec: typeof timeout === "number" && timeout > 0 ? timeout : null, maxMinutes: typeof raw.settings?.maxMinutes === "number" ? raw.settings.maxMinutes : 0, machineAgents };
}

let snap: AgentSnapshot = { clients: [], requests: [], offers: [], broker: null, recordings: [], approvalTimeoutSec: null, maxMinutes: 0, machineAgents: {}, loaded: false, error: null };
let json = "";
const subs = new Set<() => void>();
let users = 0;
let timer: ReturnType<typeof setTimeout> | undefined;
let running = false;

function take(raw: BrokerState) {
  const next = { ...fromBroker(raw), loaded: true, error: null };
  const j = JSON.stringify(next);
  // Nothing re-renders when nothing changed.
  if (j !== json) { json = j; snap = next; subs.forEach((f) => f()); }
}

// In the app, agent.rs polls the service already and sends what it saw to every window: the pages take that, and
// ask themselves only on start, after a button, and slowly as a fallback.
if (inTauri) {
  import("@tauri-apps/api/event").then(({ listen }) => listen<BrokerState>("agents-state", (e) => take(e.payload))).catch(() => {});
}

async function read() {
  try {
    const [clients, requests, offers, settings, broker, recordings, machines] = await Promise.all([
      agents.clients(), agents.requests(), agents.offers(), agents.settings().catch(() => null), agents.broker().catch(() => null), agents.recordings().catch(() => []),
      agents.machines().catch(() => [])]);
    take({ clients, requests, offers, settings, broker, recordings, machines });
  } catch (e) {
    snap = { ...snap, loaded: true, error: String(e) };
    subs.forEach((f) => f());
  }
}

/** Chained polling: faster while an agent works or waits, slow when there is none, slower with the window hidden. */
async function loop() {
  if (running) return;
  running = true;
  if (!document.hidden) await read();
  running = false;
  if (!users) return;
  const busy = snap.clients.some((c) => c.state !== "idle") || snap.requests.length > 0;
  timer = setTimeout(loop, inTauri ? 15000 : document.hidden ? 10000 : busy ? 1500 : 5000);
}

/** Read again now (after an answer or a button), instead of waiting for the next poll. */
export function refreshAgents() { clearTimeout(timer); return loop(); }

export function useAgents(): AgentSnapshot {
  useEffect(() => {
    if (users++ === 0) loop();
    const wake = () => { if (!document.hidden) refreshAgents(); };
    document.addEventListener("visibilitychange", wake);
    return () => { document.removeEventListener("visibilitychange", wake); if (--users === 0) clearTimeout(timer); };
  }, []);
  return useSyncExternalStore((f) => { subs.add(f); return () => subs.delete(f); }, () => snap);
}

/** The client working on a machine (the one shown on its page and in its viewer), if any. */
export const clientOn = (s: AgentSnapshot, machine: string) => s.clients.find((c) => c.machine === machine) ?? null;

/** An action's screenshot (the broker keeps the last 10), loaded once and kept while the app runs. */
const thumbs = new Map<string, Promise<string | null>>();
export function actionThumb(client: string, action: number): Promise<string | null> {
  const key = `${client}:${action}`;
  if (!thumbs.has(key)) {
    thumbs.set(key, agents.capture(client, action).then((c) => (c?.data ? `data:image/${c.format === "png" ? "png" : "webp"};base64,${c.data}` : null)).catch(() => null));
    if (thumbs.size > 60) thumbs.delete(thumbs.keys().next().value!);
  }
  return thumbs.get(key)!;
}

/** A size in words: 18 KB, 4.8 MB, 1.2 GB. */
export function bytes(n: number, locale?: string) {
  const fmt = (v: number, d: number) => v.toLocaleString(locale, { maximumFractionDigits: d });
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${fmt(n / 1024, 0)} KB`;
  if (n < 1024 ** 3) return `${fmt(n / 1024 ** 2, 1)} MB`;
  return `${fmt(n / 1024 ** 3, 1)} GB`;
}
