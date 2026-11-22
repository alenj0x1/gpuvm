import { useEffect, useState } from "react";
import { inTauri } from "./api";
import { resolveLang, setLang, t, type LangPref } from "./i18n";

// App preferences, kept in localStorage. The close, quit and service behaviors are also handed to the Rust side,
// which decides what the window's close button and quitting do.
export type ThemePref = "system" | "light" | "dark";
export type ClosePref = "quit" | "tray";
export type VmsOnQuitPref = "keep" | "stop";
/** Going back to Home from a machine's picture: it stays connected (back at once) or disconnects. */
export type ViewerHomePref = "keep" | "disconnect";
/** When the GpuVM service runs: while GpuVM is open, from Windows' start, or only when started by hand. */
export type ServicePref = "app" | "windows" | "manual";
/** How the person takes control from an agent. */
export type TakeControlPref = "input" | "button";
/** The accent for actions, selection and focus. */
export type AccentPref = "blue" | "violet" | "teal" | "green" | "amber";

/** Each accent as it looks in light and in dark (the same values as styles.css). `name` is a getter, so it comes out in
 *  the current language wherever it is read. */
export const ACCENTS: { id: AccentPref; name: string; light: string; dark: string }[] = [
  { id: "blue", get name() { return t("Blue"); }, light: "#2f5bd3", dark: "#7d9cf0" },
  { id: "violet", get name() { return t("Violet"); }, light: "#6a4fd2", dark: "#a796f2" },
  { id: "teal", get name() { return t("Teal"); }, light: "#1d7f7c", dark: "#6ccfca" },
  { id: "green", get name() { return t("Green"); }, light: "#2f8550", dark: "#7dd19c" },
  { id: "amber", get name() { return t("Amber"); }, light: "#a8650f", dark: "#e7b45e" },
];

export interface Prefs {
  theme: ThemePref;
  close: ClosePref;
  vmsOnQuit: VmsOnQuitPref;
  /** After quitting with the machines left on, GpuVM stays in the background (tray only) showing their administrator
   *  prompts until none is on. */
  noticesAfterQuit: boolean;
  service: ServicePref;
  /** The monitor VMs open on unless a VM has its own: a monitor's id or "primary". */
  monitor: string;
  accent: AccentPref;
  /** The app's language: Windows' (Spanish if Windows is in Spanish, English otherwise), Spanish or English. */
  lang: LangPref;
  viewerHome: ViewerHomePref;
  /** The most frames a second the app's animations (holograms, scenes) draw: 0 = as many as the monitor shows. */
  animFps: number;
  /** The resolution they draw at, in % of the screen's: less is lighter on the GPU the machines share. */
  animQuality: number;
  /** The viewer keeps the last 30 s of the picture in memory, to save them as a clip. Off: it holds memory. */
  replay: boolean;
  /** Where screenshots and videos go ("" = Pictures\GpuVM and Videos\GpuVM). */
  shotsDir: string;
  videosDir: string;
  /** Moving the mouse or pressing a key over an agent's machine pauses the agent ("input"), or only the Take control
   *  button does ("button"). */
  takeControl: TakeControlPref;
  /** Status notices (recording, saved, you took control: the status notch) over the picture, or only in the side panel. */
  statusPlacement: StatusPlacementPref;
  /** Where the notch and the docks (requests) sit over the picture, anywhere: see Pos. */
  notchPos: Pos;
  dockPos: Pos;
}

/** A place over a machine's picture, anywhere (2026-11-21, chosen by the person): x and y from 0 to 1 of the room the
 *  piece has (0 = touching the left or top edge, 1 = the right or bottom one), so it means the same at any size. */
export interface Pos { x: number; y: number }
export const DOCK_POS: Pos = { x: 0.5, y: 0 };
/** A little above the machine's taskbar, so it never covers it. */
export const NOTCH_POS: Pos = { x: 0.5, y: 0.93 };
export type StatusPlacementPref = "picture" | "panel";

/** Which edges a piece at `p` touches. */
export function edgesOf(p: Pos) {
  return { top: p.y <= 0.001, bottom: p.y >= 0.999, left: p.x <= 0.001, right: p.x >= 0.999 };
}

/** Its corners: square on every edge it touches (in a corner, on both), rounded everywhere else. As CSS border-radius. */
export function cornersAt(p: Pos, r: number): string {
  const e = edgesOf(p);
  const tl = e.top || e.left ? 0 : r, tr = e.top || e.right ? 0 : r, br = e.bottom || e.right ? 0 : r, bl = e.bottom || e.left ? 0 : r;
  return `${tl}px ${tr}px ${br}px ${bl}px`;
}

const clampPos = (p: unknown, d: Pos): Pos => {
  const o = p as Partial<Pos> | null;
  const n = (v: unknown, def: number) => (typeof v === "number" && Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : def);
  return { x: n(o?.x, d.x), y: n(o?.y, d.y) };
};

const KEY = "gpuvm.prefs";
const DEFAULTS: Prefs = { theme: "system", close: "quit", vmsOnQuit: "stop", noticesAfterQuit: true, service: "app", monitor: "primary", accent: "blue", lang: "system", viewerHome: "keep", animFps: 0, animQuality: 100, replay: false, shotsDir: "", videosDir: "", takeControl: "input", statusPlacement: "picture", notchPos: NOTCH_POS, dockPos: DOCK_POS };
const EVENT = "gpuvm-prefs";
const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

// Before version 2 every save stored "keep" (then the default) even when nobody chose it: machines stayed on in
// Hyper-V after quitting. Version 2 moves those to the new default once; a later "keep" is a real choice.
const VERSION = 2;

export function readPrefs(): Prefs {
  try {
    const saved = JSON.parse(localStorage.getItem(KEY) ?? "{}");
    if (saved.version !== VERSION) {
      if (saved.vmsOnQuit === "keep") saved.vmsOnQuit = "stop";
      saved.version = VERSION;
      if (localStorage.getItem(KEY)) localStorage.setItem(KEY, JSON.stringify(saved));
    }
    delete saved.version;
    // The time to answer lives in the service now (Get-GpuVMAgentSettings): an old stored one is never sent again.
    delete saved.approvalTimeout;
    // Before free placement (2026-11-21) the notch had named places; any of them is "over the picture" now, at the
    // nearest free position (the bottom one becomes the new default, a little above the taskbar).
    if (saved.statusPlacement && saved.statusPlacement !== "panel" && saved.statusPlacement !== "picture") {
      const old = String(saved.statusPlacement);
      if (!saved.notchPos && old !== "bottom") saved.notchPos = { x: old.endsWith("left") ? 0.01 : old.endsWith("right") ? 0.99 : 0.5, y: old.startsWith("top") ? (old === "top" ? 0 : 0.01) : NOTCH_POS.y };
      saved.statusPlacement = "picture";
    }
    delete saved.notchGap; delete saved.dockSpot; delete saved.dockGap;
    const merged = { ...DEFAULTS, ...saved };
    return { ...merged, notchPos: clampPos(merged.notchPos, NOTCH_POS), dockPos: clampPos(merged.dockPos, DOCK_POS) };
  } catch { return DEFAULTS; }
}

export function resolvedTheme(pref: ThemePref): "light" | "dark" {
  return pref === "system" ? (systemDark.matches ? "dark" : "light") : pref;
}

function applyTheme(pref: ThemePref) {
  document.documentElement.dataset.theme = resolvedTheme(pref);
}

function applyAccent(accent: AccentPref) {
  document.documentElement.dataset.accent = accent;
}

async function applyClose(close: ClosePref) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_close_to_tray", { enabled: close === "tray" }).catch(() => {});
}

async function applyLang(pref: LangPref) {
  const lang = resolveLang(pref);
  setLang(lang);
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_language", { lang }).catch(() => {});
}

async function applyVmsOnQuit(pref: VmsOnQuitPref) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_stop_vms_on_quit", { enabled: pref === "stop" }).catch(() => {});
}

async function applyNoticesAfterQuit(enabled: boolean) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_notices_after_quit", { enabled }).catch(() => {});
}

/** The take-control mode goes to the Rust side (it decides what the viewer's input does). The time to answer is the
 *  service's own setting, written only from Settings › Agents (an app start once overwrote it with a stale 30 s). */
async function applyAgents(prefs: Prefs) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_agent_prefs", { takeControl: prefs.takeControl }).catch(() => {});
}

/** The docks are drawn inside a window over the whole picture (or a strip of it): their place and corners are CSS,
 *  set here in every window of the app (all read the same stored preferences). */
function applyDockCss(prefs: Prefs) {
  const root = document.documentElement, p = prefs.dockPos, e = edgesOf(p);
  root.style.setProperty("--dock-x", String(p.x));
  root.style.setProperty("--dock-y", String(p.y));
  root.style.setProperty("--dock-radius", cornersAt(p, 16));
  // It slides in from an edge it touches (top or bottom), or fades in where it floats.
  root.dataset.dockFrom = e.top ? "top" : e.bottom ? "bottom" : "none";
}

/** The status notch's and the docks' places go to the Rust side (status.rs), which places them over every viewer. */
async function applyStatus(prefs: Prefs) {
  applyDockCss(prefs);
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_status_prefs", { placement: prefs.statusPlacement, x: prefs.notchPos.x, y: prefs.notchPos.y, dockX: prefs.dockPos.x, dockY: prefs.dockPos.y }).catch(() => {});
}

async function applyService(mode: ServicePref) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_service_mode", { mode }).catch(() => {});
}

/** The capture settings go to the Rust side, which tells the open viewers (and moves their files to these folders). */
async function applyCapture(prefs: Prefs) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_capture_prefs", { replay: prefs.replay, shotsDir: prefs.shotsDir || null, videosDir: prefs.videosDir || null, lang: resolveLang(prefs.lang) })
    .catch(() => {});
}

export function savePrefs(change: Partial<Prefs>) {
  const next = { ...readPrefs(), ...change };
  try { localStorage.setItem(KEY, JSON.stringify({ ...next, version: VERSION })); } catch { /* no storage */ }
  applyTheme(next.theme);
  applyAccent(next.accent);
  if (change.close) applyClose(next.close);
  if (change.vmsOnQuit) applyVmsOnQuit(next.vmsOnQuit);
  if (change.noticesAfterQuit !== undefined) applyNoticesAfterQuit(next.noticesAfterQuit);
  if (change.service) applyService(next.service);
  if (change.lang) applyLang(next.lang);
  if ("replay" in change || "shotsDir" in change || "videosDir" in change || change.lang) applyCapture(next);
  if ("takeControl" in change) applyAgents(next);
  if ("statusPlacement" in change || "notchPos" in change || "dockPos" in change) applyStatus(next);
  window.dispatchEvent(new Event(EVENT));
}

/** Applies the stored preferences at startup and follows the system theme while "system" is chosen. */
export function initPrefs() {
  const prefs = readPrefs();
  applyTheme(prefs.theme);
  applyAccent(prefs.accent);
  applyClose(prefs.close);
  applyVmsOnQuit(prefs.vmsOnQuit);
  applyNoticesAfterQuit(prefs.noticesAfterQuit);
  applyService(prefs.service);
  applyLang(prefs.lang);
  applyCapture(prefs);
  applyAgents(prefs);
  applyStatus(prefs);
  systemDark.addEventListener("change", () => {
    if (readPrefs().theme === "system") { applyTheme("system"); window.dispatchEvent(new Event(EVENT)); }
  });
  // Another window of the app (the viewer's panel beside the main one) changed them: follow at once.
  window.addEventListener("storage", (e) => { if (e.key === KEY) refreshPrefs(); });
}

/** Applies the stored theme and accent again (a window that stayed hidden while they changed elsewhere). */
export function refreshPrefs() {
  const prefs = readPrefs();
  const before = `${document.documentElement.dataset.theme}|${document.documentElement.dataset.accent}`;
  applyTheme(prefs.theme);
  applyAccent(prefs.accent);
  applyDockCss(prefs);
  if (before !== `${document.documentElement.dataset.theme}|${document.documentElement.dataset.accent}`) window.dispatchEvent(new Event(EVENT));
}

export function usePrefs(): Prefs {
  const [prefs, setPrefs] = useState(readPrefs);
  useEffect(() => {
    const sync = () => setPrefs(readPrefs());
    window.addEventListener(EVENT, sync);
    return () => window.removeEventListener(EVENT, sync);
  }, []);
  return prefs;
}
