import { useSyncExternalStore } from "react";
import { normalizeAmbient, type AmbientId, type AmbientTime } from "./ambient";
import { getLang, t } from "./i18n";

export interface Space {
  id: string;
  name: string;
  ambient: AmbientId;
  time?: AmbientTime;
  machines: string[];
}

export const MAIN_SPACE = "main";
const KEY = "gpuvm.spaces";
const EVENT = "gpuvm-spaces";
// Saved as "" until renamed, so its default name follows the app's language.
const defaultName = () => t("My machines");
const defaults = (): Space[] => [{ id: MAIN_SPACE, name: "", ambient: "studio", machines: [] }];

let cache: Space[] | null = null;
let cacheLang = getLang();
export function readSpaces(): Space[] {
  if (cache && cacheLang === getLang()) return cache;
  cacheLang = getLang();
  const DEFAULT = defaults();
  let list = DEFAULT;
  try {
    const raw = localStorage.getItem(KEY);
    if (raw) {
      const p = JSON.parse(raw);
      if (Array.isArray(p) && p.length) list = p.filter((s) => s && typeof s.id === "string").map((s) => ({ id: s.id, name: s.name, ambient: normalizeAmbient(s.ambient), time: ["day", "evening", "night", "auto"].includes(s.time) ? s.time : undefined, machines: Array.isArray(s.machines) ? s.machines : [] }));
    }
  } catch {}
  if (!list.some((s) => s.id === MAIN_SPACE)) list = [DEFAULT[0], ...list];
  list = list.map((s) => (s.id === MAIN_SPACE && !s.name ? { ...s, name: defaultName() } : s));
  cache = list;
  return list;
}

function write(list: Space[]) {
  const saved = list.map((s) => (s.id === MAIN_SPACE && s.name === defaultName() ? { ...s, name: "" } : s));
  cache = list.map((s) => (s.id === MAIN_SPACE && !s.name ? { ...s, name: defaultName() } : s));
  cacheLang = getLang();
  try { localStorage.setItem(KEY, JSON.stringify(saved)); } catch {}
  window.dispatchEvent(new Event(EVENT));
}

function subscribe(onChange: () => void) {
  const storage = (e: StorageEvent) => { if (e.key === KEY) { cache = null; onChange(); } };
  window.addEventListener(EVENT, onChange);
  window.addEventListener("storage", storage);
  return () => { window.removeEventListener(EVENT, onChange); window.removeEventListener("storage", storage); };
}
export const useSpaces = () => useSyncExternalStore(subscribe, readSpaces);

export function spaceOf(name: string, list = readSpaces()): Space {
  return list.find((s) => s.machines.includes(name)) ?? list.find((s) => s.id === MAIN_SPACE)!;
}
export function machinesIn<T extends { name: string }>(space: Space, all: T[], list = readSpaces()): T[] {
  const at = (v: T) => { const i = space.machines.indexOf(v.name); return i < 0 ? Infinity : i; };
  return all.filter((v) => spaceOf(v.name, list).id === space.id).map((v, i) => ({ v, i })).sort((a, b) => at(a.v) - at(b.v) || a.i - b.i).map((x) => x.v);
}
export const useSpaceOf = (name: string) => spaceOf(name, useSpaces());

const newId = () => Math.random().toString(36).slice(2, 9);

export function saveSpace(s: Omit<Space, "id"> & { id?: string }): Space {
  const id = s.id ?? newId();
  const next: Space = { id, name: s.name.trim() || (id === MAIN_SPACE ? defaultName() : t("Space")), ambient: s.ambient, time: s.time, machines: [...new Set(s.machines)] };
  const others = readSpaces().filter((x) => x.id !== id).map((x) => ({ ...x, machines: x.machines.filter((m) => !next.machines.includes(m)) }));
  const old = readSpaces().findIndex((x) => x.id === id);
  const list = [...others];
  list.splice(old >= 0 ? old : list.length, 0, next);
  write(list);
  return next;
}

export function moveToSpace(machine: string, spaceId: string, before?: string | null, shown?: string[]) {
  write(readSpaces().map((s) => {
    if (s.id !== spaceId) return { ...s, machines: s.machines.filter((m) => m !== machine) };
    const order = (shown ?? s.machines).filter((m) => m !== machine);
    const i = before ? order.indexOf(before) : -1;
    order.splice(i < 0 ? order.length : i, 0, machine);
    return { ...s, machines: order };
  }));
}

export function reorderSpaces(ids: string[]) {
  const list = readSpaces();
  const at = (s: Space) => { const i = ids.indexOf(s.id); return i < 0 ? Infinity : i; };
  write([...list].sort((a, b) => at(a) - at(b)));
}

export function deleteSpace(id: string) {
  if (id === MAIN_SPACE) return;
  write(readSpaces().filter((s) => s.id !== id));
}

export function renameInSpaces(from: string, to: string) {
  write(readSpaces().map((s) => ({ ...s, machines: s.machines.map((m) => (m === from ? to : m)) })));
}

const SHOWN = "gpuvm.space.shown";
let shown: string | null = null;
export const shownSpace = () => {
  if (shown === null) { try { shown = localStorage.getItem(SHOWN) ?? MAIN_SPACE; } catch { shown = MAIN_SPACE; } }
  return readSpaces().some((s) => s.id === shown) ? shown : MAIN_SPACE;
};
export const showSpace = (id: string) => {
  shown = id;
  try { localStorage.setItem(SHOWN, id); } catch {}
  window.dispatchEvent(new Event(EVENT));
};
export const useShownSpace = () => { useSpaces(); return useSyncExternalStore(subscribe, shownSpace); };

