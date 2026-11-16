import { useEffect, useState } from "react";
import { IconCopy, IconMinus, IconSquare, IconX } from "@tabler/icons-react";
import { inTauri } from "./api";
import { t } from "./i18n";

// Custom title bar: the Windows 10 one takes the system accent color instead of the app theme's.
// It spans the same columns as the sidebar and the content, so each part keeps its own color.
/** Only the window's own controls: Biblioteca and Ajustes live in the sidebar, the theme in Ajustes. */
export function TitleBar() {
  const [maximized, setMaximized] = useState(false);

  useEffect(() => {
    if (!inTauri) return;
    let unlisten: (() => void) | undefined;
    let alive = true;
    (async () => {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      const win = getCurrentWindow();
      const sync = async () => {
        const value = await win.isMaximized();
        document.documentElement.classList.toggle("maximized", value);
        if (alive) setMaximized(value);
      };
      await sync();
      const off = await win.onResized(sync);
      if (alive) unlisten = off; else off();
    })();
    return () => { alive = false; unlisten?.(); };
  }, []);

  const act = async (action: "minimize" | "toggleMaximize" | "close") => {
    if (!inTauri) return;
    const { getCurrentWindow } = await import("@tauri-apps/api/window");
    await getCurrentWindow()[action]();
  };

  return (
    <div className="titlebar">
      <div className="titlebar-side" data-tauri-drag-region />
      <div className="titlebar-main" data-tauri-drag-region>
        <div className="win-controls">
          <button aria-label={t("Minimizar")} onClick={() => act("minimize")}><IconMinus size={16} /></button>
          <button aria-label={maximized ? t("Restaurar") : t("Maximizar")} onClick={() => act("toggleMaximize")}>
            {maximized ? <IconCopy size={14} /> : <IconSquare size={13} />}
          </button>
          <button className="win-close" aria-label={t("Cerrar")} onClick={() => act("close")}><IconX size={16} /></button>
        </div>
      </div>
    </div>
  );
}
