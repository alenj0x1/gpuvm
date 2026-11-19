import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { IconCheck, IconFileDownload, IconHandFinger, IconHistory, IconLoader2, IconLock, IconRobot, IconShieldLock, IconTrash, IconWorld, IconX, type Icon } from "@tabler/icons-react";
import { inTauri } from "./api";
import { bytes } from "./agentStore";
import { humanError } from "./ui";
import { locale, t } from "./i18n";
import type { AgentRequest, AgentRequestKind } from "./types";

// The two windows of GpuVM over a machine's picture while an agent works on it (agent.rs):
// - the agent dock: what the agent asks, dropped from the top like the administrator dock (dock B), answered only here;
// - the take-control notch, from the bottom edge: the person has the machine and gives it back to the agent.
// The viewer (Low integrity, it draws what the guest sends) can't click either window (UIPI).

const ICON: Record<AgentRequestKind, Icon> = { deliver: IconFileDownload, admin: IconShieldLock, network: IconWorld, revert: IconHistory, delete: IconTrash };
/** Like the administrator dock: a click meant for the picture never answers it. */
const ARM_MS = 450;

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

/** Samples for the browser (?agent-dock=network|deliver|revert|human). */
function sample(kind: string | null): AgentRequest | null {
  const base = { id: "r1", client: "c1", clientName: "Claude Code", machine: "win-agent", createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 54000).toISOString() };
  switch (kind) {
    case "deliver": return { ...base, kind: "deliver", title: "Deliver report.md", reason: "Results of the installer test", file: { name: "report.md", sizeBytes: 18432 } };
    case "revert": return { ...base, kind: "revert", title: "Go back to the restore point Before installing", reason: "The installer left the machine broken" };
    case "human": return { ...base, kind: "admin", title: "Windows asks for a password", reason: null, human: true };
    default: return { ...base, kind: "network", title: "Connect to github.com", reason: "Download the latest release of GpuVM" };
  }
}

export function AgentDock() {
  const [request, setRequest] = useState<AgentRequest | null>(null);
  const [shown, setShown] = useState(false);
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState<"allow" | "deny" | "task" | null>(null);
  const [error, setError] = useState("");
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);
  const [, tick] = useState(0);
  const armTimer = useRef(0);

  useEffect(() => {
    let off: (() => void) | undefined;
    const take = (r: AgentRequest | null) => {
      if (r) {
        setRequest((old) => {
          if (!old || old.id !== r.id) {
            setBusy(null); setError(""); setArmed(false); setMenu(null);
            window.clearTimeout(armTimer.current);
            armTimer.current = window.setTimeout(() => setArmed(true), 320 + ARM_MS);
          }
          return r;
        });
        window.setTimeout(() => setShown(true), 30);
      } else setShown(false);
    };
    (async () => {
      if (!inTauri) { take(sample(new URLSearchParams(location.search).get("agent-dock"))); return; }
      take(await invoke<AgentRequest | null>("agent_dock_request"));
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      off = await getCurrentWebviewWindow().listen<{ request: AgentRequest | null }>("agent-dock", (e) => take(e.payload.request));
    })();
    const id = window.setInterval(() => tick((n) => n + 1), 1000);
    return () => { off?.(); window.clearInterval(id); window.clearTimeout(armTimer.current); };
  }, []);

  if (!request) return null;
  const I = request.human ? IconLock : ICON[request.kind];
  const ready = armed && !busy;
  const left = Math.max(0, Math.round((new Date(request.expiresAt).getTime() - Date.now()) / 1000));
  const answer = async (kind: "allow" | "deny" | "task") => {
    setMenu(null);
    if (!ready) return;
    setBusy(kind); setError("");
    try {
      if (!inTauri) { await new Promise((r) => setTimeout(r, 400)); setShown(false); return; }
      // Only which button: the request is the one GpuVM put in this dock (agent.rs).
      await invoke("agent_dock_answer", { allow: kind !== "deny", forTask: kind === "task" });
    } catch (e) { setError(humanError(e)); setBusy(null); }
  };
  const title = t(request.title);
  const detail = [request.clientName, request.reason, request.file && bytes(request.file.sizeBytes, locale())].filter(Boolean).join(" · ");

  if (request.human) {
    // Only the person can do it, in the machine itself: no veil and no buttons, the picture stays usable.
    return (
      <div className="dock-stage">
        <div className={shown ? "dock on ag-dock-human" : "dock ag-dock-human"} role="status">
          <span className="dock-icon ag-dock-warn"><I size={18} /></span>
          <div className="dock-text">
            <strong>{title}</strong>
            <span>{t("{name} waits until you do it", { name: request.clientName })}</span>
          </div>
        </div>
      </div>
    );
  }
  const risky = request.kind === "revert" || request.kind === "delete";
  return (
    <div className="dock-stage" onContextMenu={(e) => e.preventDefault()}>
      <div className={shown ? "dock-veil on" : "dock-veil"} />
      <div className={shown ? "dock on ag-dock" : "dock ag-dock"} role="alertdialog" aria-labelledby="ag-dock-title" aria-describedby="ag-dock-detail"
        onContextMenu={(e) => { e.preventDefault(); if (ready) setMenu({ x: e.clientX, y: e.clientY }); }}>
        <span className={`dock-icon${risky ? " ag-dock-risky" : request.kind === "network" ? " ag-dock-warn" : ""}`}><I size={18} /></span>
        <div className="dock-text">
          <strong id="ag-dock-title">{title}</strong>
          <span id="ag-dock-detail">{detail}</span>
          {error && <span className="dock-error">{error}</span>}
        </div>
        <span className="ag-dock-left" title={t("Refused by itself when the time runs out")}>{t("{n} s", { n: left })}</span>
        <div className="dock-actions">
          <button type="button" className="dock-btn dock-deny" disabled={!ready && busy !== "deny"} aria-busy={busy === "deny"} onClick={() => answer("deny")}>
            {busy === "deny" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}
          </button>
          <button type="button" className="dock-btn dock-allow" disabled={!ready && busy !== "allow" && busy !== "task"} aria-busy={busy === "allow" || busy === "task"} onClick={() => answer("allow")}>
            {busy === "allow" || busy === "task" ? <IconLoader2 size={15} className="spin" /> : <IconCheck size={15} />}{request.kind === "deliver" ? t("Accept") : t("Allow")}
          </button>
        </div>
      </div>
      {menu && createPortal(
        <div className="menu floating ag-dock-menu" style={{ left: Math.min(menu.x, window.innerWidth - 208), top: menu.y }} role="menu"
          onPointerDown={(e) => e.stopPropagation()}>
          <button type="button" role="menuitem" onClick={() => answer("allow")}><IconCheck size={15} />{request.kind === "deliver" ? t("Accept") : t("Allow")}</button>
          <button type="button" role="menuitem" onClick={() => answer("task")}><IconHistory size={15} />{t("Allow for this task")}</button>
          <button type="button" role="menuitem" onClick={() => answer("deny")}><IconX size={15} />{t("Refuse")}</button>
        </div>, document.body)}
      {menu && <div className="ag-dock-menu-catch" onPointerDown={() => setMenu(null)} />}
    </div>
  );
}

/** The take-control notch at the bottom of the picture: the person has the machine; the agent waits. */
export function AgentBanner() {
  const [info, setInfo] = useState<{ vm: string; clientName: string } | null>(null);
  const [shown, setShown] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  useEffect(() => {
    let off: (() => void) | undefined;
    const take = (v: { vm: string; clientName: string } | null) => {
      if (v) { setInfo(v); setBusy(false); setError(""); window.setTimeout(() => setShown(true), 30); } else setShown(false);
    };
    (async () => {
      if (!inTauri) { take({ vm: "win-agent", clientName: "Claude Code" }); return; }
      take(await invoke<{ vm: string; clientName: string } | null>("agent_banner_info"));
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      off = await getCurrentWebviewWindow().listen<{ info: { vm: string; clientName: string } | null }>("agent-banner", (e) => take(e.payload.info));
    })();
    return () => off?.();
  }, []);
  if (!info) return null;
  const back = async () => {
    setBusy(true); setError("");
    try {
      if (!inTauri) { await new Promise((r) => setTimeout(r, 400)); setShown(false); return; }
      await invoke("agent_banner_return");
    } catch (e) { setError(humanError(e)); setBusy(false); }
  };
  return (
    <div className="dock-stage ag-banner-stage">
      <div className={shown ? "ag-banner on" : "ag-banner"} role="status">
        <IconHandFinger size={16} className="ag-banner-icon" />
        <span className="ag-banner-text">{error || t("You took control · {name} paused", { name: info.clientName })}</span>
        <button type="button" className="dock-btn dock-allow" disabled={busy} onClick={back}>
          {busy ? <IconLoader2 size={15} className="spin" /> : <IconRobot size={15} />}{t("Return to agent")}
        </button>
      </div>
    </div>
  );
}
