import {
  IconAlertTriangle, IconBrandChrome, IconBrandDiscord, IconBrandFirefox, IconBrandSteam, IconDeviceGamepad2, IconDisc, IconFolderOpen, IconShieldLock,
} from "@tabler/icons-react";
import type { AppInfo, IsoFile, ProfileSettings } from "./types";
import { CheckMark } from "./ui";

export const RESOLUTIONS = ["1280x720", "1920x1080", "2560x1440", "3840x2160"];
export const FPS = [30, 60, 120, 144];

const PROFILE_NAMES: Record<string, string> = { balanced: "Equilibrado", "max-performance": "Máximo rendimiento" };
export const profileLabel = (name: string) => PROFILE_NAMES[name] ?? name;

const APP_ICONS: Record<string, React.ReactNode> = {
  steam: <IconBrandSteam size={18} />,
  epic: <IconDeviceGamepad2 size={18} />,
  discord: <IconBrandDiscord size={18} />,
  chrome: <IconBrandChrome size={18} />,
  firefox: <IconBrandFirefox size={18} />,
  protonvpn: <IconShieldLock size={18} />,
};

export function profileSummary(s: ProfileSettings, apps: AppInfo[] = []) {
  const parts = [
    `${s.cpu} hilos`, `${s.memoryGB} GB`, `GPU ${s.gpuPercent} %`,
    `disco ${s.diskType === "Fixed" ? "fijo" : "dinámico"} de ${s.diskGB} GB`,
  ];
  if (s.resolution) parts.push(`${s.resolution.split("x")[1]}p ${s.fps ?? 60} FPS${s.displayMode === "windowed" ? " en ventana" : ""}`);
  const names = s.apps.map((id) => apps.find((a) => a.id === id)?.name ?? id);
  if (names.length) parts.push(names.join(", "));
  return parts.join(" · ");
}

export const fileName = (path: string) => path.split("\\").pop() ?? path;

/** Apps from the catalog as toggles, in a grid. */
export function AppPicker({ apps, value, onChange }: { apps: AppInfo[]; value: string[]; onChange: (v: string[]) => void }) {
  return (
    <div className="app-grid" role="group">
      {apps.map((a) => {
        const on = value.includes(a.id);
        return (
          <button type="button" role="checkbox" aria-checked={on} key={a.id} className={`choice ${on ? "on" : ""}`}
            onClick={() => onChange(on ? value.filter((x) => x !== a.id) : [...value, a.id])}>
            <span className="check box">{on && <CheckMark />}</span>
            <span className="choice-icon">{APP_ICONS[a.id] ?? <IconDeviceGamepad2 size={18} />}</span>
            <span className="grow"><span className="title">{a.name}</span></span>
          </button>
        );
      })}
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
