import { useSyncExternalStore } from "react";
import { normalizeAmbient, type AmbientId, type AmbientTime } from "./ambient";
import { getLang, t } from "./i18n";

// Spaces group machines by what they are for (work, games, AI tests…), and each one has its own ambient: the place
// where its machines float (a constellation, a neon city, the ocean, Mars…). Kept in localStorage like a machine's
// decoration. Every machine is in exactly one space: the ones nobody moved are in the first space, which always exists.

export interface Space {
  id: string;
  name: string;
  ambient: AmbientId;
  /** The time of day of the world of blocks. */
  time?: AmbientTime;
  /** Machine names in this space, in the order they are shown (dragged into place, or the order they came in). */
  machines: string[];
}

/** The first space: it can be renamed and given another ambient, never deleted. */
export const MAIN_SPACE = "main";
const KEY = "gpuvm.spaces";
const EVENT = "gpuvm-spaces";
// The first space's name until someone renames it: shown in the language of the app (whichever one it was saved in).
const DEFAULT_NAMES = ["Mis m\u00e1quinas", "My machines"];
const defaults = (): Space[] => [{ id: MAIN_SPACE, name: t("Mis máquinas"), ambient: "studio", machines: [] }];

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
  } catch { /* no storage or bad data */ }
  if (!list.some((s) => s.id === MAIN_SPACE)) list = [DEFAULT[0], ...list];
  list = list.map((s) => (s.id === MAIN_SPACE && DEFAULT_NAMES.includes(s.name) ? { ...s, name: DEFAULT[0].name } : s));
  cache = list;
  return list;
}

function write(list: Space[]) {
  cache = list;
  try { localStorage.setItem(KEY, JSON.stringify(list)); } catch { /* no storage */ }
  window.dispatchEvent(new Event(EVENT));
}

function subscribe(onChange: () => void) {
  const storage = (e: StorageEvent) => { if (e.key === KEY) { cache = null; onChange(); } };
  window.addEventListener(EVENT, onChange);
  window.addEventListener("storage", storage);
  return () => { window.removeEventListener(EVENT, onChange); window.removeEventListener("storage", storage); };
}
export const useSpaces = () => useSyncExternalStore(subscribe, readSpaces);

/** The space a machine is in: the one that lists it, or the first one. */
export function spaceOf(name: string, list = readSpaces()): Space {
  return list.find((s) => s.machines.includes(name)) ?? list.find((s) => s.id === MAIN_SPACE)!;
}
/** The machines of a space, in the space's order, from the machines that exist (the first space also takes the rest). */
export function machinesIn<T extends { name: string }>(space: Space, all: T[], list = readSpaces()): T[] {
  const at = (v: T) => { const i = space.machines.indexOf(v.name); return i < 0 ? Infinity : i; };
  // Machines the space doesn't list yet (new ones in the first space) keep their order, after the placed ones.
  return all.filter((v) => spaceOf(v.name, list).id === space.id).map((v, i) => ({ v, i })).sort((a, b) => at(a.v) - at(b.v) || a.i - b.i).map((x) => x.v);
}
export const useSpaceOf = (name: string) => spaceOf(name, useSpaces());

const newId = () => Math.random().toString(36).slice(2, 9);

/** Creates or changes a space; the machines listed leave whatever space they were in. */
export function saveSpace(s: Omit<Space, "id"> & { id?: string }): Space {
  const id = s.id ?? newId();
  const next: Space = { id, name: s.name.trim() || t("Espacio"), ambient: s.ambient, time: s.time, machines: [...new Set(s.machines)] };
  const others = readSpaces().filter((x) => x.id !== id).map((x) => ({ ...x, machines: x.machines.filter((m) => !next.machines.includes(m)) }));
  const old = readSpaces().findIndex((x) => x.id === id);
  const list = [...others];
  list.splice(old >= 0 ? old : list.length, 0, next);
  write(list);
  return next;
}

/** Moves one machine into a space, at the end or just before another machine. `shown` is the space's machines as
 *  they are shown (machinesIn), so the first space's unlisted machines get a place too when one is put among them. */
export function moveToSpace(machine: string, spaceId: string, before?: string | null, shown?: string[]) {
  write(readSpaces().map((s) => {
    if (s.id !== spaceId) return { ...s, machines: s.machines.filter((m) => m !== machine) };
    const order = (shown ?? s.machines).filter((m) => m !== machine);
    const i = before ? order.indexOf(before) : -1;
    order.splice(i < 0 ? order.length : i, 0, machine);
    return { ...s, machines: order };
  }));
}

/** Puts the spaces in this order (ids); any left out keep their place at the end. */
export function reorderSpaces(ids: string[]) {
  const list = readSpaces();
  const at = (s: Space) => { const i = ids.indexOf(s.id); return i < 0 ? Infinity : i; };
  write([...list].sort((a, b) => at(a) - at(b)));
}

/** Deletes a space; its machines go back to the first one. */
export function deleteSpace(id: string) {
  if (id === MAIN_SPACE) return;
  write(readSpaces().filter((s) => s.id !== id));
}

/** A renamed machine stays in its space. */
export function renameInSpaces(from: string, to: string) {
  write(readSpaces().map((s) => ({ ...s, machines: s.machines.map((m) => (m === from ? to : m)) })));
}

/** Which space Home shows, remembered between visits. */
const SHOWN = "gpuvm.space.shown";
let shown: string | null = null;
export const shownSpace = () => {
  if (shown === null) { try { shown = localStorage.getItem(SHOWN) ?? MAIN_SPACE; } catch { shown = MAIN_SPACE; } }
  return readSpaces().some((s) => s.id === shown) ? shown : MAIN_SPACE;
};
export const showSpace = (id: string) => {
  shown = id;
  try { localStorage.setItem(SHOWN, id); } catch { /* no storage */ }
  window.dispatchEvent(new Event(EVENT));
};
export const useShownSpace = () => { useSpaces(); return useSyncExternalStore(subscribe, shownSpace); };

