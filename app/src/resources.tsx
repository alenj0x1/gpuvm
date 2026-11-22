import { IconApps, IconBolt, IconCpu, IconDatabase, IconSparkles, IconTopologyStar3 } from "@tabler/icons-react";
import type { AppInfo, ProfileSettings } from "./types";
import { t, tn } from "./i18n";

export const RESOURCES = {
  cpu: { icon: IconCpu, cls: "res-cpu" },
  mem: { icon: IconTopologyStar3, cls: "res-mem" },
  gpu: { icon: IconBolt, cls: "res-gpu" },
  disk: { icon: IconDatabase, cls: "res-disk" },
} as const;

const cleanupName = (id: string) => ({ privacy: t("Privacy"), apps: t("No extra apps"), minimal: t("Minimal") } as Record<string, string>)[id] ?? "";

export function ResourceChips({ s, apps = [] }: { s: ProfileSettings; apps?: AppInfo[] }) {
  const chosen = (s.apps ?? []).map((id) => apps.find((a) => a.id === id)?.name ?? id);
  return (
    <span className="res-chips">
      <Chip kind="cpu">{tn(s.cpu, "{n} thread", "{n} threads")}</Chip>
      <Chip kind="mem">{s.memoryGB} GB</Chip>
      <Chip kind="gpu">GPU {s.gpuPercent} %</Chip>
      <Chip kind="disk">{s.diskType === "Fixed" ? t("{gb} GB fixed", { gb: s.diskGB }) : t("{gb} GB dynamic", { gb: s.diskGB })}</Chip>
      {chosen.length > 0 && <span className="res-chip"><IconApps size={13} />{chosen.length > 3 ? t("{names} and {n} more", { names: chosen.slice(0, 3).join(", "), n: chosen.length - 3 }) : chosen.join(", ")}</span>}
      {cleanupName(s.cleanup) && <span className="res-chip"><IconSparkles size={13} />{cleanupName(s.cleanup)}</span>}
    </span>
  );
}

export function Chip({ kind, children }: { kind: keyof typeof RESOURCES; children: React.ReactNode }) {
  const R = RESOURCES[kind];
  return <span className={`res-chip ${R.cls}`}><R.icon size={13} />{children}</span>;
}
