// The figures that stand on top of the cube. Each one is built from simple solid pieces (spheres, cylinders,
// cones, boxes, rings), so a new figure is a list of pieces with their place, turn, size and color. They are
// drawn as real objects: faces turned to the light are brighter, hidden faces are skipped and the nearest go last.

export type V3 = [number, number, number];

interface Piece {
  /** sphere (half: only its top), cylinder (top: radius of its top, 0 is a cone), box, ring (tube: its thickness). */
  k: "sphere" | "cyl" | "box" | "ring";
  /** A color, or "$" for the machine's color. */
  c: string;
  p?: V3;
  /** Turn in radians, written [x, z, y] and applied in that order. */
  r?: V3;
  s?: V3 | number;
  top?: number;
  tube?: number;
  half?: boolean;
}

export interface FigureDef {
  id: string;
  name: string;
  /** Its height at size 1, in its own units (used to pick it with the mouse). */
  height: number;
  pieces: () => Piece[];
}

interface Face { pts: V3[]; n: V3; c: string }

const lift = (y: number, list: Piece[]) => list.map((p) => ({ ...p, p: [p.p?.[0] ?? 0, (p.p?.[1] ?? 0) + y, p.p?.[2] ?? 0] as V3 }));

export const FIGURES: FigureDef[] = [
  {
    id: "lucky-cat", name: "Gato de la suerte", height: 1.0,
    pieces: () => {
      const white = "#f4efe6", orange = "#e8994a", pink = "#f39aa6", gold = "#e9b949";
      return [
        { k: "box", c: "#c8443c", p: [0, 0.04, 0], s: [0.86, 0.08, 0.76] },
        { k: "box", c: "#e0b04a", p: [0, 0.084, 0], s: [0.88, 0.012, 0.78] },
        ...[[1, 1], [1, -1], [-1, 1], [-1, -1]].map(([a, b]) => ({ k: "sphere", c: gold, p: [a * 0.43, 0.05, b * 0.38], s: 0.035 }) as Piece),
        ...lift(0.06, [
          { k: "sphere", c: white, p: [0, 0.32, 0], s: [0.34, 0.3, 0.28] },
          { k: "sphere", c: "#3a3633", p: [-0.2, 0.36, -0.08], s: [0.16, 0.14, 0.18] },
          { k: "sphere", c: orange, p: [0.12, 0.42, -0.16], s: [0.16, 0.13, 0.14] },
          { k: "sphere", c: orange, p: [0.2, 0.12, -0.2], s: [0.13, 0.06, 0.09] },
          { k: "ring", c: "#d0392f", p: [0, 0.52, 0.01], s: [0.23, 0.23, 0.21], tube: 0.16 },
          { k: "sphere", c: gold, p: [0, 0.47, 0.235], s: 0.052 },
          { k: "box", c: "#8a6a1f", p: [0, 0.455, 0.284], s: [0.05, 0.008, 0.01] },
          { k: "sphere", c: white, p: [0, 0.74, 0.02], s: [0.3, 0.26, 0.27] },
          { k: "sphere", c: orange, p: [0.2, 0.85, 0], s: [0.13, 0.11, 0.17] },
          { k: "cyl", c: white, p: [-0.16, 0.88, 0.02], s: [0.09, 0.17, 0.08], top: 0, r: [0, 0.3, 0] },
          { k: "cyl", c: orange, p: [0.16, 0.88, 0.02], s: [0.09, 0.17, 0.08], top: 0, r: [0, -0.3, 0] },
          { k: "cyl", c: pink, p: [-0.155, 0.9, 0.07], s: [0.05, 0.12, 0.02], top: 0, r: [0, 0.3, 0] },
          { k: "cyl", c: pink, p: [0.155, 0.9, 0.07], s: [0.05, 0.12, 0.02], top: 0, r: [0, -0.3, 0] },
          { k: "sphere", c: "#2b2724", p: [-0.1, 0.76, 0.27], s: [0.04, 0.05, 0.025] },
          { k: "sphere", c: "#2b2724", p: [0.1, 0.76, 0.27], s: [0.04, 0.05, 0.025] },
          { k: "sphere", c: "#ffffff", p: [-0.112, 0.776, 0.292], s: 0.012 },
          { k: "sphere", c: "#ffffff", p: [0.088, 0.776, 0.292], s: 0.012 },
          { k: "sphere", c: "#fbf8f2", p: [0, 0.66, 0.2], s: [0.12, 0.07, 0.08] },
          { k: "sphere", c: pink, p: [0, 0.69, 0.285], s: [0.03, 0.02, 0.015] },
          { k: "cyl", c: white, p: [0.22, 0.42, 0.1], s: [0.075, 0.34, 0.075], r: [0, -0.3, 0] },
          { k: "sphere", c: white, p: [0.32, 0.78, 0.1], s: [0.095, 0.095, 0.085] },
          { k: "sphere", c: pink, p: [0.32, 0.78, 0.18], s: [0.045, 0.045, 0.012] },
          { k: "sphere", c: white, p: [-0.12, 0.14, 0.24], s: [0.09, 0.07, 0.09] },
          { k: "cyl", c: gold, p: [0.05, 0.24, 0.22], s: [0.14, 0.03, 0.11], r: [Math.PI / 2, 0, 0] },
          { k: "cyl", c: "#f6d474", p: [0.05, 0.24, 0.235], s: [0.1, 0.03, 0.08], r: [Math.PI / 2, 0, 0] },
        ]),
      ];
    },
  },
  {
    id: "succulent", name: "Planta", height: 0.62,
    pieces: () => {
      const leaves: Piece[] = [];
      const rings = [
        { n: 9, r: 0.17, t: 0.28, len: 0.19, w: 0.085, c: "#6ea888", y: 0.4 },
        { n: 7, r: 0.11, t: 0.62, len: 0.16, w: 0.075, c: "#86bf9a", y: 0.43 },
        { n: 5, r: 0.055, t: 1.0, len: 0.12, w: 0.06, c: "#a6d4b0", y: 0.46 },
      ];
      rings.forEach((g, gi) => {
        for (let i = 0; i < g.n; i++) {
          const a = (i / g.n) * Math.PI * 2 + gi * 0.5, dx = Math.sin(a), dz = Math.cos(a);
          const h = g.len * Math.cos(g.t), v = g.len * Math.sin(g.t);
          leaves.push({ k: "sphere", c: g.c, p: [dx * (g.r + h * 0.5), g.y + v * 0.5, dz * (g.r + h * 0.5)], s: [g.w, 0.035, g.len * 0.62], r: [-g.t, 0, a] });
          leaves.push({ k: "sphere", c: "#d98896", p: [dx * (g.r + h * 1.08), g.y + v * 1.08, dz * (g.r + h * 1.08)], s: 0.018 });
        }
      });
      return [
        { k: "cyl", c: "#c2714a", p: [0, 0, 0], s: [0.22, 0.32, 0.22], top: 1.3 },
        { k: "cyl", c: "#d27f56", p: [0, 0.29, 0], s: [0.31, 0.08, 0.31] },
        { k: "cyl", c: "#5a3d2b", p: [0, 0.37, 0], s: [0.28, 0.012, 0.28] },
        ...[[0.2, 0.05], [-0.18, 0.12], [0.06, -0.21], [-0.1, -0.17]].map(([x, z]) => ({ k: "sphere", c: "#cfc7ba", p: [x, 0.385, z], s: [0.03, 0.018, 0.026] }) as Piece),
        ...leaves,
        { k: "sphere", c: "#bfe3c4", p: [0, 0.5, 0], s: [0.045, 0.06, 0.045] },
      ];
    },
  },
  {
    id: "duck", name: "Patito", height: 0.86,
    pieces: () => {
      const y = "#ffd23f", wing = "#f5c22e", beak = "#ff8c2b";
      return [
        { k: "sphere", c: y, p: [0, 0.25, -0.02], s: [0.32, 0.23, 0.4] },
        { k: "sphere", c: y, p: [0, 0.24, 0.2], s: [0.25, 0.2, 0.2] },
        { k: "cyl", c: y, p: [0, 0.3, -0.34], s: [0.1, 0.2, 0.07], top: 0, r: [-0.85, 0, 0] },
        { k: "sphere", c: wing, p: [0.29, 0.29, -0.04], s: [0.06, 0.13, 0.21], r: [0.25, 0, -0.15] },
        { k: "sphere", c: wing, p: [-0.29, 0.29, -0.04], s: [0.06, 0.13, 0.21], r: [0.25, 0, 0.15] },
        { k: "sphere", c: y, p: [0, 0.6, 0.18], s: [0.21, 0.2, 0.2] },
        { k: "cyl", c: y, p: [0, 0.77, 0.16], s: [0.03, 0.09, 0.03], top: 0, r: [-0.35, 0, 0] },
        { k: "sphere", c: beak, p: [0, 0.575, 0.38], s: [0.1, 0.035, 0.1] },
        { k: "sphere", c: "#ea7418", p: [0, 0.545, 0.36], s: [0.08, 0.025, 0.08] },
        { k: "sphere", c: "#2a2420", p: [0.085, 0.645, 0.335], s: [0.03, 0.042, 0.022] },
        { k: "sphere", c: "#2a2420", p: [-0.085, 0.645, 0.335], s: [0.03, 0.042, 0.022] },
        { k: "sphere", c: "#ffffff", p: [0.076, 0.66, 0.352], s: 0.01 },
        { k: "sphere", c: "#ffffff", p: [-0.094, 0.66, 0.352], s: 0.01 },
        { k: "sphere", c: "#ffad7a", p: [0.13, 0.57, 0.3], s: [0.035, 0.022, 0.02] },
        { k: "sphere", c: "#ffad7a", p: [-0.13, 0.57, 0.3], s: [0.035, 0.022, 0.02] },
      ];
    },
  },
  {
    id: "robot", name: "Robot", height: 1.12,
    pieces: () => {
      const shell = "#e3e6eb", joint = "#9aa0a8", dark = "#2a3140";
      const side = (s: number): Piece[] => [
        { k: "box", c: "#8c939e", p: [s * 0.12, 0.035, 0.03], s: [0.15, 0.07, 0.24] },
        { k: "cyl", c: joint, p: [s * 0.12, 0.07, 0], s: [0.05, 0.17, 0.05] },
        { k: "sphere", c: joint, p: [s * 0.26, 0.56, 0], s: 0.065 },
        { k: "cyl", c: "#c9ced5", p: [s * 0.27, 0.56, 0], s: [0.045, 0.24, 0.045], r: [0, Math.PI + s * 0.12, 0] },
        { k: "sphere", c: joint, p: [s * 0.3, 0.3, 0], s: [0.06, 0.06, 0.06] },
        { k: "cyl", c: joint, p: [s * 0.23, 0.79, 0], s: [0.05, 0.04, 0.05], r: [0, -s * Math.PI / 2, 0] },
      ];
      return [
        ...side(1), ...side(-1),
        { k: "box", c: shell, p: [0, 0.42, 0], s: [0.42, 0.36, 0.3] },
        { k: "box", c: dark, p: [0, 0.45, 0.152], s: [0.26, 0.18, 0.01] },
        { k: "sphere", c: "$", p: [-0.07, 0.49, 0.16], s: [0.022, 0.022, 0.008] },
        { k: "sphere", c: "#ff6b6b", p: [0, 0.49, 0.16], s: [0.022, 0.022, 0.008] },
        { k: "sphere", c: "#7bd88f", p: [0.07, 0.49, 0.16], s: [0.022, 0.022, 0.008] },
        { k: "box", c: "$", p: [0, 0.41, 0.159], s: [0.16, 0.022, 0.006] },
        { k: "cyl", c: joint, p: [0, 0.6, 0], s: [0.07, 0.05, 0.07] },
        { k: "box", c: shell, p: [0, 0.79, 0], s: [0.44, 0.3, 0.34] },
        { k: "box", c: dark, p: [0, 0.8, 0.172], s: [0.34, 0.14, 0.01] },
        { k: "sphere", c: "$", p: [-0.08, 0.8, 0.178], s: [0.042, 0.042, 0.01] },
        { k: "sphere", c: "$", p: [0.08, 0.8, 0.178], s: [0.042, 0.042, 0.01] },
        { k: "box", c: "#c9ced5", p: [0, 0.935, 0], s: [0.3, 0.012, 0.24] },
        { k: "cyl", c: joint, p: [0, 0.94, 0], s: [0.012, 0.13, 0.012] },
        { k: "sphere", c: "#ff6b6b", p: [0, 1.08, 0], s: 0.036 },
      ];
    },
  },
  {
    id: "cactus", name: "Cactus", height: 0.9,
    pieces: () => {
      const green = "#5f9e6e", rib = "#4b8559";
      const arm = (s: number, y: number, out: number, up: number): Piece[] => [
        { k: "cyl", c: green, p: [s * 0.08, y, 0], s: [0.06, out, 0.06], r: [0, -s * Math.PI / 2, 0] },
        { k: "sphere", c: green, p: [s * (0.08 + out), y, 0], s: 0.06 },
        { k: "cyl", c: green, p: [s * (0.08 + out), y, 0], s: [0.06, up, 0.06] },
        { k: "sphere", c: green, p: [s * (0.08 + out), y + up, 0], s: 0.06 },
      ];
      return [
        { k: "cyl", c: "#ece6da", p: [0, 0, 0], s: [0.19, 0.24, 0.19], top: 1.2 },
        { k: "cyl", c: "$", p: [0, 0.16, 0], s: [0.215, 0.035, 0.215] },
        { k: "cyl", c: "#5a3d2b", p: [0, 0.235, 0], s: [0.22, 0.01, 0.22] },
        { k: "cyl", c: green, p: [0, 0.24, 0], s: [0.105, 0.46, 0.105] },
        { k: "sphere", c: green, p: [0, 0.7, 0], s: [0.105, 0.08, 0.105] },
        ...Array.from({ length: 8 }, (_, i) => { const a = (i / 8) * Math.PI * 2; return { k: "cyl", c: rib, p: [Math.sin(a) * 0.1, 0.25, Math.cos(a) * 0.1], s: [0.014, 0.44, 0.014] } as Piece; }),
        ...arm(1, 0.42, 0.11, 0.17), ...arm(-1, 0.36, 0.09, 0.12),
        ...Array.from({ length: 6 }, (_, i) => { const a = (i / 6) * Math.PI * 2; return { k: "sphere", c: "#f28cb1", p: [Math.sin(a) * 0.035, 0.785, Math.cos(a) * 0.035], s: [0.03, 0.018, 0.03] } as Piece; }),
        { k: "sphere", c: "#ffd34d", p: [0, 0.795, 0], s: 0.018 },
      ];
    },
  },
  {
    id: "mushroom", name: "Hongos", height: 0.66,
    pieces: () => {
      const one = (x: number, z: number, k: number): Piece[] => {
        const P = (a: number, b: number, c: number): V3 => [x + a * k, b * k, z + c * k];
        const spots = [[0, 0.95], [0.9, 0.55], [2.2, 0.6], [3.5, 0.5], [4.7, 0.62], [1.6, 0.25], [4.0, 0.22]];
        return [
          { k: "cyl", c: "#efe3cc", p: P(0, 0, 0), s: [0.11 * k, 0.4 * k, 0.11 * k], top: 0.75 },
          { k: "cyl", c: "#e2cfae", p: P(0, 0.38, 0), s: [0.33 * k, 0.025 * k, 0.33 * k] },
          { k: "sphere", c: "#d9473f", p: P(0, 0.4, 0), s: [0.36 * k, 0.24 * k, 0.36 * k], half: true },
          ...spots.map(([a, f]) => { const sf = Math.sin(f * Math.PI / 2), cf = Math.cos(f * Math.PI / 2); return { k: "sphere", c: "#fbf6ec", p: P(Math.cos(a) * sf * 0.35, 0.4 + cf * 0.235, Math.sin(a) * sf * 0.35), s: 0.045 * k } as Piece; }),
        ];
      };
      return [
        ...one(-0.06, -0.04, 1), ...one(0.27, 0.15, 0.55),
        ...[[-0.25, 0.2], [0.05, 0.3], [0.33, -0.12], [-0.3, -0.18]].map(([x, z], i) => ({ k: "cyl", c: "#6faa5e", p: [x, 0, z], s: [0.025, 0.09 + (i % 2) * 0.04, 0.025], top: 0, r: [0.25, 0, i] }) as Piece),
      ];
    },
  },
];

const rot = (v: V3, r: V3 = [0, 0, 0]): V3 => {
  let [x, y, z] = v;
  const [ax, az, ay] = [r[0], r[1], r[2]];
  // Around x, then z, then y.
  if (ax) { const c = Math.cos(ax), s = Math.sin(ax); [y, z] = [y * c - z * s, y * s + z * c]; }
  if (az) { const c = Math.cos(az), s = Math.sin(az); [x, y] = [x * c - y * s, x * s + y * c]; }
  if (ay) { const c = Math.cos(ay), s = Math.sin(ay); [x, z] = [x * c + z * s, -x * s + z * c]; }
  return [x, y, z];
};
const norm = (v: V3): V3 => { const l = Math.hypot(...v) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };

/** A piece's faces: points in place and the normal of each face (taken from the piece's own shape, so it never
 *  depends on the order of the points). */
function piece(p: Piece): Face[] {
  const S: V3 = typeof p.s === "number" ? [p.s, p.s, p.s] : p.s ?? [1, 1, 1];
  const at = p.p ?? [0, 0, 0];
  const faces: Face[] = [];
  const add = (local: V3[], ln: V3) => {
    const pts = local.map((v) => { const r = rot([v[0] * S[0], v[1] * S[1], v[2] * S[2]], p.r); return [r[0] + at[0], r[1] + at[1], r[2] + at[2]] as V3; });
    faces.push({ pts, n: norm(rot(norm([ln[0] / S[0], ln[1] / S[1], ln[2] / S[2]]), p.r)), c: p.c });
  };
  const mid = (pts: V3[]): V3 => pts.reduce<V3>((a, q) => [a[0] + q[0] / pts.length, a[1] + q[1] / pts.length, a[2] + q[2] / pts.length], [0, 0, 0]);
  if (p.k === "sphere") {
    const n = 26, m = p.half ? 8 : 16;
    const pt = (i: number, j: number): V3 => { const t = (j / 16) * Math.PI, a = (i / n) * Math.PI * 2; return [Math.sin(t) * Math.cos(a), Math.cos(t), Math.sin(t) * Math.sin(a)]; };
    for (let j = 0; j < m; j++) for (let i = 0; i < n; i++) {
      const q = [pt(i, j), pt(i + 1, j), pt(i + 1, j + 1), pt(i, j + 1)];
      add(q, mid(q));
    }
  } else if (p.k === "cyl") {
    const n = 24, top = p.top ?? 1;
    const ring = (y: number, r: number) => Array.from({ length: n }, (_, i) => { const a = (i / n) * Math.PI * 2; return [Math.cos(a) * r, y, Math.sin(a) * r] as V3; });
    const b = ring(0, 1), t = ring(1, top);
    for (let i = 0; i < n; i++) {
      const j = (i + 1) % n, q = top > 0 ? [b[i], b[j], t[j], t[i]] : [b[i], b[j], t[0]];
      const c = mid(q);
      // The side's normal points out from the axis, tilted by the taper.
      add(q, [c[0], (1 - top) * 0.5 * Math.hypot(c[0], c[2]), c[2]]);
    }
    add(b, [0, -1, 0]);
    if (top > 0) add(t, [0, 1, 0]);
  } else if (p.k === "box") {
    const h = 0.5;
    for (const ax of [0, 1, 2]) for (const sd of [-1, 1]) {
      const u = (ax + 1) % 3, w = (ax + 2) % 3;
      const q = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([a, b]) => { const v: V3 = [0, 0, 0]; v[ax] = sd * h; v[u] = a * h; v[w] = b * h; return v; });
      const ln: V3 = [0, 0, 0]; ln[ax] = sd;
      add(q, ln);
    }
  } else {
    const n = 22, m = 8, tube = p.tube ?? 0.2;
    const pt = (i: number, j: number): V3 => { const a = (i / n) * Math.PI * 2, b = (j / m) * Math.PI * 2, r = 1 + Math.cos(b) * tube; return [Math.cos(a) * r, Math.sin(b) * tube, Math.sin(a) * r]; };
    for (let i = 0; i < n; i++) for (let j = 0; j < m; j++) {
      const q = [pt(i, j), pt(i + 1, j), pt(i + 1, j + 1), pt(i, j + 1)], c = mid(q), a = Math.atan2(c[2], c[0]);
      add(q, [c[0] - Math.cos(a), c[1], c[2] - Math.sin(a)]);
    }
  }
  return faces;
}

const meshes = new Map<string, Face[]>();
export function figureMesh(id: string): Face[] {
  const hit = meshes.get(id);
  if (hit) return hit;
  const def = FIGURES.find((f) => f.id === id);
  const faces = def ? def.pieces().flatMap(piece) : [];
  meshes.set(id, faces);
  return faces;
}

const rgb = (hex: string) => { const h = hex.replace("#", ""); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); };
const LIGHT = norm([-0.45, 0.75, 0.55]);

export interface FigureView {
  /** World point to screen: x, y and depth (bigger is nearer). */
  project: (p: V3) => V3;
  /** A world direction in view space: x right, y up, z toward the viewer. */
  toView: (n: V3) => V3;
}

/** Draws a figure standing at `at`, turned `turn` radians and scaled by `scale`. `holo` draws it as a hologram in
 *  `color` instead of its own colors. */
export function drawFigure(g: CanvasRenderingContext2D, id: string, at: V3, turn: number, scale: number, view: FigureView, color: string, holo = false, alpha = 1) {
  const c = Math.cos(turn), s = Math.sin(turn);
  const list: { pts: [number, number][]; d: number; fill: string }[] = [];
  const machine = rgb(color);
  for (const f of figureMesh(id)) {
    const n: V3 = [f.n[0] * c + f.n[2] * s, f.n[1], -f.n[0] * s + f.n[2] * c];
    const vn = view.toView(n);
    if (vn[2] <= 0.0001) continue;
    let d = 0;
    const pts = f.pts.map((v) => {
      const w = view.project([at[0] + (v[0] * c + v[2] * s) * scale, at[1] + v[1] * scale, at[2] + (-v[0] * s + v[2] * c) * scale]);
      d += w[2];
      return [w[0], w[1]] as [number, number];
    });
    const lit = Math.max(0, vn[0] * LIGHT[0] + vn[1] * LIGHT[1] + vn[2] * LIGHT[2]);
    const k = 0.5 + 0.55 * lit;
    const base = f.c === "$" ? machine : rgb(f.c);
    let fill: string;
    if (holo) fill = `rgba(${machine.join(",")},${((0.12 + 0.38 * lit) * alpha).toFixed(3)})`;
    else {
      const mix = base.map((v) => Math.round(k <= 1 ? v * k : v + (255 - v) * (k - 1)));
      fill = `rgba(${mix.join(",")},${alpha})`;
    }
    list.push({ pts, d: d / pts.length, fill });
  }
  list.sort((a, b) => a.d - b.d);
  g.lineJoin = "round";
  for (const f of list) {
    g.beginPath();
    f.pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
    g.closePath();
    g.fillStyle = f.fill; g.fill();
    // The same color around each face closes the hairline gaps between neighbors.
    g.strokeStyle = f.fill; g.lineWidth = holo ? 0.4 : 0.6; g.stroke();
  }
}

/** A simple turntable view for thumbnails: the figure fills a `size` px square seen a little from above. */
export function thumbView(size: number, height: number, yaw: number, pitch = 0.42): FigureView {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch), k = (size * 0.62) / Math.max(0.6, height);
  const toView = (n: V3): V3 => { const x1 = n[0] * cy - n[2] * sy, z1 = n[0] * sy + n[2] * cy; return [x1, n[1] * cp - z1 * sp, n[1] * sp + z1 * cp]; };
  return {
    toView,
    project: (p) => { const v = toView([p[0], p[1] - height / 2, p[2]]); return [size / 2 + v[0] * k, size / 2 - v[1] * k + size * 0.04, v[2]]; },
  };
}

export const figureName = (id: string) => FIGURES.find((f) => f.id === id)?.name ?? id;
