import { useEffect, useState } from "react";
import { IconDownload } from "@tabler/icons-react";
import { inTauri } from "./api";
import { t } from "./i18n";
import { refreshPrefs } from "./prefs";
import { TransferRow } from "./FilesWidgets";
import { useTransfers } from "./transfers";

const LINGER = 3500;

async function hide() {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  invoke("viewer_drop_hide");
}

/** Never takes the focus: that would cancel the drag. */
export function DropZone() {
  const params = new URLSearchParams(location.search);
  const [vm, setVm] = useState(() => params.get("vm") ?? (inTauri ? "" : "win10"));
  const [over, setOver] = useState(!inTauri);
  const [card, setCard] = useState<string | null>(() => (params.has("card") ? "sample" : null));
  const transfers = useTransfers();

  useEffect(() => {
    if (!inTauri) return;
    type DropState = { vm: string | null; state: "drag" | "over" | "card"; id?: string | null };
    const apply = (p: DropState) => {
      if (p.vm) setVm(p.vm);
      setOver(p.state === "over");
      setCard(p.state === "card" ? p.id ?? null : null);
      if (p.state === "drag") refreshPrefs();
    };
    // The first drag creates this window: its initial state was sent before the page was listening.
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<DropState>("viewer_drop_state")).then(apply).catch(() => {});
    const off = import("@tauri-apps/api/event").then(({ listen }) => listen<DropState>("viewer-drop", (e) => apply(e.payload)));
    return () => { off.then((f) => f()); };
  }, []);

  const tr = card === "sample"
    ? { id: "sample", vm, from: null, names: ["fotos-vacaciones", "informe.pdf"], state: "running" as const, percent: 42, message: "Sending 42 % · 1.2 of 2.9 GB", error: null, items: [] }
    : transfers.find((x) => x.id === card);
  const ended = !!tr && tr.state !== "running";
  useEffect(() => {
    if (!ended || card === "sample") return;
    const timer = setTimeout(hide, LINGER);
    return () => clearTimeout(timer);
  }, [ended, card]);

  if (card) {
    return <div className="drop-progress">{tr && <ul><TransferRow tr={tr} /></ul>}</div>;
  }
  return (
    <div className={`drop-veil${over ? " over" : ""}`}>
      <div className="drop-card">
        <span className="drop-icon"><IconDownload size={22} /></span>
        <strong>{t("Drop to send")}</strong>
        <span>{t("{vm} · Desktop › {folder}", { vm, folder: t("Received") })}</span>
      </div>
    </div>
  );
}
