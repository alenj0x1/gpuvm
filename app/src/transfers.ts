import { useEffect, useState } from "react";
import { inTauri } from "./api";

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

/** "Enviando 42 % · 1.2 de 2.9 GB" -> "1.2 de 2.9 GB" (the amount part of the module's progress line). */
export const transferAmount = (t: Transfer) => t.message.split(" · ")[1] ?? "";

/** Every copy the app knows, newest first, kept up to date. */
export function useTransfers(): Transfer[] {
  const [list, setList] = useState<Transfer[]>([]);
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
