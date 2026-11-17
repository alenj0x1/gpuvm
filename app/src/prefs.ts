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
/** The accent for actions, selection and focus. */
export type AccentPref = "blue" | "violet" | "teal" | "green" | "amber";

/** Each accent as it looks in light and in dark (the same values as styles.css). `name` is a getter, so it comes out in
 *  the current language wherever it is read. */
export const ACCENTS: { id: AccentPref; name: string; light: string; dark: string }[] = [
  { id: "blue", get name() { return t("Azul"); }, light: "#2f5bd3", dark: "#7d9cf0" },
  { id: "violet", get name() { return t("Violeta"); }, light: "#6a4fd2", dark: "#a796f2" },
  { id: "teal", get name() { return t("Turquesa"); }, light: "#1d7f7c", dark: "#6ccfca" },
  { id: "green", get name() { return t("Verde"); }, light: "#2f8550", dark: "#7dd19c" },
  { id: "amber", get name() { return t("Ámbar"); }, light: "#a8650f", dark: "#e7b45e" },
];

export interface Prefs {
  theme: ThemePref;
  close: ClosePref;
  vmsOnQuit: VmsOnQuitPref;
  service: ServicePref;
  /** The monitor VMs open on unless a VM has its own: a monitor's id or "primary". */
  monitor: string;
  accent: AccentPref;
  /** The app's language: Windows' (Spanish if Windows is in Spanish, English otherwise), Spanish or English. */
  lang: LangPref;
  viewerHome: ViewerHomePref;
}

const KEY = "gpuvm.prefs";
const DEFAULTS: Prefs = { theme: "system", close: "quit", vmsOnQuit: "keep", service: "app", monitor: "primary", accent: "blue", lang: "system", viewerHome: "keep" };
const EVENT = "gpuvm-prefs";
const systemDark = window.matchMedia("(prefers-color-scheme: dark)");

export function readPrefs(): Prefs {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(KEY) ?? "{}") }; } catch { return DEFAULTS; }
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

async function applyService(mode: ServicePref) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_service_mode", { mode }).catch(() => {});
}

export function savePrefs(change: Partial<Prefs>) {
  const next = { ...readPrefs(), ...change };
  try { localStorage.setItem(KEY, JSON.stringify(next)); } catch { /* no storage */ }
  applyTheme(next.theme);
  applyAccent(next.accent);
  if (change.close) applyClose(next.close);
  if (change.vmsOnQuit) applyVmsOnQuit(next.vmsOnQuit);
  if (change.service) applyService(next.service);
  if (change.lang) applyLang(next.lang);
  window.dispatchEvent(new Event(EVENT));
}

/** Applies the stored preferences at startup and follows the system theme while "system" is chosen. */
export function initPrefs() {
  const prefs = readPrefs();
  applyTheme(prefs.theme);
  applyAccent(prefs.accent);
  applyClose(prefs.close);
  applyVmsOnQuit(prefs.vmsOnQuit);
  applyService(prefs.service);
  applyLang(prefs.lang);
  systemDark.addEventListener("change", () => {
    if (readPrefs().theme === "system") { applyTheme("system"); window.dispatchEvent(new Event(EVENT)); }
  });
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
