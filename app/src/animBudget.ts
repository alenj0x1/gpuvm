import { inTauri } from "./api";

/** How many frames a second the app's decorative animations (holograms, scenes) may draw. The VMs share this PC's
 *  GPU, so the app gives it back when nobody is looking (lab 041: the hologram on Home took ~37 % of the GPU):
 *  - 0 (stopped) while a machine's picture is shown over the app or full screen;
 *  - 30 while the window doesn't have the focus;
 *  - otherwise the page's own cap (the website sets one), or every frame. */
let covered = false;
let focused = typeof document !== "undefined" ? document.hasFocus() : true;
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((l) => l());

if (typeof window !== "undefined") {
  window.addEventListener("focus", () => { focused = true; changed(); });
  window.addEventListener("blur", () => { focused = false; changed(); });
  if (inTauri) {
    import("@tauri-apps/api/event").then(({ listen }) => listen<{ covered: boolean }>("viewer-cover", (e) => { covered = e.payload.covered; changed(); }));
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<boolean>("viewer_covered")).then((c) => { covered = c; changed(); }).catch(() => {});
  }
}

/** Frames a second allowed now: 0 = stop, undefined = every frame. */
export function animFps(): number | undefined {
  if (covered) return 0;
  const page = (window as { __gpuvmFps?: number }).__gpuvmFps;
  if (!focused) return Math.min(page ?? 30, 30);
  return page;
}

/** Called when the budget changes (so a stopped loop can start again). Returns the unsubscribe. */
export function onAnimBudget(cb: () => void): () => void {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}
