import { useEffect, useState } from "react";
import { IconDownload } from "@tabler/icons-react";
import { inTauri } from "./api";
import { t } from "./i18n";
import { refreshPrefs } from "./prefs";
import { TransferRow } from "./FilesWidgets";
import { useTransfers } from "./transfers";

/** How long the card stays once its copy ended. */
const LINGER = 3500;

async function hide() {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  invoke("viewer_drop_hide");
}

/** The window over GpuVM's viewer (label "viewer-drop", dropzone.rs). While files are dragged over the picture it
 *  dims it and shows where they go; a native window above it takes the drop (dropzone.rs) and the copy starts in Rust.
 *  Then the window becomes a small card in the picture's corner with the copy's progress and Cancelar, and goes away
 *  a moment after it ends. It never takes the focus (that would cancel the drag), so it has no keys.
 *  In the browser: "?viewer-drop" shows the drop area, "?viewer-drop&card" a card. */
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
    // The first drag builds this window: what it must show then was sent before the page could hear it.
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
