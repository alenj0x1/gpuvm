import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { PixelScene, type PixelSceneKind } from "./PixelScene";
import chrome from "./assets/apps/chrome.png";
import steam from "./assets/apps/steam.png";
import discord from "./assets/apps/discord.png";
import spotify from "./assets/apps/spotify.svg";
import brave from "./assets/apps/brave.png";
import firefox from "./assets/apps/firefox.png";
import vlc from "./assets/apps/vlc.png";
import obs from "./assets/apps/obs.png";
import epic from "./assets/apps/epic.png";

// A machine's screen for the website (2026-11-21, asked by the person): the machine's pixel landscape as wallpaper with
// a Windows desktop on it (icons, the taskbar with its clock, an open window), different for each sample machine so
// switching machines shows another Windows. Used wherever the site shows a machine's picture (the viewer, agents).
// Windows' own marks are drawn faithfully; the apps use their real icons.

type Os = "win10" | "win11";
interface Desk { scene: PixelSceneKind; os: Os; icons: [string, string][]; pinned: string[]; window: "terminal" | "explorer" | "notes" | "paint" | null }

const RECYCLE = "recycle", FOLDER = "folder", TERMINAL = "terminal", EXPLORER = "explorer", NOTEPAD = "notepad", PAINT = "paint";
const APP: Record<string, string> = { chrome, steam, discord, spotify, brave, firefox, vlc, obs, epic };

export const DESKS: Record<string, Desk> = {
  win10: { scene: "sakura", os: "win10", icons: [[RECYCLE, "Papelera"], [steam, "Steam"], [epic, "Epic Games"], [discord, "Discord"], [FOLDER, "Recibidos"]],
    pinned: [EXPLORER, chrome, steam, discord, spotify], window: "terminal" },
  "win11-pruebas": { scene: "forest", os: "win11", icons: [[RECYCLE, "Papelera"], [FOLDER, "Recibidos"], [brave, "Brave"], [FOLDER, "Proyectos"]],
    pinned: [EXPLORER, brave, firefox, TERMINAL, vlc], window: "explorer" },
  estudio: { scene: "alpine", os: "win11", icons: [[RECYCLE, "Papelera"], [obs, "OBS Studio"], [spotify, "Spotify"], [vlc, "VLC"]],
    pinned: [EXPLORER, chrome, obs, spotify, NOTEPAD], window: "notes" },
  agent: { scene: "forest", os: "win11", icons: [[RECYCLE, "Papelera"], [FOLDER, "Received"], [FOLDER, "Outbox"]],
    pinned: [EXPLORER, PAINT, TERMINAL], window: "paint" },
};

function Glyph({ id, size = 22 }: { id: string; size?: number }) {
  if (APP[id] || id.includes("/") || id.startsWith("data:")) return <img src={APP[id] ?? id} width={size} height={size} alt="" draggable={false} />;
  switch (id) {
    case FOLDER: case EXPLORER:
      return <svg width={size} height={size} viewBox="0 0 24 24"><path d="M2 6.5A1.5 1.5 0 0 1 3.5 5h5l2 2h10A1.5 1.5 0 0 1 22 8.5V18a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18z" fill="#f2b636" /><path d="M2 9.5h20V18a1.5 1.5 0 0 1-1.5 1.5h-17A1.5 1.5 0 0 1 2 18z" fill="#ffd46b" />{id === EXPLORER && <rect x="5" y="12" width="14" height="2" rx="1" fill="#3e8ede" />}</svg>;
    case RECYCLE:
      return <svg width={size} height={size} viewBox="0 0 24 24"><path d="M6 7h12l-1.2 13a1.5 1.5 0 0 1-1.5 1.3H8.7a1.5 1.5 0 0 1-1.5-1.3z" fill="#d9e6f2" stroke="#8fa9c2" strokeWidth=".8" /><rect x="5" y="4.5" width="14" height="2.5" rx="1" fill="#b9cde0" /><path d="M10 10v8M14 10v8" stroke="#8fa9c2" strokeWidth="1" /></svg>;
    case TERMINAL:
      return <svg width={size} height={size} viewBox="0 0 24 24"><rect x="2" y="4" width="20" height="16" rx="3" fill="#2b2b2b" /><path d="M6 9l3 3-3 3" stroke="#e9e9e9" strokeWidth="1.8" fill="none" strokeLinecap="round" /><path d="M11 15h6" stroke="#e9e9e9" strokeWidth="1.8" strokeLinecap="round" /></svg>;
    case NOTEPAD:
      return <svg width={size} height={size} viewBox="0 0 24 24"><rect x="4" y="3" width="16" height="18" rx="2" fill="#7fc0f0" /><rect x="6" y="6" width="12" height="13" rx="1" fill="#fff" /><path d="M8 9h8M8 12h8M8 15h5" stroke="#9aa7b3" strokeWidth="1.2" /></svg>;
    case PAINT:
      return <svg width={size} height={size} viewBox="0 0 24 24"><path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 1.5-2-.6-1.2.2-2.5 1.6-2.5H17a4 4 0 0 0 4-4C21 7 17 3 12 3z" fill="#f6efe2" stroke="#c9b48c" strokeWidth=".8" /><circle cx="8" cy="10" r="1.6" fill="#e5483f" /><circle cx="12" cy="7.5" r="1.6" fill="#f2b636" /><circle cx="16" cy="10" r="1.6" fill="#2f5bd3" /><circle cx="9" cy="14.5" r="1.6" fill="#2f9e6a" /></svg>;
    default: return null;
  }
}

function WinLogo({ os }: { os: Os }) {
  return os === "win11"
    ? <svg width="18" height="18" viewBox="0 0 16 16"><rect x="1" y="1" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="8.4" y="1" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="1" y="8.4" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="8.4" y="8.4" width="6.6" height="6.6" fill="#3b9bf0" /></svg>
    : <svg width="16" height="16" viewBox="0 0 16 16"><path d="M0 2.3 6.5 1.4v6.1H0zM7.3 1.3 16 0v7.5H7.3zM0 8.3h6.5v6.2L0 13.6zM7.3 8.3H16V16l-8.7-1.2z" fill="#fff" /></svg>;
}

function Clock() {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => { const id = setInterval(() => setNow(new Date()), 15000); return () => clearInterval(id); }, []);
  return <span className="md-clock"><b>{now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</b><small>{now.toLocaleDateString([], { day: "2-digit", month: "2-digit", year: "numeric" })}</small></span>;
}

type Kind = NonNullable<Desk["window"]>;
interface Box { x: number; y: number; w: number; h: number }
/** Each window's smallest size, so its text never breaks, and where it opens (fractions of the desktop). */
const MIN: Record<Kind, [number, number]> = { terminal: [300, 120], explorer: [330, 180], notes: [240, 130], paint: [360, 240] };
const START: Record<Kind, [number, number, number, number]> = { terminal: [0.24, 0.1, 0.52, 0.36], explorer: [0.22, 0.12, 0.56, 0.5], notes: [0.26, 0.1, 0.48, 0.36], paint: [0.08, 0.05, 0.84, 0.8] };
const ICON_OF: Record<Kind, string> = { terminal: TERMINAL, explorer: EXPLORER, notes: NOTEPAD, paint: PAINT };
const BAR = 34;

interface WinProps {
  kind: Kind; os: Os; box: Box; max: boolean; front: boolean; locked: boolean;
  onFocus(): void; onMove(b: Box): void; onMin(): void; onMax(): void; onClose(): void; bounds(): { w: number; h: number };
}

function Window({ kind, os, box, max, front, locked, onFocus, onMove, onMin, onMax, onClose, bounds }: WinProps) {
  const title = { terminal: "Windows PowerShell", explorer: "Recibidos", notes: "notas.txt: Bloc de notas", paint: "Sin título: Paint" }[kind];
  // Dragging the title bar moves it; an edge or the corner resizes it, never below its minimum nor out of the desktop.
  const drag = (e: ReactPointerEvent, mode: "move" | "e" | "s" | "se") => {
    if (locked || e.button !== 0) return;
    e.preventDefault(); e.stopPropagation();
    onFocus();
    const from = { x: e.clientX, y: e.clientY, b: box };
    const el = e.currentTarget as HTMLElement;
    el.setPointerCapture(e.pointerId);
    const [mw, mh] = MIN[kind];
    const move = (ev: PointerEvent) => {
      const { w: W, h: H } = bounds();
      const dx = ev.clientX - from.x, dy = ev.clientY - from.y;
      let { x, y, w, h } = from.b;
      if (mode === "move") {
        x = Math.min(W - 80, Math.max(80 - w, x + dx));
        y = Math.min(H - BAR - 28, Math.max(0, y + dy));
      } else {
        if (mode !== "s") w = Math.max(mw, Math.min(W - x, w + dx));
        if (mode !== "e") h = Math.max(mh, Math.min(H - BAR - y, h + dy));
      }
      onMove({ x, y, w, h });
    };
    const up = () => { el.removeEventListener("pointermove", move); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up); };
    el.addEventListener("pointermove", move); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };
  const style = max ? { left: 0, top: 0, width: "100%", height: `calc(100% - ${BAR}px)` } : { left: box.x, top: box.y, width: box.w, height: box.h };
  return (
    <div className={`md-window ${kind} ${os}${max ? " max" : ""}${front ? " front" : ""}`} style={{ ...style, zIndex: front ? 3 : 2 }} onPointerDown={onFocus}>
      <div className="md-titlebar" onPointerDown={(e) => !max && drag(e, "move")} onDoubleClick={() => !locked && onMax()}>
        <Glyph id={ICON_OF[kind]} size={14} /><span>{title}</span>
        <button type="button" className="md-ctl" aria-label="Minimizar" onPointerDown={(e) => e.stopPropagation()} onClick={onMin}>─</button>
        <button type="button" className="md-ctl" aria-label="Maximizar" onPointerDown={(e) => e.stopPropagation()} onClick={onMax}>{max ? "❐" : "☐"}</button>
        <button type="button" className="md-ctl x" aria-label="Cerrar" onPointerDown={(e) => e.stopPropagation()} onClick={onClose}>✕</button>
      </div>
      {kind === "terminal" && (
        <pre className="md-term">{`PS C:\\Users\\Ale> nvidia-smi --query-gpu=name,memory.used --format=csv
name, memory.used [MiB]
NVIDIA GeForce RTX 4060, 1342 MiB
PS C:\\Users\\Ale> `}<span className="md-caret" /></pre>
      )}
      {kind === "explorer" && (
        <div className="md-explorer">
          <div className="md-side">{["Inicio", "Escritorio", "Descargas", "Documentos", "Imágenes"].map((n) => <span key={n}><Glyph id={FOLDER} size={13} />{n}</span>)}</div>
          <div className="md-files">
            <div className="md-file head"><span>Nombre</span><span>Tamaño</span></div>
            {[["informe-pruebas.md", "18 KB"], ["capturas", ""], ["GpuVM_1.0.0_x64-setup.exe", "119 MB"], ["notas-reunion.txt", "3 KB"]].map(([n, s]) => (
              <div className="md-file" key={n}><span><Glyph id={s ? NOTEPAD : FOLDER} size={13} />{n}</span><span>{s}</span></div>
            ))}
          </div>
        </div>
      )}
      {kind === "notes" && <div className="md-notes">{"Ideas para el video\n- Abrir con la toma del lago\n- Música: algo tranquilo\n- Exportar en 1440p"}</div>}
      {kind === "paint" && <div className="md-paint"><div className="md-paint-tools">{["#23252a", "#e5483f", "#f2b636", "#2f9e6a", "#2f5bd3", "#ffffff"].map((c) => <i key={c} style={{ background: c }} />)}</div><div className="md-canvas" /></div>}
      {!max && !locked && <>
        <span className="md-grip e" onPointerDown={(e) => drag(e, "e")} />
        <span className="md-grip s" onPointerDown={(e) => drag(e, "s")} />
        <span className="md-grip se" onPointerDown={(e) => drag(e, "se")} />
      </>}
    </div>
  );
}

const CSS = `
.md { position: absolute; inset: 0; overflow: hidden; font-family: "Segoe UI Variable", "Segoe UI", system-ui, sans-serif; color: #fff; user-select: none; }
.md > .pixel-scene { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; image-rendering: pixelated; }
.md-icons { position: absolute; left: 1.2%; top: 2%; display: grid; gap: 4px; }
.md-icon { display: grid; justify-items: center; gap: 3px; width: 64px; padding: 4px 2px; border-radius: 3px; border: 1px solid transparent; font-size: 10.5px; text-align: center; line-height: 1.15; text-shadow: 0 0 2px #000, 0 1px 3px #000c; }
.md-icon img, .md-icon svg { display: block; width: 28px; height: 28px; }
.md-icon:hover { background: rgba(255,255,255,.12); } .md-icon.sel { background: rgba(120,180,255,.3); border-color: rgba(160,205,255,.6); }
.md-bar { position: absolute; z-index: 5; left: 0; right: 0; bottom: 0; height: 34px; display: flex; align-items: center; gap: 2px; padding: 0 6px; background: rgba(28, 28, 30, .92); }
.md-bar.win11 { justify-content: center; background: rgba(36, 38, 44, .88); }
.md-bar .md-pin { display: grid; place-items: center; width: 32px; height: 28px; border-radius: 4px; }
.md-bar .md-pin.open { background: rgba(255,255,255,.08); box-shadow: inset 0 -2px 0 #6cb4ff; }
.md-bar .md-pin.min { box-shadow: inset 0 -2px 0 #8a8a8a; } .md-bar .md-pin:hover { background: rgba(255,255,255,.12); }
.md-bar img, .md-bar svg { display: block; width: 18px; height: 18px; }
.md-search { display: flex; align-items: center; height: 24px; width: 150px; padding: 0 8px; margin: 0 4px; background: #2e2e30; color: #b9b9b9; font-size: 10.5px; }
.md-bar.win11 .md-search { width: 110px; border-radius: 12px; background: rgba(255,255,255,.08); }
.md-tray { position: absolute; right: 8px; display: flex; align-items: center; gap: 8px; font-size: 10px; }
.md-clock { display: grid; justify-items: end; line-height: 1.1; } .md-clock b { font-weight: 400; } .md-clock small { font-size: 9px; color: #ddd; }
.md-window { position: absolute; display: flex; flex-direction: column; background: #fff; color: #1f1f1f; border-radius: 6px; overflow: hidden; box-shadow: 0 0 0 1px rgba(0,0,0,.25); font-size: 11px; }
.md-window > :not(.md-titlebar):not(.md-grip) { flex: 1; min-height: 0; overflow: hidden; }
.md-window.max { border-radius: 0; }
.md-window:not(.front) .md-titlebar { color: #8a8a8a; }
.md-window.win10 { border-radius: 0; }
.md-titlebar { display: flex; align-items: center; gap: 6px; height: 26px; flex: none; padding-left: 8px; background: #f3f3f3; font-size: 11px; cursor: default; touch-action: none; }
.md-titlebar span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.md-ctl { width: 34px; height: 100%; padding: 0; border: 0; background: transparent; text-align: center; color: #444; font: inherit; font-size: 10px; cursor: default; }
.md-ctl:hover { background: rgba(0,0,0,.07); } .md-ctl.x:hover { background: #c42b1c; color: #fff; }
.md-grip { position: absolute; touch-action: none; } .md-grip.e { top: 0; right: 0; width: 6px; height: 100%; cursor: ew-resize; }
.md-grip.s { left: 0; bottom: 0; width: 100%; height: 6px; cursor: ns-resize; } .md-grip.se { right: 0; bottom: 0; width: 14px; height: 14px; cursor: nwse-resize; }
.md-window.terminal .md-titlebar { background: #1f1f1f; color: #eee; } .md-window.terminal .md-ctl { color: #ccc; } .md-window.terminal .md-ctl:not(.x):hover { background: rgba(255,255,255,.1); }
.md-term { margin: 0; padding: 8px 10px 12px; overflow: auto !important; background: #012456; color: #eaeaea; font: 10.5px/1.5 Consolas, "Cascadia Mono", monospace; white-space: pre-wrap; }
.md-caret { display: inline-block; width: 6px; height: 11px; background: #eaeaea; vertical-align: -1px; animation: md-blink 1s steps(1) infinite; }
@keyframes md-blink { 50% { opacity: 0; } }
.md-explorer { display: grid; grid-template-columns: 110px minmax(0, 1fr); }
.md-side { display: grid; align-content: start; gap: 2px; padding: 6px; background: #f7f7f7; border-right: 1px solid #e5e5e5; }
.md-side span, .md-file span:first-child { display: flex; align-items: center; gap: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.md-files { padding: 4px 8px; } .md-file { display: grid; grid-template-columns: 1fr 60px; padding: 4px 2px; border-bottom: 1px solid #f0f0f0; } .md-file.head { color: #6b6b6b; font-size: 10px; }
.md-file span:last-child { color: #6b6b6b; text-align: right; }
.md-notes { padding: 10px 12px 18px; white-space: pre-wrap; font: 11.5px/1.55 Consolas, monospace; }
.md-paint { display: grid; grid-template-rows: auto 1fr; } .md-paint-tools { display: flex; gap: 5px; padding: 6px 10px; background: #f3f3f3; border-bottom: 1px solid #e3e3e3; } .md-paint-tools i { width: 14px; height: 14px; border-radius: 50%; box-shadow: inset 0 0 0 1px #0002; }
.md-canvas { margin: 10px; background: #fff; box-shadow: 0 0 0 1px #d9d9d9; }
.md-window.paint .md-paint { background: #e9edf2; }
.md-over { position: absolute; z-index: 4; inset: 0 0 34px 0; pointer-events: none; }
@media (max-width: 560px) { .md-icons { display: none; } .md-search { display: none; } }
`;

/** Which window a desktop icon opens (folders open the Explorer); apps only get selected. */
const OPENS: Record<string, Kind> = { [FOLDER]: "explorer", [EXPLORER]: "explorer", [TERMINAL]: "terminal", [NOTEPAD]: "notes", [PAINT]: "paint" };

interface Win { kind: Kind; box: Box; min: boolean; max: boolean }

/** The machine `vm`'s screen; `children` go over the desktop (the agent's overlay, for one). It can be used like a
 *  desktop: windows move, resize (never below the size their text needs), minimize, maximize and close; icons are
 *  selected with a click and folders open with a double click; the taskbar brings windows back. `locked`: the windows
 *  stay where they are (under an agent's overlay, whose strokes are drawn where the window is). */
export function MachineDesktop({ vm, children, locked }: { vm: string; children?: ReactNode; locked?: boolean }) {
  const d = DESKS[vm] ?? DESKS.win10;
  const ref = useRef<HTMLDivElement>(null);
  const [wins, setWins] = useState<Win[]>([]);
  const [order, setOrder] = useState<Kind[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const bounds = () => ({ w: ref.current?.clientWidth || 800, h: ref.current?.clientHeight || 450 });
  const place = (kind: Kind): Box => {
    const { w: W, h: H } = bounds();
    const [fx, fy, fw, fh] = START[kind], [mw, mh] = MIN[kind];
    const w = Math.min(W, Math.max(mw, W * fw)), h = Math.min(H - BAR, Math.max(mh, (H - BAR) * fh));
    return { x: Math.max(0, Math.min(W - w, W * fx)), y: Math.max(0, Math.min(H - BAR - h, (H - BAR) * fy)), w, h };
  };
  // A new machine starts with its own window where it belongs.
  useLayoutEffect(() => {
    setWins(d.window ? [{ kind: d.window, box: place(d.window), min: false, max: false }] : []);
    setOrder(d.window ? [d.window] : []);
    setSelected(null);
  }, [vm]); // eslint-disable-line react-hooks/exhaustive-deps
  const front = order[order.length - 1];
  const focus = (k: Kind) => setOrder((o) => [...o.filter((x) => x !== k), k]);
  const update = (k: Kind, f: (w: Win) => Win) => setWins((list) => list.map((w) => (w.kind === k ? f(w) : w)));
  const open = (k: Kind) => {
    setWins((list) => (list.some((w) => w.kind === k) ? list.map((w) => (w.kind === k ? { ...w, min: false } : w)) : [...list, { kind: k, box: place(k), min: false, max: false }]));
    focus(k);
  };
  const pin = (k: Kind) => {
    const w = wins.find((x) => x.kind === k);
    if (w && !w.min && front === k) update(k, (x) => ({ ...x, min: true }));
    else open(k);
  };
  return (
    <div className="md" ref={ref} onPointerDown={(e) => { if (e.target === e.currentTarget || (e.target as HTMLElement).classList.contains("pixel-scene")) setSelected(null); }}>
      <style>{CSS}</style>
      <PixelScene scene={d.scene} />
      <div className="md-icons">{d.icons.map(([g, n]) => (
        <div key={n} className={`md-icon${selected === n ? " sel" : ""}`} onPointerDown={(e) => { e.stopPropagation(); setSelected(n); }}
          onDoubleClick={() => { const k = OPENS[g]; if (k && !locked) open(k); }}>
          <Glyph id={g} size={28} /><span>{n}</span>
        </div>
      ))}</div>
      {wins.filter((w) => !w.min).map((w) => (
        <Window key={w.kind} kind={w.kind} os={d.os} box={w.box} max={w.max} front={front === w.kind} locked={!!locked} bounds={bounds}
          onFocus={() => focus(w.kind)} onMove={(box) => update(w.kind, (x) => ({ ...x, box }))}
          onMin={() => update(w.kind, (x) => ({ ...x, min: true }))} onMax={() => update(w.kind, (x) => ({ ...x, max: !x.max }))}
          onClose={() => setWins((list) => list.filter((x) => x.kind !== w.kind))} />
      ))}
      <div className={`md-bar ${d.os}`}>
        <span className="md-pin"><WinLogo os={d.os} /></span>
        <span className="md-search">{d.os === "win11" ? "Buscar" : "Escribe aquí para buscar"}</span>
        {d.pinned.map((p) => {
          const k = OPENS[p];
          const w = k && wins.find((x) => x.kind === k);
          return <span key={p} className={`md-pin${w ? (w.min ? " min" : " open") : ""}`} onClick={() => k && !locked && pin(k)}><Glyph id={p} size={18} /></span>;
        })}
        <span className="md-tray"><Clock /></span>
      </div>
      {children && <div className="md-over">{children}</div>}
    </div>
  );
}
