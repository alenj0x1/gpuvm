import { inTauri } from "./api";
import { readPrefs } from "./prefs";

/** How many frames a second the app's decorative animations (holograms, scenes) may draw. The VMs share this PC's
 *  GPU, so the app gives it back when nobody is looking (lab 041: the hologram on Home took ~37 % of the GPU):
 *  - 0 (stopped) while a machine's picture is shown over the app or full screen;
 *  - 30 while the window doesn't have the focus;
 *  - otherwise the page's own cap (the website sets one), or every frame.
 *  The person's own limit in Preferences (animFps) caps all of them. */
let covered = false;
let focused = typeof document !== "undefined" ? document.hasFocus() : true;
// Read once and again when Preferences change: animFps() and animDpr() run every frame.
let user = readPrefs();
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((l) => l());

if (typeof window !== "undefined") {
  window.addEventListener("focus", () => { focused = true; changed(); });
  window.addEventListener("blur", () => { focused = false; changed(); });
  // Preferences changed here or in another window of the app.
  const reread = () => { user = readPrefs(); changed(); };
  window.addEventListener("gpuvm-prefs", reread);
  window.addEventListener("storage", (e) => { if (e.key === "gpuvm.prefs") reread(); });
  if (inTauri) {
    import("@tauri-apps/api/event").then(({ listen }) => listen<{ covered: boolean }>("viewer-cover", (e) => { covered = e.payload.covered; changed(); }));
    import("@tauri-apps/api/core").then(({ invoke }) => invoke<boolean>("viewer_covered")).then((c) => { covered = c; changed(); }).catch(() => {});
  }
}

/** Frames a second allowed now: 0 = stop, undefined = every frame. */
export function animFps(): number | undefined {
  if (covered) return 0;
  const caps = [(window as { __gpuvmFps?: number }).__gpuvmFps, user.animFps || undefined, focused ? undefined : 30]
    .filter((c): c is number => !!c);
  return caps.length ? Math.min(...caps) : undefined;
}

/** Paces a loop to `cap` frames a second: the new "drawn at" time when this frame should be drawn, or null to skip
 *  it. Keeps the phase, so 60 on a 75 or 144 Hz monitor gives 60 (gating on the gap since the last frame gave 37-50). */
export function paceFrame(now: number, drawnAt: number, cap: number | undefined): number | null {
  if (!cap) return now;
  const every = 1000 / cap;
  if (now - drawnAt < every - 1) return null;
  return Math.max(drawnAt + every, now - every);
}

/** Device pixels per CSS pixel for the animations' canvases: the screen's, scaled by the quality in Preferences. */
export function animDpr(): number {
  const q = Math.min(100, Math.max(25, user.animQuality || 100)) / 100;
  return (window.devicePixelRatio || 1) * q;
}

/** Called when the budget changes (so a stopped loop can start again). Returns the unsubscribe. */
export function onAnimBudget(cb: () => void): () => void {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}
