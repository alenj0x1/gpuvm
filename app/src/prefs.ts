import { useEffect, useState } from "react";
import { inTauri } from "./api";

// App preferences, kept in localStorage. The close, quit and service behaviors are also handed to the Rust side,
// which decides what the window's close button and quitting do.
export type ThemePref = "system" | "light" | "dark";
export type ClosePref = "quit" | "tray";
export type VmsOnQuitPref = "keep" | "stop";
/** When the GpuVM service runs: while GpuVM is open, from Windows' start, or only when started by hand. */
export type ServicePref = "app" | "windows" | "manual";

export interface Prefs {
  theme: ThemePref;
  close: ClosePref;
  vmsOnQuit: VmsOnQuitPref;
  service: ServicePref;
  /** The monitor VMs open on unless a VM has its own: a monitor's id or "primary". */
  monitor: string;
}

const KEY = "gpuvm.prefs";
const DEFAULTS: Prefs = { theme: "system", close: "quit", vmsOnQuit: "keep", service: "app", monitor: "primary" };
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

async function applyClose(close: ClosePref) {
  if (!inTauri) return;
  const { invoke } = await import("@tauri-apps/api/core");
  await invoke("set_close_to_tray", { enabled: close === "tray" }).catch(() => {});
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
  if (change.close) applyClose(next.close);
  if (change.vmsOnQuit) applyVmsOnQuit(next.vmsOnQuit);
  if (change.service) applyService(next.service);
  window.dispatchEvent(new Event(EVENT));
}

/** Applies the stored preferences at startup and follows the system theme while "system" is chosen. */
export function initPrefs() {
  const prefs = readPrefs();
  applyTheme(prefs.theme);
  applyClose(prefs.close);
  applyVmsOnQuit(prefs.vmsOnQuit);
  applyService(prefs.service);
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
