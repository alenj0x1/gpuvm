import { inTauri } from "./api";
import { readPrefs } from "./prefs";

let covered = false;
let focused = typeof document !== "undefined" ? document.hasFocus() : true;
let user = readPrefs();
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((l) => l());

if (typeof window !== "undefined") {
  window.addEventListener("focus", () => { focused = true; changed(); });
  window.addEventListener("blur", () => { focused = false; changed(); });
  const reread = () => { user = readPrefs(); changed(); };
  window.addEventListener("gpuvm-prefs", reread);
  window.addEventListener("storage", (e) => { if (e.key === "gpuvm.prefs") reread(); });
  if (inTauri) {
    import("@tauri-apps/api/event").then(({ listen }) => listen<{ covered: boolean }>("viewer-cover", (e) => { covered = e.payload.covered; changed(); }));
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<boolean>("viewer_covered")).then((c) => { covered = c; changed(); }).catch(() => {});
  }
}

export function animFps(): number | undefined {
  if (covered) return 0;
  const caps = [(window as { __gpuvmFps?: number }).__gpuvmFps, user.animFps || undefined, focused ? undefined : 30]
    .filter((c): c is number => !!c);
  return caps.length ? Math.min(...caps) : undefined;
}

/** Keeps the phase, so 60 on a 75 or 144 Hz monitor gives 60 (gating on the gap since the last frame gave 37-50). */
export function paceFrame(now: number, drawnAt: number, cap: number | undefined): number | null {
  if (!cap) return now;
  const every = 1000 / cap;
  if (now - drawnAt < every - 1) return null;
  return Math.max(drawnAt + every, now - every);
}

export function animDpr(): number {
  const q = Math.min(100, Math.max(25, user.animQuality || 100)) / 100;
  return (window.devicePixelRatio || 1) * q;
}

export function onAnimBudget(cb: () => void): () => void {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}
