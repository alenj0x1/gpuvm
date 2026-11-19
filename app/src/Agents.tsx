import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconCheck, IconCopy, IconDeviceDesktop, IconFile, IconFileDownload, IconFileText, IconFileZip, IconHandFinger, IconHandStop, IconHistory, IconLoader2,
  IconLock, IconPhoto, IconPlayerPause, IconPlayerPlay, IconPlayerStop, IconPlugConnectedX, IconRobot, IconShieldLock, IconTerminal2, IconTrash, IconVideo, IconWorld, IconX, type Icon,
} from "@tabler/icons-react";
import { agents, inTauri } from "./api";
import { actionThumb, bytes, clientOn, refreshAgents, useAgents } from "./agentStore";
import { MachineIcon } from "./machineIcon";
import { CheckMark, humanError, portalRoot } from "./ui";
import { locale, t, tn, translateModule } from "./i18n";
import type { AgentAction, AgentClient, AgentOffer, AgentRecording, AgentRequest, AgentRequestKind, AgentState } from "./types";

// Everything the app shows of agents: the Agents page, an agent's live state (machine page and the viewer's widget),
// its requests and the files it offers from the machine's Outbox. The broker decides; this only shows and answers.

/* ---------- small pieces ---------- */

/** "4 s", "3 min", "2 h": how long ago, short. */
export function since(iso: string, now = Date.now()) {
  const s = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000));
  if (s < 60) return t("{n} s", { n: s });
  if (s < 3600) return t("{n} min", { n: Math.floor(s / 60) });
  if (s < 86400) return t("{n} h", { n: Math.floor(s / 3600) });
  return new Date(iso).toLocaleDateString(locale());
}

/** Re-renders every second while mounted (times that count). */
function useTick(on = true) {
  const [, set] = useState(0);
  useEffect(() => { if (!on) return; const id = setInterval(() => set((n) => n + 1), 1000); return () => clearInterval(id); }, [on]);
}

export const stateLabel = (s: AgentState) => ({
  working: t("Working"), paused: t("Paused|agent"), control: t("You have control"), waiting: t("Waiting for you"), human: t("Needs you"), idle: t("Connected"),
})[s];
/** The dot's tone: working is the accent, anything waiting on the person is the warning tone. */
const stateTone = (s: AgentState) => (s === "working" ? "on" : s === "waiting" || s === "human" ? "warn" : "idle");

/** A client's own icon: a terminal for command-line clients (Claude Code), a robot for the rest. */
function ClientIcon({ client, size = 18 }: { client: Pick<AgentClient, "name">; size?: number }) {
  const I = /code|cli|terminal/i.test(client.name) ? IconTerminal2 : IconRobot;
  return <span className="ag-client-icon"><I size={size} /></span>;
}

export function StatePill({ state }: { state: AgentState }) {
  return <span className={`ag-state ${stateTone(state)}`}><span className="ag-dot" />{stateLabel(state)}</span>;
}

/** Steps and minutes used of the task's budget. */
function Budget({ c }: { c: AgentClient }) {
  const steps = c.maxSteps ? Math.min(1, c.steps / c.maxSteps) : 0;
  const minutes = c.maxMinutes ? Math.min(1, c.minutes / c.maxMinutes) : 0;
  const near = Math.max(steps, minutes) >= 0.9;
  return (
    <div className={`ag-budget${near ? " near" : ""}`} title={t("{steps} of {max} steps, {min} of {maxMin} min", { steps: c.steps, max: c.maxSteps, min: c.minutes, maxMin: c.maxMinutes })}>
      <div className="ag-budget-bar"><span style={{ width: `${Math.max(steps, minutes) * 100}%` }} /></div>
      <span className="ag-budget-text">{t("Step {n} of {max}", { n: c.steps, max: c.maxSteps })}<span className="ag-sep">·</span>{t("{n} of {max} min", { n: c.minutes, max: c.maxMinutes })}</span>
    </div>
  );
}

/** One action of the agent: its screenshot (when the broker kept one), what it did and when. */
function ActionRow({ a, now, client }: { a: AgentAction; now: number; client: string }) {
  const [thumb, setThumb] = useState<string | null>(a.thumb ?? null);
  useEffect(() => {
    if (!a.capture || a.thumb) return;
    let alive = true;
    actionThumb(client, a.id).then((src) => { if (alive) setThumb(src); });
    return () => { alive = false; };
  }, [client, a.id, a.capture, a.thumb]);
  return (
    <li className={`ag-action${a.ok ? "" : " failed"}`}>
      <span className="ag-thumb">{thumb ? <img src={thumb} alt="" draggable={false} /> : <IconDeviceDesktop size={14} />}</span>
      <span className="ag-action-text">{translateModule(a.text)}</span>
      <span className="ag-action-time">{since(a.at, now)}</span>
    </li>
  );
}

/* ---------- live state ---------- */

type LiveSize = "full" | "compact" | "tiny";

/** An agent working on a machine: what it does, how far into its budget, its last actions, and the person's controls.
 *  `size`: full (machine page), compact (widget with room for actions), tiny (widget one row high). */
export function AgentLive({ client, size = "full", actions = 3, onTakeControl }: { client: AgentClient; size?: LiveSize; actions?: number; onTakeControl?: () => void }) {
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState("");
  useTick(client.state === "working");
  const now = Date.now();
  const act = async (key: string, f: () => Promise<unknown>) => {
    setBusy(key); setError("");
    try { await f(); await refreshAgents(); } catch (e) { setError(humanError(e)); }
    setBusy(null);
  };
  const paused = client.state === "paused" || client.state === "control";
  const spin = (key: string, I: Icon) => (busy === key ? <IconLoader2 size={15} className="spin" /> : <I size={15} />);
  const last = client.actions[0];
  const controls = (
    <div className="ag-controls">
      {client.state === "control"
        ? <button type="button" className="btn compact" disabled={!!busy} onClick={() => act("resume", () => agents.resume(client.id))}>{spin("resume", IconRobot)}{t("Return to agent")}</button>
        : paused
          ? <button type="button" className="btn compact" disabled={!!busy} onClick={() => act("resume", () => agents.resume(client.id))}>{spin("resume", IconPlayerPlay)}{t("Resume")}</button>
          : <button type="button" className="btn compact" disabled={!!busy || client.state === "idle"} onClick={() => act("pause", () => agents.pause(client.id))}>{spin("pause", IconPlayerPause)}{t("Pause|agent")}</button>}
      {client.state !== "control" && (
        <button type="button" className="btn ghost compact" disabled={!!busy || client.state === "idle"}
          onClick={() => act("control", async () => { await agents.pause(client.id, "control"); onTakeControl?.(); })} title={t("Take control")}>{spin("control", IconHandFinger)}<span className="ag-btn-label">{t("Take control")}</span></button>
      )}
      <button type="button" className="btn ghost compact" disabled={!!busy} title={t("Ends its task on this machine")}
        onClick={() => act("stop", () => agents.stop(client.id))} aria-label={t("Stop")}>{spin("stop", IconPlayerStop)}<span className="ag-btn-label">{t("Stop")}</span></button>
    </div>
  );
  if (size === "tiny") {
    // One line: who, what it did last, its state and the one control that fits (pause, resume or give it back).
    const [label, I, run] = client.state === "control" ? [t("Return to agent"), IconRobot, () => agents.resume(client.id)] as const
      : paused ? [t("Resume"), IconPlayerPlay, () => agents.resume(client.id)] as const
      : [t("Pause|agent"), IconPlayerPause, () => agents.pause(client.id)] as const;
    return (
      <div className="ag-live tiny">
        <div className="ag-live-head">
          <ClientIcon client={client} size={16} />
          <div className="ag-live-name">
            <strong className="ellipsis">{client.name}</strong>
            <span className="ellipsis">{last ? `${translateModule(last.text)} · ${since(last.at, now)}` : stateLabel(client.state)}</span>
          </div>
          <StatePill state={client.state} />
          <button type="button" className="icon-btn ag-tiny-btn" aria-label={label} title={label} disabled={!!busy || client.state === "idle"}
            onClick={() => act("tiny", run)}>{busy ? <IconLoader2 size={16} className="spin" /> : <I size={16} />}</button>
        </div>
      </div>
    );
  }
  return (
    <div className={`ag-live ${size}`}>
      <div className="ag-live-head">
        <ClientIcon client={client} />
        <div className="ag-live-name">
          <strong className="ellipsis">{client.name}</strong>
          <span className="ellipsis">{client.reason && client.state !== "paused" && client.state !== "control" ? translateModule(client.reason) : client.task ?? (client.version ? t("Version {v}", { v: client.version }) : "")}</span>
        </div>
        <StatePill state={client.state} />
      </div>
      {client.maxSteps > 0 && <Budget c={client} />}
      {actions > 0 && (
        client.actions.length
          ? <ul className="ag-actions">{client.actions.slice(0, actions).map((a) => <ActionRow key={a.id} a={a} now={now} client={client.id} />)}</ul>
          : <div className="ag-none">{t("No actions yet")}</div>
      )}
      {error && <span className="error-text">{error}</span>}
      {controls}
    </div>
  );
}

/* ---------- requests ---------- */

const REQUEST_ICON: Record<AgentRequestKind, Icon> = { deliver: IconFileDownload, admin: IconShieldLock, network: IconWorld, revert: IconHistory, delete: IconTrash, other: IconRobot };

/** Seconds left before a request is refused by itself. */
const left = (r: AgentRequest, now: number) => Math.max(0, Math.round((new Date(r.expiresAt).getTime() - now) / 1000));

/** A request waiting for the person, answered here (a GpuVM window). Allow is once; the right click also offers
 *  Allow for this task. Human-only requests have no buttons: the person acts in the machine. */
export function RequestRow({ r, showMachine = true }: { r: AgentRequest; showMachine?: boolean }) {
  const [busy, setBusy] = useState<"allow" | "deny" | "task" | null>(null);
  const [error, setError] = useState("");
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  useTick();
  const now = Date.now();
  const I = r.human ? IconLock : REQUEST_ICON[r.kind];
  const answer = async (kind: "allow" | "deny" | "task") => {
    setMenu(null); setBusy(kind); setError("");
    try { await agents.answer(r.id, kind !== "deny", kind === "task"); await refreshAgents(); } catch (e) { setError(humanError(e)); setBusy(null); }
  };
  const sec = left(r, now);
  return (
    <div className={`ag-request${r.kind === "revert" || r.kind === "delete" ? " risky" : ""}${r.human ? " human" : ""}`}
      onContextMenu={(e) => { if (r.human) return; e.preventDefault(); setMenu({ x: e.clientX, y: e.clientY }); }}>
      <span className="ag-request-icon"><I size={17} /></span>
      <div className="ag-request-text">
        <strong className="ellipsis">{translateModule(r.title)}{r.file && <span className="ag-request-size">{bytes(r.file.sizeBytes, locale())}</span>}</strong>
        <span className="ellipsis">{[showMachine ? `${r.clientName} · ${r.machine}` : r.clientName, r.reason].filter(Boolean).join(" · ")}</span>
        {error && <span className="error-text">{error}</span>}
      </div>
      {r.human
        ? <span className="ag-request-wait">{t("{name} waits", { name: r.clientName })}</span>
        : <>
            <span className="ag-request-left" title={t("Refused by itself when the time runs out")}>{sec < 60 ? t("{n} s", { n: sec }) : t("{n} min", { n: Math.ceil(sec / 60) })}</span>
            <div className="ag-request-actions">
              <button type="button" className="btn ghost compact" disabled={!!busy} onClick={() => answer("deny")}>{busy === "deny" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}</button>
              <button type="button" className="btn compact" disabled={!!busy} onClick={() => answer("allow")}>{busy === "allow" || busy === "task" ? <IconLoader2 size={15} className="spin" /> : <IconCheck size={15} />}{r.kind === "deliver" ? t("Accept") : t("Allow")}</button>
            </div>
          </>}
      {menu && <Menu at={menu} onClose={() => setMenu(null)} items={[
        { icon: IconCheck, label: r.kind === "deliver" ? t("Accept") : t("Allow"), run: () => answer("allow") },
        { icon: IconHistory, label: t("Allow for this task"), run: () => answer("task") },
        { icon: IconX, label: t("Refuse"), run: () => answer("deny") },
      ]} />}
    </div>
  );
}

/** A small right-click menu, closed by any press outside it. */
function Menu({ at, items, onClose }: { at: { x: number; y: number }; items: { icon: Icon; label: string; run: () => void }[]; onClose: () => void }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const out = (e: PointerEvent) => { if (!ref.current?.contains(e.target as Node)) onClose(); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("pointerdown", out, true); window.addEventListener("keydown", key);
    return () => { window.removeEventListener("pointerdown", out, true); window.removeEventListener("keydown", key); };
  }, [onClose]);
  const x = Math.min(at.x, window.innerWidth - 228), y = Math.min(at.y, window.innerHeight - items.length * 36 - 16);
  return createPortal(
    <div ref={ref} className="menu floating" style={{ left: x, top: y }} role="menu">
      {items.map((it) => <button key={it.label} type="button" role="menuitem" onClick={it.run}><it.icon size={15} />{it.label}</button>)}
    </div>, portalRoot());
}

/* ---------- Outbox ---------- */

const fileIcon = (name: string): Icon => {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  if (["png", "jpg", "jpeg", "webp", "gif", "bmp"].includes(ext)) return IconPhoto;
  if (["zip", "7z", "rar", "tar", "gz"].includes(ext)) return IconFileZip;
  if (["md", "txt", "log", "csv", "json"].includes(ext)) return IconFileText;
  return IconFile;
};

/** A file an agent left in the machine's Outbox: only what the broker read about it (name, size, the agent's note),
 *  never its contents. Accepted, it goes to Downloads\GpuVM\<machine>. */
function OfferRow({ o, showMachine }: { o: AgentOffer; showMachine: boolean }) {
  const [busy, setBusy] = useState<"accept" | "refuse" | null>(null);
  const [error, setError] = useState("");
  const I = fileIcon(o.name);
  const resolve = async (accept: boolean) => {
    setBusy(accept ? "accept" : "refuse"); setError("");
    try { await agents.resolveOffer(o.id, accept); await refreshAgents(); } catch (e) { setError(humanError(e)); }
    setBusy(null);
  };
  const status = o.state === "copying" ? t("Copying to Downloads…") : o.state === "accepted" ? t("Saved in {path}", { path: o.savedTo ?? `Downloads\\GpuVM\\${o.machine}` })
    : o.state === "refused" ? t("Refused") : o.state === "expired" ? t("Expired|offer") : o.state === "failed" ? t("Couldn't save it: {error}", { error: o.error ? translateModule(o.error) : "?" }) : null;
  return (
    <div className={`ag-offer ${o.state}`}>
      <span className="ag-offer-icon"><I size={17} /></span>
      <div className="ag-offer-text">
        <strong className="ellipsis" title={o.name}>{o.name}</strong>
        <span className="ellipsis">{[bytes(o.sizeBytes, locale()), showMachine ? `${o.clientName} · ${o.machine}` : o.clientName, since(o.createdAt)].join(" · ")}</span>
        {o.note && <span className="ag-offer-note" title={o.note}>{o.note}</span>}
        {status && <span className={`ag-offer-status ${o.state}`}>{o.state === "accepted" && <IconCheck size={13} />}{status}</span>}
        {error && <span className="error-text">{error}</span>}
      </div>
      {o.state === "pending" && (
        <div className="ag-request-actions">
          <button type="button" className="btn ghost compact" disabled={!!busy} onClick={() => resolve(false)}>{busy === "refuse" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}</button>
          <button type="button" className="btn compact" disabled={!!busy} onClick={() => resolve(true)}>{busy === "accept" ? <IconLoader2 size={15} className="spin" /> : <IconFileDownload size={15} />}{t("Accept")}</button>
        </div>
      )}
    </div>
  );
}

/** The Outbox review: the files waiting first, then what was decided (newest first). */
export function OutboxList({ offers, showMachine = true, limit }: { offers: AgentOffer[]; showMachine?: boolean; limit?: number }) {
  const sorted = [...offers].sort((a, b) => (a.state === "pending" ? 0 : 1) - (b.state === "pending" ? 0 : 1) || b.createdAt.localeCompare(a.createdAt));
  const shown = limit ? sorted.slice(0, limit) : sorted;
  if (!offers.length) {
    return (
      <div className="empty-small">
        <span className="empty-small-icon"><IconFileDownload size={18} /></span>
        <strong>{t("No deliveries")}</strong>
      </div>
    );
  }
  return <div className="ag-offers">{shown.map((o) => <OfferRow key={o.id} o={o} showMachine={showMachine} />)}</div>;
}

/* ---------- recordings ---------- */

const duration = (ms: number) => { const s = Math.round(ms / 1000); return s < 60 ? t("{n} s", { n: s }) : t("{n} min", { n: Math.round(s / 60) }); };

/** Recordings of an agent's work (one per time it took the machine), each opened in the person's own player. */
export function RecordingList({ list, showMachine }: { list: AgentRecording[]; showMachine?: boolean }) {
  const [error, setError] = useState("");
  if (!list.length) return null;
  return (
    <div className="ag-recordings">
      {list.map((r) => (
        <div className="ag-offer" key={r.path}>
          <span className="ag-offer-icon"><IconVideo size={17} /></span>
          <div className="ag-offer-text">
            <strong className="ellipsis" title={r.name}>{r.name}</strong>
            <span className="ellipsis">{[duration(r.durationMs), bytes(r.bytes, locale()), showMachine ? r.machine : r.clientName, since(r.at)].join(" · ")}</span>
          </div>
          <button type="button" className="btn ghost compact" onClick={() => agents.openRecording(r.path).catch((e) => setError(humanError(e)))}><IconPlayerPlay size={15} />{t("Play|video")}</button>
        </div>
      ))}
      {error && <span className="error-text">{error}</span>}
    </div>
  );
}

/* ---------- connecting a client ---------- */

/** The command that adds GpuVM to Claude Code, with this PC's own path to gpuvm.exe. */
function useMcpCommand() {
  const [path, setPath] = useState("gpuvm.exe");
  useEffect(() => {
    if (!inTauri) return;
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<string>("mcp_exe_path")).then(setPath).catch(() => {});
  }, []);
  return `claude mcp add gpuvm -- ${/\s/.test(path) ? `"${path}"` : path} --mcp`;
}

function CopyCommand() {
  const cmd = useMcpCommand();
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    try { await navigator.clipboard.writeText(cmd); setCopied(true); setTimeout(() => setCopied(false), 1800); } catch { /* no clipboard */ }
  };
  return (
    <div className="ag-command">
      <code className="ellipsis" title={cmd}>{cmd}</code>
      <button type="button" className="btn compact" onClick={copy}>{copied ? <IconCheck size={15} /> : <IconCopy size={15} />}{copied ? t("Copied") : t("Copy")}</button>
    </div>
  );
}

/* ---------- the Agents page ---------- */

/** One connected client: who it is, the machine it uses, its state and budget, and the person's controls. */
function ClientCard({ c, onOpenVm, recordings }: { c: AgentClient; onOpenVm: (name: string) => void; recordings: AgentRecording[] }) {
  const [approvals, setApprovals] = useState(c.clientApprovals);
  const [error, setError] = useState("");
  useEffect(() => setApprovals(c.clientApprovals), [c.clientApprovals]);
  const toggle = async () => {
    const on = !approvals;
    setApprovals(on); setError("");
    try { await agents.setClientApprovals(c.name, on); await refreshAgents(); } catch (e) { setApprovals(!on); setError(humanError(e)); }
  };
  return (
    <div className="card ag-client">
      <div className="ag-client-top">
        <AgentLive client={c} actions={0} />
      </div>
      <div className="ag-client-meta">
        {c.machine
          ? <button type="button" className="ag-machine" onClick={() => onOpenVm(c.machine!)} title={t("View machine")}><MachineIcon name={c.machine} size={20} radius={6} /><span className="ellipsis">{c.machine}</span></button>
          : <span className="ag-machine none"><IconDeviceDesktop size={16} />{t("No machine yet")}</span>}
        <span className="ag-meta-text">{[c.version && t("Version {v}", { v: c.version }), t("connected {time} ago", { time: since(c.connectedAt) })].filter(Boolean).join(" · ")}</span>
      </div>
      <button type="button" role="checkbox" aria-checked={approvals} className={`choice ag-approvals${approvals ? " on" : ""}`} onClick={toggle}>
        <span className="check">{approvals ? <CheckMark /> : null}</span>
        <span className="grow">
          <span className="title">{t("Approve from {name}", { name: c.name })}</span>
          <span className="desc">{t("Low-risk requests only. The rest are always answered in GpuVM.")}</span>
        </span>
      </button>
      <RecordingList list={recordings} showMachine />
      {error && <span className="error-text">{error}</span>}
    </div>
  );
}

/** The Agents page: what is waiting for the person first, then the connected clients, the deliveries, and how to
 *  connect a client. */
export function AgentsView({ onOpenVm }: { onOpenVm: (name: string) => void }) {
  const snap = useAgents();
  const [stopping, setStopping] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const active = snap.clients.filter((c) => c.state !== "idle");
  const stopAll = async () => {
    setStopping(true);
    try { await agents.stop("*"); await refreshAgents(); } catch { /* shown by the next poll */ }
    setStopping(false); setConfirm(false);
  };
  const head = (icon: React.ReactNode, title: string, desc: string, side?: React.ReactNode) => (
    <div className="lib-section-head ag-head">
      <span className="opt-icon">{icon}</span>
      <div className="opt-text"><span className="opt-title">{title}</span><span className="opt-desc">{desc}</span></div>
      {side}
    </div>
  );
  if (!snap.loaded) {
    return <div className="main ag-page"><div className="card skeleton profile-skeleton" /><div className="card skeleton profile-skeleton" /></div>;
  }
  return (
    <div className="main ag-page">
      {snap.broker && !snap.broker.listening && (
        // Another program holds the channel's name (lab 050): no agent can reach its machine until it's freed.
        <div className="notice error-notice">
          <IconPlugConnectedX size={20} />
          <div className="grow">{t("Agents can't reach their machines: {error}", { error: snap.broker.error ? translateModule(snap.broker.error) : t("the channel isn't open") })}</div>
        </div>
      )}
      {snap.requests.length > 0 && (
        <section className="ag-section">
          {head(<IconShieldLock size={17} />, t("Requests"), t("An agent waits for your answer. With no answer, it's refused."))}
          <div className="card ag-requests">{snap.requests.map((r) => <RequestRow key={r.id} r={r} />)}</div>
        </section>
      )}
      <section className="ag-section">
        {head(<IconRobot size={17} />, t("Connected agents"), t("Clients using your machines through GpuVM."),
          active.length > 0 && (confirm
            ? <div className="ag-head-side"><button type="button" className="btn ghost compact" onClick={() => setConfirm(false)}>{t("Cancel")}</button>
                <button type="button" className="btn compact danger-fill" disabled={stopping} onClick={stopAll}>{stopping ? <IconLoader2 size={15} className="spin" /> : <IconHandStop size={15} />}{tn(active.length, "Stop {n} agent", "Stop {n} agents")}</button></div>
            : <button type="button" className="btn compact" onClick={() => setConfirm(true)}><IconHandStop size={15} />{t("Stop all")}</button>))}
        {snap.clients.length
          ? <div className="ag-clients">{snap.clients.map((c) => <ClientCard key={c.id} c={c} onOpenVm={onOpenVm} recordings={snap.recordings.filter((r) => r.client === c.id)} />)}</div>
          : (
            <div className="card ag-empty">
              <span className="empty-small-icon"><IconRobot size={18} /></span>
              <strong>{t("No agent connected")}</strong>
              <span>{t("Add GpuVM to Claude Code once from a terminal. Agents then ask for a machine and work on it while you watch.")}</span>
              <CopyCommand />
            </div>
          )}
      </section>
      <section className="ag-section">
        {head(<IconFileDownload size={17} />, t("Deliveries"), t("Files agents leave in a machine's Outbox. Nothing reaches your PC until you accept it."))}
        <div className="card"><OutboxList offers={snap.offers} /></div>
      </section>
      {snap.clients.length > 0 && (
        <section className="ag-section">
          {head(<IconTerminal2 size={17} />, t("Connect a client"), t("Run it once in a terminal to add GpuVM to Claude Code."))}
          <div className="card"><CopyCommand /></div>
        </section>
      )}
    </div>
  );
}

/* ---------- the viewer's widget ---------- */

/** The agent on the machine shown in the viewer, sized by its cells: one row is who and what it did last; two add
 *  its budget and controls; each row more shows more of its actions. */
export function AgentWidget({ machine, size }: { machine: string; size: { w: number; h: number } }) {
  const snap = useAgents();
  const client = clientOn(snap, machine);
  const requests = snap.requests.filter((r) => r.machine === machine);
  // Nothing until the first answer: "no agent" for a moment would be wrong.
  if (!snap.loaded) return <div className="ag-widget" aria-busy="true" />;
  if (!client) {
    return (
      <div className="empty-small ag-widget-empty">
        <span className="empty-small-icon"><IconRobot size={18} /></span>
        <strong>{t("No agent on this machine")}</strong>
      </div>
    );
  }
  const tiny = size.h <= 1;
  const note = !tiny && size.h >= 3 && requests.length > 0;
  return (
    <div className="ag-widget">
      <AgentLive client={client} size={tiny ? "tiny" : "compact"} actions={Math.max(0, size.h * 2 - 3 - (note ? 1 : 0))} />
      {note && <span className="ag-widget-note"><IconShieldLock size={14} />{tn(requests.length, "{n} request waits for you", "{n} requests wait for you")}</span>}
    </div>
  );
}

/* ---------- on a machine's page ---------- */

/** A machine's Agent section: the agent working on it (or none), its requests and its deliveries. */
export function MachineAgent({ machine }: { machine: string }) {
  const snap = useAgents();
  const client = clientOn(snap, machine);
  const requests = snap.requests.filter((r) => r.machine === machine);
  const offers = snap.offers.filter((o) => o.machine === machine);
  const recordings = snap.recordings.filter((r) => r.machine === machine);
  return (
    <>
      <div className="card ag-machine-live">
        {client ? <AgentLive client={client} actions={5} /> : (
          <div className="empty-small">
            <span className="empty-small-icon"><IconRobot size={18} /></span>
            <strong>{t("No agent on this machine")}</strong>
          </div>
        )}
      </div>
      {requests.length > 0 && <div className="card ag-requests">{requests.map((r) => <RequestRow key={r.id} r={r} showMachine={false} />)}</div>}
      <div className="card"><div className="ag-card-title"><IconFileDownload size={16} />{t("Deliveries")}</div><OutboxList offers={offers} showMachine={false} /></div>
      {recordings.length > 0 && <div className="card"><div className="ag-card-title"><IconVideo size={16} />{t("Recordings")}</div><RecordingList list={recordings} /></div>}
    </>
  );
}
