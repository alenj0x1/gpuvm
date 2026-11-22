import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import {
  IconCamera, IconFolder, IconHistory, IconPhoto, IconVideo,
  IconActivity, IconArrowsMaximize, IconArrowsMinimize, IconBooks, IconBolt, IconChartLine, IconClock, IconCloud, IconCloudFog,
  IconCloudRain, IconCloudSnow, IconCloudStorm, IconDeviceDesktop, IconDeviceGamepad2, IconHome, IconMinus, IconMoon,
  IconPlayerPlay, IconPlugConnectedX, IconPlus, IconSun, IconTrophy, IconCloudSearch, IconFiles, IconClipboard, IconRobot, type Icon,
} from "@tabler/icons-react";
import { MiniCube } from "./MiniCube";
import { miniOf } from "./HomeLoading";
import { GAMES, bestScore, type GameDef } from "./games";
import { FIGURES, figureName } from "./decor/figures";
import { drawFigureThumb, figureThumbImage } from "./decor/figureGL";
import { decorColor, onDecorChange, readDecor, type Decor } from "./decor/store";
import { GameDemo } from "./GameStage";
import { usePrefs } from "./prefs";
import { locale, t } from "./i18n";
import type { VmOverview } from "./types";

export type WidgetType = "machines" | "actions" | "capture" | "agent" | "stats" | "clock" | "shelf" | "games" | "weather" | "files" | "clipboard";
export interface WidgetItem { id: string; type: WidgetType; w: number; h: number; x: number; y: number }
interface Spec { icon: Icon; name: () => string; minW: number; maxW: number; minH: number; maxH: number; w: number; h: number }

export const SPEC: Record<WidgetType, Spec> = {
  machines: { icon: IconDeviceDesktop, name: () => t("Machines"), minW: 1, maxW: 3, minH: 1, maxH: 6, w: 2, h: 2 },
  actions: { icon: IconBolt, name: () => t("Actions"), minW: 1, maxW: 3, minH: 1, maxH: 2, w: 2, h: 1 },
  capture: { icon: IconCamera, name: () => t("Capture"), minW: 1, maxW: 3, minH: 1, maxH: 2, w: 2, h: 2 },
  agent: { icon: IconRobot, name: () => t("Agent"), minW: 2, maxW: 3, minH: 1, maxH: 4, w: 2, h: 2 },
  stats: { icon: IconActivity, name: () => t("Picture"), minW: 1, maxW: 3, minH: 1, maxH: 3, w: 1, h: 2 },
  clock: { icon: IconClock, name: () => t("Clock"), minW: 1, maxW: 3, minH: 1, maxH: 2, w: 1, h: 1 },
  shelf: { icon: IconBooks, name: () => t("Shelf"), minW: 1, maxW: 3, minH: 1, maxH: 4, w: 2, h: 2 },
  games: { icon: IconDeviceGamepad2, name: () => t("Games"), minW: 1, maxW: 3, minH: 1, maxH: 3, w: 2, h: 2 },
  weather: { icon: IconCloud, name: () => t("Weather"), minW: 1, maxW: 3, minH: 1, maxH: 2, w: 1, h: 1 },
  files: { icon: IconFiles, name: () => t("Files"), minW: 2, maxW: 3, minH: 2, maxH: 5, w: 2, h: 2 },
  clipboard: { icon: IconClipboard, name: () => t("Clipboard"), minW: 2, maxW: 3, minH: 2, maxH: 5, w: 2, h: 3 },
};
const ORDER: WidgetType[] = ["machines", "actions", "capture", "agent", "stats", "clock", "files", "clipboard", "shelf", "games", "weather"];
const DEFAULT_SIZES: [WidgetType, number, number][] = [["machines", 2, 2], ["stats", 1, 2], ["clock", 1, 2], ["actions", 2, 2], ["capture", 3, 2], ["files", 3, 2], ["clipboard", 3, 3], ["shelf", 3, 2], ["games", 3, 2]];

const clamp = (n: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, n));
const GAP = 8, ROW = 76;
interface Cell { x: number; y: number; w: number; h: number }
const hit = (a: Cell, b: Cell) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;

const shownW = (it: { type: WidgetType; w: number }, cols: number) => clamp(it.w, Math.min(SPEC[it.type].minW, cols), Math.min(SPEC[it.type].maxW, cols));

function settle(list: Omit<WidgetItem, "x" | "y">[] | WidgetItem[], cols = 3): WidgetItem[] {
  const out: WidgetItem[] = [], taken: Cell[] = [];
  for (const it of list) {
    const w = shownW(it, cols);
    const has = "x" in it && Number.isFinite(it.x) && Number.isFinite(it.y);
    if (has) { const c = { x: (it as WidgetItem).x, y: (it as WidgetItem).y, w, h: it.h }; out.push(it as WidgetItem); taken.push(c); continue; }
    search: for (let y = 0; ; y++) for (let x = 0; x <= cols - w; x++) {
      const c = { x, y, w, h: it.h };
      if (!taken.some((o) => hit(o, c))) { taken.push(c); out.push({ ...it, x, y }); break search; }
    }
  }
  return out;
}

function place(items: WidgetItem[], cols: number, first?: string): Record<string, Cell> {
  const out: Record<string, Cell> = {}, taken: Cell[] = [];
  const seq = settle(items, cols).sort((a, b) => (a.id === first ? -1 : b.id === first ? 1 : a.y - b.y || a.x - b.x));
  for (const it of seq) {
    const w = shownW(it, cols), c = { x: clamp(it.x, 0, cols - w), y: Math.max(0, it.y), w, h: it.h };
    if (it.id !== first) {
      while (c.y > 0 && !taken.some((o) => hit(o, { ...c, y: c.y - 1 }))) c.y--;
      while (taken.some((o) => hit(o, c))) c.y++;
    }
    taken.push(c);
    out[it.id] = c;
  }
  if (!first) return out;
  return place(items.map((o) => ({ ...o, x: out[o.id].x, y: out[o.id].y })), cols);
}

const KEY = "gpuvm.viewerPanelWidgets";
const NEWER: WidgetType[] = ["capture", "files", "clipboard"];
const OFFERED = "gpuvm.viewerPanelWidgetsOffered.v2";
export function loadWidgets(): WidgetItem[] {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) ?? "null");
    if (!Array.isArray(raw)) return defaultWidgets();
    const seen = new Set<string>();
    const list = raw.filter((x) => x && x.type in SPEC && !seen.has(x.type) && !!seen.add(x.type)).map((x) => {
      const s = SPEC[x.type as WidgetType];
      const base = { id: x.type, type: x.type as WidgetType, w: clamp(Number(x.w) || 1, s.minW, s.maxW), h: clamp(Number(x.h) || 1, s.minH, s.maxH) };
      return Number.isFinite(x.x) && Number.isFinite(x.y) ? { ...base, x: clamp(x.x, 0, 2), y: Math.max(0, x.y) } : base;
    });
    const offered = new Set<string>(JSON.parse(localStorage.getItem(OFFERED) ?? "[]"));
    let added = false;
    for (const type of NEWER) {
      if (!offered.has(type) && !list.some((x) => x.type === type)) { list.push(newWidget(type, settle(list))); added = true; }
    }
    if (added) saveWidgets(settle(list));
    else localStorage.setItem(OFFERED, JSON.stringify(NEWER));
    return settle(list);
  } catch { return defaultWidgets(); }
}
export function saveWidgets(items: WidgetItem[]) {
  try {
    localStorage.setItem(KEY, JSON.stringify(items.map(({ type, w, h, x, y }) => ({ type, w, h, x, y }))));
    localStorage.setItem(OFFERED, JSON.stringify(NEWER));
  } catch {}
}
export const defaultWidgets = () => settle(DEFAULT_SIZES.map(([type, w, h]) => ({ id: type, type, w, h })));
export const missingWidgets = (items: WidgetItem[]) => ORDER.filter((type) => !items.some((x) => x.type === type));
export const newWidget = (type: WidgetType, items: WidgetItem[]): WidgetItem =>
  ({ id: type, type, w: SPEC[type].w, h: SPEC[type].h, x: 0, y: Math.max(0, ...items.map((o) => (Number(o.y) || 0) + o.h)) });

export interface WidgetSize { w: number; h: number; px: number; py: number }

export function WidgetBoard({ items, onChange, edit, children }: {
  items: WidgetItem[]; onChange: (items: WidgetItem[]) => void; edit: boolean;
  children: (item: WidgetItem, size: WidgetSize) => ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [drag, setDrag] = useState<{ id: string; x: number; y: number; cx: number; cy: number } | null>(null);
  const [sizing, setSizing] = useState<{ id: string; w: number; h: number } | null>(null);
  const [ready, setReady] = useState(false);
  const live = useRef(items);
  live.current = items;

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  // Also on every redraw: some browsers (Brave) deliver the observer's last size late or never.
  useLayoutEffect(() => {
    const w = ref.current?.clientWidth ?? 0;
    if (w && w !== width) setWidth(w);
  });
  useEffect(() => { if (width && !ready) { const f = requestAnimationFrame(() => setReady(true)); return () => cancelAnimationFrame(f); } }, [width, ready]);

  const cols = width >= 416 ? 3 : 2;
  const cellW = (width - GAP * (cols - 1)) / cols;
  useEffect(() => {
    if (cols !== 3) return;
    const list = live.current;
    if (!list.length || !list.every((it) => it.x + shownW(it, 2) <= 2)) return;
    const order = [...list].sort((a, b) => a.y - b.y || a.x - b.x)
      .map(({ x: _x, y: _y, ...rest }) => (shownW(rest, 2) === 2 ? { ...rest, w: Math.min(SPEC[rest.type].maxW, 3) } : rest));
    const flowed = settle(order, 3);
    if (flowed.some((f) => { const o = list.find((x) => x.id === f.id)!; return o.x !== f.x || o.y !== f.y || o.w !== f.w; })) onChange(flowed);
  }, [cols]);
  const px = (c: Cell) => ({ x: c.x * (cellW + GAP), y: c.y * (ROW + GAP), w: c.w * cellW + (c.w - 1) * GAP, h: c.h * ROW + (c.h - 1) * GAP });

  const shown = useMemo(() => {
    if (drag) return { list: items.map((o) => (o.id === drag.id ? { ...o, x: drag.cx, y: drag.cy } : o)), first: drag.id };
    if (sizing) return { list: items.map((o) => (o.id === sizing.id ? { ...o, w: sizing.w, h: sizing.h } : o)), first: sizing.id };
    return { list: items, first: undefined };
  }, [items, drag, sizing]);
  const cells = useMemo(() => place(shown.list, cols, shown.first), [shown, cols]);
  const rows = Math.max(0, ...Object.values(cells).map((c) => c.y + c.h));
  const boardH = Math.max(0, (rows + (drag || sizing ? 1 : 0)) * (ROW + GAP) - GAP);
  const commit = (list: WidgetItem[], first?: string) => {
    const at = place(list, cols, first);
    onChange(list.map((o) => ({ ...o, x: at[o.id].x, y: at[o.id].y })));
  };

  const edgeScroll = (pointerY: () => number | null, onScroll: () => void) => {
    const sc = ref.current?.closest(".viewer-panel-body") as HTMLElement | null;
    let frame = 0;
    const tick = () => {
      const y = pointerY();
      if (sc && y !== null) {
        const r = sc.getBoundingClientRect(), zone = 40;
        const v = y > r.bottom - zone ? Math.min(7, (y - (r.bottom - zone)) / 6 + 1) : y < r.top + zone ? -Math.min(7, (r.top + zone - y) / 6 + 1) : 0;
        if (v) { const before = sc.scrollTop; sc.scrollTop += v; if (sc.scrollTop !== before) onScroll(); }
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return { stop: () => cancelAnimationFrame(frame), top: () => sc?.scrollTop ?? 0 };
  };

  const startDrag = (e: React.PointerEvent, id: string) => {
    if (!edit || e.button !== 0 || (e.target as HTMLElement).closest(".vp-remove, .vp-grip")) return;
    const me = live.current.find((o) => o.id === id);
    if (!me) return;
    const box = ref.current!.getBoundingClientRect(), at = px(cells[id]);
    const gx = e.clientX - box.left - at.x, gy = e.clientY - box.top - at.y, sx = e.clientX, sy = e.clientY;
    const w = shownW(me, cols);
    let on = false, frame = 0, pending: PointerEvent | null = null, cell = { cx: cells[id].x, cy: cells[id].y };
    const step = () => {
      frame = 0;
      const ev = pending!;
      const b = ref.current!.getBoundingClientRect(), x = ev.clientX - b.left - gx, y = ev.clientY - b.top - gy;
      cell = { cx: clamp(Math.round(x / (cellW + GAP)), 0, cols - w), cy: Math.max(0, Math.round(y / (ROW + GAP))) };
      setDrag({ id, x, y, ...cell });
    };
    const auto = edgeScroll(() => (on && pending ? pending.clientY : null), () => { if (pending && !frame) frame = requestAnimationFrame(step); });
    const move = (ev: PointerEvent) => {
      if (!on) {
        if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
        on = true;
      }
      pending = ev;
      if (!frame) frame = requestAnimationFrame(step);
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      cancelAnimationFrame(frame);
      auto.stop();
      if (on) commit(live.current.map((o) => (o.id === id ? { ...o, x: cell.cx, y: cell.cy } : o)), id);
      setDrag(null);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  };

  const startResize = (e: React.PointerEvent, it: WidgetItem) => {
    e.preventDefault();
    e.stopPropagation();
    const s = SPEC[it.type], at = px(cells[it.id]), sx = e.clientX, sy = e.clientY;
    let frame = 0, pending: PointerEvent | null = null, size = { w: shownW(it, cols), h: it.h };
    const auto = edgeScroll(() => pending?.clientY ?? null, () => { if (pending && !frame) frame = requestAnimationFrame(step); });
    const top0 = auto.top();
    const step = () => {
      frame = 0;
      const ev = pending!;
      const w = at.w + ev.clientX - sx, h = at.h + ev.clientY - sy + auto.top() - top0;
      const cw = clamp(Math.round((w + GAP) / (cellW + GAP)), Math.min(s.minW, cols), Math.min(s.maxW, cols, cols - cells[it.id].x));
      const ch = clamp(Math.round((h + GAP) / (ROW + GAP)), s.minH, s.maxH);
      if (cw !== size.w || ch !== size.h) { size = { w: cw, h: ch }; setSizing({ id: it.id, ...size }); }
    };
    const move = (ev: PointerEvent) => { pending = ev; if (!frame) frame = requestAnimationFrame(step); };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      window.removeEventListener("pointercancel", up);
      cancelAnimationFrame(frame);
      auto.stop();
      commit(live.current.map((o) => (o.id === it.id ? { ...o, w: size.w, h: size.h } : o)), it.id);
      setSizing(null);
    };
    setSizing({ id: it.id, ...size });
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    window.addEventListener("pointercancel", up);
  };

  return (
    <div ref={ref} className={`vp-board${ready ? " ready" : ""}${edit ? " edit" : ""}${drag ? " dragging" : ""}`} style={{ height: boardH }}>
      {drag && cells[drag.id] && (() => { const p = px(cells[drag.id]); return <div className="vp-slot" style={{ transform: `translate(${p.x}px, ${p.y}px)`, width: p.w, height: p.h }} />; })()}
      {width > 0 && items.map((it) => {
        const c = cells[it.id];
        if (!c) return null;
        const p = px(c), dragged = drag?.id === it.id, sized = sizing?.id === it.id;
        const s = SPEC[it.type];
        const canResize = Math.min(s.maxW, cols) > Math.min(s.minW, cols) || s.maxH > s.minH;
        return (
          <section key={it.id} className={`vp-widget vp-w-${it.type}${dragged ? " lifted" : ""}${sized ? " sizing" : ""}`} aria-label={s.name()}
            style={{ transform: `translate(${dragged ? drag.x : p.x}px, ${dragged ? drag.y : p.y}px)`, width: p.w, height: p.h }}
            onPointerDown={(e) => startDrag(e, it.id)}>
            {children(it, { w: c.w, h: c.h, px: p.w, py: p.h })}
            {edit && (
              <button type="button" className="vp-remove" aria-label={t("Remove")} title={t("Remove")} onClick={() => commit(items.filter((o) => o.id !== it.id))}>
                <IconMinus size={14} />
              </button>
            )}
            {edit && canResize && <div className="vp-grip" onPointerDown={(e) => startResize(e, it)} aria-hidden="true" />}
          </section>
        );
      })}
    </div>
  );
}

function useFade<T extends HTMLElement>() {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const check = () => {
      el.classList.toggle("more-below", el.scrollTop + el.clientHeight < el.scrollHeight - 2);
      el.classList.toggle("more-above", el.scrollTop > 2);
    };
    check();
    const ro = new ResizeObserver(check);
    ro.observe(el);
    for (const c of Array.from(el.children)) ro.observe(c);
    el.addEventListener("scroll", check, { passive: true });
    return () => { ro.disconnect(); el.removeEventListener("scroll", check); };
  });
  return ref;
}

export function MachinesWidget({ vms, current, size, onSwitch }: { vms: VmOverview[]; current: string; size: WidgetSize; onSwitch: (name: string) => void }) {
  const list = useMemo(() => vms.filter((v) => v.streaming).sort((a, b) => (a.name === current ? -1 : b.name === current ? 1 : 0)), [vms, current]);
  const cubesRef = useFade<HTMLDivElement>(), listRef = useFade<HTMLUListElement>();
  if (list.length <= 1) {
    return <WidgetEmpty icon={IconDeviceDesktop} title={t("No other machines")} />;
  }
  if (size.w === 1 || size.h === 1) {
    return (
      <div className={`vp-cubes vp-scroll${size.h >= 3 ? " big" : ""}`} ref={cubesRef}>
        {list.map((v) => {
          const here = v.name === current, on = v.state === "Running";
          const label = here ? v.name : `${on ? t("Switch to {name}", { name: v.name }) : t("Start {name}", { name: v.name })}`;
          return (
            <button key={v.name} type="button" className={here ? "here" : ""} title={label} aria-label={label} disabled={!here && !on && !v.fits} onClick={() => !here && onSwitch(v.name)}>
              <MiniCube machine={miniOf(v)} ghost={!on} />
            </button>
          );
        })}
      </div>
    );
  }
  return (
    <ul className={`vp-machines vp-scroll${size.h >= 3 ? " roomy" : ""}`} ref={listRef}>
      {list.map((v) => {
        const here = v.name === current, on = v.state === "Running", m = miniOf(v);
        const state = here ? t("Watching now") : on ? t("On") : t("Off");
        return (
          <li key={v.name} className={here ? "here" : ""}>
            <MiniCube machine={m} ghost={!on} />
            <span className="vp-machine-text">
              <span className="name">{v.name}</span>
              <span className="sub">{size.px >= 400 && m.cores ? `${state} · ${t("{n} threads", { n: m.cores })} · ${m.memoryGB} GB` : state}</span>
            </span>
            {!here && (
              <button type="button" className="vp-chip" disabled={!on && !v.fits} onClick={() => onSwitch(v.name)}>
                {on ? t("Switch") : t("Start")}
              </button>
            )}
          </li>
        );
      })}
    </ul>
  );
}

export function ActionsWidget({ size, fullScreen, overlay, onHome, onFullscreen, onOverlay, onDisconnect }: {
  size: WidgetSize; fullScreen: boolean; overlay: boolean; onHome: () => void; onFullscreen: () => void; onOverlay: () => void; onDisconnect: () => void;
}) {
  const actions: { icon: Icon; label: string; on?: boolean; run: () => void }[] = [
    { icon: IconHome, label: t("Home"), run: onHome },
    fullScreen ? { icon: IconArrowsMinimize, label: t("Inside GpuVM"), run: onFullscreen } : { icon: IconArrowsMaximize, label: t("Full screen"), run: onFullscreen },
    { icon: IconChartLine, label: t("Stats on the picture"), on: overlay, run: onOverlay },
    { icon: IconPlugConnectedX, label: t("Disconnect"), run: onDisconnect },
  ];
  const labels = size.h >= 2 && size.px >= 260, beside = labels && size.px >= 440;
  const perRow = !labels && size.h === 1 && size.px >= 200 ? 4 : 2;
  return (
    <div className={`vp-actions${labels ? (beside ? " labels" : " labels under") : ""}`} style={{ gridTemplateColumns: `repeat(${perRow}, minmax(0, 1fr))` }}>
      {actions.map((a) => (
        <button key={a.label} type="button" className={a.on ? "on" : ""} title={a.label} aria-label={a.label} aria-pressed={a.on} onClick={a.run}>
          <a.icon size={18} />{labels && <span>{a.label}</span>}
        </button>
      ))}
    </div>
  );
}

export interface SavedCapture { kind: "shot" | "clip" | "replay"; path: string; name: string; thumb: string | null; durationMs: number; at: number }
export interface CaptureState {
  recording: boolean;
  since: number;
  replay: boolean;
  last: SavedCapture | null;
  error: string;
}

const clock = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  const mm = String(Math.floor(s / 60) % 60).padStart(2, "0"), ss = String(s % 60).padStart(2, "0");
  return s >= 3600 ? `${Math.floor(s / 3600)}:${mm}:${ss}` : `${mm}:${ss}`;
};

function useNow(on: boolean) {
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    if (!on) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [on]);
  return now;
}

export function CaptureWidget({ size, state, onShot, onRecord, onReplay, onOpen, onReveal }: {
  size: WidgetSize; state: CaptureState; onShot: () => void; onRecord: () => void; onReplay: () => void;
  onOpen: (c: SavedCapture) => void; onReveal: (c: SavedCapture) => void;
}) {
  const now = useNow(state.recording || !!state.last);
  const labels = size.px >= 220, under = size.h >= 2 && size.px < 300;
  const replayTitle = state.replay ? t("Save the last 30 s") : t("Turn it on in Settings, in Captures");
  const buttons = (
    <div className={`vp-capture-buttons${labels ? (under ? " labels under" : " labels") : ""}`}>
      <button type="button" title={t("Screenshot")} aria-label={t("Screenshot")} onClick={onShot}>
        <IconCamera size={18} />{labels && <span>{t("Screenshot")}</span>}
      </button>
      <button type="button" className={state.recording ? "rec" : ""} title={state.recording ? t("Stop") : t("Record")} aria-label={state.recording ? t("Stop") : t("Record")} aria-pressed={state.recording} onClick={onRecord}>
        {state.recording ? <span className="vp-rec-dot" aria-hidden="true" /> : <IconVideo size={18} />}
        {state.recording
          ? <span>{labels && <>{t("Stop")} </>}<span className="vp-rec-time">{clock(now - state.since)}</span></span>
          : labels && <span>{t("Record")}</span>}
      </button>
      <button type="button" title={replayTitle} aria-label={replayTitle} disabled={!state.replay} onClick={onReplay}>
        <IconHistory size={18} />{labels && <span>{t("Save 30 s")}</span>}
      </button>
    </div>
  );
  if (size.h < 2) return <div className="vp-capture">{buttons}</div>;
  const last = state.last;
  const when = last ? (now - last.at < 60000 ? t("Just now") : t("{n} min ago", { n: Math.floor((now - last.at) / 60000) })) : "";
  return (
    <div className="vp-capture tall">
      {buttons}
      {state.error ? (
        <div className="vp-capture-last"><span className="vp-error">{state.error}</span></div>
      ) : last ? (
        <div className="vp-capture-last">
          <button type="button" className="vp-capture-thumb" title={t("Open")} aria-label={t("Open {name}", { name: last.name })} onClick={() => onOpen(last)}>
            {last.thumb ? <img src={last.thumb} alt="" draggable={false} /> : last.kind === "shot" ? <IconPhoto size={16} /> : <IconVideo size={16} />}
            {last.kind !== "shot" && last.durationMs > 0 && <small>{clock(last.durationMs)}</small>}
          </button>
          <span className="vp-machine-text">
            <span className="name" title={last.name}>{last.name}</span>
            <span className="sub">{when}</span>
          </span>
          <button type="button" className="vp-icon" title={t("Show in folder")} aria-label={t("Show in folder")} onClick={() => onReveal(last)}>
            <IconFolder size={15} />
          </button>
        </div>
      ) : (
        <div className="vp-capture-last empty"><span className="vp-empty-icon"><IconPhoto size={16} /></span><strong>{t("No captures yet")}</strong></div>
      )}
    </div>
  );
}

export interface ViewerStats { receivedFps: number; renderedFps: number; networkDropPercent: number; decodeMs: number; renderMs: number; hostLatencyMs: number; networkLatencyMs: number }

export function StatsWidget({ stats, history, size }: { stats: ViewerStats | null; history: number[]; size: WidgetSize }) {
  const ms = (n: number | undefined) => (n && n > 0 ? `${n.toLocaleString(locale(), { maximumFractionDigits: 1, minimumFractionDigits: 1 })} ms` : "—");
  const tall = size.h >= 2, wide = size.px >= 220;
  const rows: [string, string][] = tall || wide
    ? [[t("Network"), ms(stats?.networkLatencyMs)], [t("Machine"), ms(stats?.hostLatencyMs)]]
    : [[t("Latency"), ms(stats ? stats.networkLatencyMs + stats.hostLatencyMs : 0)]];
  if (tall) rows.push([wide ? t("Network loss") : t("Loss"), stats ? `${stats.networkDropPercent.toLocaleString(locale(), { maximumFractionDigits: 1, minimumFractionDigits: 1 })} %` : "—"]);
  if (size.h >= 3) rows.push([t("Decoding"), ms(stats?.decodeMs)]);
  const chartH = Math.min(size.h >= 3 ? 110 : 64, size.py - 48 - 18 * rows.length - 24);
  return (
    <div className={`vp-stats${tall ? " tall" : wide ? " side" : ""}`}>
      <div className="vp-big"><strong>{stats ? Math.round(stats.renderedFps) : "—"}</strong><span>{t("frames/s")}</span></div>
      {tall && chartH > 18 && <Spark values={history} height={chartH} />}
      <dl>{rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{v}</dd></div>)}</dl>
    </div>
  );
}

function Spark({ values, height }: { values: number[]; height: number }) {
  if (values.length < 2) return <div className="vp-spark" style={{ height }} />;
  const lo = Math.min(...values) - 2, hi = Math.max(...values) + 2;
  const pts = values.map((v, i) => `${(i / (values.length - 1)) * 100},${(1 - (v - lo) / (hi - lo)) * 100}`).join(" ");
  return (
    <svg className="vp-spark" style={{ height }} viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
      <polyline points={pts} fill="none" stroke="var(--accent)" strokeWidth="1.5" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
    </svg>
  );
}

export function ClockWidget({ size }: { size: WidgetSize }) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => {
    let timer = 0;
    const tick = () => { setNow(new Date()); timer = window.setTimeout(tick, 60000 - (Date.now() % 60000) + 50); };
    timer = window.setTimeout(tick, 60000 - (Date.now() % 60000) + 50);
    return () => clearTimeout(timer);
  }, []);
  const parts = new Intl.DateTimeFormat(locale(), { hour: "numeric", minute: "2-digit" }).formatToParts(now);
  const time = parts.filter((p) => p.type !== "dayPeriod").map((p) => p.value).join("").trim();
  const period = parts.find((p) => p.type === "dayPeriod")?.value;
  const wide = size.px >= 220;
  return (
    <div className={`vp-clock${size.h >= 2 ? " tall" : ""}`}>
      <span className="vp-time"><strong>{time}</strong>{period && <small>{period}</small>}</span>
      <span>{now.toLocaleDateString(locale(), wide ? { weekday: "long", day: "numeric", month: "long" } : { weekday: "short", day: "numeric", month: "short" })}</span>
    </div>
  );
}

function useAllDecor(names: string[]) {
  const key = names.join("|");
  const snap = useRef<{ key: string; figures: { id: string; figure: string; vm: string; color: string | null }[] } | null>(null);
  const light = usePrefs().theme;
  return useSyncExternalStore(onDecorChange, () => {
    const figures = names.flatMap((vm) => readDecor(vm).figures.filter((f) => FIGURES.some((d) => d.id === f.figure)).map((f) => ({ id: `${vm}:${f.id}`, figure: f.figure, vm, color: decorColor(vm) })));
    const sig = `${key}#${light}#${figures.map((f) => `${f.id}${f.figure}${f.color}`).join(",")}`;
    if (snap.current?.key !== sig) snap.current = { key: sig, figures };
    return snap.current.figures;
  });
}

function Figure({ figure, color, title, size: FIG }: { figure: string; color: string; title: string; size: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const dpr = window.devicePixelRatio || 1;
    cv.width = cv.height = Math.round(FIG * dpr);
    const g = cv.getContext("2d")!;
    const still = () => { g.setTransform(1, 0, 0, 1, 0, 0); g.clearRect(0, 0, cv.width, cv.height); g.drawImage(figureThumbImage(figure, FIG, color, dpr), 0, 0); };
    still();
    let frame = 0, yaw = 0.6, last = 0;
    const loop = (tm: number) => {
      if (last) yaw += Math.min(0.05, (tm - last) / 1000) * 1.2;
      last = tm;
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.clearRect(0, 0, cv.width, cv.height);
      drawFigureThumb(g, figure, FIG, yaw, color, dpr);
      frame = requestAnimationFrame(loop);
    };
    const enter = () => { last = 0; cancelAnimationFrame(frame); frame = requestAnimationFrame(loop); };
    const leave = () => { cancelAnimationFrame(frame); yaw = 0.6; still(); };
    cv.addEventListener("pointerenter", enter);
    cv.addEventListener("pointerleave", leave);
    return () => { cancelAnimationFrame(frame); cv.removeEventListener("pointerenter", enter); cv.removeEventListener("pointerleave", leave); };
  }, [figure, color, FIG]);
  return <canvas ref={ref} className="vp-figure" style={{ width: FIG, height: FIG }} title={title} aria-label={title} role="img" />;
}

export function ShelfWidget({ vms, size }: { vms: VmOverview[]; size: WidgetSize }) {
  const names = useMemo(() => vms.map((v) => v.name), [vms]);
  const figures = useAllDecor(names);
  const accent = useAccent();
  if (!figures.length) return <WidgetEmpty icon={IconBooks} title={t("No figures yet")} text={size.h >= 2 ? t("They go on each machine from Customize.") : undefined} />;
  const fig = Math.round(clamp((size.py - 12) / size.h - 14, 40, 84));
  const perRow = Math.max(1, Math.floor((size.px - 20) / (fig + 4)));
  const each = Math.min(perRow, Math.ceil(figures.length / size.h));
  const shelves = Array.from({ length: size.h }, (_, i) => figures.slice(i * each, (i + 1) * each));
  return (
    <div className="vp-shelf" style={{ gridTemplateRows: `repeat(${size.h}, minmax(0, 1fr))` }}>
      {shelves.map((row, i) => (
        <div key={i} className="vp-board-row">
          {row.map((f) => <Figure key={f.id} size={fig} figure={f.figure} color={f.color ?? accent} title={`${figureName(f.figure)} · ${f.vm}`} />)}
        </div>
      ))}
    </div>
  );
}

function useAccent() {
  const prefs = usePrefs();
  return useMemo(() => getComputedStyle(document.documentElement).getPropertyValue("--accent").trim() || "#7d9cf0", [prefs.theme, prefs.accent]); // eslint-disable-line react-hooks/exhaustive-deps
}

export function GamesWidget({ size, player, fallback, onPlay }: { size: WidgetSize; player: string; fallback: Decor; onPlay: (g: GameDef) => void }) {
  const ref = useFade<HTMLUListElement>(), coversRef = useFade<HTMLDivElement>();
  const record = (g: GameDef) => Math.max(bestScore(g.id), ...(g.modes ?? []).map((m) => bestScore(`${g.id}.${m.id}`)));
  if (size.w >= 2 && size.h >= 2) {
    const cols = size.px >= 500 ? 4 : 2, rows = cols === 2 ? 2 : 1;
    const cardW = (size.px - 12 - 8 * (cols - 1)) / cols;
    const cardH = (size.py - 12 - 8 * (rows - 1)) / rows;
    return (
      <div ref={coversRef} className="vp-covers vp-scroll" style={{ gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`, gridAutoRows: cardH }}>
        {GAMES.map((g) => {
          const best = record(g);
          return (
            <button key={g.id} type="button" className="vp-cover" aria-label={t("Play {name}", { name: g.name })} onClick={() => onPlay(g)}>
              <GameCover game={g} player={player} fallback={fallback} />
              <span className="vp-cover-row">
                <span className="vp-game-text">
                  <span className="name">{g.name}</span>
                  {cardH >= 130 && cardW >= 140 && <span className="sub">{best > 0 ? <><IconTrophy size={12} />{best.toLocaleString(locale())}</> : t("No record yet")}</span>}
                </span>
                <IconPlayerPlay size={15} className="vp-cover-play" />
              </span>
            </button>
          );
        })}
      </div>
    );
  }
  return (
    <ul ref={ref} className="vp-games vp-scroll" style={{ gridTemplateColumns: `repeat(${size.w >= 3 ? 2 : 1}, minmax(0, 1fr))` }}>
      {GAMES.map((g) => {
        const best = record(g);
        return (
          <li key={g.id}>
            <span className="vp-game-text">
              <span className="name">{g.name}</span>
              {size.w >= 2 && <span className="sub">{best > 0 ? <><IconTrophy size={12} />{best.toLocaleString(locale())}</> : t("No record yet")}</span>}
            </span>
            <button type="button" className="vp-icon" aria-label={t("Play {name}", { name: g.name })} title={t("Play {name}", { name: g.name })} onClick={() => onPlay(g)}>
              <IconPlayerPlay size={15} />
            </button>
          </li>
        );
      })}
    </ul>
  );
}

const covers = new Map<string, { url: string; width: number }>();
function GameCover({ game, player, fallback }: { game: GameDef; player: string; fallback: Decor }) {
  const theme = usePrefs().theme;
  const key = `${game.id}|${player}|${theme}`;
  const [still, setStill] = useState(() => covers.get(key)?.url ?? "");
  const [live, setLive] = useState(!covers.has(key));
  const box = useRef<HTMLSpanElement>(null);
  useEffect(() => { const c = covers.get(key); setStill(c?.url ?? ""); if (!c) setLive(true); }, [key]);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const c = covers.get(key);
      if (c && el.clientWidth * window.devicePixelRatio > c.width * 1.1) setLive(true);
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [key]);
  const hover = useRef(false);
  useEffect(() => {
    if (!live) return;
    const timer = window.setTimeout(() => {
      const cv = box.current?.querySelector("canvas");
      try { if (cv && cv.width) { const url = cv.toDataURL("image/webp", 0.9); covers.set(key, { url, width: cv.width }); setStill(url); } } catch {}
      if (!hover.current) setLive(false);
    }, 1400);
    return () => clearTimeout(timer);
  }, [live, key]);
  return (
    <span ref={box} className="vp-cover-art" onPointerEnter={() => { hover.current = true; setLive(true); }} onPointerLeave={() => { hover.current = false; if (covers.has(key)) setLive(false); }}>
      {still && <img src={still} alt="" draggable={false} />}
      {live && <GameDemo game={game} player={player || undefined} fallback={fallback} />}
    </span>
  );
}

/* Privacy: only the typed city name, then its coordinates, go to Open-Meteo; never the PC's location. */
const WEATHER_KEY = "gpuvm.weather";
interface Place { name: string; lat: number; lon: number }
interface Now { temp: number; code: number; day: boolean; at: number }
export const forgetWeather = () => { try { localStorage.removeItem(WEATHER_KEY); } catch {} };
const readPlace = (): Place | null => { try { const p = JSON.parse(localStorage.getItem(WEATHER_KEY) ?? "null"); return p && typeof p.lat === "number" ? p : null; } catch { return null; } };

async function getJson<T>(url: string): Promise<T> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 8000);
  try {
    const r = await fetch(url, { signal: ctl.signal, credentials: "omit", referrerPolicy: "no-referrer" });
    if (!r.ok) throw new Error(String(r.status));
    return await r.json() as T;
  } finally { clearTimeout(timer); }
}

function weatherLook(code: number, day: boolean): { icon: Icon; label: string } {
  if (code === 0 || code === 1) return { icon: day ? IconSun : IconMoon, label: t("Clear|weather") };
  if (code <= 3) return { icon: IconCloud, label: t("Cloudy") };
  if (code === 45 || code === 48) return { icon: IconCloudFog, label: t("Fog") };
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return { icon: IconCloudSnow, label: t("Snow") };
  if (code >= 95) return { icon: IconCloudStorm, label: t("Storm") };
  return { icon: IconCloudRain, label: t("Rain") };
}

export function WeatherWidget({ size, open }: { size: WidgetSize; open: boolean }) {
  const [place, setPlace] = useState<Place | null>(readPlace);
  const [now, setNow] = useState<Now | null>(null);
  const [asking, setAsking] = useState(false);
  const [city, setCity] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");

  useEffect(() => {
    if (!place || !open) return;
    let alive = true;
    const load = () => getJson<{ current: { temperature_2m: number; weather_code: number; is_day: number } }>(
      `https://api.open-meteo.com/v1/forecast?latitude=${place.lat.toFixed(2)}&longitude=${place.lon.toFixed(2)}&current=temperature_2m,weather_code,is_day`)
      .then((d) => { if (alive) { setNow({ temp: d.current.temperature_2m, code: d.current.weather_code, day: !!d.current.is_day, at: Date.now() }); setError(""); } })
      .catch(() => { if (alive) setError(t("No connection")); });
    if (!now || Date.now() - now.at > 30 * 60000) load();
    const timer = setInterval(load, 30 * 60000);
    return () => { alive = false; clearInterval(timer); };
  }, [place, open]); // eslint-disable-line react-hooks/exhaustive-deps

  const find = async (e: React.FormEvent) => {
    e.preventDefault();
    const q = city.trim();
    if (!q) { setError(t("Enter a city")); return; }
    setBusy(true); setError("");
    try {
      const r = await getJson<{ results?: { name: string; latitude: number; longitude: number }[] }>(
        `https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(q)}&count=1&language=${locale().slice(0, 2)}&format=json`);
      const hit = r.results?.[0];
      if (!hit) { setError(t("City not found")); return; }
      const p = { name: hit.name, lat: hit.latitude, lon: hit.longitude };
      try { localStorage.setItem(WEATHER_KEY, JSON.stringify(p)); } catch {}
      setNow(null); setPlace(p); setAsking(false); setCity("");
    } catch { setError(t("No connection")); } finally { setBusy(false); }
  };

  if (asking) {
    return (
      <form className="vp-weather-ask" onSubmit={find} data-nodrag>
        <input autoFocus value={city} placeholder={t("City")} aria-label={t("City")} onChange={(e) => { setCity(e.target.value); setError(""); }}
          onKeyDown={(e) => { if (e.key === "Escape") { e.stopPropagation(); setAsking(false); setError(""); } }} />
        <button type="submit" className="vp-icon" disabled={busy} aria-label={t("Search")} title={t("Search")}><IconCloudSearch size={16} /></button>
        {error && <span className="vp-error">{error}</span>}
      </form>
    );
  }
  if (!place) {
    return (
      <div className={`vp-weather${size.px < 220 || size.h >= 2 ? " stack" : ""}`}>
        <IconCloud size={size.h >= 2 ? 32 : 22} className="vp-weather-off" />
        <button type="button" className="vp-chip" onClick={() => setAsking(true)}>{t("Turn on weather")}</button>
      </div>
    );
  }
  const look = now ? weatherLook(now.code, now.day) : null;
  const Ico = look?.icon ?? IconCloud;
  return (
    <button type="button" className={`vp-weather${size.h >= 2 ? " tall" : ""}`} title={t("Change city")} onClick={() => setAsking(true)}>
      <Ico size={size.h >= 2 ? 40 : size.w >= 2 ? 30 : 24} className="vp-weather-icon" />
      <span className="vp-weather-text">
        <strong>{now ? `${Math.round(now.temp)}°` : "—"}</strong>
        {size.h >= 2 && look && <span>{look.label}</span>}
        <span>{error && !now ? error : size.w >= 2 && size.h === 1 && look ? `${place.name} · ${look.label}` : place.name}</span>
      </span>
    </button>
  );
}

function WidgetEmpty({ icon: Ico, title, text }: { icon: Icon; title: string; text?: string }) {
  return (
    <div className="vp-empty">
      <span className="vp-empty-icon"><Ico size={18} /></span>
      <strong>{title}</strong>
      {text && <span>{text}</span>}
    </div>
  );
}

export function WidgetTray({ items, onAdd, onReset }: { items: WidgetItem[]; onAdd: (type: WidgetType) => void; onReset: () => void }) {
  const missing = missingWidgets(items);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => { ref.current?.scrollIntoView({ block: "nearest", behavior: "smooth" }); }, []);
  return (
    <div ref={ref} className="vp-tray">
      {missing.map((type) => {
        const s = SPEC[type];
        return (
          <button key={type} type="button" className="vp-chip" onClick={() => onAdd(type)}>
            <IconPlus size={14} /><s.icon size={15} className="vp-tray-icon" />{s.name()}
          </button>
        );
      })}
      <button type="button" className="vp-chip ghost" onClick={onReset}>{t("Reset")}</button>
    </div>
  );
}
