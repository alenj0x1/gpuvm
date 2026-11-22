import { useEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { IconCheck, IconDeviceDesktop, IconFileDownload, IconFileUpload, IconHistory, IconLoader2, IconLock, IconRobot, IconShieldLock, IconTrash, IconWorld, IconX, type Icon } from "@tabler/icons-react";
import { inTauri } from "./api";
import { bytes, middlePath, sendOf } from "./agentStore";
import { humanError } from "./ui";
import { useReportDockSize } from "./dockSize";
import { locale, t, translateModule } from "./i18n";
import type { AgentRequest, AgentRequestKind } from "./types";

const ICON: Record<AgentRequestKind, Icon> = { deliver: IconFileDownload, admin: IconShieldLock, network: IconWorld, revert: IconHistory, delete: IconTrash, send: IconFileUpload, take: IconDeviceDesktop, other: IconRobot };
/** Like the administrator dock: a click meant for the picture never answers it. */
const ARM_MS = 450;

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

function sample(kind: string | null): AgentRequest | null {
  const base = { id: "r1", client: "c1", clientName: "Claude Code", machine: "win-agent", createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 54000).toISOString() };
  switch (kind) {
    case "deliver": return { ...base, kind: "deliver", title: "Deliver report.md", reason: "Results of the installer test", file: { name: "report.md", sizeBytes: 18432 } };
    case "revert": return { ...base, kind: "revert", title: "Go back to the restore point Before installing", reason: "The installer left the machine broken" };
    case "human": return { ...base, kind: "admin", title: "Windows asks for a password", reason: null, human: true };
    case "send": return { ...base, kind: "send", title: "", reason: "The installer to test", send: { paths: ["C:\\Users\\you\\Downloads\\GpuVM_0.9.0_x64-setup.exe"], bytes: 48_234_496, files: 1 } };
    case "send-folder": return { ...base, kind: "send", title: "", reason: null, send: { paths: ["C:\\Users\\you\\Desktop\\gpu-vm\\labs\\054-agent-ui\\out\\a-very-long-folder-name-for-the-test", "C:\\Users\\you\\Documents\\notes.txt"], bytes: 1_288_490_188, files: 342 } };
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
  const dockRef = useRef<HTMLDivElement>(null);
  useReportDockSize(dockRef, shown && !!request);

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
      // Only the choice is sent: agent.rs knows which request this dock shows.
      await invoke("agent_dock_answer", { id: request.id, allow: kind !== "deny", forTask: kind === "task" });
    } catch (e) { setError(humanError(e)); setBusy(null); }
  };
  const send = request.kind === "send" ? (request.send ?? sendOf(request as unknown as Record<string, unknown>)) : null;
  const title = request.kind === "send" ? t("{name} wants to copy to {machine}", { name: request.clientName, machine: request.machine }) : translateModule(request.title);
  const detail = send
    ? [send.files > 1 ? t("{n} files", { n: send.files }) : null, bytes(send.bytes, locale()), request.reason].filter(Boolean).join(" · ")
    : [request.clientName, request.reason, request.file && bytes(request.file.sizeBytes, locale())].filter(Boolean).join(" · ");
  const canAllow = request.kind !== "send" || !!send;

  if (request.human) {
    const back = async () => {
      setBusy("allow"); setError("");
      try {
        if (!inTauri) { await new Promise((r) => setTimeout(r, 400)); setShown(false); return; }
        await invoke("agent_dock_resume", { id: request.id });
      } catch (e) { setError(humanError(e)); setBusy(null); }
    };
    return (
      <div className="dock-stage">
        <div ref={dockRef} className={shown ? "dock on ag-dock-human" : "dock ag-dock-human"} role="alertdialog" aria-labelledby="ag-dock-title">
          <span className="dock-icon ag-dock-warn"><I size={18} /></span>
          <div className="dock-text">
            <strong id="ag-dock-title">{t("{name} needs you", { name: request.clientName })}</strong>
            <span title={title}>{title}</span>
            {error && <span className="dock-error">{error}</span>}
          </div>
          <div className="dock-actions">
            <button type="button" className="dock-btn dock-allow" disabled={!!busy} onClick={back}>
              {busy ? <IconLoader2 size={15} className="spin" /> : <IconRobot size={15} />}{t("Return to agent")}
            </button>
          </div>
        </div>
      </div>
    );
  }
  const risky = request.kind === "revert" || request.kind === "delete";
  return (
    <div className="dock-stage" onContextMenu={(e) => e.preventDefault()}>
      <div className={shown ? "dock-veil on" : "dock-veil"} />
      <div ref={dockRef} className={`dock ag-dock${send ? " ag-dock-send" : ""}${shown ? " on" : ""}`} role="alertdialog" aria-labelledby="ag-dock-title" aria-describedby="ag-dock-detail"
        onContextMenu={(e) => { e.preventDefault(); if (ready) setMenu({ x: e.clientX, y: e.clientY }); }}>
        <span className={`dock-icon${risky ? " ag-dock-risky" : request.kind === "network" ? " ag-dock-warn" : ""}`}><I size={18} /></span>
        <div className="dock-text">
          <strong id="ag-dock-title" title={title}>{title}</strong>
          {send?.paths.map((p) => <span key={p} className="ag-dock-path" title={p}>{middlePath(p, 50)}</span>)}
          <span id="ag-dock-detail">{detail}</span>
          {error && <span className="dock-error">{error}</span>}
        </div>
        <span className="ag-dock-left" title={t("Refused by itself when the time runs out")}>{t("{n} s", { n: left })}</span>
        <div className="dock-actions">
          <button type="button" className="dock-btn dock-deny" disabled={!ready && busy !== "deny"} aria-busy={busy === "deny"} onClick={() => answer("deny")}>
            {busy === "deny" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{t("Refuse")}
          </button>
          <button type="button" className="dock-btn dock-allow" disabled={!canAllow || (!ready && busy !== "allow" && busy !== "task")} aria-busy={busy === "allow" || busy === "task"} onClick={() => answer("allow")}>
            {busy === "allow" || busy === "task" ? <IconLoader2 size={15} className="spin" /> : <IconCheck size={15} />}{request.kind === "deliver" ? t("Accept") : t("Allow")}
          </button>
        </div>
      </div>
      {menu && createPortal(
        <div className="menu floating ag-dock-menu" style={{ left: Math.min(menu.x, window.innerWidth - 208), top: menu.y }} role="menu"
          onPointerDown={(e) => e.stopPropagation()}>
          {canAllow && <button type="button" role="menuitem" onClick={() => answer("allow")}><IconCheck size={15} />{request.kind === "deliver" ? t("Accept") : t("Allow")}</button>}
          {/* A copy from the PC names one exact path: never allowed ahead for the rest of the task. */}
          {request.kind !== "send" && <button type="button" role="menuitem" onClick={() => answer("task")}><IconHistory size={15} />{t("Allow for this task")}</button>}
          <button type="button" role="menuitem" onClick={() => answer("deny")}><IconX size={15} />{t("Refuse")}</button>
        </div>, document.body)}
      {menu && <div className="ag-dock-menu-catch" onPointerDown={() => setMenu(null)} />}
    </div>
  );
}
