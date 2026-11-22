import { useEffect, useRef } from "react";
import { animFps, onAnimBudget, paceFrame } from "./animBudget";

export type PixelSceneKind = "sakura" | "forest" | "alpine";

const W = 192, H = 108;
const BAYER = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map((v) => (v + 0.5) / 16);
type RGB = [number, number, number];
const hex = (h: string): RGB => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
const mix = (a: RGB, b: RGB, t: number): RGB => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
const hash = (x: number, y: number) => { let h = (x * 374761393 + y * 668265263) | 0; h = Math.imul(h ^ (h >>> 13), 1274126177); return ((h ^ (h >>> 16)) >>> 0) / 4294967296; };
const solid = (h: string) => { const [r, g, b] = hex(h); return (255 << 24) | (b << 16) | (g << 8) | r; };

function ramp(stops: [number, RGB][], t: number): RGB {
  t = Math.max(0, Math.min(1, t));
  let i = 0;
  while (i < stops.length - 2 && t > stops[i + 1][0]) i++;
  const [t0, c0] = stops[i], [t1, c1] = stops[i + 1];
  return mix(c0, c1, (t - t0) / (t1 - t0));
}

function put(buf: Uint32Array, x: number, y: number, c: RGB, step = 22) {
  const b = BAYER[(y & 3) * 4 + (x & 3)] - 0.5;
  const q = (v: number) => Math.max(0, Math.min(255, Math.round((v + b * step) / step) * step));
  buf[y * W + x] = (255 << 24) | (q(c[2]) << 16) | (q(c[1]) << 8) | q(c[0]);
}
const inside = (x: number, y: number) => x >= 0 && x < W && y >= 0 && y < H;

interface Scene { build(): Uint32Array; frame(buf: Uint32Array, layer: Uint32Array, T: number): void }

const sakura: Scene = (() => {
  const HORIZON = 64, SUN = { x: 112, y: HORIZON - 4, r: 9 };
  const SKY: [number, RGB][] = [[0, hex("#1b2447")], [0.32, hex("#3f3160")], [0.55, hex("#a4475f")], [0.78, hex("#ea7a48")], [1, hex("#ffc970")]];
  const skyAt = (x: number, y: number): RGB => {
    const c = ramp(SKY, y / HORIZON);
    const dx = (x - SUN.x) / 1.6, dy = y - SUN.y, glow = Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy) / 46);
    return mix(c, hex("#ffd98c"), glow * glow * 0.75);
  };
  const far = Array.from({ length: W }, (_, x) => HORIZON - (7 + 5 * Math.sin(x * 0.045 + 0.6) + 3 * Math.sin(x * 0.14 + 2) + 1.5 * Math.sin(x * 0.37)));
  const near = Array.from({ length: W }, (_, x) => HORIZON - Math.max(0, 5 + 4 * Math.sin(x * 0.07 + 3.4) + 2 * Math.sin(x * 0.21)) * (x < 70 || x > 150 ? 1 : 0.35));
  const petals = Array.from({ length: 46 }, (_, i) => ({ x: hash(i, 1) * W, y: hash(i, 2) * H, v: 3 + hash(i, 3) * 5, p: hash(i, 4) * 6, big: hash(i, 5) > 0.75 }));
  const clouds = [{ y: 22, x: 20, w: 46, s: 0.6 }, { y: 31, x: 120, w: 58, s: 0.4 }, { y: 40, x: 70, w: 34, s: 0.8 }, { y: 15, x: 150, w: 30, s: 0.5 }];

  function build() {
    const layer = new Uint32Array(W * H);
    const shore = (x: number) => (x < 84 ? 92 + (x / 84) * 18 : x > 150 ? 110 - ((x - 150) / 42) * 20 : 999);
    for (let x = 0; x < W; x++) for (let y = Math.max(0, Math.floor(shore(x))); y < H; y++) {
      layer[y * W + x] = solid(y - shore(x) < 1.5 ? "#4a2433" : hash(x, y) < 0.12 ? "#2f1828" : "#25131f");
    }
    const trunk = (x0: number, y0: number, x1: number, y1: number, w: number) => {
      const n = Math.ceil(Math.hypot(x1 - x0, y1 - y0));
      for (let i = 0; i <= n; i++) {
        const t = i / n, cx = x0 + (x1 - x0) * t, cy = y0 + (y1 - y0) * t, ww = w * (1 - t * 0.55);
        for (let dx = -ww; dx <= ww; dx++) {
          const x = Math.round(cx + dx), y = Math.round(cy);
          if (inside(x, y)) layer[y * W + x] = solid(dx > ww * 0.3 ? "#5a2c38" : "#2a1520");
        }
      }
    };
    const canopy = (blobs: [number, number, number][]) => {
      for (const [cx, cy, r] of blobs) {
        for (let y = Math.floor(cy - r - 2); y <= cy + r + 2; y++) for (let x = Math.floor(cx - r - 2); x <= cx + r + 2; x++) {
          if (!inside(x, y)) continue;
          const dx = x - cx, dy = y - cy, d = Math.hypot(dx, dy) / (r * (0.86 + hash(x, y) * 0.24));
          if (d > 1 || (d > 0.82 && hash(y, x) < 0.35)) continue;
          const toSun = Math.hypot(SUN.x - cx, SUN.y - cy) || 1;
          const light = ((dx / r) * (SUN.x - cx) + (dy / r) * (SUN.y - cy)) / toSun - (dy / r) * 0.35;
          const n = hash(x * 3, y * 7);
          const color = light > 0.45 && n > 0.25 ? (n > 0.8 ? "#ffe2b8" : "#ffc2a0")
            : light > 0.05 ? (n > 0.7 ? "#ffc4d6" : "#f59ab6")
            : light > -0.45 ? (n > 0.75 ? "#e985a6" : "#cf6690")
            : n > 0.6 ? "#9b3f6a" : "#6f2a52";
          layer[y * W + x] = solid(color);
        }
      }
    };
    trunk(26, 108, 30, 58, 3.4); trunk(29, 74, 46, 52, 1.6); trunk(28, 66, 12, 46, 1.4);
    canopy([[20, 40, 15], [40, 46, 13], [8, 30, 12], [32, 28, 13], [52, 38, 9], [-2, 50, 11], [14, 54, 9]]);
    trunk(176, 108, 172, 66, 2.8); trunk(173, 80, 160, 62, 1.3);
    canopy([[170, 56, 12], [184, 50, 12], [158, 60, 8], [192, 64, 9], [176, 44, 9]]);
    for (const [x, s] of [[62, 3], [70, 4], [77, 3], [138, 3], [145, 4]] as [number, number][]) {
      trunk(x, HORIZON, x, HORIZON - s, 0.5);
      canopy([[x, HORIZON - s - 2, s]]);
    }
    return layer;
  }

  function frame(buf: Uint32Array, layer: Uint32Array, T: number) {
    for (let y = 0; y < HORIZON; y++) for (let x = 0; x < W; x++) put(buf, x, y, skyAt(x, y));
    for (let y = SUN.y - SUN.r; y < HORIZON; y++) for (let x = SUN.x - SUN.r; x <= SUN.x + SUN.r; x++) {
      const d = Math.hypot(x - SUN.x, y - SUN.y);
      if (d <= SUN.r) buf[y * W + x] = solid(d < SUN.r - 3 ? "#fff6d6" : "#ffe08f");
    }
    for (const c of clouds) {
      const x0 = ((c.x + T * c.s) % (W + c.w)) - c.w;
      for (let row = 0; row < 4; row++) {
        const inset = [6, 2, 0, 4][row], y = c.y + row;
        for (let x = Math.round(x0 + inset); x < x0 + c.w - inset * 1.5; x++) {
          if (x < 0 || x >= W) continue;
          buf[y * W + x] = solid(row >= 2 ? (Math.abs(x - SUN.x) < 50 ? "#ffb98a" : "#e8846a") : "#7e3a5c");
        }
      }
    }
    for (let x = 0; x < W; x++) {
      for (let y = Math.ceil(far[x]); y < HORIZON; y++) put(buf, x, y, mix(skyAt(x, y), hex("#5b2f4f"), 0.7));
      for (let y = Math.ceil(near[x]); y < HORIZON; y++) put(buf, x, y, hex("#3a2038"));
    }
    for (let y = HORIZON; y < H; y++) {
      const r = y - HORIZON;
      for (let x = 0; x < W; x++) {
        const wx = Math.round(x + Math.sin(r * 0.9 + T * 1.8) * (0.5 + r * 0.04));
        const my = HORIZON - 1 - Math.floor(r * 1.4);
        let c: RGB = my >= 0 ? skyAt(wx, my) : hex("#1b2447");
        if (my >= 0 && wx >= 0 && wx < W && my >= far[wx]) c = mix(c, hex("#4a2742"), 0.75);
        put(buf, x, y, mix(c, hex("#20223f"), 0.28 + r * 0.006));
      }
      const half = Math.max(1, (12 - r * 0.2) * (0.55 + 0.45 * Math.sin(r * 1.3 + T * 3.1)));
      const cx = SUN.x + Math.sin(r * 0.7 + T * 2.2) * (1 + r * 0.05);
      if ((r + Math.floor(T * 5)) % 3 === 2 && r > 2) continue;
      for (let x = Math.round(cx - half); x <= cx + half; x++) {
        if (x < 0 || x >= W) continue;
        const edge = Math.abs(x - cx) > half * 0.6;
        buf[y * W + x] = solid(edge ? "#f2a25a" : r < 10 || hash(x, y + Math.floor(T * 4)) > 0.7 ? "#fff0b8" : "#ffd27a");
      }
    }
    for (let i = 0; i < buf.length; i++) if (layer[i]) buf[i] = layer[i];
    for (const p of petals) {
      const y = Math.floor((p.y + T * p.v) % H), x = Math.floor(((p.x - T * p.v * 0.7 + Math.sin(T * 1.3 + p.p) * 3) % W + W) % W);
      const c = solid(p.big ? "#ffd1df" : "#f6a5bf");
      buf[y * W + x] = c;
      if (p.big && x + 1 < W) buf[y * W + x + 1] = c;
    }
  }
  return { build, frame };
})();

const forest: Scene = (() => {
  const SUN = { x: 138, y: 22 };
  const SKY: [number, RGB][] = [[0, hex("#7fbcd6")], [0.45, hex("#bfe0dc")], [0.8, hex("#f3e7b8")], [1, hex("#fff3cf")]];
  const ROWS = [
    { base: 58, h: 16, gap: 7, color: "#8fb7a6", seed: 1 },
    { base: 68, h: 22, gap: 9, color: "#5f9180", seed: 2 },
    { base: 80, h: 30, gap: 12, color: "#3b6b57", seed: 3 },
    { base: 96, h: 44, gap: 17, color: "#24493a", seed: 4 },
  ];
  const motes = Array.from({ length: 34 }, (_, i) => ({ x: hash(i, 11) * W, y: 20 + hash(i, 12) * 80, s: 0.6 + hash(i, 13) * 1.4, p: hash(i, 14) * 6 }));

  function pine(layer: Uint32Array, cx: number, base: number, h: number, color: RGB, lit: RGB) {
    const top = base - h;
    for (let y = Math.max(0, Math.floor(top)); y < Math.min(H, base); y++) {
      const t = (y - top) / h;
      const tier = (t * 4) % 1;
      const half = (1.2 + t * h * 0.32) * (0.72 + tier * 0.28);
      for (let x = Math.round(cx - half); x <= cx + half; x++) {
        if (!inside(x, y)) continue;
        const c = x > cx + half * 0.35 && hash(x, y) > 0.35 ? lit : color;
        layer[y * W + x] = (255 << 24) | (Math.round(c[2]) << 16) | (Math.round(c[1]) << 8) | Math.round(c[0]);
      }
    }
    for (let y = base; y < Math.min(H, base + 3); y++) if (inside(Math.round(cx), y)) layer[y * W + Math.round(cx)] = solid("#3a2a20");
  }

  function build() {
    const layer = new Uint32Array(W * H);
    for (const r of ROWS) {
      const c = hex(r.color), lit = mix(c, hex("#f7e3a1"), 0.35);
      for (let x = -6, i = 0; x < W + 6; x += r.gap * (0.7 + hash(i, r.seed) * 0.6), i++) {
        pine(layer, x, r.base + hash(i, r.seed + 9) * 3, r.h * (0.7 + hash(i, r.seed + 5) * 0.5), c, lit);
      }
      for (let x = 0; x < W; x++) for (let y = Math.round(r.base); y < H; y++) layer[y * W + x] = (255 << 24) | (Math.round(c[2] * 0.9) << 16) | (Math.round(c[1] * 0.9) << 8) | Math.round(c[0] * 0.9);
    }
    for (let x = 0; x < W; x++) for (let y = 100; y < H; y++) layer[y * W + x] = solid(hash(x, y) > 0.8 ? "#3f6b36" : "#2c4a2a");
    for (let i = 0; i < 26; i++) {
      const x = Math.floor(hash(i, 40) * W), y = 99 + Math.floor(hash(i, 41) * 7);
      layer[y * W + x] = solid(hash(i, 42) > 0.5 ? "#f4e27a" : "#f1f1e6");
    }
    for (const [x0, w] of [[8, 7], [180, 8]]) for (let y = 0; y < H; y++) for (let x = x0 - w / 2; x < x0 + w / 2; x++) {
      if (!inside(Math.round(x), y)) continue;
      const side = x > x0 + w * 0.15;
      layer[y * W + Math.round(x)] = solid(side ? (hash(Math.round(x), y) > 0.7 ? "#7a5636" : "#6b4a2e") : hash(Math.round(x), y) > 0.85 ? "#4a321f" : "#3b2818");
    }
    return layer;
  }

  function frame(buf: Uint32Array, layer: Uint32Array, T: number) {
    for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
      const d = Math.hypot((x - SUN.x) / 1.3, y - SUN.y);
      put(buf, x, y, mix(ramp(SKY, y / 70), hex("#fffbe6"), Math.max(0, 1 - d / 40) ** 2 * 0.9));
    }
    for (let y = SUN.y - 5; y <= SUN.y + 5; y++) for (let x = SUN.x - 5; x <= SUN.x + 5; x++) if (Math.hypot(x - SUN.x, y - SUN.y) <= 5) buf[y * W + x] = solid("#fffdf0");
    for (let i = 0; i < buf.length; i++) if (layer[i]) buf[i] = layer[i];
    for (let y = 0; y < 100; y++) for (let x = 0; x < W; x++) {
      const band = ((x - SUN.x) * 0.55 + (y - SUN.y) * 0.85 + 600) % 23;
      const shaft = band < 5 && x < SUN.x + 10 ? (0.18 + 0.08 * Math.sin(T * 0.8 + band)) * Math.max(0, 1 - Math.hypot(x - SUN.x, y - SUN.y) / 150) : 0;
      const mist = [62, 73, 86].reduce((m, my) => m + Math.max(0, 1 - Math.abs(y - my) / 4) * (0.5 + 0.5 * Math.sin(x * 0.05 + T * 0.4 + my)) * 0.22, 0);
      const k = shaft + mist;
      if (k < 0.04) continue;
      const i = y * W + x, v = buf[i];
      const c: RGB = [v & 255, (v >> 8) & 255, (v >> 16) & 255];
      put(buf, x, y, mix(c, hex("#fff6d8"), Math.min(0.6, k)), 14);
    }
    for (const m of motes) {
      const x = Math.floor(((m.x + Math.sin(T * 0.7 + m.p) * 6 + T * m.s) % W + W) % W), y = Math.floor(m.y + Math.sin(T * 1.1 + m.p) * 3);
      if (inside(x, y)) buf[y * W + x] = solid(hash(m.p * 100, 1) > 0.5 ? "#fff3b0" : "#fffbe6");
    }
  }
  return { build, frame };
})();

const alpine: Scene = (() => {
  const HORIZON = 70, SUN = { x: 64, y: 44, r: 7 };
  const SKY: [number, RGB][] = [[0, hex("#2b3a67")], [0.35, hex("#5d6aa0")], [0.6, hex("#c99bb5")], [0.82, hex("#f6c3a0")], [1, hex("#ffe1b0")]];
  const skyAt = (x: number, y: number): RGB => {
    const c = ramp(SKY, y / HORIZON);
    const dx = (x - SUN.x) / 1.5, dy = y - SUN.y, glow = Math.max(0, 1 - Math.sqrt(dx * dx + dy * dy) / 40);
    return mix(c, hex("#fff1cf"), glow * glow * 0.7);
  };
  const ridge = (x: number, peaks: [number, number, number][]) => peaks.reduce((top, [px, h, w]) => Math.min(top, HORIZON - Math.max(0, h - Math.abs(x - px) * w)), HORIZON);
  const FAR: [number, number, number][] = [[10, 26, 0.7], [40, 22, 0.55], [92, 30, 0.6], [140, 24, 0.5], [178, 28, 0.65]];
  const BIG: [number, number, number][] = [[28, 34, 0.95], [70, 22, 0.8], [118, 44, 1.05], [160, 30, 0.85], [196, 36, 1.1]];
  const far = Array.from({ length: W }, (_, x) => ridge(x, FAR) + Math.sin(x * 0.5) * 0.6);
  const big = Array.from({ length: W }, (_, x) => ridge(x, BIG) + (hash(x, 3) - 0.5) * 1.2);
  const hills = Array.from({ length: W }, (_, x) => HORIZON - Math.max(0, 6 + 3 * Math.sin(x * 0.09 + 1.2) + 2 * Math.sin(x * 0.27)));
  const birds = [{ x: 30, y: 24, s: 5 }, { x: 44, y: 28, s: 4.4 }, { x: 52, y: 22, s: 5.4 }];
  const stars = Array.from({ length: 22 }, (_, i) => ({ x: Math.floor(hash(i, 9) * W), y: Math.floor(hash(i, 10) * 18), p: hash(i, 11) * 6 }));

  function build() {
    const layer = new Uint32Array(W * H);
    const pine = (cx: number, base: number, h: number) => {
      for (let y = base - h; y <= base; y++) {
        const half = Math.max(0, Math.round(((y - (base - h)) / h) * (h * 0.32)) - ((y - base + h) % 3 === 0 ? 1 : 0));
        for (let x = cx - half; x <= cx + half; x++) if (inside(x, y)) layer[y * W + x] = solid(x > cx ? "#1d2b33" : "#16222a");
      }
    };
    for (let x = 0; x < W; x++) {
      const shore = x < 40 ? 92 + x * 0.35 : x > 160 ? 106 - (x - 160) * 0.4 : 999;
      for (let y = Math.max(0, Math.floor(shore)); y < H; y++) layer[y * W + x] = solid(y - shore < 1.5 ? "#2f3d3c" : hash(x, y) < 0.12 ? "#1e2a2a" : "#18221f");
    }
    for (const [x, b, h] of [[6, 100, 22], [16, 98, 16], [26, 103, 26], [36, 104, 14], [166, 104, 18], [176, 101, 24], [187, 99, 20]] as [number, number, number][]) pine(x, b, h);
    return layer;
  }

  function frame(buf: Uint32Array, layer: Uint32Array, T: number) {
    for (let y = 0; y < HORIZON; y++) for (let x = 0; x < W; x++) put(buf, x, y, skyAt(x, y));
    for (const st of stars) if (Math.sin(T * 1.3 + st.p) > 0.2) buf[st.y * W + st.x] = solid("#e9e6ff");
    for (let y = SUN.y - SUN.r; y <= SUN.y + SUN.r; y++) for (let x = SUN.x - SUN.r; x <= SUN.x + SUN.r; x++) {
      const d = Math.hypot(x - SUN.x, y - SUN.y);
      if (d <= SUN.r) buf[y * W + x] = solid(d < SUN.r - 2.5 ? "#fffbe8" : "#ffe6a8");
    }
    for (let x = 0; x < W; x++) {
      for (let y = Math.ceil(far[x]); y < HORIZON; y++) put(buf, x, y, mix(skyAt(x, y), hex("#8e86b4"), 0.55));
      for (let y = Math.ceil(big[x]); y < HORIZON; y++) {
        const depth = y - big[x];
        const left = x < big.length - 1 && big[x + 1] < big[x];
        const snow = depth < 7 + hash(x, y) * 4;
        const lit = (x - SUN.x) * 0 + (left ? 1 : 0);
        put(buf, x, y, snow ? (lit ? hex("#fbe3d6") : hex("#c8c6e6")) : (lit ? hex("#7d6d8c") : hex("#4f4a72")));
      }
      for (let y = Math.ceil(hills[x]); y < HORIZON; y++) put(buf, x, y, hash(x, y) < 0.2 ? hex("#26363d") : hex("#2d4046"));
    }
    for (const b of birds) {
      const bx = Math.round((b.x + T * b.s) % (W + 20)) - 10, by = Math.round(b.y + Math.sin(T * 2 + b.x) * 1.2);
      const wing = Math.sin(T * 7 + b.x) > 0 ? -1 : 0;
      for (const [dx, dy] of [[-2, wing], [-1, 0], [0, 1], [1, 0], [2, wing]]) if (inside(bx + dx, by + dy)) buf[(by + dy) * W + bx + dx] = solid("#3a3554");
    }
    for (let y = HORIZON; y < H; y++) {
      const r = y - HORIZON;
      for (let x = 0; x < W; x++) {
        const wx = Math.max(0, Math.min(W - 1, Math.round(x + Math.sin(r * 0.8 + T * 1.6) * (0.4 + r * 0.035))));
        const my = HORIZON - 1 - Math.floor(r * 1.25);
        let c: RGB = my >= 0 ? skyAt(wx, my) : hex("#2b3a67");
        if (my >= 0 && my >= hills[wx]) c = hex("#22323a");
        else if (my >= 0 && my >= big[wx]) c = my - big[wx] < 7 ? hex("#b9b4d6") : hex("#48436a");
        else if (my >= 0 && my >= far[wx]) c = mix(c, hex("#8e86b4"), 0.5);
        put(buf, x, y, mix(c, hex("#1d2a45"), 0.3 + r * 0.008));
      }
      const half = Math.max(1, (9 - r * 0.18) * (0.55 + 0.45 * Math.sin(r * 1.2 + T * 2.9)));
      const cx = SUN.x + Math.sin(r * 0.6 + T * 2) * (1 + r * 0.05);
      if ((r + Math.floor(T * 5)) % 3 === 2 && r > 2) continue;
      for (let x = Math.round(cx - half); x <= cx + half; x++) {
        if (x < 0 || x >= W) continue;
        buf[y * W + x] = solid(Math.abs(x - cx) > half * 0.6 ? "#f4c48e" : r < 8 || hash(x, y + Math.floor(T * 4)) > 0.7 ? "#fff6d2" : "#ffe1a0");
      }
    }
    for (let i = 0; i < buf.length; i++) if (layer[i]) buf[i] = layer[i];
  }
  return { build, frame };
})();

const SCENES: Record<PixelSceneKind, Scene> = { sakura, forest, alpine };

export function PixelScene({ scene }: { scene: PixelSceneKind }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const cv = ref.current!;
    const g = cv.getContext("2d")!;
    const img = g.createImageData(W, H);
    const buf = new Uint32Array(img.data.buffer);
    const s = SCENES[scene], layer = s.build();
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    let raf = 0, drawnAt = 0, visible = true;
    const start = performance.now();
    const draw = (now: number) => { s.frame(buf, layer, (now - start) / 1000); g.putImageData(img, 0, 0); };
    const loop = (now: number) => {
      raf = 0;
      const cap = animFps();
      if (cap === 0 || !visible) return;
      const due = paceFrame(now, drawnAt, Math.min(cap ?? 12, 12));
      if (due !== null) { drawnAt = due; draw(now); }
      raf = requestAnimationFrame(loop);
    };
    const restart = () => { if (!raf && !still) raf = requestAnimationFrame(loop); };
    draw(start);
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; if (visible) restart(); });
    io.observe(cv);
    const off = onAnimBudget(restart);
    restart();
    return () => { cancelAnimationFrame(raf); io.disconnect(); off(); };
  }, [scene]);
  return <canvas ref={ref} width={W} height={H} className="pixel-scene" aria-hidden="true" />;
}
