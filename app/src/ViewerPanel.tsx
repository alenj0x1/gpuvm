import { useEffect, useRef, useState } from "react";
import { IconCheck, IconLayoutGrid, IconPlus, IconX } from "@tabler/icons-react";
import { api, inTauri } from "./api";
import type { VmOverview } from "./types";
import { GameStage } from "./GameStage";
import { useDecor } from "./decor/store";
import type { GameDef } from "./games";
import { MachineIcon } from "./machineIcon";
import { refreshPrefs } from "./prefs";
import { t } from "./i18n";
import { humanError } from "./ui";
import {
  ActionsWidget, CaptureWidget, ClockWidget, GamesWidget, MachinesWidget, ShelfWidget, StatsWidget, WeatherWidget, WidgetBoard, WidgetTray,
  defaultWidgets, forgetWeather, loadWidgets, newWidget, saveWidgets, type CaptureState, type SavedCapture, type ViewerStats, type WidgetItem,
} from "./ViewerWidgets";
import { usePrefs } from "./prefs";

const WIDTH_KEY = "gpuvm.viewerPanelWidth";

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

/** Why a capture failed, in words (the viewer and the app send a short reason). */
const captureErrorText = (reason: string) => ({
  "disk-full": t("No hay espacio en el disco"),
  "too-slow": t("El disco no da abasto, la grabación se detuvo"),
  "no-frame": t("No llegó la imagen, inténtalo de nuevo"),
  "format": t("Esta imagen no se puede capturar"),
  "replay-empty": t("Aún no hay segundos guardados"),
  "replay-off": t("Actívalo en Ajustes, en Capturas"),
}[reason] ?? t("No se pudo guardar"));

/** The panel beside GpuVM's viewer: it slides in from the right while the picture moves aside. A board of widgets
 *  the person arranges (ViewerWidgets.tsx): machines to switch to, the usual actions, the picture's numbers, the time,
 *  the shelf with the machines' figures, games for the waits and, if turned on, the weather. */
export function ViewerPanel({ machine, onSwitched, onResize, sample }: {
  machine?: string; onSwitched?: (name: string) => void;
  /** The website's sample: adjusts the machines it lists (all on, so they can be switched to). */
  sample?: (vms: VmOverview[]) => VmOverview[];
  /** The website's sample: the edge drag reports the width here instead of resizing a window. */
  onResize?: (width: number) => void;
} = {}) {
  const [vm, setVm] = useState<string>(() => machine ?? new URLSearchParams(location.search).get("vm") ?? "");
  const vmRef = useRef(vm);
  vmRef.current = vm;
  const [open, setOpen] = useState(!inTauri);
  const [vms, setVms] = useState<VmOverview[]>([]);
  const [stats, setStats] = useState<ViewerStats | null>(null);
  const [history, setHistory] = useState<number[]>([]);
  const [overlay, setOverlay] = useState(false);
  const [fullScreen, setFullScreen] = useState(false);
  const [error, setError] = useState("");
  const [items, setItems] = useState<WidgetItem[]>(loadWidgets);
  const [edit, setEdit] = useState(false);
  const [game, setGame] = useState<GameDef | null>(null);
  const decor = useDecor(vm);
  // Screenshots and recordings: per machine, as the viewers report them (they may record while the panel is closed).
  const prefs = usePrefs();
  const [captures, setCaptures] = useState<Record<string, { recording: boolean; since: number; last: SavedCapture | null; error: string }>>({});
  const captureOf = (name: string) => captures[name] ?? { recording: false, since: 0, last: null, error: "" };
  const setCapture = (name: string, change: Partial<{ recording: boolean; since: number; last: SavedCapture | null; error: string }>) =>
    setCaptures((all) => ({ ...all, [name]: { ...(all[name] ?? { recording: false, since: 0, last: null, error: "" }), ...change } }));
  const errorTimer = useRef(0);
  const showError = (name: string, text: string) => {
    setCapture(name, { error: text });
    clearTimeout(errorTimer.current);
    errorTimer.current = window.setTimeout(() => setCapture(name, { error: "" }), 5000);
  };

  const onStats = (s: ViewerStats) => {
    setStats(s);
    setHistory((h) => [...h.slice(-39), s.renderedFps]);
  };

  useEffect(() => {
    invoke<string | null>("viewer_panel_vm").then((v) => { if (v) { setVm(v); setOpen(true); } });
    const offs = [
      listen<{ open: boolean; vm: string }>("viewer-panel", (p) => { setVm(p.vm); setOpen(p.open); if (!p.open) setEdit(false); }),
      listen<{ vm: string; msg: Record<string, unknown> & { type: string } }>("viewer", (p) => {
        // Recording state is kept for every machine (it can record while another one is on screen).
        if (p.msg.type === "recording") setCapture(p.vm, p.msg.on ? { recording: true, since: Date.now(), error: "" } : { recording: false });
        if (p.msg.type === "capture-error") showError(p.vm, captureErrorText(String(p.msg.reason ?? "")));
        if (p.msg.type === "closed" || p.msg.type === "ended") setCapture(p.vm, { recording: false });
        // Another machine may stay connected in the background: only this one's numbers.
        if (p.vm !== vmRef.current) return;
        if (p.msg.type === "stats") onStats(p.msg as unknown as ViewerStats);
        if (p.msg.type === "window") setFullScreen(!!p.msg.fullScreen);
      }),
      listen<SavedCapture & { vm: string }>("capture-saved", (p) => {
        setCapture(p.vm, { last: { kind: p.kind, path: p.path, name: p.name, thumb: p.thumb, durationMs: p.durationMs, at: Date.now() }, error: "" });
      }),
    ];
    return () => { offs.forEach((o) => o.then((f) => f())); };
  }, []);

  // The panel lives on hidden between uses: each time it opens it takes the theme and accent chosen meanwhile.
  useEffect(() => { if (open) refreshPrefs(); }, [open]);

  // And the machine's newest capture and recording, which may have happened before the panel existed (keys).
  useEffect(() => {
    if (!open || !vm || !inTauri) return;
    invoke<{ last: (SavedCapture & { at: number }) | null; recordingSince: number | null }>("capture_state", { vm }).then((s) => {
      if (!s) return;
      setCapture(vm, {
        recording: s.recordingSince != null, since: s.recordingSince ?? 0,
        ...(s.last ? { last: { kind: s.last.kind, path: s.last.path, name: s.last.name, thumb: s.last.thumb, durationMs: s.last.durationMs, at: s.last.at } } : {}),
      });
    }).catch(() => {});
  }, [open, vm]);

  // In the browser preview there is no viewer: made-up numbers so the widget can be seen working.
  useEffect(() => {
    if (inTauri) return;
    const timer = setInterval(() => onStats({ receivedFps: 60, renderedFps: 57 + Math.random() * 3 - (Math.random() < 0.08 ? 8 : 0), networkDropPercent: 0, decodeMs: 1.2, renderMs: 0.4, hostLatencyMs: 4 + Math.random(), networkLatencyMs: 1.5 + Math.random() * 0.6 }), 1000);
    return () => clearInterval(timer);
  }, []);

  // The machine list while the panel is open; nothing runs while it is hidden.
  useEffect(() => {
    if (!open) return;
    let alive = true;
    const load = () => api.overview().then((list) => { if (alive) setVms(sample ? sample(list) : list); }).catch(() => {});
    load();
    const timer = setInterval(load, 4000);
    return () => { alive = false; clearInterval(timer); };
  }, [open]);

  const change = (next: WidgetItem[]) => {
    setItems(next);
    saveWidgets(next);
    // Taking the weather off forgets its city too.
    if (!next.some((x) => x.type === "weather")) forgetWeather();
  };

  // The panel's width: dragged from its left edge, within limits (overlay.rs), remembered.
  useEffect(() => {
    const saved = Number(localStorage.getItem(WIDTH_KEY));
    if (saved) invoke("viewer_panel_resize", { width: saved });
  }, []);
  const startResize = (e: React.PointerEvent<HTMLDivElement>) => {
    const target = e.currentTarget;
    target.setPointerCapture(e.pointerId);
    const startX = e.screenX, startW = inTauri ? window.innerWidth : target.parentElement!.getBoundingClientRect().width;
    let frame = 0, last = startW;
    const move = (ev: PointerEvent) => {
      last = Math.round(startW - (ev.screenX - startX));
      if (!inTauri) { onResize?.(Math.min(560, Math.max(300, last))); return; }
      if (!frame) frame = requestAnimationFrame(() => { frame = 0; invoke<number>("viewer_panel_resize", { width: last }); });
    };
    const up = () => {
      target.removeEventListener("pointermove", move);
      target.removeEventListener("pointerup", up);
      target.removeEventListener("pointercancel", up);
      if (!inTauri) return;
      invoke<number>("viewer_panel_resize", { width: last }).then((w) => { try { localStorage.setItem(WIDTH_KEY, String(w ?? last)); } catch { /* no storage */ } });
    };
    target.addEventListener("pointermove", move);
    target.addEventListener("pointerup", up);
    target.addEventListener("pointercancel", up);
  };
  const goHome = async () => {
    if (!inTauri) return;
    const { emitTo } = await import("@tauri-apps/api/event");
    await emitTo("main", "viewer-home", { vm });
  };

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      // The viewer's shortcuts also work while the panel has the focus: the same keys close it or go Home.
      // By the key's position, its letter or its key code: input without a scan code (remote desktops, test
      // tools) has no `code`.
      const letter = e.code === "KeyG" || e.keyCode === 71 || e.key.toLowerCase() === "g" ? "g"
        : e.code === "KeyH" || e.keyCode === 72 || e.key.toLowerCase() === "h" ? "h" : "";
      if (e.ctrlKey && e.altKey && e.shiftKey && letter) {
        e.preventDefault();
        if (letter === "g") invoke("viewer_panel_close");
        else goHome();
        return;
      }
      if (e.key !== "Escape" || e.defaultPrevented) return;
      if (game) return;
      if (edit) { setEdit(false); return; }
      invoke("viewer_panel_close");
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [game, edit, vm]);

  const switchTo = async (name: string) => {
    setError("");
    // The website's sample: switching shows the other machine in the panel.
    if (!inTauri) { setVm(name); onSwitched?.(name); return; }
    try {
      const { emitTo } = await import("@tauri-apps/api/event");
      await emitTo("main", "viewer-switch", { from: vm, to: name });
      invoke("viewer_panel_close");
    } catch (e) { setError(humanError(e)); }
  };

  return (
    <aside className={`viewer-panel${open ? " open" : ""}`} aria-label={t("Panel del visor")}>
      <div className="viewer-panel-edge" onPointerDown={startResize} onDoubleClick={() => { onResize?.(340); invoke("viewer_panel_resize", { width: 340 }); try { localStorage.removeItem(WIDTH_KEY); } catch { /* no storage */ } }} aria-hidden="true" />
      <div className="viewer-panel-top">
        <span className="viewer-panel-machine"><MachineIcon name={vm} size={20} radius={6} /><span>{vm}</span></span>
        {!game && (
          <button type="button" className={`vp-edit${edit ? " on" : ""}`} onClick={() => setEdit(!edit)}>
            {edit ? <><IconCheck size={15} />{t("Listo")}</> : <><IconLayoutGrid size={15} />{t("Editar")}</>}
          </button>
        )}
        <button type="button" className="icon-btn" aria-label={t("Cerrar")} title={t("Cerrar")} onClick={() => invoke("viewer_panel_close")}><IconX size={16} /></button>
      </div>
      <div className="viewer-panel-body" onScroll={(e) => {
        // Only up and down: while the panel narrows the board is wider for a moment, and a sideways scroll left the
        // widgets cut on the left once it widened again.
        if (e.currentTarget.scrollLeft) e.currentTarget.scrollLeft = 0;
      }}>
        {game ? (
          <div className="viewer-game"><GameStage game={game} machines={vms.filter((v) => v.streaming).map((v) => v.name)} first={vm} fallback={decor} onClose={() => setGame(null)} /></div>
        ) : (
          <>
            {items.length === 0 && !edit ? (
              <div className="vp-board-empty">
                <span className="vp-empty-icon"><IconLayoutGrid size={20} /></span>
                <strong>{t("Sin widgets")}</strong>
                <span>{t("Elige lo que quieres tener a mano mientras usas la máquina.")}</span>
                <button type="button" className="vp-chip" onClick={() => setEdit(true)}><IconPlus size={14} />{t("Agregar")}</button>
              </div>
            ) : (
              <WidgetBoard items={items} onChange={change} edit={edit}>
                {(it, size) => {
                  switch (it.type) {
                    case "machines": return <MachinesWidget vms={vms} current={vm} size={size} onSwitch={switchTo} />;
                    case "actions": return (
                      <ActionsWidget size={size} fullScreen={fullScreen} overlay={overlay} onHome={goHome}
                        onFullscreen={() => send(vm, { type: "fullscreen" })}
                        onOverlay={() => { send(vm, { type: "stats", on: !overlay }); setOverlay(!overlay); }}
                        onDisconnect={() => { invoke("viewer_panel_close"); send(vm, { type: "quit" }); }} />
                    );
                    case "capture": {
                      const c = captureOf(vm);
                      const state: CaptureState = { ...c, replay: prefs.replay };
                      // The website's sample: made-up files so the widget can be seen working.
                      const sampleShot = (kind: SavedCapture["kind"], durationMs = 0) =>
                        setCapture(vm, { last: { kind, path: "", name: `${vm} 2026-11-18 21.04.13.${kind === "shot" ? "png" : "mp4"}`, thumb: null, durationMs, at: Date.now() } });
                      return (
                        <CaptureWidget size={size} state={state}
                          onShot={() => (inTauri ? send(vm, { type: "screenshot" }) : sampleShot("shot"))}
                          onRecord={() => {
                            if (inTauri) { send(vm, { type: "record", on: !c.recording }); return; }
                            if (c.recording) { setCapture(vm, { recording: false }); sampleShot("clip", Date.now() - c.since); }
                            else setCapture(vm, { recording: true, since: Date.now() });
                          }}
                          onReplay={() => (inTauri ? send(vm, { type: "replay-save" }) : sampleShot("replay", 30000))}
                          onOpen={(f) => invoke("capture_open", { path: f.path }).catch((e) => showError(vm, humanError(e)))}
                          onReveal={(f) => invoke("capture_reveal", { path: f.path }).catch((e) => showError(vm, humanError(e)))} />
                      );
                    }
                    case "stats": return <StatsWidget stats={stats} history={history} size={size} />;
                    case "clock": return <ClockWidget size={size} />;
                    case "shelf": return <ShelfWidget vms={vms} size={size} />;
                    case "games": return <GamesWidget size={size} player={vm} fallback={decor} onPlay={(g) => { setEdit(false); setGame(g); }} />;
                    case "weather": return <WeatherWidget size={size} open={open} />;
                  }
                }}
              </WidgetBoard>
            )}
            {edit && <WidgetTray items={items} onAdd={(type) => change([...items, newWidget(type, items)])} onReset={() => change(defaultWidgets())} />}
          </>
        )}
        {error && <p className="viewer-panel-error">{error}</p>}
      </div>
    </aside>
  );
}
