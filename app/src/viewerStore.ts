import { useEffect, useState } from "react";
import { inTauri } from "./api";

export interface OpenViewer { vm: string; embed: boolean; visible: boolean }

let open: OpenViewer[] = [];
const listeners = new Set<(list: OpenViewer[]) => void>();
let started = false;

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

async function refresh() {
  if (!inTauri) return;
  open = await invoke<OpenViewer[]>("viewer_list").catch(() => open);
  listeners.forEach((l) => l(open));
}

function start() {
  if (started || !inTauri) return;
  started = true;
  import("@tauri-apps/api/event").then(({ listen }) => listen<{ vm: string; msg: { type: string } }>("viewer", (e) => {
    if (["opened", "first-frame", "closed"].includes(e.payload.msg.type)) refresh();
  }));
  // An event can be missed while the window sleeps in the background: asked again when it comes back.
  window.addEventListener("focus", () => { refresh(); });
  refresh();
}

export function openViewers(): OpenViewer[] { return open; }

export function useOpenViewers(): OpenViewer[] {
  const [list, setList] = useState(open);
  useEffect(() => {
    start();
    listeners.add(setList);
    return () => { listeners.delete(setList); };
  }, []);
  return list;
}

export async function closeGoneViewers(names: string[]) {
  if (!inTauri) return;
  const list = await invoke<OpenViewer[]>("viewer_list").catch(() => [] as OpenViewer[]);
  const known = new Set(names.map((n) => n.toLowerCase()));
  const gone = list.filter((v) => !known.has(v.vm.toLowerCase()));
  for (const v of gone) await invoke("viewer_gone", { vm: v.vm }).catch(() => {});
  if (gone.length) await refresh();
}

export async function showViewer(vm: string) {
  await invoke("viewer_show", { vm });
  await refresh();
}

export async function leaveViewer(vm: string, keep: boolean) {
  await invoke("viewer_home", { vm, keep }).catch(() => {});
  await refresh();
}
