import { useEffect, useState } from "react";
import { IconDownload } from "@tabler/icons-react";
import { inTauri } from "./api";
import { t } from "./i18n";
import { refreshPrefs } from "./prefs";

/** The drop area over GpuVM's viewer (window "viewer-drop", dropzone.rs): shown while files are dragged over the
 *  picture. The drop itself is Windows' (the window's own drop target); the copy starts in Rust. It never takes
 *  the focus (that would cancel the drag), so it has no keys: it hides when the files leave or are dropped. */
export function DropZone() {
  const [vm, setVm] = useState(() => new URLSearchParams(location.search).get("vm") ?? "win10");
  const [over, setOver] = useState(!inTauri);

  useEffect(() => {
    if (!inTauri) return;
    const offs: Promise<() => void>[] = [];
    offs.push(import("@tauri-apps/api/event").then(({ listen }) => listen<{ vm: string }>("viewer-drop", (e) => {
      setVm(e.payload.vm);
      setOver(false);
      refreshPrefs();
    })));
    offs.push(import("@tauri-apps/api/webview").then(({ getCurrentWebview }) => getCurrentWebview().onDragDropEvent((e) => {
      setOver(e.payload.type === "enter" || e.payload.type === "over");
    })));
    return () => { offs.forEach((o) => o.then((f) => f())); };
  }, []);

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
