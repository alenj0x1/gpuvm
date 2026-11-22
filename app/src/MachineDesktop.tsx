import { useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent, type ReactNode } from "react";
import { PixelScene, type PixelSceneKind } from "./PixelScene";
import { getLang, type Lang } from "./i18n";
import chrome from "./assets/apps/chrome.png";
import steam from "./assets/apps/steam.png";
import discord from "./assets/apps/discord.png";
import spotify from "./assets/apps/spotify.svg";
import brave from "./assets/apps/brave.png";
import firefox from "./assets/apps/firefox.png";
import vlc from "./assets/apps/vlc.png";
import obs from "./assets/apps/obs.png";
import epic from "./assets/apps/epic.png";

type Os = "win10" | "win11";
export type Kind = "terminal" | "explorer" | "notes" | "paint" | "browser";
interface Desk { scene: PixelSceneKind; os: Os; icons: [string, string][]; pinned: string[]; window: Kind | null }

const RECYCLE = "recycle", FOLDER = "folder", TERMINAL = "terminal", EXPLORER = "explorer", NOTEPAD = "notepad", PAINT = "paint";
const APP: Record<string, string> = { chrome, steam, discord, spotify, brave, firefox, vlc, obs, epic };
const BROWSERS = new Set([chrome, brave, firefox]);
export const GLYPHS = { chrome, vlc, terminal: TERMINAL, paint: PAINT, explorer: EXPLORER };

const TEXT = {
  es: {
    recycle: "Papelera", received: "Recibidos", projects: "Proyectos", outbox: "Outbox", vlc: "VLC media player",
    search10: "Escribe aquí para buscar", search11: "Buscar", min: "Minimizar", max: "Maximizar", close: "Cerrar",
    notepad: "Bloc de notas", untitled: "Sin título", newTab: "Nueva pestaña", addressHint: "Buscar o escribir una dirección web",
    side: ["Inicio", "Escritorio", "Descargas", "Documentos", "Imágenes"], name: "Nombre", size: "Tamaño",
    notes: "Ideas para el video\n- Abrir con la toma del lago\n- Música: algo tranquilo\n- Exportar en 1440p", notesFile: "notas.txt",
    help: "Prueba: nvidia-smi, dir, whoami, hostname, echo, cls",
    unknown: (c: string) => `${c}: El término '${c}' no se reconoce como nombre de un cmdlet, función, archivo de script o programa ejecutable.`,
    siteSearch: "Buscar videos", play: "Reproducir", pause: "Pausa",
  },
  en: {
    recycle: "Recycle Bin", received: "Received", projects: "Projects", outbox: "Outbox", vlc: "VLC media player",
    search10: "Type here to search", search11: "Search", min: "Minimize", max: "Maximize", close: "Close",
    notepad: "Notepad", untitled: "Untitled", newTab: "New tab", addressHint: "Search or type a web address",
    side: ["Home", "Desktop", "Downloads", "Documents", "Pictures"], name: "Name", size: "Size",
    notes: "Video ideas\n- Open with the lake shot\n- Music: something calm\n- Export at 1440p", notesFile: "notes.txt",
    help: "Try: nvidia-smi, dir, whoami, hostname, echo, cls",
    unknown: (c: string) => `${c}: The term '${c}' is not recognized as the name of a cmdlet, function, script file, or operable program.`,
    siteSearch: "Search videos", play: "Play", pause: "Pause",
  },
};
type Texts = (typeof TEXT)["es"];
const label = (tx: Texts, key: string) => (key in tx && typeof tx[key as keyof Texts] === "string" ? (tx[key as keyof Texts] as string) : key);

const FILES: Record<Lang, { name: string; size: string; text?: string }[]> = {
  es: [
    { name: "informe-pruebas.md", size: "18 KB", text: "# Prueba del instalador\n\n- Instaló en 41 s, sin errores\n- La app abrió y detectó la GPU\n- Capturas en la carpeta capturas" },
    { name: "capturas", size: "" },
    { name: "GpuVM_1.0.0_x64-setup.exe", size: "119 MB" },
    { name: "notas-reunion.txt", size: "3 KB", text: "Reunión del viernes\n- Revisar los tiempos de apertura\n- Probar con dos máquinas a la vez" },
  ],
  en: [
    { name: "test-report.md", size: "18 KB", text: "# Installer test\n\n- Installed in 41 s, no errors\n- The app opened and found the GPU\n- Screenshots in the screenshots folder" },
    { name: "screenshots", size: "" },
    { name: "GpuVM_1.0.0_x64-setup.exe", size: "119 MB" },
    { name: "meeting-notes.txt", size: "3 KB", text: "Friday meeting\n- Review the opening times\n- Try two machines at once" },
  ],
};

export const VIDEOS: { scene: PixelSceneKind; length: number; title: Record<Lang, string> }[] = [
  { scene: "alpine", length: 252, title: { es: "Amanecer en el lago alpino", en: "Dawn at the alpine lake" } },
  { scene: "sakura", length: 185, title: { es: "Cerezos al atardecer", en: "Cherry trees at sunset" } },
  { scene: "forest", length: 400, title: { es: "Bosque con niebla", en: "Misty forest" } },
];
export const SITE = "videos.example";

export const DESKS: Record<string, Desk> = {
  win10: { scene: "sakura", os: "win10", icons: [[RECYCLE, "recycle"], [steam, "Steam"], [epic, "Epic Games"], [discord, "Discord"], [FOLDER, "received"]],
    pinned: [EXPLORER, chrome, steam, discord, spotify], window: "terminal" },
  "win11-pruebas": { scene: "forest", os: "win11", icons: [[RECYCLE, "recycle"], [FOLDER, "received"], [brave, "Brave"], [FOLDER, "projects"]],
    pinned: [EXPLORER, brave, firefox, TERMINAL, vlc], window: "explorer" },
  estudio: { scene: "alpine", os: "win11", icons: [[RECYCLE, "recycle"], [obs, "OBS Studio"], [spotify, "Spotify"], [vlc, "VLC"]],
    pinned: [EXPLORER, chrome, obs, spotify, NOTEPAD], window: "notes" },
  agent: { scene: "forest", os: "win11", icons: [[RECYCLE, "recycle"], [FOLDER, "received"], [FOLDER, "outbox"]],
    pinned: [EXPLORER, chrome, PAINT, TERMINAL], window: "paint" },
};

export interface Box { x: number; y: number; w: number; h: number }
type Point = [number, number];
export type Frac = [number, number, number, number];
export const BAR = 34;
const TITLE = 26;
export const stageBox = (at: Frac, W: number, H: number): Box => ({ x: Math.round(W * at[0]), y: Math.round(H * at[1]), w: Math.round(W * at[2]), h: Math.round(H * at[3]) });

export const PAINT_COLORS = ["#23252a", "#ffffff", "#1d2654", "#56619f", "#161c40", "#9cc3f0", "#f7d774", "#fff4cc", "#b5483e", "#7a5240", "#ffc857", "#3c4a86"];
export const PAINT_TOOLS = ["pencil", "bucket", "brush"] as const;
export type PaintTool = (typeof PAINT_TOOLS)[number];
const P_TOOLS = 34, P_PAD = 10, P_TOOL_X = 8, P_TOOL_STEP = 24, P_CURRENT_X = 95, P_SWATCH_X = 122, P_SWATCH = 11;
const swatchStep = (w?: number) => (w !== undefined && w < 330 ? 13 : 15);
export function paintLayout(b: Box) {
  const mid = b.y + TITLE + P_TOOLS / 2;
  return {
    canvas: { x: b.x + P_PAD, y: b.y + TITLE + P_TOOLS + P_PAD, w: b.w - 2 * P_PAD, h: b.h - TITLE - P_TOOLS - 2 * P_PAD } as Box,
    tool: (t: PaintTool): Point => [b.x + P_TOOL_X + PAINT_TOOLS.indexOf(t) * P_TOOL_STEP + 11, mid],
    swatch: (i: number): Point => [b.x + P_SWATCH_X + i * swatchStep(b.w) + P_SWATCH / 2, mid],
  };
}

export function browserLayout(b: Box) {
  const address: Box = { x: b.x + 8, y: b.y + TITLE + 4, w: b.w - 16, h: 26 };
  const page: Box = { x: b.x, y: b.y + TITLE + 34, w: b.w, h: b.h - TITLE - 34 };
  const cols = page.w >= 300 ? 3 : 2, gap = 10, tw = (page.w - 24 - gap * (cols - 1)) / cols;
  const thumbs: Box[] = Array.from({ length: cols }, (_, i) => ({ x: page.x + 12 + i * (tw + gap), y: page.y + 44, w: tw, h: (tw * 9) / 16 }));
  const maxW = page.w - 24;
  let pw = Math.min(maxW, ((page.h - 50) * 16) / 9);
  const side = maxW * 0.3 >= 110;
  if (side) pw = Math.min(pw, maxW * 0.68);
  const player: Box = { x: page.x + 12, y: page.y + 10, w: pw, h: (pw * 9) / 16 };
  return { address, page, thumbs, player, side, play: [player.x + player.w / 2, player.y + player.h / 2] as Point };
}

export interface PaintStage { color?: number; tool?: PaintTool; background?: string; fills?: { pts: Point[]; color: string }[]; title?: string }
export interface TermStage { lines: string[]; input: string }
const BAR_MARK = "\u0001";
export const termBar = (done: number, cells: number, text: string) => `${BAR_MARK}${done}|${cells}|${text}`;
export interface BrowserStage { address: string; editing?: boolean; page: "new" | "site" | "video"; playing?: boolean }
export interface StageWindow { kind: Kind; at: Frac; paint?: PaintStage; term?: TermStage; browser?: BrowserStage }
export interface Stage { windows: StageWindow[]; icons?: [string, string][]; pinned?: string[] }

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

function ToolIcon({ tool }: { tool: PaintTool }) {
  const line = { fill: "none", stroke: "#3b3b3b", strokeWidth: 1.3, strokeLinecap: "round" as const, strokeLinejoin: "round" as const };
  if (tool === "pencil") return <svg viewBox="0 0 16 16"><path d="M3 13l.6-2.6L10.8 3.2a1.2 1.2 0 0 1 1.7 0l.3.3a1.2 1.2 0 0 1 0 1.7L5.6 12.4z" {...line} /><path d="M9.6 4.4l2 2" {...line} /></svg>;
  if (tool === "bucket") return <svg viewBox="0 0 16 16"><path d="M7.2 2.6l5 5-4.6 4.6a1 1 0 0 1-1.4 0L2.6 8.6a1 1 0 0 1 0-1.4z" {...line} /><path d="M3 7.6h8.6" {...line} /><path d="M13.6 10.2c.6.9 1 1.5 1 2a1 1 0 0 1-2 0c0-.5.4-1.1 1-2z" fill="#3b3b3b" /></svg>;
  return <svg viewBox="0 0 16 16"><path d="M13.6 2.4c-1.6.8-4.8 3.6-6.2 5.4l1 1c1.8-1.4 4.6-4.6 5.4-6.2z" {...line} /><path d="M6.9 8.6c-1.5-.3-2.7.7-2.9 2.2-.1 1-.6 1.8-1.5 2.2 2.4.6 4.9-.2 5.2-2.6" {...line} /></svg>;
}

function WinLogo({ os }: { os: Os }) {
  return os === "win11"
    ? <svg width="18" height="18" viewBox="0 0 16 16"><rect x="1" y="1" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="8.4" y="1" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="1" y="8.4" width="6.6" height="6.6" fill="#3b9bf0" /><rect x="8.4" y="8.4" width="6.6" height="6.6" fill="#3b9bf0" /></svg>
    : <svg width="16" height="16" viewBox="0 0 16 16"><path d="M0 2.3 6.5 1.4v6.1H0zM7.3 1.3 16 0v7.5H7.3zM0 8.3h6.5v6.2L0 13.6zM7.3 8.3H16V16l-8.7-1.2z" fill="#fff" /></svg>;
}

function Clock({ lang }: { lang: Lang }) {
  const [now, setNow] = useState(() => new Date());
  useEffect(() => { const id = setInterval(() => setNow(new Date()), 15000); return () => clearInterval(id); }, []);
  const loc = lang === "es" ? "es" : "en-US";
  return <span className="md-clock"><b>{now.toLocaleTimeString(loc, { hour: lang === "es" ? "2-digit" : "numeric", minute: "2-digit" })}</b><small>{now.toLocaleDateString(loc, { day: "2-digit", month: "2-digit", year: "numeric" })}</small></span>;
}

const MIN: Record<Kind, [number, number]> = { terminal: [300, 120], explorer: [330, 180], notes: [240, 130], paint: [360, 240], browser: [380, 240] };
const START: Record<Kind, Frac> = { terminal: [0.24, 0.1, 0.52, 0.4], explorer: [0.22, 0.12, 0.56, 0.5], notes: [0.3, 0.16, 0.44, 0.4], paint: [0.14, 0.05, 0.8, 0.8], browser: [0.16, 0.05, 0.7, 0.8] };
const ICON_OF: Record<Kind, string> = { terminal: TERMINAL, explorer: EXPLORER, notes: NOTEPAD, paint: PAINT, browser: chrome };

interface WinProps {
  kind: Kind; os: Os; tx: Texts; lang: Lang; box: Box; max: boolean; front: boolean; locked: boolean; icon?: string; file?: number; onOpenFile(i: number): void;
  onFocus(): void; onMove(b: Box): void; onMin(): void; onMax(): void; onClose(): void; bounds(): { w: number; h: number };
  title?: string; body?: ReactNode; appear?: boolean;
}

function Window({ kind, os, tx, lang, box, max, front, locked, icon, file, onOpenFile, onFocus, onMove, onMin, onMax, onClose, bounds, title, body, appear }: WinProps) {
  const files = FILES[lang];
  const opened = file !== undefined ? files[file] : undefined;
  const theme = document.documentElement.dataset.theme === "dark" ? "dark" : "light";
  const name = title ?? { terminal: "Windows PowerShell", explorer: tx.received, notes: `${opened?.name ?? tx.notesFile}: ${tx.notepad}`, paint: `${tx.untitled}: Paint`, browser: "gpuvm" }[kind];
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
    <div className={`md-window ${kind} ${os}${max ? " max" : ""}${front ? " front" : ""}${appear ? " appear" : ""}`} style={{ ...style, zIndex: front ? 3 : 2 }} onPointerDown={onFocus}>
      <div className="md-titlebar" onPointerDown={(e) => !max && drag(e, "move")} onDoubleClick={() => !locked && onMax()}>
        <Glyph id={icon ?? ICON_OF[kind]} size={14} /><span>{name}</span>
        <button type="button" className="md-ctl" aria-label={tx.min} onPointerDown={(e) => e.stopPropagation()} onClick={onMin}>─</button>
        <button type="button" className="md-ctl" aria-label={tx.max} onPointerDown={(e) => e.stopPropagation()} onClick={onMax}>{max ? "❐" : "☐"}</button>
        <button type="button" className="md-ctl x" aria-label={tx.close} onPointerDown={(e) => e.stopPropagation()} onClick={onClose}>✕</button>
      </div>
      {body ?? <>
        {kind === "terminal" && <Terminal tx={tx} />}
        {kind === "explorer" && (
          <div className="md-explorer">
            <div className="md-side">{tx.side.map((n) => <span key={n}><Glyph id={FOLDER} size={13} />{n}</span>)}</div>
            <div className="md-files">
              <div className="md-file head"><span>{tx.name}</span><span>{tx.size}</span></div>
              {files.map((f, i) => (
                <div className="md-file" key={f.name} onDoubleClick={() => f.text && onOpenFile(i)}><span><Glyph id={f.size ? NOTEPAD : FOLDER} size={13} />{f.name}</span><span>{f.size}</span></div>
              ))}
            </div>
          </div>
        )}
        {kind === "notes" && <textarea key={lang} className="md-notes" spellCheck={false} defaultValue={opened?.text ?? tx.notes} onPointerDown={(e) => e.stopPropagation()} />}
        {kind === "browser" && (
          <div className="md-browser">
            <div className="md-address-row"><div className="md-address"><Lock /><span>{location.host || "gpuvm"}</span></div></div>
            <div className="md-page"><iframe title="gpuvm" src={`${location.origin}${location.pathname}?theme=${theme}&lang=${lang}`} loading="lazy" tabIndex={-1} /></div>
          </div>
        )}
        {kind === "paint" && <PaintBody stage={{}} />}
      </>}
      {!max && !locked && <>
        <span className="md-grip e" onPointerDown={(e) => drag(e, "e")} />
        <span className="md-grip s" onPointerDown={(e) => drag(e, "s")} />
        <span className="md-grip se" onPointerDown={(e) => drag(e, "se")} />
      </>}
    </div>
  );
}

const Lock = () => <svg className="md-lock" width="10" height="10" viewBox="0 0 16 16"><rect x="3" y="7" width="10" height="7" rx="1.5" fill="#6b6b6b" /><path d="M5 7V5a3 3 0 0 1 6 0v2" stroke="#6b6b6b" strokeWidth="1.6" fill="none" /></svg>;

function Terminal({ tx }: { tx: Texts }) {
  const prompt = "PS C:\\Users\\Ale> ";
  const [lines, setLines] = useState<string[]>([`${prompt}nvidia-smi --query-gpu=name,memory.used --format=csv`, "name, memory.used [MiB]", "NVIDIA GeForce RTX 4060, 1342 MiB"]);
  const [input, setInput] = useState("");
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => { end.current?.scrollIntoView({ block: "nearest" }); }, [lines]);
  const answer = (cmd: string): string[] => {
    const c = cmd.trim().toLowerCase();
    if (!c) return [];
    if (c === "cls" || c === "clear") return ["\u0000"];
    if (c.startsWith("nvidia-smi")) return ["NVIDIA GeForce RTX 4060, 1342 MiB, 47 °C"];
    if (c === "dir" || c === "ls") return ["Desktop", "Documents", "Downloads", "Pictures"];
    if (c === "whoami") return ["gpuvm\\ale"];
    if (c === "hostname") return ["win10"];
    if (c.startsWith("echo ")) return [cmd.trim().slice(5)];
    if (c === "help" || c === "get-help") return [tx.help];
    return [tx.unknown(cmd.trim().split(/\s+/)[0])];
  };
  const run = () => {
    const out = answer(input);
    setLines((l) => (out[0] === "\u0000" ? [] : [...l, `${prompt}${input}`, ...out]).slice(-40));
    setInput("");
  };
  return (
    <div className="md-term" onPointerDown={(e) => { e.stopPropagation(); (e.currentTarget.querySelector("input") as HTMLInputElement | null)?.focus(); }}>
      {lines.map((l, i) => <div key={i}>{l || "\u00a0"}</div>)}
      <div className="md-term-line" ref={end}><span>{prompt}</span>
        <input value={input} onChange={(e) => setInput(e.target.value)} onKeyDown={(e) => { e.stopPropagation(); if (e.key === "Enter") run(); }} spellCheck={false} aria-label="PowerShell" />
      </div>
    </div>
  );
}

function ScriptTerminal({ term }: { term: TermStage }) {
  const end = useRef<HTMLDivElement>(null);
  useEffect(() => { const el = end.current?.parentElement; if (el) el.scrollTop = el.scrollHeight; }, [term]);
  return (
    <div className="md-term">
      {term.lines.map((l, i) => {
        if (!l.startsWith(BAR_MARK)) return <div key={i}>{l || "\u00a0"}</div>;
        const [done, cells, text] = l.slice(1).split("|");
        return <div key={i} className="md-term-bar"><span style={{ width: `${cells}ch` }}><i style={{ width: `${Number(done) * 100}%` }} /></span>{text}</div>;
      })}
      <div className="md-term-line" ref={end}><span>{term.input}</span><i className="md-caret" /></div>
    </div>
  );
}

function PaintBody({ stage, width }: { stage: PaintStage; width?: number }) {
  const color = PAINT_COLORS[stage.color ?? 0];
  return (
    <div className="md-paint">
      <div className="md-paint-tools">
        {PAINT_TOOLS.map((t, i) => <span key={t} className={`md-tool${(stage.tool ?? "pencil") === t ? " on" : ""}`} style={{ left: P_TOOL_X + i * P_TOOL_STEP }}><ToolIcon tool={t} /></span>)}
        <span className="md-sep" />
        <span className="md-current" style={{ left: P_CURRENT_X, background: color }} />
        {PAINT_COLORS.map((c, i) => <span key={c} className="md-swatch" style={{ left: P_SWATCH_X + i * swatchStep(width), background: c }} />)}
      </div>
      <div className="md-canvas" style={{ background: stage.background ?? "#fff" }}>
        {stage.fills?.length ? (
          <svg viewBox="0 0 1 1" preserveAspectRatio="none">
            {stage.fills.map((f, i) => <polygon key={i} points={f.pts.map((p) => `${p[0]},${p[1]}`).join(" ")} fill={f.color} />)}
          </svg>
        ) : null}
      </div>
    </div>
  );
}

const clock = (s: number) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;

function Player({ playing, rect, tx, lang }: { playing: boolean; rect: Box; tx: Texts; lang: Lang }) {
  const v = VIDEOS[0];
  const [time, setTime] = useState(0);
  useEffect(() => {
    if (!playing) return;
    const id = setInterval(() => setTime((s) => (s + 0.25) % v.length), 250);
    return () => clearInterval(id);
  }, [playing, v.length]);
  return (
    <div className="md-player" style={{ left: rect.x, top: rect.y, width: rect.w, height: rect.h }}>
      <PixelScene scene={v.scene} />
      {!playing && <span className="md-bigplay" aria-label={tx.play}><svg viewBox="0 0 24 24"><path d="M9 6.5v11l9-5.5z" fill="#fff" /></svg></span>}
      <div className="md-controls">
        <span className="md-pp" aria-label={playing ? tx.pause : tx.play}>{playing
          ? <svg viewBox="0 0 16 16"><rect x="4" y="3" width="2.6" height="10" rx=".8" fill="#fff" /><rect x="9.4" y="3" width="2.6" height="10" rx=".8" fill="#fff" /></svg>
          : <svg viewBox="0 0 16 16"><path d="M5 3.2v9.6l7.6-4.8z" fill="#fff" /></svg>}</span>
        <span className="md-track"><i style={{ width: `${(time / v.length) * 100}%` }} /></span>
        <span className="md-time">{clock(time)} / {clock(v.length)}</span>
        <svg className="md-vol" viewBox="0 0 16 16"><path d="M2.5 6h2.6L8.5 3v10L5.1 10H2.5z" fill="#fff" /><path d="M10.6 5.6a3.4 3.4 0 0 1 0 4.8M12.4 3.8a6 6 0 0 1 0 8.4" stroke="#fff" strokeWidth="1.3" fill="none" strokeLinecap="round" /></svg>
      </div>
      <span className="md-sr">{v.title[lang]}</span>
    </div>
  );
}

function ScriptBrowser({ b, box, tx, lang }: { b: BrowserStage; box: Box; tx: Texts; lang: Lang }) {
  const L = browserLayout(box);
  const rel = (r: Box): Box => ({ x: r.x - L.page.x, y: r.y - L.page.y, w: r.w, h: r.h });
  return (
    <div className="md-browser">
      <div className="md-address-row">
        <div className={`md-address${b.editing ? " editing" : ""}`}>
          {b.address || b.editing ? <><Lock /><span className="md-url">{b.address}{b.editing && <i className="md-caret dark" />}</span></> : <span className="md-hint">{tx.addressHint}</span>}
        </div>
      </div>
      <div className="md-page site">
        {b.page === "new" && <div className="md-newtab"><span><svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.2" stroke="#7a7a7a" strokeWidth="1.4" fill="none" /><path d="M10.2 10.2 13 13" stroke="#7a7a7a" strokeWidth="1.4" strokeLinecap="round" /></svg>{tx.addressHint}</span></div>}
        {b.page === "site" && <>
          <div className="md-site-head"><span className="md-site-mark"><svg viewBox="0 0 16 16"><path d="M6 4.6v6.8l5.4-3.4z" fill="#fff" /></svg></span><span className="md-site-search">{tx.siteSearch}</span></div>
          {L.thumbs.map((r, i) => { const v = VIDEOS[i], p = rel(r); return (
            <div key={i} className="md-thumb" style={{ left: p.x, top: p.y, width: p.w }}>
              <div className="md-thumb-pic" style={{ height: p.h }}><PixelScene scene={v.scene} /><span className="md-dur">{clock(v.length)}</span></div>
              <span className="md-thumb-title">{v.title[lang]}</span>
            </div>
          ); })}
        </>}
        {b.page === "video" && <>
          <Player playing={!!b.playing} rect={rel(L.player)} tx={tx} lang={lang} />
          <span className="md-video-title" style={{ left: rel(L.player).x, top: rel(L.player).y + L.player.h + 8, width: L.player.w }}>{VIDEOS[0].title[lang]}</span>
          {L.side && <div className="md-next" style={{ left: rel(L.player).x + L.player.w + 12, top: rel(L.player).y, right: 12 }}>
            {VIDEOS.slice(1).map((v) => <div key={v.scene} className="md-next-item"><div className="md-next-pic"><PixelScene scene={v.scene} /></div><span>{v.title[lang]}</span></div>)}
          </div>}
        </>}
      </div>
    </div>
  );
}

const CSS = `
.md { position: absolute; inset: 0; overflow: hidden; font-family: "Segoe UI Variable", "Segoe UI", system-ui, sans-serif; color: #fff; user-select: none; }
.md > .pixel-scene { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; image-rendering: pixelated; }
.md-icons { position: absolute; left: 1.2%; top: 2%; display: grid; gap: 4px; }
.md-icon { display: grid; justify-items: center; align-content: start; gap: 3px; width: 64px; padding: 4px 2px; border-radius: 3px; border: 1px solid transparent; font-size: 10.5px; text-align: center; line-height: 1.15; text-shadow: 0 0 2px #000, 0 1px 3px #000c; }
.md-icon img, .md-icon svg { display: block; width: 28px; height: 28px; }
.md-icon:hover { background: rgba(255,255,255,.12); } .md-icon.sel { background: rgba(120,180,255,.3); border-color: rgba(160,205,255,.6); }
.md-new { animation: md-pop .5s cubic-bezier(.3, 1.4, .5, 1) both; }
@keyframes md-pop { from { transform: scale(.4); opacity: 0; } to { transform: none; opacity: 1; } }
.md-bar { position: absolute; z-index: 5; left: 0; right: 0; bottom: 0; height: 34px; display: flex; align-items: center; gap: 2px; padding: 0 6px; background: rgba(28, 28, 30, .92); }
.md-bar.win11 { justify-content: center; background: rgba(36, 38, 44, .88); }
.md-bar .md-pin { display: grid; place-items: center; width: 32px; height: 28px; border-radius: 4px; flex: none; }
.md-bar .md-pin.open { background: rgba(255,255,255,.08); box-shadow: inset 0 -2px 0 #6cb4ff; }
.md-bar .md-pin.min { box-shadow: inset 0 -2px 0 #8a8a8a; } .md-bar .md-pin:hover { background: rgba(255,255,255,.12); }
.md-bar img, .md-bar svg { display: block; width: 18px; height: 18px; }
.md-search { display: flex; align-items: center; height: 24px; width: 150px; padding: 0 8px; margin: 0 4px; background: #2e2e30; color: #b9b9b9; font-size: 10.5px; flex: none; white-space: nowrap; overflow: hidden; }
.md-bar.win11 .md-search { width: 110px; border-radius: 12px; background: rgba(255,255,255,.08); }
.md-tray { position: absolute; right: 8px; display: flex; align-items: center; gap: 8px; font-size: 10px; }
.md-clock { display: grid; justify-items: end; line-height: 1.1; } .md-clock b { font-weight: 400; } .md-clock small { font-size: 9px; color: #ddd; }
.md-window { position: absolute; display: flex; flex-direction: column; background: #fff; color: #1f1f1f; border-radius: 6px; overflow: hidden; box-shadow: 0 0 0 1px rgba(0,0,0,.25); font-size: 11px; }
.md-window.appear { animation: md-open .22s cubic-bezier(.2, .8, .2, 1) both; }
@keyframes md-open { from { opacity: 0; transform: translateY(10px) scale(.97); } }
.md-window > :not(.md-titlebar):not(.md-grip) { flex: 1; min-height: 0; overflow: hidden; }
.md-window.max { border-radius: 0; }
.md-window:not(.front) .md-titlebar { color: #8a8a8a; }
.md-window.win10 { border-radius: 0; }
.md-titlebar { display: flex; align-items: center; gap: 6px; height: 26px; flex: none; padding-left: 8px; background: #f3f3f3; font-size: 11px; cursor: default; touch-action: none; }
.md-titlebar span { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.md-ctl { width: 34px; height: 100%; padding: 0; border: 0; background: transparent; text-align: center; color: #444; font: inherit; font-size: 10px; cursor: default; flex: none; }
.md-ctl:hover { background: rgba(0,0,0,.07); } .md-ctl.x:hover { background: #c42b1c; color: #fff; }
.md-grip { position: absolute; touch-action: none; } .md-grip.e { top: 0; right: 0; width: 6px; height: 100%; cursor: ew-resize; }
.md-grip.s { left: 0; bottom: 0; width: 100%; height: 6px; cursor: ns-resize; } .md-grip.se { right: 0; bottom: 0; width: 14px; height: 14px; cursor: nwse-resize; }
.md-term { margin: 0; padding: 8px 10px 12px; overflow: auto !important; cursor: text; background: #012456; color: #eaeaea; font: 10.5px/1.5 Consolas, "Cascadia Mono", monospace; white-space: pre-wrap; overflow-wrap: anywhere; scrollbar-width: none; }
.md-term-line { display: flex; align-items: center; white-space: pre; } .md-term-line input { flex: 1; min-width: 0; padding: 0; border: 0; outline: 0; background: transparent; color: inherit; font: inherit; caret-color: #eaeaea; }
.md-term-bar { display: flex; align-items: center; gap: 2ch; padding-left: 2ch; white-space: pre; }
.md-term-bar > span { position: relative; height: 9px; background: rgba(234,234,234,.22); flex: none; } .md-term-bar i { position: absolute; left: 0; top: 0; bottom: 0; background: #eaeaea; }
.md-caret { display: inline-block; flex: none; width: 6px; height: 11px; background: #eaeaea; vertical-align: -1px; animation: md-blink 1s steps(1) infinite; }
.md-caret.dark { width: 1px; height: 12px; margin-left: 1px; background: #1f1f1f; }
@keyframes md-blink { 50% { opacity: 0; } }
.md-explorer { display: grid; grid-template-columns: 110px minmax(0, 1fr); }
.md-side { display: grid; align-content: start; gap: 2px; padding: 6px; background: #f7f7f7; border-right: 1px solid #e5e5e5; }
.md-side span, .md-file span:first-child { display: flex; align-items: center; gap: 6px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.md-files { padding: 4px 8px; } .md-file { display: grid; grid-template-columns: minmax(0, 1fr) 60px; padding: 4px 2px; border-bottom: 1px solid #f0f0f0; } .md-file.head { color: #6b6b6b; font-size: 10px; }
.md-file span:last-child { color: #6b6b6b; text-align: right; }
.md-notes { width: 100%; padding: 10px 12px 18px; border: 0; outline: 0; resize: none; white-space: pre-wrap; background: #fff; color: #1f1f1f; font: 11.5px/1.55 Consolas, monospace; }
.md-browser { display: flex; flex-direction: column; background: #f3f3f3; }
.md-address-row { flex: none; height: 34px; padding: 4px 8px; }
.md-address { display: flex; align-items: center; gap: 6px; height: 26px; padding: 0 10px; border-radius: 13px; background: #fff; color: #444; font-size: 10.5px; white-space: nowrap; overflow: hidden; }
.md-address.editing { box-shadow: inset 0 0 0 1.5px #3b82f6; }
.md-url { display: flex; align-items: center; min-width: 0; overflow: hidden; color: #1f1f1f; } .md-hint { color: #8a8a8a; overflow: hidden; text-overflow: ellipsis; }
.md-lock { flex: none; }
.md-page { position: relative; flex: 1; min-height: 0; overflow: hidden; background: #161616; }
.md-page iframe { position: absolute; left: 0; top: 0; width: 200%; height: 200%; border: 0; transform: scale(.5); transform-origin: 0 0; }
.md-page.site { background: #fff; color: #1f1f1f; font-family: "Plus Jakarta Sans", system-ui, sans-serif; }
.md-page.site .pixel-scene { display: block; width: 100%; height: 100%; object-fit: cover; image-rendering: pixelated; }
.md-newtab { position: absolute; inset: 0; display: grid; place-items: center; background: #f7f7f8; }
.md-newtab > span { display: flex; align-items: center; gap: 8px; width: min(70%, 280px); height: 30px; padding: 0 14px; border-radius: 15px; background: #fff; box-shadow: inset 0 0 0 1px #e2e2e2; color: #8a8a8a; font-size: 10.5px; white-space: nowrap; overflow: hidden; }
.md-newtab svg { width: 12px; height: 12px; flex: none; }
.md-site-head { position: absolute; left: 0; right: 0; top: 0; height: 32px; display: flex; align-items: center; gap: 10px; padding: 0 12px; border-bottom: 1px solid #eee; }
.md-site-mark { display: grid; place-items: center; width: 20px; height: 20px; border-radius: 6px; background: #2f8f83; flex: none; } .md-site-mark svg { width: 13px; height: 13px; }
.md-site-search { flex: 0 1 200px; height: 20px; display: flex; align-items: center; padding: 0 10px; border-radius: 10px; box-shadow: inset 0 0 0 1px #e2e2e2; color: #8a8a8a; font-size: 9.5px; white-space: nowrap; overflow: hidden; }
.md-thumb { position: absolute; display: grid; gap: 5px; }
.md-thumb-pic { position: relative; border-radius: 6px; overflow: hidden; background: #ddd; }
.md-dur { position: absolute; right: 4px; bottom: 4px; padding: 1px 4px; border-radius: 3px; background: rgba(20,20,24,.75); color: #fff; font-size: 8.5px; font-weight: 600; }
.md-thumb-title { font-size: 9.5px; font-weight: 600; line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.md-player { position: absolute; border-radius: 6px; overflow: hidden; background: #222; }
.md-bigplay { position: absolute; left: 50%; top: 50%; width: 44px; height: 44px; margin: -22px 0 0 -22px; border-radius: 50%; display: grid; place-items: center; background: rgba(20,20,24,.6); }
.md-bigplay svg { width: 24px; height: 24px; }
.md-controls { position: absolute; left: 0; right: 0; bottom: 0; height: 26px; display: flex; align-items: center; gap: 8px; padding: 0 8px; background: linear-gradient(transparent, rgba(16,16,20,.7)); color: #fff; font-size: 9px; }
.md-controls svg { width: 13px; height: 13px; display: block; flex: none; } .md-pp { display: grid; place-items: center; flex: none; }
.md-track { position: relative; flex: 1; height: 3px; border-radius: 2px; background: rgba(255,255,255,.35); }
.md-track i { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 2px; background: #2f8f83; transition: width .25s linear; }
.md-track i::after { content: ""; position: absolute; right: -4px; top: -2.5px; width: 8px; height: 8px; border-radius: 50%; background: #2f8f83; }
.md-time { flex: none; font-variant-numeric: tabular-nums; }
.md-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
.md-video-title { position: absolute; font-size: 11px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.md-next { position: absolute; display: grid; gap: 8px; align-content: start; }
.md-next-item { display: grid; grid-template-columns: minmax(0, min(46%, 112px)) minmax(0, 1fr); gap: 6px; align-items: start; font-size: 9px; font-weight: 600; line-height: 1.3; }
.md-next-item span { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
.md-next-pic { aspect-ratio: 16 / 9; border-radius: 4px; overflow: hidden; }
.md-file { cursor: default; } .md-file:not(.head):hover { background: #eef5fd; }
.md-paint { position: relative; display: grid; grid-template-rows: ${P_TOOLS}px minmax(0, 1fr); background: #e9edf2; }
.md-paint-tools { position: relative; height: ${P_TOOLS}px; background: #f8f9fb; border-bottom: 1px solid #e3e3e3; overflow: hidden; }
.md-tool { position: absolute; top: 6px; width: 22px; height: 22px; border-radius: 4px; display: grid; place-items: center; }
.md-tool.on { background: #dbe6f6; } .md-tool svg { display: block; width: 14px; height: 14px; }
.md-sep { position: absolute; left: 86px; top: 8px; width: 1px; height: 18px; background: #d8d8d8; }
.md-current { position: absolute; top: 8px; width: 18px; height: 18px; border-radius: 50%; box-shadow: inset 0 0 0 1px rgba(0,0,0,.18); transition: background .15s; }
.md-swatch { position: absolute; top: ${(P_TOOLS - P_SWATCH) / 2}px; width: ${P_SWATCH}px; height: ${P_SWATCH}px; border-radius: 50%; box-shadow: inset 0 0 0 1px rgba(0,0,0,.14); }
.md-canvas { position: relative; margin: ${P_PAD}px; background: #fff; box-shadow: 0 0 0 1px #d9d9d9; overflow: hidden; transition: background .2s; }
.md-canvas svg { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
/* Dark mode (the page's): Windows 11's dark windows. PowerShell keeps its blue body. */
:host([data-theme="dark"]) .md-window { background: #1f1f1f; color: #e6e6e6; box-shadow: 0 0 0 1px rgba(255,255,255,.08); }
:host([data-theme="dark"]) .md-titlebar { background: #202020; color: #e6e6e6; }
:host([data-theme="dark"]) .md-window:not(.front) .md-titlebar { color: #8a8a8a; }
:host([data-theme="dark"]) .md-ctl { color: #cfcfcf; } :host([data-theme="dark"]) .md-ctl:not(.x):hover { background: rgba(255,255,255,.08); }
:host([data-theme="dark"]) .md-side { background: #272727; border-right-color: #333; }
:host([data-theme="dark"]) .md-file { border-bottom-color: #2e2e2e; } :host([data-theme="dark"]) .md-file.head, :host([data-theme="dark"]) .md-file span:last-child { color: #a3a3a3; }
:host([data-theme="dark"]) .md-file:not(.head):hover { background: #2a3442; }
:host([data-theme="dark"]) .md-notes { background: #1f1f1f; color: #e6e6e6; }
:host([data-theme="dark"]) .md-browser { background: #2b2b2b; }
:host([data-theme="dark"]) .md-address { background: #1f1f1f; color: #e6e6e6; } :host([data-theme="dark"]) .md-url { color: #e6e6e6; } :host([data-theme="dark"]) .md-hint { color: #9a9a9a; }
:host([data-theme="dark"]) .md-lock * { fill: #9a9a9a; } :host([data-theme="dark"]) .md-lock path { fill: none; stroke: #9a9a9a; }
:host([data-theme="dark"]) .md-caret.dark { background: #e6e6e6; }
:host([data-theme="dark"]) .md-page.site { background: #1f1f1f; color: #e6e6e6; }
:host([data-theme="dark"]) .md-newtab { background: #232323; } :host([data-theme="dark"]) .md-newtab > span { background: #2b2b2b; box-shadow: inset 0 0 0 1px #3a3a3a; color: #9a9a9a; }
:host([data-theme="dark"]) .md-site-head { border-bottom-color: #333; } :host([data-theme="dark"]) .md-site-search { box-shadow: inset 0 0 0 1px #3a3a3a; color: #9a9a9a; }
:host([data-theme="dark"]) .md-paint, :host([data-theme="dark"]) .md-window.paint .md-paint { background: #202020; }
:host([data-theme="dark"]) .md-paint-tools { background: #2b2b2b; border-bottom-color: #383838; }
:host([data-theme="dark"]) .md-tool.on { background: #3a4a62; } :host([data-theme="dark"]) .md-tool svg [stroke] { stroke: #e0e0e0; } :host([data-theme="dark"]) .md-tool svg [fill="#3b3b3b"] { fill: #e0e0e0; }
:host([data-theme="dark"]) .md-sep { background: #444; }
:host([data-theme="dark"]) .md-swatch, :host([data-theme="dark"]) .md-current { box-shadow: inset 0 0 0 1px rgba(255,255,255,.22); }
:host([data-theme="dark"]) .md-canvas { box-shadow: 0 0 0 1px #3a3a3a; }
.md-over { position: absolute; z-index: 6; inset: 0 0 34px 0; pointer-events: none; }
@media (max-width: 560px) { .md-icons { display: none; } .md-search { display: none; } }
`;

const OPENS: Record<string, Kind> = { [FOLDER]: "explorer", [EXPLORER]: "explorer", [TERMINAL]: "terminal", [NOTEPAD]: "notes", [PAINT]: "paint",
  [chrome]: "browser", [brave]: "browser", [firefox]: "browser" };

interface Win { kind: Kind; box: Box; min: boolean; max: boolean; icon?: string; file?: number }
const noop = () => {};

export function MachineDesktop({ vm, children, locked, stage, bare }: { vm: string; children?: ReactNode; locked?: boolean; stage?: Stage; bare?: boolean }) {
  const d = DESKS[vm] ?? DESKS.win10;
  const lang = getLang();
  const tx = TEXT[lang];
  const ref = useRef<HTMLDivElement>(null);
  const [wins, setWins] = useState<Win[]>([]);
  const [order, setOrder] = useState<Kind[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [dims, setDims] = useState<{ w: number; h: number } | null>(null);
  const bounds = () => ({ w: ref.current?.clientWidth || 800, h: ref.current?.clientHeight || 450 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el || !stage) return;
    const measure = () => setDims({ w: el.clientWidth, h: el.clientHeight });
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [!stage]); // eslint-disable-line react-hooks/exhaustive-deps
  const place = (kind: Kind): Box => {
    const { w: W, h: H } = bounds();
    const [fx, fy, fw, fh] = START[kind], [mw, mh] = MIN[kind];
    const w = Math.min(W, Math.max(mw, W * fw)), h = Math.min(H - BAR, Math.max(mh, (H - BAR) * fh));
    return { x: Math.max(0, Math.min(W - w, W * fx)), y: Math.max(0, Math.min(H - BAR - h, (H - BAR) * fy)), w, h };
  };
  useLayoutEffect(() => {
    setWins(d.window && !bare ? [{ kind: d.window, box: place(d.window), min: false, max: false }] : []);
    setOrder(d.window ? [d.window] : []);
    setSelected(null);
  }, [vm]); // eslint-disable-line react-hooks/exhaustive-deps
  const front = order[order.length - 1];
  const focus = (k: Kind) => setOrder((o) => [...o.filter((x) => x !== k), k]);
  const update = (k: Kind, f: (w: Win) => Win) => setWins((list) => list.map((w) => (w.kind === k ? f(w) : w)));
  const open = (k: Kind, extra: Partial<Win> = {}) => {
    setWins((list) => (list.some((w) => w.kind === k) ? list.map((w) => (w.kind === k ? { ...w, ...extra, min: false } : w)) : [...list, { kind: k, box: place(k), min: false, max: false, ...extra }]));
    focus(k);
  };
  const launch = (glyph: string) => {
    const k = OPENS[glyph];
    if (k && !locked && !stage) open(k, BROWSERS.has(glyph) ? { icon: glyph } : {});
  };
  const pin = (k: Kind) => {
    const w = wins.find((x) => x.kind === k);
    if (w && !w.min && front === k) update(k, (x) => ({ ...x, min: true }));
    else open(k);
  };
  const icons = stage?.icons ? [...d.icons, ...stage.icons] : d.icons;
  const pinned = stage?.pinned ? [...d.pinned, ...stage.pinned] : d.pinned;
  const added = new Set([...(stage?.icons ?? []).map(([g]) => g), ...(stage?.pinned ?? [])]);

  const scripted = () => {
    if (!stage || !dims) return null;
    const H = dims.h - BAR;
    return stage.windows.map((sw, i) => {
      const box = stageBox(sw.at, dims.w, H);
      const isFront = i === stage.windows.length - 1;
      const title = sw.kind === "paint" ? sw.paint?.title
        : sw.kind === "browser" ? (sw.browser?.page === "video" ? VIDEOS[0].title[lang] : sw.browser?.page === "site" ? SITE : tx.newTab) : undefined;
      const body = sw.kind === "paint" ? <PaintBody stage={sw.paint ?? {}} width={box.w} />
        : sw.kind === "terminal" && sw.term ? <ScriptTerminal term={sw.term} />
        : sw.kind === "browser" && sw.browser ? <ScriptBrowser b={sw.browser} box={box} tx={tx} lang={lang} /> : undefined;
      return (
        <Window key={sw.kind} kind={sw.kind} os={d.os} tx={tx} lang={lang} box={box} max={false} front={isFront} locked bounds={bounds} appear
          title={title} body={body} onOpenFile={noop} onFocus={noop} onMove={noop} onMin={noop} onMax={noop} onClose={noop} />
      );
    });
  };

  return (
    <div className="md" ref={ref} onPointerDown={(e) => { if (e.target === e.currentTarget || (e.target as HTMLElement).classList.contains("pixel-scene")) setSelected(null); }}>
      <style>{CSS}</style>
      <PixelScene scene={d.scene} />
      <div className="md-icons">{icons.map(([g, key]) => {
        const n = label(tx, key);
        return (
          <div key={key} className={`md-icon${selected === key ? " sel" : ""}${added.has(g) ? " md-new" : ""}`} onPointerDown={(e) => { e.stopPropagation(); if (!stage) setSelected(key); }}
            onDoubleClick={() => launch(g)}>
            <Glyph id={g} size={28} /><span>{n}</span>
          </div>
        );
      })}</div>
      {stage ? scripted() : wins.filter((w) => !w.min).map((w) => (
        <Window key={w.kind + (w.file ?? "")} kind={w.kind} os={d.os} tx={tx} lang={lang} box={w.box} max={w.max} front={front === w.kind} locked={!!locked} bounds={bounds}
          icon={w.icon} file={w.file} onOpenFile={(i) => open("notes", { file: i })}
          onFocus={() => focus(w.kind)} onMove={(box) => update(w.kind, (x) => ({ ...x, box }))}
          onMin={() => update(w.kind, (x) => ({ ...x, min: true }))} onMax={() => update(w.kind, (x) => ({ ...x, max: !x.max }))}
          onClose={() => setWins((list) => list.filter((x) => x.kind !== w.kind))} />
      ))}
      <div className={`md-bar ${d.os}`}>
        <span className="md-pin"><WinLogo os={d.os} /></span>
        <span className="md-search">{d.os === "win11" ? tx.search11 : tx.search10}</span>
        {pinned.map((p) => {
          const k = OPENS[p];
          const open = stage ? !!k && stage.windows.some((x) => x.kind === k) : false;
          const w = !stage && k && wins.find((x) => x.kind === k && (k !== "browser" || x.icon === p));
          const cls = stage ? (open ? " open" : "") : w ? (w.min ? " min" : " open") : "";
          return <span key={p} data-pin={p} className={`md-pin${cls}${added.has(p) ? " md-new" : ""}`} onClick={() => { if (!k || locked || stage) return; if (k === "browser" && !w) launch(p); else pin(k); }}><Glyph id={p} size={18} /></span>;
        })}
        <span className="md-tray"><Clock lang={lang} /></span>
      </div>
      {children && <div className="md-over">{children}</div>}
    </div>
  );
}
