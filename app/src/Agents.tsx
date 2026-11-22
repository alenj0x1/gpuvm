import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconCheck, IconCopy, IconDeviceDesktop, IconDeviceDesktopOff, IconFile, IconFileDownload, IconFileText, IconFileUpload, IconFileZip, IconHandFinger, IconHandStop, IconHistory, IconLoader2,
  IconLock, IconPhoto, IconPlayerPause, IconPlayerPlay, IconPlayerStop, IconPlugConnected, IconPlugConnectedX, IconRobot, IconShieldLock, IconTerminal2, IconTrash, IconVideo, IconWorld, IconX, type Icon,
} from "@tabler/icons-react";
import { agents, inTauri } from "./api";
import { actionThumb, bytes, clientOn, middlePath, refreshAgents, useAgents } from "./agentStore";
import { MachineIcon } from "./machineIcon";
import { CheckMark, humanError, portalRoot } from "./ui";
import { locale, t, tn, translateModule } from "./i18n";
import type { AgentAction, AgentClient, AgentHistoryEntry, AgentOffer, AgentRecording, AgentRequest, AgentRequestKind, AgentState } from "./types";

export function since(iso: string, now = Date.now()) {
  const s = Math.max(0, Math.round((now - new Date(iso).getTime()) / 1000));
  if (s < 60) return t("{n} s", { n: s });
  if (s < 3600) return t("{n} min", { n: Math.floor(s / 60) });
  if (s < 86400) return t("{n} h", { n: Math.floor(s / 3600) });
  return new Date(iso).toLocaleDateString(locale());
}

function useTick(on = true) {
  const [, set] = useState(0);
  useEffect(() => { if (!on) return; const id = setInterval(() => set((n) => n + 1), 1000); return () => clearInterval(id); }, [on]);
}

export const stateLabel = (s: AgentState) => ({
  working: t("Working"), paused: t("Paused|agent"), control: t("You have control"), waiting: t("Waiting for you"), human: t("Needs you"), idle: t("Connected"),
})[s];
const stateTone = (s: AgentState) => (s === "working" ? "on" : s === "waiting" || s === "human" ? "warn" : "idle");

function ClientIcon({ client, size = 18 }: { client: Pick<AgentClient, "name">; size?: number }) {
  const I = /code|cli|terminal/i.test(client.name) ? IconTerminal2 : IconRobot;
  return <span className="ag-client-icon"><I size={size} /></span>;
}

export function StatePill({ state, noDisplay }: { state: AgentState; noDisplay?: boolean }) {
  if (noDisplay) return <span className="ag-state warn"><span className="ag-dot" />{t("No display")}</span>;
  return <span className={`ag-state ${stateTone(state)}`}><span className="ag-dot" />{stateLabel(state)}</span>;
}

export function useNoDisplay(machine: string | null | undefined) {
  const snap = useAgents();
  const m = machine ? snap.machineAgents[machine] : undefined;
  return m?.state === "no-display" ? m : null;
}

export function NoDisplayNotice({ machine }: { machine: string | null | undefined }) {
  const nd = useNoDisplay(machine);
  if (!nd) return null;
  return (
    <div className="ag-nodisplay" role="status">
      <span className="ag-nodisplay-icon"><IconDeviceDesktopOff size={16} /></span>
      <div className="ag-nodisplay-text">
        <strong>{t("No display")}</strong>
        <span>{nd.error ? translateModule(nd.error) : t("The agent can't see this machine's screen.")}</span>
      </div>
    </div>
  );
}

function Budget({ c }: { c: AgentClient }) {
  const used = <>{tn(c.steps, "{n} action", "{n} actions")}<span className="ag-sep">·</span>{t("{n} min", { n: c.minutes })}</>;
  if (!c.maxSteps && !c.maxMinutes) {
    return <div className="ag-budget"><span className="ag-budget-text">{used}</span></div>;
  }
  const steps = c.maxSteps ? Math.min(1, c.steps / c.maxSteps) : 0;
  const minutes = c.maxMinutes ? Math.min(1, c.minutes / c.maxMinutes) : 0;
  const near = Math.max(steps, minutes) >= 0.9;
  const limit = c.maxMinutes ? t("Limit {n} min", { n: c.maxMinutes }) : t("Limit {n} actions", { n: c.maxSteps });
  return (
    <div className={`ag-budget${near ? " near" : ""}`}>
      <div className="ag-budget-bar"><span style={{ width: `${Math.max(steps, minutes) * 100}%` }} /></div>
      <span className="ag-budget-text">{used}<span className="ag-sep">·</span>{limit}</span>
    </div>
  );
}

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

type LiveSize = "full" | "compact" | "tiny";

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
  const noDisplay = !!useNoDisplay(client.machine);
  const controls = noDisplay ? (
    <div className="ag-controls">
      <button type="button" className="btn ghost compact" disabled={!!busy} title={t("Ends its task on this machine")}
        onClick={() => act("stop", () => agents.stop(client.id))} aria-label={t("Stop")}>{spin("stop", IconPlayerStop)}<span className="ag-btn-label">{t("Stop")}</span></button>
    </div>
  ) : (
    <div className="ag-controls">
      {client.state === "control"
        ? <button type="button" className="btn compact" disabled={!!busy} onClick={() => act("resume", () => agents.resume(client.id, client.machine ?? ""))}>{spin("resume", IconRobot)}{t("Return to agent")}</button>
        : paused
          ? <button type="button" className="btn compact" disabled={!!busy} onClick={() => act("resume", () => agents.resume(client.id, client.machine ?? ""))}>{spin("resume", IconPlayerPlay)}{t("Resume")}</button>
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
    const [label, I, run] = client.state === "control" ? [t("Return to agent"), IconRobot, () => agents.resume(client.id, client.machine ?? "")] as const
      : paused ? [t("Resume"), IconPlayerPlay, () => agents.resume(client.id, client.machine ?? "")] as const
      : [t("Pause|agent"), IconPlayerPause, () => agents.pause(client.id)] as const;
    return (
      <div className="ag-live tiny">
        <div className="ag-live-head">
          <ClientIcon client={client} size={16} />
          <div className="ag-live-name">
            <strong className="ellipsis">{client.name}</strong>
            <span className="ellipsis">{last ? `${translateModule(last.text)} · ${since(last.at, now)}` : stateLabel(client.state)}</span>
          </div>
          <StatePill state={client.state} noDisplay={noDisplay} />
          <button type="button" className="icon-btn ag-tiny-btn" aria-label={label} title={label} disabled={!!busy || client.state === "idle" || noDisplay}
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
        <StatePill state={client.state} noDisplay={noDisplay} />
      </div>
      {size === "full" && <NoDisplayNotice machine={client.machine} />}
      <Budget c={client} />
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

const REQUEST_ICON: Record<AgentRequestKind, Icon> = { deliver: IconFileDownload, admin: IconShieldLock, network: IconWorld, revert: IconHistory, delete: IconTrash, send: IconFileUpload, take: IconDeviceDesktop, other: IconRobot };

const left = (r: AgentRequest, now: number) => Math.max(0, Math.round((new Date(r.expiresAt).getTime() - now) / 1000));

const ARM_MS = 800;

// Allow and Accept answer only a deliberate click: not one already on its way when GpuVM came to the front (an agent
// can raise the window) or when the window got the focus.
function useArmed() {
  const [armed, setArmed] = useState(false);
  useEffect(() => {
    let timer = 0;
    const arm = () => { setArmed(false); window.clearTimeout(timer); timer = window.setTimeout(() => setArmed(true), ARM_MS); };
    arm();
    window.addEventListener("focus", arm);
    let off: (() => void) | undefined;
    let gone = false;
    import("@tauri-apps/api/event").then(({ listen }) => listen("app-raised", arm)).then((f) => { if (gone) f(); else off = f; }).catch(() => {});
    return () => { gone = true; window.clearTimeout(timer); window.removeEventListener("focus", arm); off?.(); };
  }, []);
  return armed;
}

export function RequestRow({ r, showMachine = true, onView }: { r: AgentRequest; showMachine?: boolean; onView?: (machine: string) => void }) {
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
  const send = r.kind === "send" ? r.send ?? null : null;
  const armed = useArmed();
  const canAllow = (r.kind !== "send" || !!send) && armed;
  return (
    <div className={`ag-request${r.kind === "revert" || r.kind === "delete" ? " risky" : ""}${r.human ? " human" : ""}`}
      onContextMenu={(e) => { if (r.human) return; e.preventDefault(); setMenu({ x: e.clientX, y: e.clientY }); }}>
      <span className="ag-request-icon"><I size={17} /></span>
      <div className="ag-request-text">
        {r.kind === "send"
          ? <strong className="ellipsis">{t("{name} wants to copy to {machine}", { name: r.clientName, machine: r.machine })}</strong>
          : <strong className="ellipsis">{translateModule(r.title)}{r.file && <span className="ag-request-size">{bytes(r.file.sizeBytes, locale())}</span>}</strong>}
        {send?.paths.map((p) => <span key={p} className="ag-request-path" title={p}>{middlePath(p)}</span>)}
        <span className="ellipsis">{send
          ? [send.files > 1 ? t("{n} files", { n: send.files }) : null, bytes(send.bytes, locale()), r.reason].filter(Boolean).join(" · ")
          : [showMachine ? `${r.clientName} · ${r.machine}` : r.clientName, r.reason].filter(Boolean).join(" · ")}</span>
        {error && <span className="error-text">{error}</span>}
      </div>
      {r.human
        ? <div className="ag-request-actions">
            {onView && <button type="button" className="btn ghost compact" onClick={() => onView(r.machine)}><IconDeviceDesktop size={15} />{t("View")}</button>}
            <button type="button" className="btn compact" disabled={!!busy}
              onClick={async () => { setBusy("allow"); setError(""); try { await agents.resume(r.client, r.machine); await refreshAgents(); } catch (e) { setError(humanError(e)); setBusy(null); } }}>
              {busy ? <IconLoader2 size={15} className="spin" /> : <IconRobot size={15} />}{t("Return to agent")}
            </button>
          </div>
        : <>
            <span className="ag-request-left" title={t("Refused by itself when the time runs out")}>{sec < 60 ? t("{n} s", { n: sec }) : t("{n} min", { n: Math.ceil(sec / 60) })}</span>
            <div className="ag-request-actions">
              <button type="button" className="btn ghost compact" disabled={!!busy} onClick={() => answer("deny")}>{busy === "deny" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}</button>
              <button type="button" className="btn compact" disabled={!!busy || !canAllow} onClick={() => answer("allow")}>{busy === "allow" || busy === "task" ? <IconLoader2 size={15} className="spin" /> : <IconCheck size={15} />}{r.kind === "deliver" ? t("Accept") : t("Allow")}</button>
            </div>
          </>}
      {menu && <Menu at={menu} onClose={() => setMenu(null)} items={[
        ...(canAllow ? [{ icon: IconCheck, label: r.kind === "deliver" ? t("Accept") : t("Allow"), run: () => answer("allow") }] : []),
        // A copy from the PC names one exact path: never allowed ahead for the rest of the task.
        ...(r.kind !== "send" && armed ? [{ icon: IconHistory, label: t("Allow for this task"), run: () => answer("task") }] : []),
        { icon: IconX, label: t("Refuse"), run: () => answer("deny") },
      ]} />}
    </div>
  );
}

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

const fileIcon = (name: string): Icon => {
  const ext = name.split(".").pop()?.toLowerCase() ?? "";
  if (["png", "jpg", "jpeg", "webp", "gif", "bmp"].includes(ext)) return IconPhoto;
  if (["zip", "7z", "rar", "tar", "gz"].includes(ext)) return IconFileZip;
  if (["md", "txt", "log", "csv", "json"].includes(ext)) return IconFileText;
  return IconFile;
};

function OfferRow({ o, showMachine }: { o: AgentOffer; showMachine: boolean }) {
  const armed = useArmed();
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
        {status && <span className={`ag-offer-status ${o.state}`}>{o.state === "accepted" && <IconCheck size={13} />}{o.state === "copying" && <IconLoader2 size={13} className="spin" />}{status}</span>}
        {error && <span className="error-text">{error}</span>}
      </div>
      {o.state === "pending" && (
        <div className="ag-request-actions">
          <button type="button" className="btn ghost compact" disabled={!!busy} onClick={() => resolve(false)}>{busy === "refuse" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}</button>
          <button type="button" className="btn compact" disabled={!!busy || !armed} onClick={() => resolve(true)}>{busy === "accept" ? <IconLoader2 size={15} className="spin" /> : <IconFileDownload size={15} />}{t("Accept")}</button>
        </div>
      )}
    </div>
  );
}

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

const duration = (ms: number) => { const s = Math.round(ms / 1000); return s < 60 ? t("{n} s", { n: s }) : t("{n} min", { n: Math.round(s / 60) }); };

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
          <div className="ag-request-actions"><button type="button" className="btn ghost compact" onClick={() => agents.openRecording(r.path).catch((e) => setError(humanError(e)))}><IconPlayerPlay size={15} />{t("Play|video")}</button></div>
        </div>
      ))}
      {error && <span className="error-text">{error}</span>}
    </div>
  );
}

const ENDED: Record<AgentHistoryEntry["ended"], () => string> = { done: () => t("Finished"), stopped: () => t("You stopped it"), limit: () => t("Reached the limit") };

function useHistory(): AgentHistoryEntry[] | null {
  const [list, setList] = useState<AgentHistoryEntry[] | null>(null);
  const snap = useAgents();
  const ids = snap.clients.map((c) => c.id).join(",");
  useEffect(() => {
    let alive = true;
    agents.history().then((raw) => {
      if (!alive) return;
      setList(raw.filter((r) => typeof r.id === "string").map((r) => ({
        id: String(r.id), client: String(r.client ?? "Agent"), version: String(r.version ?? ""), task: typeof r.task === "string" && r.task ? r.task : null,
        machines: Array.isArray(r.machines) ? r.machines.map(String) : [], start: Number(r.start) || 0, end: Number(r.end) || 0,
        steps: Number(r.steps) || 0, runs: Number(r.runs) || 0, approvals: Number(r.approvals) || 0, offers: Number(r.offers) || 0, controls: Number(r.controls) || 0,
        ended: (["done", "stopped", "limit"].includes(String(r.ended)) ? r.ended : "done") as AgentHistoryEntry["ended"],
      })));
    }).catch(() => { if (alive) setList([]); });
    return () => { alive = false; };
  }, [ids]);
  return list;
}

function HistoryRow({ h, recordings, showMachine }: { h: AgentHistoryEntry; recordings: AgentRecording[]; showMachine: boolean }) {
  const [open, setOpen] = useState(false);
  const [error, setError] = useState("");
  const minutes = Math.max(1, Math.round((h.end - h.start) / 60000));
  // since() switches to a date past a day, where "ago" would be wrong.
  const when = Date.now() - h.end < 86_400_000 ? t("{time} ago", { time: since(new Date(h.end).toISOString()) }) : new Date(h.end).toLocaleDateString(locale(), { day: "numeric", month: "short" });
  const recording = recordings.find((r) => r.client === h.id);
  const facts = [
    h.runs > 0 && { icon: IconTerminal2, text: tn(h.runs, "{n} command run", "{n} commands run") },
    h.approvals > 0 && { icon: IconShieldLock, text: tn(h.approvals, "{n} approval asked", "{n} approvals asked") },
    h.offers > 0 && { icon: IconFileDownload, text: tn(h.offers, "{n} file delivered", "{n} files delivered") },
    h.controls > 0 && { icon: IconHandStop, text: tn(h.controls, "You took control {n} time", "You took control {n} times") },
  ].filter(Boolean) as { icon: Icon; text: string }[];
  return (
    <div className={`ag-history-item${open ? " open" : ""}`}>
      <button type="button" className="ag-offer ag-history-row" onClick={() => setOpen(!open)} aria-expanded={open}>
        <ClientIcon client={{ name: h.client }} />
        <span className="ag-offer-text">
          <strong className="ellipsis" title={h.task ?? undefined}>{h.task ?? t("No task given")}</strong>
          <span className="ellipsis">{[h.client, showMachine && h.machines.join(", "), when, t("{n} min", { n: minutes }), tn(h.steps, "{n} action", "{n} actions")].filter(Boolean).join(" · ")}</span>
        </span>
        <span className={`ag-ended ${h.ended}`}>{ENDED[h.ended]()}</span>
      </button>
      {open && (
        <div className="ag-history-detail">
          {facts.length ? facts.map((f) => <span key={f.text}><f.icon size={15} />{f.text}</span>) : <span>{t("Only looked and clicked")}</span>}
          {recording && (
            <div className="ag-request-actions">
              <button type="button" className="btn ghost compact" onClick={() => agents.openRecording(recording.path).catch((e) => setError(humanError(e)))}><IconPlayerPlay size={15} />{t("Watch recording")}</button>
            </div>
          )}
          {error && <span className="error-text">{error}</span>}
        </div>
      )}
    </div>
  );
}

export function HistoryList({ machine }: { machine?: string }) {
  const list = useHistory();
  const snap = useAgents();
  if (!list) return <div className="ag-history skeleton-lines" aria-busy="true" />;
  const shown = machine ? list.filter((h) => h.machines.includes(machine)) : list;
  if (!shown.length) {
    return (
      <div className="empty-small">
        <span className="empty-small-icon"><IconHistory size={18} /></span>
        <strong>{t("No sessions yet")}</strong>
      </div>
    );
  }
  return <div className="ag-history">{shown.map((h) => <HistoryRow key={h.id} h={h} recordings={snap.recordings} showMachine={!machine} />)}</div>;
}

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
    try { await navigator.clipboard.writeText(cmd); setCopied(true); setTimeout(() => setCopied(false), 1800); } catch {}
  };
  return (
    <div className="ag-command">
      <code className="ellipsis" title={cmd}>{cmd}</code>
      <button type="button" className="btn compact" onClick={copy}>{copied ? <IconCheck size={15} /> : <IconCopy size={15} />}{copied ? t("Copied") : t("Copy")}</button>
    </div>
  );
}

type ClaudeState = { cli: boolean; added: boolean; current: boolean; allowed: boolean };

function ClaudeConnect() {
  const [state, setState] = useState<ClaudeState | null>(inTauri ? null : { cli: true, added: false, current: false, allowed: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    if (!inTauri) return;
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<ClaudeState>("claude_code_state")).then(setState).catch(() => setState({ cli: false, added: false, current: false, allowed: false }));
  }, []);
  const connect = async () => {
    setBusy(true); setError("");
    try {
      if (inTauri) {
        const { invoke } = await import("@tauri-apps/api/core");
        setState(await invoke<ClaudeState>("connect_claude_code"));
      } else {
        setState({ cli: true, added: true, current: true, allowed: true });
      }
    } catch (e) { setError(humanError(e)); } finally { setBusy(false); }
  };
  if (!state) return <div className="ag-connect" aria-busy="true" />;
  if (!state.cli) return <CopyCommand />;
  const done = state.added && state.current && state.allowed;
  return (
    <div className="ag-connect">
      <span className="ag-connect-icon">{done ? <IconCheck size={17} /> : <IconPlugConnected size={17} />}</span>
      <div className="ag-connect-text">
        <strong>{done ? t("Connected to Claude Code") : state.added ? t("Claude Code asks before each action") : t("Claude Code")}</strong>
        <span>{done
          ? t("Agents act without asking in the chat. Administrator rights, network and files are approved here.")
          : t("Adds GpuVM to Claude Code and lets agents act without asking in the chat. What matters is still approved here.")}</span>
        {error && <span className="error-text">{error}</span>}
      </div>
      {!done && (
        <button type="button" className="btn compact" disabled={busy} onClick={connect}>
          {busy ? <IconLoader2 size={15} className="spin" /> : <IconPlugConnected size={15} />}{t("Connect")}
        </button>
      )}
    </div>
  );
}

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

export function AgentsView({ onOpenVm, onViewMachine }: { onOpenVm: (name: string) => void; onViewMachine?: (name: string) => void }) {
  const snap = useAgents();
  const [stopping, setStopping] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const active = snap.clients.filter((c) => c.state !== "idle");
  const stopAll = async () => {
    setStopping(true);
    try { await agents.stop("*"); await refreshAgents(); } catch {}
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
        <div className="notice error-notice">
          <IconPlugConnectedX size={20} />
          <div className="grow">{t("Agents can't reach their machines: {error}", { error: snap.broker.error ? translateModule(snap.broker.error) : t("the channel isn't open") })}</div>
        </div>
      )}
      {snap.requests.length > 0 && (
        <section className="ag-section">
          {head(<IconShieldLock size={17} />, t("Requests"), t("An agent waits for your answer. With no answer, it's refused."))}
          <div className="card ag-requests">{snap.requests.map((r) => <RequestRow key={r.id} r={r} onView={onViewMachine} />)}</div>
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
              <span>{t("Connect Claude Code once. Agents then ask for a machine and work on it while you watch.")}</span>
              <ClaudeConnect />
            </div>
          )}
      </section>
      <section className="ag-section">
        {head(<IconFileDownload size={17} />, t("Deliveries"), t("Files agents leave in a machine's Outbox. Nothing reaches your PC until you accept it."))}
        <div className="card"><OutboxList offers={snap.offers} /></div>
      </section>
      <section className="ag-section">
        {head(<IconHistory size={17} />, t("History"), t("Which agents used your machines, when and what they did."))}
        <div className="card"><HistoryList /></div>
      </section>
      {snap.clients.length > 0 && (
        <section className="ag-section">
          {head(<IconTerminal2 size={17} />, t("Connect a client"), t("Agents reach your machines through GpuVM's MCP server."))}
          <div className="card ag-connect-card"><ClaudeConnect /></div>
        </section>
      )}
    </div>
  );
}

export function AgentWidget({ machine, size }: { machine: string; size: { w: number; h: number } }) {
  const snap = useAgents();
  const client = clientOn(snap, machine);
  const requests = snap.requests.filter((r) => r.machine === machine);
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
          <>
            <div className="empty-small">
              <span className="empty-small-icon"><IconRobot size={18} /></span>
              <strong>{t("No agent on this machine")}</strong>
            </div>
            <NoDisplayNotice machine={machine} />
          </>
        )}
      </div>
      {requests.length > 0 && <div className="card ag-requests">{requests.map((r) => <RequestRow key={r.id} r={r} showMachine={false} />)}</div>}
      <div className="card"><div className="ag-card-title"><IconFileDownload size={16} />{t("Deliveries")}</div><OutboxList offers={offers} showMachine={false} /></div>
      {recordings.length > 0 && <div className="card"><div className="ag-card-title"><IconVideo size={16} />{t("Recordings")}</div><RecordingList list={recordings} /></div>}
      <div className="card"><div className="ag-card-title"><IconHistory size={16} />{t("History")}</div><HistoryList machine={machine} /></div>
    </>
  );
}
