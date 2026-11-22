import { useEffect, useState } from "react";
import { IconCheck, IconLoader2, IconShieldLock, IconX } from "@tabler/icons-react";
import { api, inTauri } from "./api";
import { humanError } from "./ui";
import { t, translateModule } from "./i18n";
import type { AdminPrompt } from "./types";

/** Shown over the viewer because WGC can't capture the guest's administrator prompt. */
export function PromptCard() {
  const [prompts, setPrompts] = useState<AdminPrompt[]>([]);
  const [busy, setBusy] = useState<"Allow" | "Deny" | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let off: (() => void) | undefined;
    (async () => {
      setPrompts(await api.adminPrompts());
      if (!inTauri) return;
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      off = await getCurrentWebviewWindow().listen<AdminPrompt[]>("admin-prompt", (e) => { setPrompts(e.payload); setBusy(null); setError(""); });
    })();
    return () => off?.();
  }, []);

  const prompt = prompts[0];
  if (!prompt) return null;
  const unknown = !prompt.publisher || /desconocido|unknown/i.test(prompt.publisher);

  const answer = async (choice: "Allow" | "Deny") => {
    setBusy(choice);
    setError("");
    try {
      if (!inTauri) { await new Promise((r) => setTimeout(r, 400)); setPrompts([]); return; }
      // Narrow command: only a prompt GpuVM put on this card can be answered (prompt.rs).
      const { invoke } = await import("@tauri-apps/api/core");
      await invoke("card_answer", { name: prompt.name, id: prompt.id, allow: choice === "Allow" });
    }
    catch (e) { setError(humanError(e)); setBusy(null); }
  };

  return (
    <div className="prompt-card" role="alertdialog" aria-labelledby="prompt-title">
      <div className="prompt-head">
        <span className="prompt-icon"><IconShieldLock size={18} /></span>
        <strong id="prompt-title">{t("{name} asks for administrator permission", { name: prompt.name })}</strong>
      </div>
      <div className="prompt-app">
        {prompt.reading ? <><span className="prompt-name skeleton-line" /><span className="prompt-publisher skeleton-line short" /></> : <>
          <span className="prompt-name">{prompt.app ? translateModule(prompt.app) : t("A program")}</span>
          <span className={unknown ? "prompt-publisher unknown" : "prompt-publisher"}>{unknown ? t("Unknown publisher") : prompt.publisher}</span>
        </>}
      </div>
      {error && <span className="error-text">{error}</span>}
      <div className="prompt-actions">
        <button type="button" className="btn ghost" disabled={!!busy || !!prompt.reading} onClick={() => answer("Deny")}>
          {busy === "Deny" ? <IconLoader2 size={16} className="spin" /> : <IconX size={16} />}{t("Deny")}
        </button>
        <button type="button" className="primary compact" disabled={!!busy || !!prompt.reading} onClick={() => answer("Allow")}>
          {busy === "Allow" ? <IconLoader2 size={16} className="spin" /> : <IconCheck size={16} />}{t("Allow")}
        </button>
      </div>
    </div>
  );
}
