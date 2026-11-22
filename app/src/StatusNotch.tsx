import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { IconAlertTriangle, IconCamera, IconCheck, IconHandFinger, IconHandStop, IconHistoryOff, IconLoader2, IconMovie, IconPlayerPause, IconPlayerPlay, IconRobot, IconVideo, type Icon } from "@tabler/icons-react";
import { inTauri } from "./api";
import { cornersFor, usePrefs, type Spot } from "./prefs";
import { humanError } from "./ui";
import { t, translateModule } from "./i18n";

// The status notch (status.rs): the one place over a machine's picture for what only says how things are (recording,
// saved, you took control, an agent paused). Requests drop from the top as docks; status lives here, at the bottom
// center unless the person put it elsewhere (Settings › Appearance). Several notices stack in the same notch.

export type StatusPlacement = Spot | "panel";
/** "copy": a file an agent delivered, being copied to this PC after the person accepted it (agent.rs): `state`
 *  copying, then accepted or failed for a few seconds, with `name` (the file) and `error`. */
/** "live": what an agent is doing now on the machine (live.rs): the step's `intent` in its own words, or a plain text
 *  from its `method` and first input `shape`; `thinking` between steps. */
export interface StatusItem { id: string; kind: "recording" | "notice" | "control" | "paused" | "copy" | "live"; key?: string; since?: number; client?: string; clientName?: string;
  name?: string; state?: "copying" | "accepted" | "failed"; error?: string | null; method?: string | null; intent?: string | null; shape?: string | null; thinking?: boolean }

/** What an agent's step does, in plain words, when it didn't say. */
export function liveText(item: StatusItem): string {
  if (item.thinking) return t("Thinking…");
  if (item.intent) return item.intent;
  const byShape: Record<string, () => string> = {
    click: () => t("Clicking"), draw: () => t("Drawing"), drag: () => t("Dragging"), scroll: () => t("Scrolling"),
    type: () => t("Typing"), key: () => t("Pressing keys"), move: () => t("Moving the pointer"), wait: () => t("Waiting"),
  };
  const byMethod: Record<string, () => string> = {
    "screen.capture": () => t("Looking at the screen"), "ui.tree": () => t("Reading the window"), "ui.invoke": () => t("Using a control"),
    "exec.run": () => t("Running a command"), "files.write": () => t("Saving a file"), "files.read": () => t("Reading a file"),
    "files.list": () => t("Looking through files"), "outbox.offer": () => t("Delivering a file"),
  };
  return (item.method === "input.act" && item.shape && byShape[item.shape]?.()) || (item.method && byMethod[item.method]?.()) || t("Working|live");
}
export interface StatusState { vm: string | null; items: StatusItem[]; placement: StatusPlacement }

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

/** The texts of what the viewer names (a fixed key; the viewer never sends text). */
const NOTICE: Record<string, { text: () => string; icon: Icon; warn?: boolean }> = {
  shot: { text: () => t("Screenshot saved"), icon: IconCamera },
  recording: { text: () => t("Recording saved"), icon: IconVideo },
  replay: { text: () => t("Clip saved"), icon: IconMovie },
  "replay-off": { text: () => t("Turn on the last 30 s in Settings"), icon: IconHistoryOff, warn: true },
  "disk-full": { text: () => t("The disk is full"), icon: IconAlertTriangle, warn: true },
  error: { text: () => t("Couldn't save"), icon: IconAlertTriangle, warn: true },
};

const clock = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  const two = (n: number) => String(n).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${two(Math.floor(s / 60) % 60)}:${two(s % 60)}` : `${two(Math.floor(s / 60))}:${two(s % 60)}`;
};

/** One notice, the same in the notch and in the side panel. */
/** `short`: the side panel's narrow column says it in fewer words. */
export function StatusRow({ item, onAction, short }: { item: StatusItem; onAction?: (id: string) => Promise<void>; short?: boolean }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [, tick] = useState(0);
  useEffect(() => {
    if (item.kind !== "recording") return;
    const id = window.setInterval(() => tick((n) => n + 1), 500);
    return () => window.clearInterval(id);
  }, [item.kind]);
  const act = async () => {
    if (!onAction) return;
    setBusy(true); setError("");
    try { await onAction(item.id); } catch (e) { setError(humanError(e)); setBusy(false); }
  };
  if (item.kind === "recording") {
    return <div className="sn-row"><span className="sn-rec" aria-hidden="true" /><span className="sn-text">{t("Recording")}</span><span className="sn-time">{clock(Date.now() - (item.since ?? Date.now()))}</span></div>;
  }
  if (item.kind === "copy") {
    const name = item.name ?? "";
    if (item.state === "failed") {
      return <div className="sn-row warn"><IconAlertTriangle size={15} className="sn-icon" />
        <span className="sn-text" title={name}>{t("Couldn't save {name}. {error}", { name, error: item.error ? translateModule(item.error) : "?" })}</span></div>;
    }
    return (
      <div className="sn-row">
        {item.state === "accepted" ? <IconCheck size={15} className="sn-icon ok" /> : <IconLoader2 size={15} className="sn-icon spin" />}
        <span className="sn-text" title={name}>{item.state === "accepted" ? t("{name} saved in Downloads", { name }) : t("Copying {name}…", { name })}</span>
      </div>
    );
  }
  if (item.kind === "notice") {
    const n = NOTICE[item.key ?? ""] ?? NOTICE.error;
    return <div className={`sn-row${n.warn ? " warn" : ""}`}>{n.warn ? <n.icon size={15} className="sn-icon" /> : <IconCheck size={15} className="sn-icon ok" />}<span className="sn-text">{n.text()}</span></div>;
  }
  const name = item.clientName ?? t("The agent");
  if (item.kind === "live") {
    const long = item.method === "exec.run" || item.method === "files.write";
    return (
      <div className="sn-row">
        {item.thinking || long ? <IconLoader2 size={15} className="sn-icon spin" /> : <IconRobot size={15} className="sn-icon accent" />}
        <span className="sn-text" title={liveText(item)}>{t("{name} · {doing}", { name, doing: liveText(item) })}</span>
        {onAction && (
          <button type="button" className="dock-btn sn-btn sn-ghost" disabled={busy} onClick={act}>
            {busy ? <IconLoader2 size={14} className="spin" /> : <IconHandStop size={14} />}{t("Take control")}
          </button>
        )}
      </div>
    );
  }
  const control = item.kind === "control";
  return (
    <div className="sn-row">
      {control ? <IconHandFinger size={15} className="sn-icon accent" /> : <IconPlayerPause size={15} className="sn-icon" />}
      <span className="sn-text">{error || (control ? (short ? t("You have control") : t("You took control · {name} paused", { name })) : t("{name} paused", { name }))}</span>
      {onAction && (
        <button type="button" className="dock-btn dock-allow sn-btn" disabled={busy} onClick={act}>
          {busy ? <IconLoader2 size={14} className="spin" /> : control ? <IconRobot size={14} /> : <IconPlayerPlay size={14} />}{control ? t("Return to agent") : t("Resume")}
        </button>
      )}
    </div>
  );
}

/** Samples for the browser (?status-notch&placement=top&dock): recording, a saved notice and take control. */
function sample(): StatusState {
  const q = new URLSearchParams(location.search);
  const items: StatusItem[] = [
    { id: "agent", kind: "control", client: "c1", clientName: "Claude Code" },
    { id: "recording", kind: "recording", since: Date.now() - 83000 },
    { id: "notice:1", kind: "notice", key: q.get("notice") ?? "shot" },
  ];
  const live = q.get("live");
  if (live !== null) return { vm: "win-agent", items: [{ id: "live", kind: "live", client: "c1", clientName: "Claude Code", method: live === "run" ? "exec.run" : "input.act", shape: "draw", intent: live === "intent" ? "Dibujando la luna" : null, thinking: live === "thinking" }], placement: "bottom" };
  const copy = q.get("copy") as StatusItem["state"] | null;
  if (copy) return { vm: "win-agent", items: [{ id: "copy:o1", kind: "copy", state: copy, name: "installer-test-report.md", error: copy === "failed" ? "There isn't enough room in Downloads." : null }], placement: "bottom" };
  return { vm: "win-agent", items: items.slice(0, Number(q.get("n") ?? 3)), placement: (q.get("placement") as StatusPlacement) ?? "bottom" };
}

/** The notch's window: exactly the size of what it shows (status.rs sizes and places it). */
export function StatusNotch() {
  const prefs = usePrefs();
  const [state, setState] = useState<StatusState | null>(null);
  const [shown, setShown] = useState(false);
  const [under, setUnder] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const offs: (() => void)[] = [];
    const take = (s: StatusState | null) => {
      if (s && s.items.length) { setState(s); window.setTimeout(() => setShown(true), 30); } else setShown(false);
    };
    (async () => {
      if (!inTauri) { take(sample()); setUnder(new URLSearchParams(location.search).has("dock")); return; }
      take(await invoke<StatusState | null>("status_state"));
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      const w = getCurrentWebviewWindow();
      offs.push(await w.listen<StatusState | null>("status-notch", (e) => take(e.payload)));
      offs.push(await w.listen<{ under: boolean }>("status-place", (e) => setUnder(!!e.payload.under)));
    })();
    return () => offs.forEach((f) => f());
  }, []);

  // The window follows the notch's size (it never covers more of the picture than the notch itself).
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    // offsetWidth/Height: its size without the entrance's transform.
    const send = () => { invoke("status_resize", { width: el.offsetWidth, height: el.offsetHeight }); };
    send();
    const ro = new ResizeObserver(send);
    ro.observe(el);
    return () => ro.disconnect();
  }, [state]);

  if (!state) return null;
  const action = async (id: string) => { if (inTauri) await invoke("status_action", { id }); };
  const spot: Spot = state.placement === "panel" ? "bottom" : state.placement;
  // Under a dock it floats (rounded all round); otherwise attached to the edge only when its gap is 0.
  const gap = under ? 1 : prefs.notchGap;
  const bottom = spot.startsWith("bottom");
  // Bottom: the agent's notice nearest the edge, moment notices above it; at the top, the other way around.
  const order = (i: StatusItem) => (i.kind === "control" || i.kind === "paused" ? 0 : i.kind === "recording" ? 1 : 2);
  const items = [...state.items].sort((a, b) => order(a) - order(b));
  return (
    <div className={`sn-stage sn-${spot} sn-v-${bottom ? "bottom" : "top"}${gap <= 0 ? " attached" : ""}${under ? " under" : ""}`}
      style={{ ["--sn-radius" as string]: cornersFor(spot, gap, 14) }}>
      <div ref={ref} className={`sn${shown ? " on" : ""}`} role="status" aria-live="polite">
        {(bottom ? [...items].reverse() : items).map((i) => <StatusRow key={i.id} item={i} onAction={i.kind === "control" || i.kind === "paused" || i.kind === "live" ? action : undefined} />)}
      </div>
    </div>
  );
}

/** In the side panel, when the person put status notices there: the same rows at the top of the panel. */
export function PanelStatus({ vm }: { vm: string }) {
  const [state, setState] = useState<StatusState | null>(null);
  useEffect(() => {
    if (!inTauri) {
      if (new URLSearchParams(location.search).get("placement") === "panel") setState({ ...sample(), placement: "panel" });
      return;
    }
    let off: (() => void) | undefined;
    (async () => {
      setState(await invoke<StatusState | null>("status_state"));
      const { listen } = await import("@tauri-apps/api/event");
      off = await listen<StatusState>("status-items", (e) => setState(e.payload));
    })();
    return () => off?.();
  }, []);
  if (!state || state.placement !== "panel" || state.vm !== vm || !state.items.length) return null;
  return (
    <div className="vp-status" role="status" aria-live="polite">
      {state.items.map((i) => <StatusRow key={i.id} item={i} short onAction={i.kind === "control" || i.kind === "paused" || i.kind === "live" ? (id) => invoke("status_action", { id }).then(() => {}) : undefined} />)}
    </div>
  );
}
