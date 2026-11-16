import { IconApps, IconBolt, IconCpu, IconDatabase, IconSparkles, IconTopologyStar3 } from "@tabler/icons-react";
import type { AppInfo, ProfileSettings } from "./types";
import { t, tn } from "./i18n";

/** Each resource is a piece with its own fixed color, the same everywhere: processor, memory, GPU and disk. */
export const RESOURCES = {
  cpu: { icon: IconCpu, cls: "res-cpu" },
  mem: { icon: IconTopologyStar3, cls: "res-mem" },
  gpu: { icon: IconBolt, cls: "res-gpu" },
  disk: { icon: IconDatabase, cls: "res-disk" },
} as const;

const cleanupName = (id: string) => ({ privacy: t("Privacidad"), apps: t("Sin apps de más"), minimal: t("Mínimo") } as Record<string, string>)[id] ?? "";

/** A machine or profile as its pieces: one small chip per resource, then its apps and cleanup when it has them. */
export function ResourceChips({ s, apps = [] }: { s: ProfileSettings; apps?: AppInfo[] }) {
  const chosen = (s.apps ?? []).map((id) => apps.find((a) => a.id === id)?.name ?? id);
  return (
    <span className="res-chips">
      <Chip kind="cpu">{tn(s.cpu, "{n} hilo", "{n} hilos")}</Chip>
      <Chip kind="mem">{s.memoryGB} GB</Chip>
      <Chip kind="gpu">GPU {s.gpuPercent} %</Chip>
      <Chip kind="disk">{s.diskType === "Fixed" ? t("{gb} GB fijo", { gb: s.diskGB }) : t("{gb} GB dinámico", { gb: s.diskGB })}</Chip>
      {chosen.length > 0 && <span className="res-chip"><IconApps size={13} />{chosen.length > 3 ? t("{names} y {n} más", { names: chosen.slice(0, 3).join(", "), n: chosen.length - 3 }) : chosen.join(", ")}</span>}
      {cleanupName(s.cleanup) && <span className="res-chip"><IconSparkles size={13} />{cleanupName(s.cleanup)}</span>}
    </span>
  );
}

export function Chip({ kind, children }: { kind: keyof typeof RESOURCES; children: React.ReactNode }) {
  const R = RESOURCES[kind];
  return <span className={`res-chip ${R.cls}`}><R.icon size={13} />{children}</span>;
}
