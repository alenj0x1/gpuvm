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
  /** Where status notices over the picture go (recording, saved, you took control): the status notch. */
  statusPlacement: StatusPlacementPref;
  /** How far the notch sits from the picture's edge (logical px; 0 = attached to it, which squares that side). */
  notchGap: number;
  /** Where requests drop over the picture (the docks), and how far from its edge. */
  dockSpot: Spot;
  dockGap: number;
}

/** Six places over a machine's picture: top or bottom, left, center or right. */
export type Spot = "top-left" | "top" | "top-right" | "bottom-left" | "bottom" | "bottom-right";
export const SPOTS: Spot[] = ["top-left", "top", "top-right", "bottom-left", "bottom", "bottom-right"];
/** Where the status notch sits over the picture, or only in the side panel. */
export type StatusPlacementPref = Spot | "panel";

/** The corners of a notice at a spot: square on a side it is attached to (gap 0), rounded everywhere else. As CSS
 *  border-radius (top-left, top-right, bottom-right, bottom-left). */
export function cornersFor(spot: Spot, gap: number, r: number): string {
  const top = spot.startsWith("top"), left = spot.endsWith("left"), right = spot.endsWith("right");
  const flush = gap <= 0;
  const tl = flush && (top || left) ? 0 : r, tr = flush && (top || right) ? 0 : r;
  const br = flush && (!top || right) ? 0 : r, bl = flush && (!top || left) ? 0 : r;
  return `${tl}px ${tr}px ${br}px ${bl}px`;
}

const KEY = "gpuvm.prefs";
const DEFAULTS: Prefs = { theme: "system", close: "quit", vmsOnQuit: "stop", noticesAfterQuit: true, service: "app", monitor: "primary", accent: "blue", lang: "system", viewerHome: "keep", animFps: 0, animQuality: 100, replay: false, shotsDir: "", videosDir: "", takeControl: "input", statusPlacement: "bottom", notchGap: 52, dockSpot: "top", dockGap: 0 };
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
    // Before the placement editor (2026-11-21) a corner sat 12 px in and the centers were attached to the edge; the
    // new default for the bottom is a little above the machine's taskbar.
    if (saved.statusPlacement && saved.notchGap === undefined) saved.notchGap = saved.statusPlacement === "top" ? 0 : saved.statusPlacement === "bottom" ? 52 : 12;
    return { ...DEFAULTS, ...saved };
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
  const root = document.documentElement;
  root.dataset.dock = prefs.dockSpot;
  root.style.setProperty("--dock-gap", `${Math.max(0, prefs.dockGap)}px`);
  root.style.setProperty("--dock-side", `${prefs.dockGap > 0 ? 16 : 0}px`);
  root.style.setProperty("--dock-radius", cornersFor(prefs.dockSpot, prefs.dockGap, 16));
}

/** The status notch's and the docks' places go to the Rust side (status.rs), which places them over every viewer. */
async function applyStatus(prefs: Prefs) {
  applyDockCss(prefs);
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_status_prefs", { placement: prefs.statusPlacement, gap: prefs.notchGap, dock: prefs.dockSpot, dockGap: prefs.dockGap }).catch(() => {});
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
  if ("statusPlacement" in change || "notchGap" in change || "dockSpot" in change || "dockGap" in change) applyStatus(next);
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
