import { useEffect, useSyncExternalStore } from "react";
import { agents } from "./api";
import type { AgentClient, AgentOffer, AgentRequest } from "./types";

/** What every agent screen shows, read once for all of them (one poll, however many components look). */
export interface AgentSnapshot { clients: AgentClient[]; requests: AgentRequest[]; offers: AgentOffer[]; loaded: boolean; error: string | null }

let snap: AgentSnapshot = { clients: [], requests: [], offers: [], loaded: false, error: null };
let json = "";
const subs = new Set<() => void>();
let users = 0;
let timer: ReturnType<typeof setTimeout> | undefined;
let running = false;

async function read() {
  try {
    const [clients, requests, offers] = await Promise.all([agents.clients(), agents.requests(), agents.offers()]);
    const next = { clients, requests, offers, loaded: true, error: null };
    const j = JSON.stringify(next);
    // Nothing re-renders when nothing changed.
    if (j !== json) { json = j; snap = next; subs.forEach((f) => f()); }
  } catch (e) {
    snap = { ...snap, loaded: true, error: String(e) };
    subs.forEach((f) => f());
  }
}

/** Chained polling: faster while an agent works or waits, slow when there is none, slower with the window hidden. */
async function loop() {
  if (running) return;
  running = true;
  if (!document.hidden) await read();
  running = false;
  if (!users) return;
  const busy = snap.clients.some((c) => c.state !== "idle") || snap.requests.length > 0;
  timer = setTimeout(loop, document.hidden ? 10000 : busy ? 1500 : 5000);
}

/** Read again now (after an answer or a button), instead of waiting for the next poll. */
export function refreshAgents() { clearTimeout(timer); return loop(); }

export function useAgents(): AgentSnapshot {
  useEffect(() => {
    if (users++ === 0) loop();
    const wake = () => { if (!document.hidden) refreshAgents(); };
    document.addEventListener("visibilitychange", wake);
    return () => { document.removeEventListener("visibilitychange", wake); if (--users === 0) clearTimeout(timer); };
  }, []);
  return useSyncExternalStore((f) => { subs.add(f); return () => subs.delete(f); }, () => snap);
}

/** The client working on a machine (the one shown on its page and in its viewer), if any. */
export const clientOn = (s: AgentSnapshot, machine: string) => s.clients.find((c) => c.machine === machine) ?? null;

/** A size in words: 18 KB, 4.8 MB, 1.2 GB. */
export function bytes(n: number, locale?: string) {
  const fmt = (v: number, d: number) => v.toLocaleString(locale, { maximumFractionDigits: d });
  if (n < 1024) return `${n} B`;
  if (n < 1024 ** 2) return `${fmt(n / 1024, 0)} KB`;
  if (n < 1024 ** 3) return `${fmt(n / 1024 ** 2, 1)} MB`;
  return `${fmt(n / 1024 ** 3, 1)} GB`;
}
