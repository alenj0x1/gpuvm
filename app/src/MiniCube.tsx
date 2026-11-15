import { useEffect, useRef } from "react";

/** What a small cube shows: the pieces a profile (or any recipe of a machine) gives. */
export interface MiniMachine { cores: number; memoryGB: number; gpuPercent: number; diskGB: number; apps: number }

type V3 = [number, number, number];
const rgba = (c: string, a: number) => {
  const s = c.trim();
  const rgb = s.startsWith("rgb") ? s.replace(/[^\d,.]/g, "").split(",").slice(0, 3).map(Number)
    : [0, 2, 4].map((i) => parseInt(s.replace("#", "").slice(i, i + 2), 16));
  return `rgba(${rgb.join(",")},${a})`;
};

/** A small, still version of a machine's cube for lists (profiles in the Library): the same pieces as the hologram,
 *  sized by the recipe, drawn once. It turns slowly while the pointer is over it. Light enough for many at once. */
export function MiniCube({ machine, className }: { machine: MiniMachine; className?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const key = `${machine.cores}:${machine.memoryGB}:${machine.gpuPercent}:${machine.diskGB}:${machine.apps}`;

  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const g = cv.getContext("2d")!;
    let yaw = Math.PI / 4 + 0.15, frame = 0, hover = false, last = 0;
    const draw = () => {
      const W = cv.clientWidth, H = cv.clientHeight, dpr = window.devicePixelRatio || 1;
      if (!W || !H) return;
      if (cv.width !== Math.round(W * dpr) || cv.height !== Math.round(H * dpr)) { cv.width = Math.round(W * dpr); cv.height = Math.round(H * dpr); }
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, W, H);
      const css = getComputedStyle(cv);
      const accent = css.getPropertyValue("--accent").trim() || "#7d9cf0";
      const light = document.documentElement.dataset.theme === "light";
      g.globalCompositeOperation = light ? "source-over" : "lighter";
      const S = Math.min(W / 3.1, H / 3.1), cs = Math.cos(yaw), sn = Math.sin(yaw), cp = Math.cos(0.55), sp = Math.sin(0.55);
      const P = (x: number, y: number, z: number): [number, number] => {
        const x1 = x * cs - z * sn, z1 = x * sn + z * cs, yy = y - 1;
        return [W / 2 + x1 * S, H / 2 - (yy * cp - z1 * sp) * S];
      };
      const line = (a: V3, b: V3, al: number) => { const p = P(...a), q = P(...b); g.beginPath(); g.moveTo(p[0], p[1]); g.lineTo(q[0], q[1]); g.strokeStyle = rgba(accent, al); g.stroke(); };
      const box = (x: number, y: number, z: number, w: number, h: number, d: number, al = 0.8, fill = 0.12) => {
        const a = w / 2, b = d / 2;
        const top: V3[] = [[x - a, y + h, z - b], [x + a, y + h, z - b], [x + a, y + h, z + b], [x - a, y + h, z + b]];
        g.beginPath(); top.forEach((p, i) => { const q = P(...p); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); }); g.closePath();
        g.fillStyle = rgba(accent, fill); g.fill(); g.strokeStyle = rgba(accent, al); g.stroke();
        for (const [px, pz] of [[x - a, z - b], [x + a, z - b], [x + a, z + b], [x - a, z + b]]) line([px, y, pz], [px, y + h, pz], al * 0.8);
        for (let i = 0; i < 4; i++) { const p = top[i], q = top[(i + 1) % 4]; line([p[0], y, p[2]], [q[0], y, q[2]], al * 0.5); }
      };
      g.lineWidth = 1;
      // The glass cube.
      for (const [a, b] of EDGES) line(a, b, 0.35);
      // Board, processor with a cell per thread, a module per 4 GB, the graphics card, the disk and the apps.
      box(0, 0, 0, 1.78, 0.05, 1.78, 0.6, 0.06);
      box(-0.38, 0.05, -0.32, 0.46, 0.08, 0.46, 0.9, 0.16);
      const n = Math.min(16, machine.cores);
      for (let i = 0; i < 16; i++) {
        const u = -0.38 - 0.135 + (i % 4) * 0.09, w = -0.32 - 0.135 + Math.floor(i / 4) * 0.09;
        const q = [[u - 0.035, w - 0.035], [u + 0.035, w - 0.035], [u + 0.035, w + 0.035], [u - 0.035, w + 0.035]].map(([a, b]) => P(a, 0.131, b));
        g.beginPath(); q.forEach((p, k) => (k ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1]))); g.closePath();
        g.fillStyle = rgba(accent, i < n ? 0.75 : 0.06); g.fill();
      }
      const k = Math.max(1, Math.min(8, Math.round(machine.memoryGB / 4)));
      for (let i = 0; i < k; i++) box(0.2 + i * 0.088, 0.05, -0.36, 0.03, 0.5, 0.6, 0.85, 0.14);
      box(0.35, 0.05, 0.32, 1, 0.47, 0.16, 0.9, 0.1);
      const lit = Math.round(machine.gpuPercent / 10);
      for (let i = 0; i < 10; i++) line([0.35 - 0.45 + i * 0.09, 0.1, 0.401], [0.35 - 0.45 + i * 0.09 + 0.07, 0.1, 0.401], i < lit ? 0.95 : 0.15);
      box(-0.55, 0.05, 0.6, 0.42, 0.1, 0.5, 0.9, 0.1);
      const ring: V3[] = [];
      for (let i = 0; i <= 32; i++) { const a = -Math.PI / 2 + (Math.PI * 2 * Math.min(1, machine.diskGB / 512) * i) / 32; ring.push([-0.55 + Math.cos(a) * 0.17, 0.151, 0.66 + Math.sin(a) * 0.17]); }
      g.beginPath(); ring.forEach((p, i) => { const q = P(...p); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); }); g.lineWidth = 2; g.strokeStyle = rgba(accent, 0.9); g.stroke(); g.lineWidth = 1;
      const spots: V3[] = [[-0.6, 1.1, -0.5], [0.6, 1.0, -0.2], [-0.65, 0.75, 0.3], [0.55, 1.5, 0.5], [-0.4, 1.6, 0.6], [0.15, 1.05, -0.7]];
      for (let i = 0; i < Math.min(machine.apps, spots.length); i++) { const [x, y, z] = spots[i]; box(x, y, z, 0.12, 0.12, 0.12, 0.9, 0.25); }
      g.globalCompositeOperation = "source-over";
    };
    const loop = (t: number) => {
      if (last) yaw += Math.min(0.05, (t - last) / 1000) * 0.6;
      last = t;
      draw();
      if (hover) frame = requestAnimationFrame(loop);
    };
    const enter = () => { hover = true; last = 0; cancelAnimationFrame(frame); frame = requestAnimationFrame(loop); };
    const leave = () => { hover = false; };
    cv.addEventListener("pointerenter", enter);
    cv.addEventListener("pointerleave", leave);
    // Drawn again when its size, the theme or the accent changes.
    const ro = new ResizeObserver(draw);
    ro.observe(cv);
    const mo = new MutationObserver(() => requestAnimationFrame(draw));
    mo.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme", "data-accent"] });
    draw();
    return () => { cancelAnimationFrame(frame); ro.disconnect(); mo.disconnect(); cv.removeEventListener("pointerenter", enter); cv.removeEventListener("pointerleave", leave); };
  }, [key]); // eslint-disable-line react-hooks/exhaustive-deps

  return <canvas ref={ref} className={`mini-cube${className ? ` ${className}` : ""}`} aria-hidden="true" />;
}

const CORNERS: V3[] = [];
for (const x of [-1, 1]) for (const y of [0, 2]) for (const z of [-1, 1]) CORNERS.push([x, y, z]);
const EDGES: [V3, V3][] = [];
for (let i = 0; i < 8; i++) for (let j = i + 1; j < 8; j++) {
  const a = CORNERS[i], b = CORNERS[j];
  if (Number(a[0] !== b[0]) + Number(a[1] !== b[1]) + Number(a[2] !== b[2]) === 1) EDGES.push([a, b]);
}
