import { useEffect, useState } from "react";
import { inTauri } from "./api";

/** A machine whose viewer is open (connected): inside the app's window (embed) or full screen, shown or waiting in
 *  the background while the person is in Home. */
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

/** Back to a connected machine's picture. */
export async function showViewer(vm: string) {
  await invoke("viewer_show", { vm });
  await refresh();
}

/** Leaves the picture for Home: hidden and still connected, or disconnected. */
export async function leaveViewer(vm: string, keep: boolean) {
  await invoke("viewer_home", { vm, keep }).catch(() => {});
  await refresh();
}
