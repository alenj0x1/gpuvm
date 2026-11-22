import { useEffect, useState } from "react";
import { IconCopy, IconMinus, IconSquare, IconX } from "@tabler/icons-react";
import { inTauri } from "./api";
import { t } from "./i18n";

// Custom title bar: Windows 10's takes the system accent color instead of the app theme's.
export function TitleBar({ children }: { children?: React.ReactNode } = {}) {
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
      <div className="titlebar-side" data-tauri-drag-region>{children}</div>
      <div className="titlebar-main" data-tauri-drag-region>
        <div className="win-controls">
          <button aria-label={t("Minimize")} onClick={() => act("minimize")}><IconMinus size={16} /></button>
          <button aria-label={maximized ? t("Restore") : t("Maximize")} onClick={() => act("toggleMaximize")}>
            {maximized ? <IconCopy size={14} /> : <IconSquare size={13} />}
          </button>
          <button className="win-close" aria-label={t("Close")} onClick={() => act("close")}><IconX size={16} /></button>
        </div>
      </div>
    </div>
  );
}
