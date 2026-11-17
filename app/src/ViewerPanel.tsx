import { useEffect, useMemo, useState } from "react";
import { IconAdjustments, IconArrowsMaximize, IconChartLine, IconDeviceDesktop, IconDeviceGamepad2, IconPlayerStop, IconX } from "@tabler/icons-react";
import { api, inTauri } from "./api";
import type { VmOverview } from "./types";
import { GameGallery, GameStage } from "./GameStage";
import { useDecor } from "./decor/store";
import type { GameDef } from "./games";
import { MachineIcon } from "./machineIcon";
import { t } from "./i18n";
import { humanError } from "./ui";

type Tab = "machines" | "games" | "picture";
interface Stats { receivedFps: number; renderedFps: number; networkDropPercent: number; decodeMs: number; renderMs: number; hostLatencyMs: number; networkLatencyMs: number }

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

async function listen<T>(event: string, handler: (payload: T) => void): Promise<() => void> {
  if (!inTauri) return () => {};
  const { listen } = await import("@tauri-apps/api/event");
  return listen<T>(event, (e) => handler(e.payload));
}

const send = (vm: string, msg: Record<string, unknown>) => invoke("viewer_send", { vm, msg }).catch(() => {});

/** The panel beside GpuVM's viewer: it slides in from the right while the picture moves aside. Machines (switch
 *  without leaving the viewer), games for the waits, and the picture's numbers and actions. */
export function ViewerPanel() {
  const [vm, setVm] = useState<string>(() => new URLSearchParams(location.search).get("vm") ?? "");
  const [open, setOpen] = useState(!inTauri);
  const [tab, setTab] = useState<Tab>("machines");
  const [vms, setVms] = useState<VmOverview[]>([]);
  const [stats, setStats] = useState<Stats | null>(null);
  const [overlay, setOverlay] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    invoke<string | null>("viewer_panel_vm").then((v) => { if (v) { setVm(v); setOpen(true); } });
    const offs = [
      listen<{ open: boolean; vm: string }>("viewer-panel", (p) => { setVm(p.vm); setOpen(p.open); }),
      listen<{ vm: string; msg: Record<string, unknown> & { type: string } }>("viewer", (p) => {
        if (p.msg.type === "stats") setStats(p.msg as unknown as Stats);
      }),
    ];
    return () => { offs.forEach((o) => o.then((f) => f())); };
  }, []);

  // The machine list while the panel is open; nothing runs while it is hidden.
  useEffect(() => {
    if (!open) return;
    let alive = true;
    const load = () => api.overview().then((list) => { if (alive) setVms(list); }).catch(() => {});
    load();
    const timer = setInterval(load, 4000);
    return () => { alive = false; clearInterval(timer); };
  }, [open]);

  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") invoke("viewer_panel_close"); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, []);

  const switchTo = async (name: string) => {
    setError("");
    try {
      const { emitTo } = await import("@tauri-apps/api/event");
      await emitTo("main", "viewer-switch", { from: vm, to: name });
      invoke("viewer_panel_close");
    } catch (e) { setError(humanError(e)); }
  };

  const tabs: { id: Tab; label: string; icon: React.ReactNode }[] = [
    { id: "machines", label: t("Máquinas"), icon: <IconDeviceDesktop size={15} /> },
    { id: "games", label: t("Juegos"), icon: <IconDeviceGamepad2 size={15} /> },
    { id: "picture", label: t("Imagen"), icon: <IconAdjustments size={15} /> },
  ];

  return (
    <aside className={`viewer-panel${open ? " open" : ""}`} aria-label={t("Panel del visor")}>
      <header className="viewer-panel-head">
        <div className="viewer-panel-tabs" role="tablist">
          {tabs.map((x) => (
            <button key={x.id} role="tab" aria-selected={tab === x.id} className={tab === x.id ? "on" : ""} onClick={() => setTab(x.id)}>
              {x.icon}{x.label}
            </button>
          ))}
        </div>
        <button className="icon-btn" aria-label={t("Cerrar")} onClick={() => invoke("viewer_panel_close")}><IconX size={16} /></button>
      </header>
      <div className="viewer-panel-body">
        {tab === "machines" && <Machines vms={vms} current={vm} onSwitch={switchTo} />}
        {tab === "games" && <Games vm={vm} names={vms.map((v) => v.name)} />}
        {tab === "picture" && (
          <Picture stats={stats} overlay={overlay}
            onFullscreen={() => send(vm, { type: "fullscreen" })}
            onOverlay={() => { send(vm, { type: "stats", on: !overlay }); setOverlay(!overlay); }}
            onDisconnect={() => { invoke("viewer_panel_close"); send(vm, { type: "quit" }); }} />
        )}
        {error && <p className="viewer-panel-error">{error}</p>}
      </div>
    </aside>
  );
}

function Machines({ vms, current, onSwitch }: { vms: VmOverview[]; current: string; onSwitch: (name: string) => void }) {
  const list = useMemo(() => [...vms].filter((v) => v.streaming).sort((a, b) => (a.name === current ? -1 : b.name === current ? 1 : 0)), [vms, current]);
  return (
    <ul className="viewer-machines">
      {list.map((v) => {
        const here = v.name === current;
        const on = v.state === "Running";
        return (
          <li key={v.name} className={here ? "here" : ""}>
            <MachineIcon name={v.name} size={28} />
            <div className="viewer-machine-text">
              <span className="name">{v.name}</span>
              <span className="sub">{here ? t("Viendo ahora") : on ? t("Encendida") : t("Apagada")}</span>
            </div>
            {!here && (
              <button className="btn" disabled={!on && !v.fits} onClick={() => onSwitch(v.name)}>
                {on ? t("Cambiar") : t("Encender")}
              </button>
            )}
          </li>
        );
      })}
    </ul>
  );
}

function Games({ vm, names }: { vm: string; names: string[] }) {
  const decor = useDecor(vm);
  const [game, setGame] = useState<GameDef | null>(null);
  if (game) return <div className="viewer-game"><GameStage game={game} machines={names} first={vm} fallback={decor} onClose={() => setGame(null)} /></div>;
  return <div className="viewer-games"><GameGallery player={vm} fallback={decor} onPick={setGame} onClose={() => {}} /></div>;
}

function Picture({ stats, overlay, onFullscreen, onOverlay, onDisconnect }: {
  stats: Stats | null; overlay: boolean; onFullscreen: () => void; onOverlay: () => void; onDisconnect: () => void;
}) {
  const ms = (n: number | undefined) => (n && n > 0 ? `${n.toFixed(1)} ms` : "—");
  const rows: [string, string][] = [
    [t("Cuadros por segundo"), stats ? `${Math.round(stats.renderedFps)}` : "—"],
    [t("Red"), ms(stats?.networkLatencyMs)],
    [t("Máquina"), ms(stats?.hostLatencyMs)],
    [t("Decodificación"), ms(stats?.decodeMs)],
    [t("Pérdidas de red"), stats ? `${stats.networkDropPercent.toFixed(1)} %` : "—"],
  ];
  return (
    <>
      <dl className="viewer-stats">
        {rows.map(([k, v]) => (<div key={k}><dt>{k}</dt><dd>{v}</dd></div>))}
      </dl>
      <div className="viewer-actions">
        <button className="btn" onClick={onFullscreen}><IconArrowsMaximize size={16} />{t("Pantalla completa")}</button>
        <button className={`btn${overlay ? " on" : ""}`} onClick={onOverlay}><IconChartLine size={16} />{t("Datos sobre la imagen")}</button>
        <button className="btn" onClick={onDisconnect}><IconPlayerStop size={16} />{t("Desconectar")}</button>
      </div>
    </>
  );
}
