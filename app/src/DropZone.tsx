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
 *  dims it and shows where they go; the drop is Windows' own (the window's drop target) and the copy starts in Rust.
 *  Then the window becomes a small card in the picture's corner with the copy's progress and Cancelar, and goes away
 *  a moment after it ends. It never takes the focus (that would cancel the drag), so it has no keys.
 *  In the browser: "?viewer-drop" shows the drop area, "?viewer-drop&card" a card. */
export function DropZone() {
  const params = new URLSearchParams(location.search);
  const [vm, setVm] = useState(() => params.get("vm") ?? "win10");
  const [over, setOver] = useState(!inTauri);
  const [card, setCard] = useState<string | null>(() => (params.has("card") ? "sample" : null));
  const transfers = useTransfers();

  useEffect(() => {
    if (!inTauri) return;
    const offs: Promise<() => void>[] = [];
    offs.push(import("@tauri-apps/api/event").then(({ listen }) => listen<{ vm: string; state: "drag" | "card"; id?: string }>("viewer-drop", (e) => {
      setVm(e.payload.vm);
      setOver(false);
      setCard(e.payload.state === "card" ? e.payload.id ?? null : null);
      if (e.payload.state === "drag") refreshPrefs();
    })));
    offs.push(import("@tauri-apps/api/webview").then(({ getCurrentWebview }) => getCurrentWebview().onDragDropEvent((e) => {
      setOver(e.payload.type === "enter" || e.payload.type === "over");
    })));
    return () => { offs.forEach((o) => o.then((f) => f())); };
  }, []);

  const tr = card === "sample"
    ? { id: "sample", vm, from: null, names: ["fotos-vacaciones", "informe.pdf"], state: "running" as const, percent: 42, message: "Enviando 42 % · 1.2 de 2.9 GB", error: null, items: [] }
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
        <strong>{t("Soltar para enviar")}</strong>
        <span>{t("{vm} · Escritorio › {folder}", { vm, folder: t("Recibidos") })}</span>
      </div>
    </div>
  );
}
