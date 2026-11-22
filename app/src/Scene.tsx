import { useEffect, useRef } from "react";
import { animFps, onAnimBudget, animDpr, paceFrame } from "./animBudget";
import { hash, machineColor, patternVariant, random } from "./machineIcon";

export type SceneStyle = "wafer" | "partition" | "mosaic";
export const SCENE_STYLES: SceneStyle[] = ["wafer", "partition", "mosaic"];

const STYLE_KEY = "gpuvm.banner.";
export function sceneStyle(name: string): SceneStyle {
  try {
    const saved = localStorage.getItem(STYLE_KEY + name) as SceneStyle | null;
    if (saved && SCENE_STYLES.includes(saved)) return saved;
  } catch {}
  return SCENE_STYLES[hash(`${name}#banner`) % SCENE_STYLES.length];
}
export function nextSceneStyle(name: string): SceneStyle {
  const next = SCENE_STYLES[(SCENE_STYLES.indexOf(sceneStyle(name)) + 1) % SCENE_STYLES.length];
  try { localStorage.setItem(STYLE_KEY + name, next); } catch {}
  window.dispatchEvent(new Event("gpuvm-pattern"));
  return next;
}

export function renameSceneStyle(from: string, to: string) {
  try {
    const saved = localStorage.getItem(STYLE_KEY + from);
    if (saved) { localStorage.setItem(STYLE_KEY + to, saved); localStorage.removeItem(STYLE_KEY + from); }
  } catch {}
}

export interface SceneActivity { cpu: number; gpu: number; mem: number }

interface Props {
  name: string;
  variant?: number;
  style: SceneStyle;
  state: string;
  activity: SceneActivity;
}

const CELLS: [number, number][] = [[0, 0], [1, 0], [0, 1], [1, 1]];

function round(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, r: number) {
  g.beginPath();
  g.roundRect(x, y, w, h, r);
}

export function Scene({ name, variant, style, state, activity }: Props) {
  const ref = useRef<HTMLCanvasElement>(null);
  const target = useRef(activity);
  target.current = activity;
  const phase = state === "Running" ? "on" : state === "Off" ? "off" : state === "Paused" || state === "Saved" ? "still" : "sweep";
  const v = variant ?? patternVariant(name);
  const color = machineColor(name, v);

  useEffect(() => {
    const canvas = ref.current;
    if (!canvas) return;
    const seed = hash(`${name}#${v}#${style}`);
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    const moving = phase === "on" || phase === "sweep";
    const now = { ...target.current };
    let t = 0;
    let last = performance.now(), drawnAt = 0;
    let frame = 0;
    let layout: ReturnType<typeof build> | null = null;
    let size = "";

    function build(w: number, h: number) {
      const r = random(seed);
      if (style === "wafer") {
        const D = 26, G = 8;
        const cols = Math.ceil(w / (D + G)) + 2, rows = Math.max(1, Math.floor((h - 4) / (D + G)));
        const dies = Array.from({ length: cols * rows }, (_, k) => ({ i: k % cols, j: Math.floor(k / cols), part: Math.floor(r() * 4), ph: r() * 6, fill: r() }));
        return { kind: "wafer" as const, D, G, cols, rows, dies, mine: { x: Math.round(w * (0.55 + r() * 0.3)), j: Math.floor(r() * rows) } };
      }
      if (style === "partition") {
        const cell = 10, gap = 3;
        const cols = Math.floor((w - 24) / (cell + gap)), rows = Math.max(1, Math.floor((h - 20) / (cell + gap)));
        const n = cols * rows;
        const order = Array.from({ length: n }, (_, k) => k).sort(() => r() - 0.5);
        const shade = Array.from({ length: n }, () => 0.3 + r() * 0.4);
        const ph = Array.from({ length: n }, () => r() * 6);
        return { kind: "partition" as const, cell, gap, cols, rows, n, order, shade, ph, ox: (w - cols * (cell + gap) + gap) / 2, oy: (h - rows * (cell + gap) + gap) / 2 };
      }
      const U = 14, cw = Math.ceil(w / U), ch = Math.ceil(h / U);
      const occupied = new Set<string>();
      const tiles: { i: number; j: number; s: number; part: number; rank: number; ph: number }[] = [];
      for (let tries = 0; tries < 1400; tries++) {
        const s = [1, 2, 2, 3, 4][Math.floor(r() * 5)];
        const i = Math.floor(r() * cw), j = Math.floor(r() * ch);
        let ok = i + s <= cw && j + s <= ch;
        for (let a = 0; a < s && ok; a++) for (let b = 0; b < s && ok; b++) if (occupied.has(`${i + a},${j + b}`)) ok = false;
        if (!ok) continue;
        for (let a = 0; a < s; a++) for (let b = 0; b < s; b++) occupied.add(`${i + a},${j + b}`);
        tiles.push({ i, j, s, part: Math.floor(r() * 4), rank: r(), ph: r() * 6 });
      }
      return { kind: "mosaic" as const, U, tiles };
    }

    const draw = (stamp: number) => {
      const cap = animFps();
      if (cap === 0) { frame = 0; stale = true; return; }
      const due = paceFrame(stamp, drawnAt, cap);
      if (due === null) { frame = requestAnimationFrame(draw); return; }
      drawnAt = due;
      const dt = Math.min(0.1, (stamp - last) / 1000);
      last = stamp;
      const goal = target.current;
      const ease = Math.min(1, dt * 1.5);
      now.cpu += (goal.cpu - now.cpu) * ease;
      now.gpu += (goal.gpu - now.gpu) * ease;
      now.mem += (goal.mem - now.mem) * ease;
      const on = phase === "on";
      const gpu = on ? now.gpu / 100 : 0, cpu = on ? now.cpu / 100 : 0, mem = phase === "off" ? 0 : now.mem / 100;
      if (!reduced && moving) t += dt * (on ? 0.4 + gpu * 2.2 : 0.8);

      const w = canvas.clientWidth, h = canvas.clientHeight, d = animDpr();
      if (w && h) {
        if (canvas.width !== Math.round(w * d) || canvas.height !== Math.round(h * d)) {
          canvas.width = Math.round(w * d);
          canvas.height = Math.round(h * d);
        }
        if (size !== `${w}x${h}`) { size = `${w}x${h}`; layout = build(w, h); }
        const g = canvas.getContext("2d")!;
        g.setTransform(d, 0, 0, d, 0, 0);
        g.clearRect(0, 0, w, h);
        const ink = getComputedStyle(canvas).getPropertyValue("--scene-ink").trim() || "#888";
        const rest = phase === "off" ? 0.6 : 1;
        const sweepX = phase === "sweep" ? ((t * 0.35) % 1.3 - 0.15) * w : -1e9;
        const swept = (x: number) => Math.max(0, 1 - Math.abs(x - sweepX) / 60);
        const L = layout!;

        if (L.kind === "wafer") {
          const step = L.D + L.G;
          const ox = -((t * 18) % step) - step;
          const oy = (h - L.rows * step + L.G) / 2;
          for (const die of L.dies) {
            const x = ox + die.i * step, y = oy + die.j * step;
            round(g, x, y, L.D, L.D, 5);
            g.strokeStyle = ink; g.globalAlpha = 0.12 * rest; g.lineWidth = 1; g.stroke();
            CELLS.forEach(([a, b], k) => {
              round(g, x + 4 + a * 10, y + 4 + b * 10, 8, 8, 2);
              const flick = (Math.sin(t * 3 + die.ph * 7 + k * 1.7) + 1) / 2;
              const busy = k === die.part && flick > 1 - cpu * 0.9;
              const filled = k !== die.part && die.fill < mem * 0.5;
              const s = swept(x + L.D / 2);
              g.fillStyle = busy || s > 0.2 ? color : ink;
              g.globalAlpha = (busy ? 0.75 : s > 0.2 ? s : filled ? 0.16 : 0.06) * rest;
              g.fill();
            });
          }
          const mx = L.mine.x, my = oy + L.mine.j * step;
          round(g, mx - 3, my - 3, L.D + 6, L.D + 6, 7);
          g.fillStyle = getComputedStyle(canvas).getPropertyValue("--surface").trim() || "#1c1c1c"; g.globalAlpha = 1; g.fill();
          round(g, mx, my, L.D, L.D, 5);
          g.strokeStyle = color; g.globalAlpha = 0.9 * rest; g.lineWidth = 1.2; g.stroke();
          const part = hash(`${name}#${v}#part`) % 4;
          CELLS.forEach(([a, b], k) => {
            round(g, mx + 4 + a * 10, my + 4 + b * 10, 8, 8, 2);
            g.fillStyle = k === part ? color : ink;
            g.globalAlpha = k === part ? (phase === "off" ? 0.5 : 0.65 + 0.35 * Math.sin(t * 4)) : 0.1 * rest;
            g.fill();
          });
        } else if (L.kind === "partition") {
          const lit = gpu * L.n, used = Math.min(L.n, lit + mem * L.n * 0.6);
          L.order.forEach((idx, k) => {
            const i = idx % L.cols, j = Math.floor(idx / L.cols);
            const x = L.ox + i * (L.cell + L.gap), y = L.oy + j * (L.cell + L.gap);
            round(g, x, y, L.cell, L.cell, 2.5);
            const s = swept(x);
            if (k < lit || s > 0.2) {
              const shimmer = 1 - cpu * 0.45 * (Math.sin(t * 5 + L.ph[idx] * 9) + 1) / 2;
              g.fillStyle = color; g.globalAlpha = Math.max(s, L.shade[idx] * shimmer);
            } else if (k < used) {
              g.fillStyle = ink; g.globalAlpha = 0.2;
            } else {
              g.fillStyle = ink; g.globalAlpha = 0.06 * rest;
            }
            g.fill();
          });
        } else {
          for (const tile of L.tiles) {
            const x = tile.i * L.U + 1, y = tile.j * L.U + 1, S = tile.s * L.U - 2, q = (S - 3) / 2;
            const hot = tile.rank < 0.06 + cpu * 0.3;
            const s = swept(x + S / 2);
            CELLS.forEach(([a, b], k) => {
              round(g, x + a * (q + 3), y + b * (q + 3), q, q, Math.max(1.5, q * 0.22));
              const own = k === tile.part;
              if (own && (hot || s > 0.2)) {
                g.fillStyle = color;
                g.globalAlpha = Math.max(s, phase === "off" ? 0.35 : 0.55 + 0.45 * Math.sin(t * 3 + tile.ph));
              } else {
                g.fillStyle = ink;
                g.globalAlpha = (own ? 0.12 + mem * 0.12 : 0.04 + mem * 0.04) * rest;
              }
              g.fill();
            });
          }
        }
        g.globalAlpha = 1;
      }
      if (moving && !reduced && seen) frame = requestAnimationFrame(draw);
    };
    let seen = true, stale = false;
    const restart = () => {
      cancelAnimationFrame(frame);
      if (!seen) { stale = true; return; }
      stale = false; last = performance.now(); frame = requestAnimationFrame(draw);
    };
    const io = new IntersectionObserver(([e]) => { const was = seen; seen = e.isIntersecting; if (seen && (!was || stale)) restart(); });
    io.observe(canvas);
    restart();
    const resize = new ResizeObserver(restart);
    resize.observe(canvas);
    const visibility = () => { if (document.hidden) cancelAnimationFrame(frame); else restart(); };
    document.addEventListener("visibilitychange", visibility);
    const theme = new MutationObserver(restart);
    theme.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
    window.addEventListener("gpuvm-palette", restart);
    const offBudget = onAnimBudget(restart);
    return () => {
      cancelAnimationFrame(frame);
      offBudget();
      io.disconnect();
      resize.disconnect();
      theme.disconnect();
      document.removeEventListener("visibilitychange", visibility);
      window.removeEventListener("gpuvm-palette", restart);
    };
  }, [name, v, color, style, phase]);

  return <canvas ref={ref} className="scene" aria-hidden="true" />;
}
