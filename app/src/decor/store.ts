import { useSyncExternalStore } from "react";
import { t } from "../i18n";

export type Face = "front" | "right" | "back" | "left" | "top";
export const FACES: Face[] = ["front", "right", "back", "left", "top"];

export interface StickerPlacement {
  id: string;
  sticker: string;
  face: Face;
  u: number;
  v: number;
  rot: number;
  size: number;
}

export interface FigurePlacement {
  id: string;
  figure: string;
  x: number;
  z: number;
  rot: number;
  size: number;
}

export type LedColor = "amber" | "red" | "green" | "white" | "machine";
export interface LedSign {
  text: string; color: LedColor;
  live: boolean;
  y?: number;
}
export const ledTop = (y = 0) => -0.66 + Math.min(1, Math.max(0, y)) * 1.62;
export const LED_STEP = 2 / 44;

export interface Decor {
  color: string | null;
  led: LedSign | null;
  stickers: StickerPlacement[];
  figures: FigurePlacement[];
}

export const MACHINE_COLORS: { id: string; name: string; light: string; dark: string }[] = [
  { id: "blue", get name() { return t("Blue"); }, light: "#2f5bd3", dark: "#7d9cf0" },
  { id: "violet", get name() { return t("Violet"); }, light: "#6a4fd2", dark: "#a796f2" },
  { id: "pink", get name() { return t("Pink"); }, light: "#b8467a", dark: "#ee8fbd" },
  { id: "red", get name() { return t("Red"); }, light: "#b83a3a", dark: "#f08a84" },
  { id: "coral", get name() { return t("Coral"); }, light: "#c0583a", dark: "#f29b7c" },
  { id: "amber", get name() { return t("Amber"); }, light: "#a8650f", dark: "#e7b45e" },
  { id: "green", get name() { return t("Green"); }, light: "#2f8550", dark: "#7dd19c" },
  { id: "teal", get name() { return t("Teal"); }, light: "#1d7f7c", dark: "#6ccfca" },
];

export const LED_COLORS: { id: LedColor; name: string; hex: string }[] = [
  { id: "amber", get name() { return t("Amber"); }, hex: "#ffb547" },
  { id: "red", get name() { return t("Red"); }, hex: "#ff5a4e" },
  { id: "green", get name() { return t("Green"); }, hex: "#6fe08a" },
  { id: "white", get name() { return t("White"); }, hex: "#f2efe8" },
  { id: "machine", get name() { return t("Machine color"); }, hex: "" },
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
  } catch {}
  cache.set(name, d);
  return d;
}

const pending = new Map<string, Decor>();
let flushTimer = 0;
function flush() {
  flushTimer = 0;
  for (const [n, d] of pending) { try { localStorage.setItem(KEY + n, JSON.stringify(d)); } catch {} }
  pending.clear();
}
window.addEventListener("beforeunload", flush);

export function saveDecor(name: string, d: Decor) {
  if (!name) return;
  cache.set(name, d);
  pending.set(name, d);
  if (!flushTimer) flushTimer = window.setTimeout(flush, 300);
  window.dispatchEvent(new Event(EVENT));
}

export function updateDecor(name: string, change: (d: Decor) => Decor) {
  saveDecor(name, change(readDecor(name)));
}

export function renameDecor(from: string, to: string) {
  const d = readDecor(from);
  cache.delete(from);
  pending.delete(from);
  try { localStorage.removeItem(KEY + from); } catch {}
  saveDecor(to, d);
}

window.addEventListener("storage", (e) => {
  if (!e.key?.startsWith(KEY)) return;
  cache.delete(e.key.slice(KEY.length));
  window.dispatchEvent(new Event(EVENT));
});

function subscribe(onChange: () => void) {
  window.addEventListener(EVENT, onChange);
  return () => window.removeEventListener(EVENT, onChange);
}
export function useDecor(name: string): Decor {
  return useSyncExternalStore(subscribe, () => readDecor(name));
}
export const onDecorChange = subscribe;

export function colorOfDecor(d: Decor, light = document.documentElement.dataset.theme === "light"): string | null {
  const c = MACHINE_COLORS.find((m) => m.id === d.color);
  return c ? (light ? c.light : c.dark) : null;
}
export function decorColor(name: string, light = document.documentElement.dataset.theme === "light"): string | null {
  return colorOfDecor(readDecor(name), light);
}

export const newId = () => Math.random().toString(36).slice(2, 10);

export interface DecorSource {
  name: string;
  get: () => Decor;
  set: (d: Decor) => void;
  subscribe: (onChange: () => void) => () => void;
}
export const machineSource = (name: string): DecorSource => ({ name, get: () => readDecor(name), set: (d) => saveDecor(name, d), subscribe });
export function draftSource(name: string, initial: Decor = EMPTY): DecorSource & { rename: (n: string) => void } {
  let value = initial;
  const listeners = new Set<() => void>();
  const src = {
    name,
    get: () => value,
    set: (d: Decor) => { value = d; listeners.forEach((l) => l()); },
    subscribe: (l: () => void) => { listeners.add(l); const off = subscribe(l); return () => { listeners.delete(l); off(); }; },
    rename: (n: string) => { src.name = n; },
  };
  return src;
}
export function useSource(src: DecorSource): Decor {
  return useSyncExternalStore(src.subscribe, src.get);
}
