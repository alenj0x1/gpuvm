import { useEffect, useState } from "react";
import { inTauri } from "./api";
import { locale, t } from "./i18n";

// Copies of files into machines (dropzone.rs keeps the list; every window sees the same one).

export type TransferState = "running" | "done" | "error" | "cancelled";
export interface Transfer {
  id: string; vm: string; from: string | null; names: string[]; state: TransferState;
  percent: number; message: string; error: string | null; items: string[]; folder?: string;
}

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!inTauri) return null;
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

export const startTransfer = (vm: string, paths: string[], folder: string, from?: string) =>
  invoke<string>("transfer_start", { vm, paths, folder, from: from ?? null });
export const cancelTransfer = (id: string) => invoke("transfer_cancel", { id });

/** "Enviando 42 % · 1.2 de 2.9 GB" -> "1,2 de 2,9 GB" in the app's language (the module sends invariant numbers). */
export const transferAmount = (tr: Transfer) => {
  const m = /· ([\d.]+) de ([\d.]+) (\w+)$/.exec(tr.message);
  if (!m) return "";
  const n = (v: string) => Number(v).toLocaleString(locale(), { maximumFractionDigits: 1 });
  return t("{sent} de {total}", { sent: n(m[1]), total: `${n(m[2])} ${m[3]}` });
};

const SAMPLE: Transfer[] = [
  { id: "a", vm: "win10", from: null, names: ["fotos-vacaciones", "informe.pdf"], state: "running", percent: 42, message: "Enviando 42 % · 1.2 de 2.9 GB", error: null, items: [] },
  { id: "b", vm: "win11-pruebas", from: "win10", names: ["presupuesto.xlsx"], state: "done", percent: 100, message: "", error: null, items: ["presupuesto.xlsx"], folder: "Recibidos" },
  { id: "c", vm: "win10", from: null, names: ["setup.iso"], state: "error", percent: 0, message: "", error: "No cabe: son 6200 MB y win10 tiene 4100 MB libres.", items: [] },
];

/** Every copy the app knows, newest first, kept up to date. */
export function useTransfers(): Transfer[] {
  // In the browser preview: one copy going and two that ended, so the widget can be seen with content.
  const [list, setList] = useState<Transfer[]>(() => inTauri || new URLSearchParams(location.search).has("empty") ? [] : SAMPLE);
  useEffect(() => {
    if (!inTauri) return;
    let stop = () => {};
    let alive = true;
    invoke<Transfer[]>("transfer_list").then((all) => { if (alive && all) setList([...all].reverse()); });
    import("@tauri-apps/api/event").then(({ listen }) => listen<Transfer>("transfer", (e) => {
      setList((old) => [e.payload, ...old.filter((t) => t.id !== e.payload.id)].slice(0, 20));
    })).then((un) => { if (alive) stop = un; else un(); });
    return () => { alive = false; stop(); };
  }, []);
  return list;
}
