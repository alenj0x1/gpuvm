import { useEffect, useState } from "react";
import { inTauri } from "./api";
import { resolveLang, setLang, t, type LangPref } from "./i18n";

export type ThemePref = "system" | "light" | "dark";
export type ClosePref = "quit" | "tray";
export type VmsOnQuitPref = "keep" | "stop";
export type ViewerHomePref = "keep" | "disconnect";
export type ServicePref = "app" | "windows" | "manual";
export type TakeControlPref = "input" | "button";
export type AccentPref = "blue" | "violet" | "teal" | "green" | "amber";

/** Same values as styles.css. `name` is a getter, so it follows the current language. */
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
  noticesAfterQuit: boolean;
  service: ServicePref;
  monitor: string;
  accent: AccentPref;
  lang: LangPref;
  viewerHome: ViewerHomePref;
  animFps: number;
  animQuality: number;
  replay: boolean;
  shotsDir: string;
  videosDir: string;
  takeControl: TakeControlPref;
  statusPlacement: StatusPlacementPref;
  notchPos: Pos;
  dockPos: Pos;
}

export interface Pos { x: number; y: number }
export const DOCK_POS: Pos = { x: 0.5, y: 0 };
export const NOTCH_POS: Pos = { x: 0.5, y: 0.93 };
export type StatusPlacementPref = "picture" | "panel";

export function edgesOf(p: Pos) {
  return { top: p.y <= 0.001, bottom: p.y >= 0.999, left: p.x <= 0.001, right: p.x >= 0.999 };
}

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
    delete saved.approvalTimeout;
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

/** The time to answer is never written from here, only from Settings › Agents (a stale value once overwrote it). */
async function applyAgents(prefs: Prefs) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_agent_prefs", { takeControl: prefs.takeControl }).catch(() => {});
}

function applyDockCss(prefs: Prefs) {
  const root = document.documentElement, p = prefs.dockPos, e = edgesOf(p);
  root.style.setProperty("--dock-x", String(p.x));
  root.style.setProperty("--dock-y", String(p.y));
  root.style.setProperty("--dock-radius", cornersAt(p, 16));
  root.dataset.dockFrom = e.top ? "top" : e.bottom ? "bottom" : "none";
}

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

async function applyCapture(prefs: Prefs) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_capture_prefs", { replay: prefs.replay, shotsDir: prefs.shotsDir || null, videosDir: prefs.videosDir || null, lang: resolveLang(prefs.lang) })
    .catch(() => {});
}

export function savePrefs(change: Partial<Prefs>) {
  const next = { ...readPrefs(), ...change };
  try { localStorage.setItem(KEY, JSON.stringify({ ...next, version: VERSION })); } catch {}
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
  window.addEventListener("storage", (e) => { if (e.key === KEY) refreshPrefs(); });
}

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
