import { IconAlertTriangle, IconApps, IconCheck, IconDisc, IconFolderOpen, IconSearch, IconX } from "@tabler/icons-react";
import { useEffect, useMemo, useState } from "react";
import { api } from "./api";
import type { AppInfo, CleanupLevel, CleanupLevelId, IsoFile, ProfileSettings } from "./types";
import { CheckMark, Segmented, useScrollFade } from "./ui";

export const RESOLUTIONS = ["1280x720", "1920x1080", "2560x1440", "3840x2160"];
export const FPS = [30, 60, 120, 144];

const PROFILE_NAMES: Record<string, string> = { balanced: "Equilibrado", "max-performance": "Máximo rendimiento" };
export const profileLabel = (name: string) => PROFILE_NAMES[name] ?? name;

// Each app's own icon, in color (tools/app-icons/extract.ps1 takes them from the official installers).
const APP_ICONS = import.meta.glob<string>("./assets/apps/*.{png,svg}", { eager: true, query: "?url", import: "default" });

function AppLogo({ id }: { id: string }) {
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
  if (s.resolution) parts.push(`${s.resolution.split("x")[1]}p ${s.fps ?? 60} FPS${s.displayMode === "windowed" ? " en ventana" : ""}`);
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
export function AppPicker({ apps, value, onChange, scroll = true }: { apps: AppInfo[]; value: string[]; onChange: (v: string[]) => void; scroll?: boolean }) {
  const [query, setQuery] = useState("");
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
