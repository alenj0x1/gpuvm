import { useSyncExternalStore } from "react";

// How each machine is decorated: its color, the LED sign around the glass, the stickers on the glass and the
// figures on top of the cube. Kept per machine in localStorage, like its icon and banner; a rename carries it over.

/** A face of the glass cube, as seen from outside. */
export type Face = "front" | "right" | "back" | "left" | "top";
export const FACES: Face[] = ["front", "right", "back", "left", "top"];

export interface StickerPlacement {
  /** This placement (the same sticker can go on the glass several times). */
  id: string;
  /** Which sticker: a built-in one or "custom:<id>" for an image the person added. */
  sticker: string;
  face: Face;
  /** Center on the face, -1 to 1 from left to right and from bottom to top. */
  u: number;
  v: number;
  /** Turn in degrees and size in cube units (the face is 2 wide). */
  rot: number;
  size: number;
}

export interface FigurePlacement {
  id: string;
  figure: string;
  /** Where it stands on the cube's top, -1 to 1. */
  x: number;
  z: number;
  /** Turn in degrees and size (1 = its normal size). */
  rot: number;
  size: number;
}

export type LedColor = "amber" | "red" | "green" | "white" | "machine";
export interface LedSign { text: string; color: LedColor; /** Adds the machine's state and use to the text. */ live: boolean }

export interface Decor {
  /** A color from MACHINE_COLORS; none follows the accent. */
  color: string | null;
  led: LedSign | null;
  stickers: StickerPlacement[];
  figures: FigurePlacement[];
}

/** The machine colors, as they look in light and in dark (soft in light, a little stronger in dark). */
export const MACHINE_COLORS: { id: string; name: string; light: string; dark: string }[] = [
  { id: "blue", name: "Azul", light: "#2f5bd3", dark: "#7d9cf0" },
  { id: "violet", name: "Violeta", light: "#6a4fd2", dark: "#a796f2" },
  { id: "pink", name: "Rosa", light: "#b8467a", dark: "#ee8fbd" },
  { id: "red", name: "Rojo", light: "#b83a3a", dark: "#f08a84" },
  { id: "coral", name: "Coral", light: "#c0583a", dark: "#f29b7c" },
  { id: "amber", name: "Ámbar", light: "#a8650f", dark: "#e7b45e" },
  { id: "green", name: "Verde", light: "#2f8550", dark: "#7dd19c" },
  { id: "teal", name: "Turquesa", light: "#1d7f7c", dark: "#6ccfca" },
];

export const LED_COLORS: { id: LedColor; name: string; hex: string }[] = [
  { id: "amber", name: "Ámbar", hex: "#ffb547" },
  { id: "red", name: "Rojo", hex: "#ff5a4e" },
  { id: "green", name: "Verde", hex: "#6fe08a" },
  { id: "white", name: "Blanco", hex: "#f2efe8" },
  { id: "machine", name: "Color de la máquina", hex: "" },
];

export const EMPTY: Decor = { color: null, led: null, stickers: [], figures: [] };
const KEY = "gpuvm.decor.";
const EVENT = "gpuvm-decor";

const cache = new Map<string, Decor>();
export function readDecor(name: string): Decor {
  if (!name) return EMPTY;
  const hit = cache.get(name);
  if (hit) return hit;
  let d = EMPTY;
  try {
    const raw = localStorage.getItem(KEY + name);
    if (raw) { const p = JSON.parse(raw); d = { ...EMPTY, ...p, stickers: Array.isArray(p.stickers) ? p.stickers : [], figures: Array.isArray(p.figures) ? p.figures : [] }; }
  } catch { /* no storage or bad data */ }
  cache.set(name, d);
  return d;
}

export function saveDecor(name: string, d: Decor) {
  if (!name) return;
  cache.set(name, d);
  try { localStorage.setItem(KEY + name, JSON.stringify(d)); } catch { /* no storage */ }
  window.dispatchEvent(new Event(EVENT));
}

export function updateDecor(name: string, change: (d: Decor) => Decor) {
  saveDecor(name, change(readDecor(name)));
}

/** A renamed machine keeps its decoration. */
export function renameDecor(from: string, to: string) {
  const d = readDecor(from);
  cache.delete(from);
  try { localStorage.removeItem(KEY + from); } catch { /* no storage */ }
  saveDecor(to, d);
}

function subscribe(onChange: () => void) {
  window.addEventListener(EVENT, onChange);
  return () => window.removeEventListener(EVENT, onChange);
}
export function useDecor(name: string): Decor {
  return useSyncExternalStore(subscribe, () => readDecor(name));
}
export const onDecorChange = subscribe;

/** The machine's own color for the theme, or null to follow the accent. */
export function decorColor(name: string, light = document.documentElement.dataset.theme === "light"): string | null {
  const c = MACHINE_COLORS.find((m) => m.id === readDecor(name).color);
  return c ? (light ? c.light : c.dark) : null;
}

export const newId = () => Math.random().toString(36).slice(2, 10);
