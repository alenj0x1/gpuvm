import { useEffect, useState } from "react";
import { IconCopy, IconMinus, IconMoon, IconSettings, IconSquare, IconStack2, IconSun, IconX } from "@tabler/icons-react";
import { inTauri } from "./api";
import { resolvedTheme, savePrefs, usePrefs } from "./prefs";

// Custom title bar: the Windows 10 one takes the system accent color instead of the app theme's.
// It spans the same columns as the sidebar and the content, so each part keeps its own color.
export function TitleBar({ prefsOpen = false, onPrefs, libraryOpen = false, onLibrary }: {
  prefsOpen?: boolean; onPrefs?: () => void; libraryOpen?: boolean; onLibrary?: () => void;
}) {
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

  const dark = resolvedTheme(usePrefs().theme) === "dark";

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
          {onLibrary && (
            <button className={`app-action ${libraryOpen ? "on" : ""}`} aria-label="Biblioteca" title="Biblioteca: perfiles, discos e ISOs" onClick={onLibrary}>
              <IconStack2 size={16} />
            </button>
          )}
          {onPrefs && (
            <button className={`app-action ${prefsOpen ? "on" : ""}`} aria-label="Preferencias" title="Preferencias" onClick={onPrefs}>
              <IconSettings size={16} />
            </button>
          )}
          <button className="app-action" aria-label={dark ? "Cambiar a claro" : "Cambiar a oscuro"} title={dark ? "Cambiar a claro" : "Cambiar a oscuro"}
            onClick={() => savePrefs({ theme: dark ? "light" : "dark" })}>
            {dark ? <IconSun size={16} /> : <IconMoon size={16} />}
          </button>
          <button aria-label="Minimizar" onClick={() => act("minimize")}><IconMinus size={16} /></button>
          <button aria-label={maximized ? "Restaurar" : "Maximizar"} onClick={() => act("toggleMaximize")}>
            {maximized ? <IconCopy size={14} /> : <IconSquare size={13} />}
          </button>
          <button className="win-close" aria-label="Cerrar" onClick={() => act("close")}><IconX size={16} /></button>
        </div>
      </div>
    </div>
  );
}
