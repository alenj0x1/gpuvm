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
/** `ghost` draws it as a machine that is off: every piece there but faint, waiting to be made. `kind` draws a single
 *  piece instead of a whole machine, for the Library's other cards: a disk (filled to `fill`), a Windows ISO disc, a
 *  template (a cube with Windows installed and its apps) or a prepared Windows (a disk with the Windows logo). */
export type PieceKind = "machine" | "disk" | "iso" | "template" | "windows";
const NO_MACHINE: MiniMachine = { cores: 0, memoryGB: 0, gpuPercent: 0, diskGB: 0, apps: 0 };
export function MiniCube({ machine = NO_MACHINE, className, ghost = false, kind = "machine", fill = 0 }: {
  machine?: MiniMachine; className?: string; ghost?: boolean; kind?: PieceKind; fill?: number;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const key = `${machine.cores}:${machine.memoryGB}:${machine.gpuPercent}:${machine.diskGB}:${machine.apps}:${ghost}:${kind}:${fill.toFixed(3)}`;

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
      const accent = ghost ? (css.getPropertyValue("--muted").trim() || "#8a8a8a") : css.getPropertyValue("--accent").trim() || "#7d9cf0";
      const light = document.documentElement.dataset.theme === "light";
      g.globalCompositeOperation = light ? "source-over" : "lighter";
      g.globalAlpha = ghost ? 0.45 : 1;
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
      const flat = (cx: number, y: number, cz: number, r: number, a0 = 0, a1 = Math.PI * 2, n = 40): V3[] =>
        Array.from({ length: n + 1 }, (_, i) => { const a = a0 + ((a1 - a0) * i) / n; return [cx + Math.cos(a) * r, y, cz + Math.sin(a) * r] as V3; });
      const stroke = (pts: V3[], al: number, lw = 1, fillA = 0) => {
        g.beginPath(); pts.forEach((p, i) => { const q = P(...p); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); });
        if (fillA) { g.closePath(); g.fillStyle = rgba(accent, fillA); g.fill(); }
        g.lineWidth = lw; g.strokeStyle = rgba(accent, al); g.stroke(); g.lineWidth = 1;
      };
      // The four squares of the Windows logo, flat at a height.
      const windowsLogo = (cx: number, y: number, cz: number, size: number) => {
        const q = size / 2, gap = size * 0.08;
        for (const [dx, dz] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) {
          const x0 = cx + (dx < 0 ? -q : gap / 2), z0 = cz + (dz < 0 ? -q : gap / 2), w = q - gap / 2;
          stroke([[x0, y, z0], [x0 + w, y, z0], [x0 + w, y, z0 + w], [x0, y, z0 + w]], 0.9, 1, 0.55);
        }
      };
      if (kind === "disk" || kind === "windows") {
        // The disk on its own: case, screws, platter with tracks, how full it is as a ring, and the arm.
        box(0, 0.75, 0, 1.25, 0.24, 1.6, 0.9, 0.08);
        const y = 0.991;
        for (const [a, b] of [[-0.52, -0.7], [0.52, -0.7], [-0.52, 0.7], [0.52, 0.7]]) stroke(flat(a, y, b, 0.04, 0, Math.PI * 2, 10), 0.8);
        stroke(flat(0, y, 0.12, 0.5), 0.9, 1.2, 0.05);
        for (let i = 1; i < 5; i++) stroke(flat(0, y, 0.12, 0.1 + i * 0.08), 0.25);
        stroke(flat(0, y, 0.12, 0.1, 0, Math.PI * 2, 16), 0.9, 1, 0.25);
        if (kind === "windows") windowsLogo(0, y + 0.002, 0.12, 0.42);
        else if (fill > 0) stroke(flat(0, y + 0.002, 0.12, 0.56, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(1, fill), 48), 1, 2.4);
        stroke([[0.42, y, -0.55], [0.42 + Math.cos(2.3) * 0.6, y, -0.55 + Math.sin(2.3) * 0.6]], 1, 2);
        stroke(flat(0.42, y, -0.55, 0.07, 0, Math.PI * 2, 12), 0.9, 1, 0.2);
        box(0, 0.75, -0.86, 0.5, 0.1, 0.1, 0.9, 0.2);
      } else if (kind === "iso") {
        // A Windows install disc: a flat disc with its hole, tracks and the Windows logo.
        const y = 0.85;
        stroke(flat(0, y, 0, 0.95, 0, Math.PI * 2, 64), 0.95, 1.3, 0.06);
        stroke(flat(0, y, 0, 0.13, 0, Math.PI * 2, 20), 0.9, 1.2);
        stroke(flat(0, y, 0, 0.3, 0, Math.PI * 2, 32), 0.45);
        for (let i = 0; i < 4; i++) stroke(flat(0, y, 0, 0.45 + i * 0.12, 0.4 + i, 1.6 + i, 18), 0.35);
        windowsLogo(0.42, y + 0.002, -0.05, 0.36);
      } else if (kind === "template") {
        // A Windows ready to copy: the glass cube with its board and a screen showing Windows, and its apps.
        for (const [a, b] of EDGES) line(a, b, 0.35);
        box(0, 0, 0, 1.78, 0.05, 1.78, 0.6, 0.06);
        const sx = 0.8, sy0 = 0.45, sy1 = 1.45, sz = -0.2;
        stroke([[-sx, sy0, sz], [sx, sy0, sz], [sx, sy1, sz], [-sx, sy1, sz], [-sx, sy0, sz]], 0.9, 1.2, 0.07);
        stroke([[-sx, sy0 + 0.12, sz], [sx, sy0 + 0.12, sz]], 0.6);
        // The logo stands on the screen: drawn on its plane.
        const lx = 0, ly = 1.0, q = 0.16, gp = 0.025;
        for (const [dx, dy] of [[-1, 1], [1, 1], [-1, -1], [1, -1]]) {
          const x0 = lx + (dx < 0 ? -q : gp), y0 = ly + (dy < 0 ? -q : gp), w = q - gp;
          stroke([[x0, y0, sz], [x0 + w, y0, sz], [x0 + w, y0 + w, sz], [x0, y0 + w, sz]], 0.9, 1, 0.55);
        }
        const spots: V3[] = [[-0.6, 1.6, 0.5], [0.6, 1.55, 0.45], [-0.55, 0.3, 0.55], [0.55, 0.35, 0.6], [0, 1.7, 0.6]];
        for (let i = 0; i < Math.min(machine.apps, spots.length); i++) { const [x, y, z] = spots[i]; box(x, y, z, 0.12, 0.12, 0.12, 0.9, 0.25); }
      }
      if (kind !== "machine") { g.globalCompositeOperation = "source-over"; g.globalAlpha = 1; return; }
      // The glass cube.
      for (const [a, b] of EDGES) line(a, b, 0.35);
      // An empty recipe (a profile still to make) is the glass cube alone.
      if (!machine.cores && !machine.memoryGB) { g.globalCompositeOperation = "source-over"; return; }
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
      g.globalAlpha = 1;
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
