import { useEffect, useRef, useState } from "react";
import { inTauri } from "./api";

// The agent's live overlay (live.rs): a click-through window over a machine's picture that shows where the agent acts
// — its cursor with its name, a ring on each click, the stroke of a drag, the keys it presses. Only shapes arrive
// (desktop pixels, key names, a count of typed characters), never what is typed. What it is doing in words goes in the
// status notch, not here.

type Point = [number, number];
type Shape =
  | { type: "click"; x: number; y: number; button?: string; count?: number }
  | { type: "move"; x: number; y: number }
  | { type: "scroll"; x: number; y: number; dy?: number; dx?: number }
  | { type: "drag"; strokes: Point[][]; ms?: number | null }
  | { type: "type"; chars: number }
  | { type: "key"; keys: string }
  | { type: "wait"; ms: number }
  | { type: "invoke"; action?: string };
interface LiveEvent { phase: "start" | "end"; step: number; clientName?: string | null; method?: string; shapes?: Shape[] | null; screen?: { w: number; h: number } | null }

interface Mark { id: number; x: number; y: number; kind: "ring" | "double" | "scroll" }
interface Stroke { id: number; d: string; length: number; ms: number; fading: boolean }
interface Chip { id: number; text: string }

/** Desktop pixels → this window's pixels: the picture is fitted whole (letterboxed) in the viewer. */
function fit(screen: { w: number; h: number }) {
  const W = window.innerWidth, H = window.innerHeight;
  const s = Math.min(W / screen.w, H / screen.h);
  const ox = (W - screen.w * s) / 2, oy = (H - screen.h * s) / 2;
  return (p: Point): Point => [ox + p[0] * s, oy + p[1] * s];
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
/** How long the cursor glides to a new place: quick, so it never lags far behind the machine. */
const GLIDE_MS = 240;

export function LiveOverlay() {
  const [name, setName] = useState("");
  const [cursor, setCursor] = useState<{ p: Point; glide: number } | null>(null);
  const [marks, setMarks] = useState<Mark[]>([]);
  const [strokes, setStrokes] = useState<Stroke[]>([]);
  const [chip, setChip] = useState<Chip | null>(null);
  const screen = useRef({ w: 1280, h: 800 });
  const queue = useRef<Promise<void>>(Promise.resolve());
  const next = useRef(1);
  const at = useRef<Point>([0, 0]);

  useEffect(() => {
    const play = async (ev: LiveEvent) => {
      if (ev.clientName) setName(ev.clientName);
      if (ev.screen?.w && ev.screen?.h) screen.current = ev.screen;
      if (ev.phase !== "start" || !ev.shapes?.length) return;
      const map = fit(screen.current);
      const glide = async (p: Point, ms = GLIDE_MS) => { at.current = p; setCursor({ p: map(p), glide: ms }); await sleep(ms); };
      const mark = (p: Point, kind: Mark["kind"]) => {
        const id = next.current++;
        const [x, y] = map(p);
        setMarks((m) => [...m, { id, x, y, kind }]);
        setTimeout(() => setMarks((m) => m.filter((k) => k.id !== id)), 700);
      };
      const say = (text: string) => {
        const id = next.current++;
        setChip({ id, text });
        setTimeout(() => setChip((c) => (c?.id === id ? null : c)), 1400);
      };
      for (const s of ev.shapes) {
        if (s.type === "click") { await glide([s.x, s.y]); mark([s.x, s.y], (s.count ?? 1) > 1 ? "double" : "ring"); }
        else if (s.type === "move") await glide([s.x, s.y]);
        else if (s.type === "scroll") { await glide([s.x, s.y]); mark([s.x, s.y], "scroll"); }
        else if (s.type === "key") say(s.keys);
        else if (s.type === "type") say("•".repeat(Math.min(12, Math.max(1, s.chars))));
        else if (s.type === "drag") {
          const all = s.strokes.flat();
          const total = s.strokes.reduce((n, st) => n + st.slice(1).reduce((len, p, i) => len + Math.hypot(p[0] - st[i][0], p[1] - st[i][1]), 0), 0);
          // The machine draws at ~1500 desktop px/s (or in `ms`); the overlay follows at that pace, 3 s at most.
          const ms = Math.min(3000, Math.max(250, s.ms ?? (total / 1500) * 1000));
          if (!all.length) continue;
          await glide(all[0]);
          for (const st of s.strokes) {
            if (st.length < 2) continue;
            const pts = st.map(map);
            const length = pts.slice(1).reduce((len, p, i) => len + Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]), 0);
            const stLen = st.slice(1).reduce((len, p, i) => len + Math.hypot(p[0] - st[i][0], p[1] - st[i][1]), 0);
            const stMs = total > 0 ? (ms * stLen) / total : ms / s.strokes.length;
            const id = next.current++;
            setStrokes((list) => [...list.slice(-30), { id, d: "M" + pts.map((p) => `${p[0].toFixed(1)} ${p[1].toFixed(1)}`).join(" L"), length, ms: stMs, fading: false }]);
            // The cursor rides the stroke: a few hops along it.
            const hops = Math.max(2, Math.min(24, Math.round(stMs / 40)));
            for (let h = 1; h <= hops; h++) {
              const p = st[Math.round(((st.length - 1) * h) / hops)];
              at.current = p;
              setCursor({ p: map(p), glide: stMs / hops });
              await sleep(stMs / hops);
            }
            setTimeout(() => setStrokes((list) => list.map((k) => (k.id === id ? { ...k, fading: true } : k))), 1200);
            setTimeout(() => setStrokes((list) => list.filter((k) => k.id !== id)), 2200);
          }
        }
      }
    };
    const take = (ev: LiveEvent) => { queue.current = queue.current.then(() => play(ev)).catch(() => {}); };

    if (!inTauri) {
      // Browser preview (?agent-live): a short loop of what an agent does.
      const demo: LiveEvent[] = [
        { phase: "start", step: 1, clientName: "Claude Code", screen: { w: 1280, h: 800 }, shapes: [{ type: "click", x: 300, y: 240 }] },
        { phase: "start", step: 2, shapes: [{ type: "drag", strokes: [Array.from({ length: 40 }, (_, i): Point => [640 + 120 * Math.cos(i / 6), 380 + 120 * Math.sin(i / 6)])] }] },
        { phase: "start", step: 3, shapes: [{ type: "key", keys: "ctrl+s" }] },
        { phase: "start", step: 4, shapes: [{ type: "click", x: 980, y: 620, count: 2 }, { type: "type", chars: 9 }] },
        { phase: "start", step: 5, shapes: [{ type: "scroll", x: 700, y: 500, dy: 3 }] },
      ];
      let i = 0;
      const id = window.setInterval(() => take(demo[i++ % demo.length]), 1300);
      return () => window.clearInterval(id);
    }
    let off: (() => void) | undefined;
    let gone = false;
    (async () => {
      const { getCurrentWebviewWindow } = await import("@tauri-apps/api/webviewWindow");
      const u = await getCurrentWebviewWindow().listen<LiveEvent>("agent-live", (e) => take(e.payload));
      if (gone) u(); else off = u;
    })();
    return () => { gone = true; off?.(); };
  }, []);

  // A resize of the viewer moves the picture: the cursor goes back to where it was on the machine.
  useEffect(() => {
    const onResize = () => setCursor((c) => (c ? { p: fit(screen.current)(at.current), glide: 0 } : c));
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  return (
    <div className="lv-root" aria-hidden="true">
      <svg className="lv-strokes">
        {strokes.map((s) => (
          <path key={s.id} d={s.d} className={s.fading ? "fading" : ""}
            style={{ strokeDasharray: s.length, strokeDashoffset: 0, animation: `lv-draw ${Math.round(s.ms)}ms linear`, ["--len" as string]: s.length }} />
        ))}
      </svg>
      {marks.map((m) => <span key={m.id} className={`lv-mark ${m.kind}`} style={{ left: m.x, top: m.y }} />)}
      {cursor && (
        <div className="lv-cursor" style={{ transform: `translate(${cursor.p[0]}px, ${cursor.p[1]}px)`, transitionDuration: `${Math.round(cursor.glide)}ms` }}>
          <svg width="22" height="24" viewBox="0 0 22 24"><path d="M3 2 L3 19 L7.5 15 L10.6 21.6 L13.6 20.2 L10.6 13.8 L16.6 13.8 Z" /></svg>
          {name && <span className="lv-name">{name}</span>}
          {chip && <span className="lv-chip" key={chip.id}>{chip.text}</span>}
        </div>
      )}
    </div>
  );
}
