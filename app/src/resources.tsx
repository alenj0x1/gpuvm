import { IconApps, IconBolt, IconCpu, IconDatabase, IconSparkles, IconTopologyStar3 } from "@tabler/icons-react";
import type { AppInfo, ProfileSettings } from "./types";

/** Each resource is a piece with its own fixed color, the same everywhere: processor, memory, GPU and disk. */
export const RESOURCES = {
  cpu: { icon: IconCpu, cls: "res-cpu" },
  mem: { icon: IconTopologyStar3, cls: "res-mem" },
  gpu: { icon: IconBolt, cls: "res-gpu" },
  disk: { icon: IconDatabase, cls: "res-disk" },
} as const;

const CLEANUP_NAME: Record<string, string> = { none: "", privacy: "Privacidad", apps: "Sin apps de más", minimal: "Mínimo" };

/** A machine or profile as its pieces: one small chip per resource, then its apps and cleanup when it has them. */
export function ResourceChips({ s, apps = [] }: { s: ProfileSettings; apps?: AppInfo[] }) {
  const chosen = (s.apps ?? []).map((id) => apps.find((a) => a.id === id)?.name ?? id);
  return (
    <span className="res-chips">
      <Chip kind="cpu">{s.cpu} hilos</Chip>
      <Chip kind="mem">{s.memoryGB} GB</Chip>
      <Chip kind="gpu">GPU {s.gpuPercent} %</Chip>
      <Chip kind="disk">{s.diskGB} GB {s.diskType === "Fixed" ? "fijo" : "dinámico"}</Chip>
      {chosen.length > 0 && <span className="res-chip"><IconApps size={13} />{chosen.slice(0, 3).join(", ")}{chosen.length > 3 ? ` y ${chosen.length - 3} más` : ""}</span>}
      {CLEANUP_NAME[s.cleanup] && <span className="res-chip"><IconSparkles size={13} />{CLEANUP_NAME[s.cleanup]}</span>}
    </span>
  );
}

export function Chip({ kind, children }: { kind: keyof typeof RESOURCES; children: React.ReactNode }) {
  const R = RESOURCES[kind];
  return <span className={`res-chip ${R.cls}`}><R.icon size={13} />{children}</span>;
}
