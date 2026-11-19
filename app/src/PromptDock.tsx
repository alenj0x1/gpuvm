import { useEffect, useRef, useState } from "react";
import { IconCheck, IconLoader2, IconShieldLock, IconX } from "@tabler/icons-react";
import { inTauri } from "./api";
import { humanError } from "./ui";
import { t, translateModule } from "./i18n";
import type { AdminPrompt } from "./types";
import * as mock from "./mock";
import { useReportDockSize } from "./dockSize";

/** Time after the dock lands before its buttons take clicks: a click meant for the picture never answers it. */
const ARM_MS = 450;

/**
 * The administrator-prompt dock (lab 042): a window of GpuVM over the machine's picture, the size of the picture. The
 * picture darkens like Windows' secure desktop and the prompt drops from its top center, attached to the edge. The
 * answer is decided here, never by the viewer (dock.rs).
 */
export function PromptDock() {
  const [prompt, setPrompt] = useState<AdminPrompt | null>(null);
  const [shown, setShown] = useState(false);
  const [armed, setArmed] = useState(false);
  const [busy, setBusy] = useState<"Allow" | "Deny" | null>(null);
  const [error, setError] = useState("");
  const armTimer = useRef<number>(0);
  const dockRef = useRef<HTMLDivElement>(null);
  useReportDockSize(dockRef, shown);

  useEffect(() => {
    let off: (() => void) | undefined;
    const take = (p: AdminPrompt | null) => {
      if (p) {
        setPrompt((old) => {
          // A different prompt (or the first): arms again after it lands.
          if (!old || old.id !== p.id || old.name !== p.name) {
            setBusy(null); setError(""); setArmed(false);
            window.clearTimeout(armTimer.current);
            armTimer.current = window.setTimeout(() => setArmed(true), 320 + ARM_MS);
          }
          return p;
        });
        // A moment after the first paint, so it drops instead of appearing (a timer, not rAF: it also runs when the
        // window isn't painting yet).
        window.setTimeout(() => setShown(true), 30);
      } else {
        setShown(false);
      }
    };
    (async () => {
      if (!inTauri) { take((await mock.adminPrompts())[0] ?? null); return; }
      const { invoke } = await import("@tauri-apps/api/core");
      take(await invoke<AdminPrompt | null>("dock_prompt"));
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      off = await getCurrentWebviewWindow().listen<{ prompt: AdminPrompt | null }>("prompt-dock", (e) => take(e.payload.prompt));
    })();
    return () => { off?.(); window.clearTimeout(armTimer.current); };
  }, []);

  if (!prompt) return null;
  const unknown = !prompt.publisher || /desconocido|unknown/i.test(prompt.publisher);
  const ready = armed && !busy && !prompt.reading;

  const answer = async (choice: "Allow" | "Deny") => {
    if (!ready) return;
    setBusy(choice);
    setError("");
    try {
      if (!inTauri) { await new Promise((r) => setTimeout(r, 400)); setShown(false); return; }
      // Only which button: the machine and the prompt are the ones GpuVM put in this dock (dock.rs).
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("dock_answer", { allow: choice === "Allow" });
    }
    catch (e) { setError(humanError(e)); setBusy(null); }
  };

  return (
    <div className="dock-stage">
      <div className={shown ? "dock-veil on" : "dock-veil"} />
      <div ref={dockRef} className={shown ? "dock on" : "dock"} role="alertdialog" aria-labelledby="dock-app" aria-describedby="dock-publisher">
        <span className="dock-icon"><IconShieldLock size={18} /></span>
        <div className="dock-text">
          {prompt.reading ? <><span className="dock-skeleton" /><span className="dock-skeleton short" /></> : <>
            <strong id="dock-app">{prompt.app ? translateModule(prompt.app) : t("A program")}</strong>
            <span id="dock-publisher" className={unknown ? "unknown" : undefined}>{unknown ? t("Unknown publisher") : prompt.publisher}</span>
          </>}
          {error && <span className="dock-error">{error}</span>}
        </div>
        <div className="dock-actions">
          <button type="button" className="dock-btn dock-deny" disabled={!ready && busy !== "Deny"} aria-busy={busy === "Deny"} onClick={() => answer("Deny")}>
            {busy === "Deny" ? <IconLoader2 size={15} className="spin" /> : <IconX size={15} />}{busy === "Deny" ? t("Denying") : t("Deny")}
          </button>
          <button type="button" className="dock-btn dock-allow" disabled={!ready && busy !== "Allow"} aria-busy={busy === "Allow"} onClick={() => answer("Allow")}>
            {busy === "Allow" ? <IconLoader2 size={15} className="spin" /> : <IconCheck size={15} />}{busy === "Allow" ? t("Allowing") : t("Allow")}
          </button>
        </div>
      </div>
    </div>
  );
}
