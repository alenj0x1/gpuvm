import {
  IconAdjustments, IconAlertTriangle, IconApps, IconDeviceDesktop, IconDeviceDesktopOff, IconDeviceDesktopStar, IconBriefcase, IconCheck, IconDeviceGamepad2, IconDisc, IconDots, IconFolderOpen, IconMovie, IconRefresh, IconSearch, IconTrash, IconX,
} from "@tabler/icons-react";
import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { api } from "./api";
import type { AppInfo, CleanupLevel, CleanupLevelId, HostMonitor, IsoFile, MouseMode, ProfileSettings } from "./types";
import { CheckMark, Segmented, useScrollFade } from "./ui";

export const RESOLUTIONS = ["1280x720", "1920x1080", "2560x1440", "3840x2160"];
export const FPS = [30, 60, 120, 144];
/** 0 = the host monitor's refresh rate, read each time the VM opens (lab 022). */
export const MONITOR_FPS = 0;
export const FPS_OPTIONS = [...FPS.map((f) => ({ value: f, label: `${f} FPS` })), { value: MONITOR_FPS, label: "Monitor" }];
export const fpsLabel = (fps: number | null | undefined) => (fps === MONITOR_FPS ? "al ritmo del monitor" : `${fps ?? 60} FPS`);
export const CODECS = [{ value: "auto", label: "Automático" }, { value: "H.264", label: "H.264" }, { value: "HEVC", label: "HEVC" }, { value: "AV1", label: "AV1" }];

/** What a VM is used for: each use sets the stream settings measured for it (labs 020-022). At the monitor's own
 * refresh rate V-Sync costs no latency and halves the stutters, so no use has to trade one for the other. */
export type StreamUse = "games" | "video" | "work";
export interface StreamUseInfo {
  id: StreamUse;
  label: string;
  icon: typeof IconMovie;
  description: string;
  client: { fps: number; vsync: boolean; framePacing: boolean; mouse: MouseMode };
}
export const USES: StreamUseInfo[] = [
  { id: "games", label: "Juegos", icon: IconDeviceGamepad2, description: "Al ritmo de tu monitor, con la respuesta más rápida y la imagen siempre entera.",
    client: { fps: MONITOR_FPS, vsync: true, framePacing: false, mouse: "capture" } },
  { id: "video", label: "Películas y video", icon: IconMovie, description: "Movimiento parejo para películas y series, con menos uso de red.",
    client: { fps: 60, vsync: true, framePacing: true, mouse: "absolute" } },
  { id: "work", label: "Trabajo", icon: IconBriefcase, description: "Todo el monitor fluido, con el mouse libre como en escritorio remoto.",
    client: { fps: MONITOR_FPS, vsync: true, framePacing: false, mouse: "absolute" } },
];

/** The use whose settings match exactly, or null when they were changed by hand. */
export function streamUseOf(c: { fps: number; vsync: boolean; framePacing: boolean; mouse: MouseMode }) {
  return USES.find((u) => u.client.fps === c.fps && u.client.vsync === c.vsync && u.client.framePacing === c.framePacing && u.client.mouse === c.mouse)?.id ?? null;
}

const PROFILE_NAMES: Record<string, string> = { balanced: "Equilibrado", "max-performance": "Máximo rendimiento" };
export const profileLabel = (name: string) => PROFILE_NAMES[name] ?? name;

// Each app's own icon, in color (tools/app-icons/extract.ps1 takes them from the official installers).
const APP_ICONS = import.meta.glob<string>("./assets/apps/*.{png,svg}", { eager: true, query: "?url", import: "default" });

export function AppLogo({ id }: { id: string }) {
  const src = APP_ICONS[`./assets/apps/${id}.png`] ?? APP_ICONS[`./assets/apps/${id}.svg`];
  if (!src) return <IconApps size={20} />;
  return <img className="app-logo" src={src} alt="" width={20} height={20} draggable={false} />;
}

/** hardwareOnly: for a VM built on a template, whose Windows, apps and cleanup come from the template. */
export function profileSummary(s: ProfileSettings, apps: AppInfo[] = [], hardwareOnly = false) {
  const parts = [
    `${s.cpu} hilos`, `${s.memoryGB} GB`, `GPU ${s.gpuPercent} %`,
    `disco ${s.diskType === "Fixed" ? "fijo" : "dinámico"} de ${s.diskGB} GB`,
  ];
  if (s.resolution) parts.push(`${s.resolution.split("x")[1]}p ${fpsLabel(s.fps)}${s.displayMode === "windowed" ? " en ventana" : ""}`);
  if (hardwareOnly) return parts.slice(0, 3).join(" · ");
  const cleanup = cleanupCache?.find((l) => l.id === s.cleanup);
  if (cleanup && s.cleanup !== "none") parts.push(`Windows: ${cleanup.name.toLowerCase()}`);
  const names = s.apps.map((id) => apps.find((a) => a.id === id)?.name ?? id);
  if (names.length) parts.push(names.join(", "));
  return parts.join(" · ");
}

export const fileName = (path: string) => path.split("\\").pop() ?? path;

// Accents and case do not matter when searching ("comunicacion" finds "Comunicación").
const fold = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Apps from the catalog as toggles: a search box, category tabs and a grid that scrolls within a fixed height. */
/** scroll: false inside dialogs, where the dialog is the one that scrolls (never a scroll inside another). */
interface AppPickerProps {
  apps: AppInfo[];
  value: string[];
  onChange: (v: string[]) => void;
  scroll?: boolean;
  /** Apps already in the VM: shown as installed, with their actions in a menu instead of a checkbox. */
  installed?: string[];
  onReinstall?: (app: AppInfo) => void;
  onUninstall?: (app: AppInfo) => void;
  /** An app job is running: the installed apps' actions wait for it. */
  locked?: boolean;
}

export function AppPicker({ apps, value, onChange, scroll = true, installed = [], onReinstall, onUninstall, locked }: AppPickerProps) {
  const [query, setQuery] = useState("");
  const [menu, setMenu] = useState<{ app: AppInfo; x: number; y: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!menu) return;
    // pointerdown in capture, so a tile or button that stops the click still closes it.
    const close = (e: PointerEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(null); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(null); };
    const away = () => setMenu(null);
    window.addEventListener("pointerdown", close, true);
    window.addEventListener("keydown", key);
    window.addEventListener("resize", away);
    window.addEventListener("scroll", away, true);
    return () => {
      window.removeEventListener("pointerdown", close, true); window.removeEventListener("keydown", key);
      window.removeEventListener("resize", away); window.removeEventListener("scroll", away, true);
    };
  }, [menu]);
  const openMenu = (app: AppInfo, target: HTMLElement, point?: { x: number; y: number }) => {
    const box = target.getBoundingClientRect();
    const width = 200;
    const x = Math.min(point?.x ?? box.right - width, window.innerWidth - width - 8);
    const below = (point?.y ?? box.bottom) + 6;
    // Opens upward when it would leave the window.
    const y = below + 96 > window.innerHeight ? Math.max(8, (point?.y ?? box.top) - 96 - 6) : below;
    setMenu({ app, x: Math.max(8, x), y });
  };
  const [category, setCategory] = useState<string | null>(null);
  const categories = useMemo(() => {
    const seen = new Map<string, string>();
    for (const a of apps) if (a.category && !seen.has(a.category)) seen.set(a.category, a.categoryName ?? a.category);
    return [...seen];
  }, [apps]);
  const q = fold(query.trim());
  // A search looks through every category, so a result is never hidden by the tab that happens to be open.
  const shown = apps.filter((a) => q
    ? fold(`${a.name} ${a.categoryName ?? ""}`).includes(q)
    : !category || a.category === category);
  const [gridRef, gridFade] = useScrollFade<HTMLDivElement>();
  const [tabsRef, tabFade] = useScrollFade<HTMLDivElement>("x");
  return (
    <div className="app-picker">
      <div className="app-picker-bar">
        <label className="search-box">
          <IconSearch size={16} />
          <input className="text-input" value={query} placeholder="Buscar" aria-label="Buscar apps"
            onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => { if (e.key === "Escape" && query) { e.stopPropagation(); setQuery(""); } }} />
          {query && <button type="button" className="search-clear" aria-label="Borrar búsqueda" onClick={() => setQuery("")}><IconX size={14} /></button>}
        </label>
        {categories.length > 1 && !q && (
          <div ref={tabsRef} className={`segmented app-tabs ${tabFade}`} role="tablist">
            <button type="button" role="tab" aria-selected={!category} className={!category ? "on" : ""} onClick={() => setCategory(null)}>Todas</button>
            {categories.map(([id, label]) => (
              <button type="button" role="tab" key={id} aria-selected={category === id} className={category === id ? "on" : ""} onClick={() => setCategory(id)}>{label}</button>
            ))}
          </div>
        )}
      </div>
      <div ref={gridRef} className={`app-grid ${scroll ? `capped ${gridFade}` : ""}`} role="group">
        {shown.map((a) => {
          if (installed.includes(a.id)) {
            const open = menu?.app.id === a.id;
            return (
              <button type="button" key={a.id} className={`choice installed ${open ? "open" : ""}`} aria-haspopup="menu" aria-expanded={open}
                disabled={locked} title={`${a.name} está instalada`} aria-label={`${a.name}, instalada`}
                onClick={(e) => (open ? setMenu(null) : openMenu(a, e.currentTarget))}
                onContextMenu={(e) => { e.preventDefault(); if (!locked) openMenu(a, e.currentTarget, { x: e.clientX, y: e.clientY }); }}>
                <span className="check done"><IconCheck size={14} stroke={2} /></span>
                <span className="choice-icon"><AppLogo id={a.id} /></span>
                <span className="grow"><span className="title">{a.name}</span></span>
                <IconDots size={16} className="choice-more" />
              </button>
            );
          }
          const on = value.includes(a.id);
          return (
            <button type="button" role="checkbox" aria-checked={on} key={a.id} className={`choice ${on ? "on" : ""}`}
              onClick={() => onChange(on ? value.filter((x) => x !== a.id) : [...value, a.id])}>
              <span className="check box">{on && <CheckMark />}</span>
              <span className="choice-icon"><AppLogo id={a.id} /></span>
              <span className="grow"><span className="title">{a.name}</span></span>
            </button>
          );
        })}
        {!shown.length && <p className="app-none">Ninguna app se llama «{query.trim()}»</p>}
      </div>
      {/* At app level: the scrolling content's fade mask would clip it. */}
      {menu && createPortal(
        <div ref={menuRef} className="menu floating" role="menu" style={{ left: menu.x, top: menu.y }}>
          <button role="menuitem" onClick={() => { setMenu(null); onReinstall?.(menu.app); }}><IconRefresh size={16} />Reinstalar</button>
          <button role="menuitem" className="danger" onClick={() => { setMenu(null); onUninstall?.(menu.app); }}><IconTrash size={16} />Desinstalar</button>
        </div>,
        document.body,
      )}
    </div>
  );
}

// The levels never change while the app runs; loaded once and shared by every picker.
let cleanupCache: CleanupLevel[] | null = null;
export function useCleanupLevels() {
  const [levels, setLevels] = useState<CleanupLevel[]>(cleanupCache ?? []);
  useEffect(() => {
    if (!cleanupCache) api.cleanupLevels().then((l) => { cleanupCache = l; setLevels(l); }).catch(() => {});
  }, []);
  return levels;
}

/** Windows cleanup level as tabs, with everything the chosen level does (each level includes the ones before it). */
export function CleanupPicker({ levels, value, onChange }: { levels: CleanupLevel[]; value: CleanupLevelId; onChange: (v: CleanupLevelId) => void }) {
  const rank = Math.max(0, levels.findIndex((l) => l.id === value));
  const items = levels.slice(0, rank + 1).flatMap((l) => l.items);
  return (
    <div className="cleanup-picker">
      <div className="segment-row">
        <Segmented value={value} onChange={onChange} options={levels.map((l) => ({ value: l.id, label: l.name }))} />
      </div>
      {items.length ? (
        <ul className="cleanup-items">
          {items.map((i) => <li key={i.id}><IconCheck size={14} />{i.description}</li>)}
        </ul>
      ) : <span className="hint">Windows tal como viene, con sus apps y ajustes de fábrica.</span>}
      {items.length > 0 && <span className="hint">Microsoft Defender, Windows Update, SmartScreen y el firewall no se tocan.</span>}
    </div>
  );
}

/** Windows ISOs: the library first (with the machines that used each one), then the ones found on disk. */
export function IsoPicker({ isos, value, onChange, onBrowse, allowNone }: {
  isos: IsoFile[] | null; value: string | null; onChange: (v: string | null) => void; onBrowse: () => void; allowNone?: boolean;
}) {
  return (
    <div className="choice-list" role="radiogroup">
      {isos === null && <div className="skeleton" style={{ height: 52 }} />}
      {allowNone && (
        <button type="button" role="radio" aria-checked={value === null} className={`choice ${value === null ? "on" : ""}`} onClick={() => onChange(null)}>
          <span className="check">{value === null && <CheckMark />}</span>
          <span className="grow"><span className="title">Elegir al crear la máquina</span></span>
        </button>
      )}
      {isos?.map((f) => (
        <button type="button" role="radio" aria-checked={value === f.path} key={f.path} disabled={f.missing}
          className={`choice ${value === f.path ? "on" : ""} ${f.missing ? "missing" : ""}`} onClick={() => onChange(f.path)} title={f.path}>
          <span className="check">{value === f.path && <CheckMark />}</span>
          {f.missing ? <IconAlertTriangle size={18} className="choice-icon" /> : <IconDisc size={18} className="choice-icon" />}
          <span className="grow">
            <span className="title">{f.name}</span>
            <span className="desc">{isoDetail(f)}</span>
          </span>
        </button>
      ))}
      <button type="button" className="choice" onClick={onBrowse}>
        <span className="check plain"><IconFolderOpen size={16} /></span>
        <span className="grow"><span className="title">{isos?.length ? "Buscar otro ISO" : "Elegir ISO"}</span></span>
      </button>
    </div>
  );
}

export function isoDetail(f: IsoFile) {
  if (f.missing) return "Ya no está en esta ruta";
  const parts = [];
  if (f.sizeGB > 0) parts.push(`${f.sizeGB} GB`);
  if (f.usedBy?.length) parts.push(`Usada en ${f.usedBy.join(", ")}`);
  else if (!f.remembered) parts.push(f.path.includes("\\Desktop\\") ? "En el escritorio" : "En descargas");
  return parts.join(" · ");
}

// Monitors only change when one is plugged in or out: read once per screen that shows them.
export function useMonitors() {
  const [monitors, setMonitors] = useState<HostMonitor[]>([]);
  useEffect(() => { api.monitors().then(setMonitors).catch(() => {}); }, []);
  return monitors;
}

const monitorText = (m: HostMonitor) => `${m.name} · ${m.width}×${m.height} · ${m.hz} Hz`;

/** Where Moonlight opens: the primary monitor (follows Windows), a given one, or (per VM) what Preferences say. */
export function MonitorPicker({ monitors, value, onChange, inherited }: {
  monitors: HostMonitor[]; value: string; onChange: (v: string) => void;
  /** Per VM: the monitor Preferences choose, offered as "Predeterminado". */
  inherited?: string;
}) {
  const primary = monitors.find((m) => m.primary) ?? monitors[0];
  const describe = (id: string): string => {
    if (id === "primary") return primary ? `El principal de Windows, ahora ${primary.name}.` : "El principal de Windows.";
    const m = monitors.find((x) => x.id === id);
    return m ? `${monitorText(m)}.` : "No está conectado, se abre en el principal.";
  };
  const known = value === "default" || value === "primary" || monitors.some((m) => m.id === value);
  const options = [
    ...(inherited !== undefined ? [{ value: "default", label: <><IconAdjustments size={15} />Predeterminado</> }] : []),
    { value: "primary", label: <><IconDeviceDesktopStar size={15} />Principal</> },
    ...monitors.map((m) => ({ value: m.id, label: <><IconDeviceDesktop size={15} />{m.name}</> })),
    // A saved monitor that is unplugged stays chosen until another is picked.
    ...(known ? [] : [{ value, label: <><IconDeviceDesktopOff size={15} />Desconectado</> }]),
  ];
  const hint = value === "default" && inherited !== undefined ? `Como en Preferencias. ${describe(inherited)}` : describe(value);
  return (
    <>
      <div className="segment-row">
        <Segmented value={value} onChange={onChange} options={options} />
      </div>
      <span className="hint">{hint}</span>
    </>
  );
}
