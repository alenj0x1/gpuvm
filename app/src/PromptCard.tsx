import { useEffect, useState } from "react";
import { IconCheck, IconLoader2, IconShieldLock, IconX } from "@tabler/icons-react";
import { adminPromptAnswered, api, inTauri } from "./api";
import { humanError } from "./ui";
import type { AdminPrompt } from "./types";

/**
 * The small always-on-top card shown over Moonlight while Windows in a VM asks for administrator permission (WGC
 * can't stream that prompt). It shows what asks and from whom, as Windows does, and answers it on the person's click.
 */
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
      await api.answerAdminPrompt(prompt.name, choice, prompt.id);
      await adminPromptAnswered(prompt.id);
    }
    catch (e) { setError(humanError(e)); setBusy(null); }
  };

  return (
    <div className="prompt-card" role="alertdialog" aria-labelledby="prompt-title">
      <div className="prompt-head">
        <span className="prompt-icon"><IconShieldLock size={18} /></span>
        <strong id="prompt-title">{prompt.name} pide permiso de administrador</strong>
      </div>
      <div className="prompt-app">
        <span className="prompt-name">{prompt.app || "Un programa"}</span>
        <span className={unknown ? "prompt-publisher unknown" : "prompt-publisher"}>{unknown ? "Editor desconocido" : prompt.publisher}</span>
      </div>
      {error && <span className="error-text">{error}</span>}
      <div className="prompt-actions">
        <button type="button" className="btn ghost" disabled={!!busy} onClick={() => answer("Deny")}>
          {busy === "Deny" ? <IconLoader2 size={16} className="spin" /> : <IconX size={16} />}Rechazar
        </button>
        <button type="button" className="primary compact" disabled={!!busy} onClick={() => answer("Allow")}>
          {busy === "Allow" ? <IconLoader2 size={16} className="spin" /> : <IconCheck size={16} />}Permitir
        </button>
      </div>
    </div>
  );
}
