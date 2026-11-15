// The figures that stand on top of the cube. Each one is built from simple solid pieces (spheres, cylinders and
// cones, rounded boxes, rings and arcs), so a new figure is a list of pieces with their place, turn, size and
// color. figureGL.ts turns them into smooth meshes and draws them on the GPU.

export type V3 = [number, number, number];

export interface Piece {
  /** sphere (half: only its top), cyl (top: radius of its top, 0 is a cone), box (round: radius of its edges),
   *  ring (tube: its thickness; arc: how much of the ring, in radians). */
  k: "sphere" | "cyl" | "box" | "ring";
  /** A color, or "$" for the machine's color. */
  c: string;
  p?: V3;
  /** Turn in radians, written [x, z, y] and applied in that order. */
  r?: V3;
  s?: V3 | number;
  top?: number;
  tube?: number;
  arc?: number;
  half?: boolean;
  round?: number;
}

export interface FigureDef {
  id: string;
  name: string;
  /** Its height at size 1, in its own units (used to pick it with the mouse and frame its thumbnail). */
  height: number;
  pieces: () => Piece[];
}

const lift = (y: number, list: Piece[]) => list.map((p) => ({ ...p, p: [p.p?.[0] ?? 0, (p.p?.[1] ?? 0) + y, p.p?.[2] ?? 0] as V3 }));
const mirror = (list: Piece[]) => [...list, ...list.map((p) => ({ ...p, p: [-(p.p?.[0] ?? 0), p.p?.[1] ?? 0, p.p?.[2] ?? 0] as V3, r: p.r ? [p.r[0], -p.r[1], -p.r[2]] as V3 : undefined }))];
const INK = "#2a2522";

export const FIGURES: FigureDef[] = [
  {
    id: "lucky-cat", name: "Gato de la suerte", height: 1.02,
    pieces: () => {
      const white = "#f6f1e8", orange = "#e8994a", pink = "#f2a0ab", gold = "#e9b949", red = "#cc3d36";
      return [
        { k: "box", c: red, p: [0, 0.045, 0], s: [0.86, 0.09, 0.76], round: 0.035 },
        { k: "box", c: "#e2b24c", p: [0, 0.092, 0], s: [0.8, 0.012, 0.7], round: 0.006 },
        ...[[1, 1], [1, -1], [-1, 1], [-1, -1]].map(([a, b]) => ({ k: "sphere", c: gold, p: [a * 0.42, 0.05, b * 0.37], s: 0.04 }) as Piece),
        ...lift(0.07, [
          { k: "sphere", c: white, p: [0, 0.31, 0], s: [0.33, 0.3, 0.28] },
          { k: "sphere", c: "#3b3632", p: [-0.19, 0.38, -0.08], s: [0.16, 0.14, 0.18] },
          { k: "sphere", c: orange, p: [0.12, 0.42, -0.16], s: [0.16, 0.13, 0.14] },
          { k: "sphere", c: orange, p: [0.17, 0.08, -0.22], s: [0.14, 0.06, 0.1] },
          { k: "ring", c: red, p: [0, 0.52, 0.01], s: [0.235, 0.235, 0.215], tube: 0.15 },
          { k: "sphere", c: gold, p: [0, 0.46, 0.235], s: 0.055 },
          { k: "box", c: "#8a6a1f", p: [0, 0.445, 0.288], s: [0.05, 0.008, 0.01] },
          { k: "sphere", c: white, p: [0, 0.75, 0.02], s: [0.3, 0.26, 0.27] },
          { k: "sphere", c: orange, p: [0.19, 0.86, 0], s: [0.13, 0.11, 0.17] },
          { k: "cyl", c: white, p: [-0.16, 0.89, 0.02], s: [0.09, 0.17, 0.08], top: 0, r: [0, 0.3, 0] },
          { k: "cyl", c: orange, p: [0.16, 0.89, 0.02], s: [0.09, 0.17, 0.08], top: 0, r: [0, -0.3, 0] },
          { k: "cyl", c: pink, p: [-0.155, 0.91, 0.07], s: [0.05, 0.12, 0.02], top: 0, r: [0, 0.3, 0] },
          { k: "cyl", c: pink, p: [0.155, 0.91, 0.07], s: [0.05, 0.12, 0.02], top: 0, r: [0, -0.3, 0] },
          // Happy closed eyes, a little mouth and blush, like the classic figure.
          { k: "ring", c: INK, p: [-0.1, 0.765, 0.262], s: [0.045, 0.045, 0.045], tube: 0.22, arc: Math.PI, r: [-Math.PI / 2, 0, 0] },
          { k: "ring", c: INK, p: [0.1, 0.765, 0.262], s: [0.045, 0.045, 0.045], tube: 0.22, arc: Math.PI, r: [-Math.PI / 2, 0, 0] },
          { k: "sphere", c: "#fbf8f2", p: [0, 0.67, 0.2], s: [0.12, 0.07, 0.085] },
          { k: "sphere", c: pink, p: [0, 0.7, 0.285], s: [0.03, 0.02, 0.016] },
          { k: "ring", c: INK, p: [-0.022, 0.672, 0.28], s: 0.022, tube: 0.25, arc: Math.PI, r: [Math.PI / 2, 0, 0] },
          { k: "ring", c: INK, p: [0.022, 0.672, 0.28], s: 0.022, tube: 0.25, arc: Math.PI, r: [Math.PI / 2, 0, 0] },
          { k: "sphere", c: "#f5b3b8", p: [-0.17, 0.7, 0.22], s: [0.045, 0.03, 0.02] },
          { k: "sphere", c: "#f5b3b8", p: [0.17, 0.7, 0.22], s: [0.045, 0.03, 0.02] },
          // The raised paw beckoning, the other holding a gold coin.
          { k: "cyl", c: white, p: [0.22, 0.42, 0.1], s: [0.075, 0.34, 0.075], r: [0, -0.3, 0] },
          { k: "sphere", c: white, p: [0.32, 0.78, 0.1], s: [0.095, 0.095, 0.085] },
          { k: "sphere", c: pink, p: [0.32, 0.78, 0.18], s: [0.045, 0.045, 0.012] },
          { k: "sphere", c: white, p: [-0.12, 0.14, 0.24], s: [0.09, 0.07, 0.09] },
          { k: "cyl", c: gold, p: [0.05, 0.24, 0.215], s: [0.14, 0.03, 0.11], r: [Math.PI / 2, 0, 0] },
          { k: "cyl", c: "#f6d474", p: [0.05, 0.24, 0.232], s: [0.1, 0.03, 0.08], r: [Math.PI / 2, 0, 0] },
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
          leaves.push({ k: "sphere", c: "#d98896", p: [dx * (g.r + h * 1.06), g.y + v * 1.06, dz * (g.r + h * 1.06)], s: [0.02, 0.014, 0.02] });
        }
      });
      return [
        { k: "cyl", c: "#c2714a", p: [0, 0, 0], s: [0.22, 0.32, 0.22], top: 1.3 },
        { k: "cyl", c: "#d27f56", p: [0, 0.29, 0], s: [0.31, 0.08, 0.31] },
        { k: "ring", c: "#b8653f", p: [0, 0.29, 0], s: 0.305, tube: 0.03 },
        { k: "cyl", c: "#5a3d2b", p: [0, 0.37, 0], s: [0.28, 0.012, 0.28] },
        ...[[0.2, 0.05], [-0.18, 0.12], [0.06, -0.21], [-0.1, -0.17], [0.15, -0.14]].map(([x, z]) => ({ k: "sphere", c: "#cfc7ba", p: [x, 0.385, z], s: [0.03, 0.018, 0.026] }) as Piece),
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
        ...mirror([{ k: "sphere", c: wing, p: [0.29, 0.29, -0.04], s: [0.06, 0.13, 0.21], r: [0.25, -0.15, 0] }]),
        { k: "sphere", c: y, p: [0, 0.6, 0.18], s: [0.21, 0.2, 0.2] },
        { k: "cyl", c: y, p: [0, 0.77, 0.16], s: [0.03, 0.09, 0.03], top: 0, r: [-0.35, 0, 0] },
        { k: "cyl", c: y, p: [0.02, 0.77, 0.14], s: [0.025, 0.07, 0.025], top: 0, r: [-0.6, -0.4, 0] },
        { k: "sphere", c: beak, p: [0, 0.575, 0.38], s: [0.1, 0.035, 0.1] },
        { k: "sphere", c: "#ea7418", p: [0, 0.545, 0.36], s: [0.08, 0.025, 0.08] },
        ...mirror([
          { k: "sphere", c: INK, p: [0.085, 0.645, 0.335], s: [0.03, 0.042, 0.022] },
          { k: "sphere", c: "#ffffff", p: [0.076, 0.66, 0.352], s: 0.01 },
          { k: "sphere", c: "#ffad7a", p: [0.13, 0.57, 0.3], s: [0.035, 0.022, 0.02] },
        ]),
      ];
    },
  },
  {
    id: "robot", name: "Robot", height: 1.12,
    pieces: () => {
      const shell = "#e3e6eb", joint = "#9aa0a8", dark = "#2c3442";
      return [
        ...mirror([
          { k: "box", c: "#8c939e", p: [0.12, 0.035, 0.03], s: [0.15, 0.07, 0.24], round: 0.025 },
          { k: "cyl", c: joint, p: [0.12, 0.07, 0], s: [0.05, 0.17, 0.05] },
          { k: "sphere", c: joint, p: [0.26, 0.56, 0], s: 0.065 },
          { k: "cyl", c: "#c9ced5", p: [0.27, 0.56, 0], s: [0.045, 0.24, 0.045], r: [0, Math.PI + 0.12, 0] },
          { k: "sphere", c: joint, p: [0.3, 0.3, 0], s: 0.06 },
          { k: "cyl", c: joint, p: [0.22, 0.79, 0], s: [0.05, 0.04, 0.05], r: [0, -Math.PI / 2, 0] },
          { k: "sphere", c: "#b8bec6", p: [0.27, 0.79, 0], s: [0.012, 0.03, 0.03] },
          // Screws at the torso's corners.
          { k: "sphere", c: "#b8bec6", p: [0.17, 0.57, 0.152], s: 0.012 },
          { k: "sphere", c: "#b8bec6", p: [0.17, 0.28, 0.152], s: 0.012 },
        ]),
        { k: "box", c: shell, p: [0, 0.42, 0], s: [0.42, 0.36, 0.3], round: 0.05 },
        { k: "box", c: dark, p: [0, 0.45, 0.148], s: [0.26, 0.18, 0.012], round: 0.02 },
        { k: "sphere", c: "$", p: [-0.07, 0.49, 0.156], s: [0.022, 0.022, 0.008] },
        { k: "sphere", c: "#ff6b6b", p: [0, 0.49, 0.156], s: [0.022, 0.022, 0.008] },
        { k: "sphere", c: "#7bd88f", p: [0.07, 0.49, 0.156], s: [0.022, 0.022, 0.008] },
        { k: "box", c: "$", p: [0, 0.41, 0.155], s: [0.16, 0.022, 0.006], round: 0.003 },
        { k: "cyl", c: joint, p: [0, 0.6, 0], s: [0.07, 0.05, 0.07] },
        { k: "box", c: shell, p: [0, 0.79, 0], s: [0.44, 0.3, 0.34], round: 0.06 },
        { k: "box", c: dark, p: [0, 0.81, 0.166], s: [0.34, 0.14, 0.012], round: 0.04 },
        { k: "sphere", c: "$", p: [-0.08, 0.815, 0.172], s: [0.04, 0.04, 0.01] },
        { k: "sphere", c: "$", p: [0.08, 0.815, 0.172], s: [0.04, 0.04, 0.01] },
        ...[-0.05, 0, 0.05].map((x) => ({ k: "box", c: joint, p: [x, 0.7, 0.168], s: [0.03, 0.012, 0.006], round: 0.003 }) as Piece),
        { k: "cyl", c: joint, p: [0, 0.94, 0], s: [0.012, 0.13, 0.012] },
        { k: "sphere", c: "#ff6b6b", p: [0, 1.08, 0], s: 0.036 },
      ];
    },
  },
  {
    id: "gamepad", name: "Control", height: 0.3,
    pieces: () => {
      const body = "#3a3d44", grip = "#34373d", stick = "#25272c", cap = "#4b4f58";
      return lift(0.0, [
        { k: "box", c: body, p: [0, 0.06, 0], s: [0.6, 0.1, 0.26], round: 0.05 },
        ...mirror([
          { k: "sphere", c: grip, p: [0.22, 0.05, 0.11], s: [0.12, 0.075, 0.17], r: [0, 0, 0.35] },
          { k: "box", c: "#4a4e57", p: [0.2, 0.09, -0.12], s: [0.15, 0.05, 0.05], round: 0.02 },
        ]),
        { k: "cyl", c: stick, p: [-0.15, 0.1, -0.02], s: [0.045, 0.03, 0.045] },
        { k: "cyl", c: cap, p: [-0.15, 0.13, -0.02], s: [0.058, 0.02, 0.058] },
        { k: "cyl", c: stick, p: [0.07, 0.1, 0.06], s: [0.045, 0.03, 0.045] },
        { k: "cyl", c: cap, p: [0.07, 0.13, 0.06], s: [0.058, 0.02, 0.058] },
        { k: "box", c: stick, p: [-0.07, 0.112, 0.06], s: [0.075, 0.02, 0.025], round: 0.006 },
        { k: "box", c: stick, p: [-0.07, 0.112, 0.06], s: [0.025, 0.02, 0.075], round: 0.006 },
        ...([[0.17, -0.06, "#ffd34d"], [0.17, 0.02, "#7bd88f"], [0.13, -0.02, "#6aa8ff"], [0.21, -0.02, "#ff6b6b"]] as [number, number, string][])
          .map(([x, z, c]) => ({ k: "sphere", c, p: [x, 0.108, z], s: [0.022, 0.016, 0.022] }) as Piece),
        { k: "sphere", c: "$", p: [0, 0.108, -0.06], s: [0.03, 0.01, 0.03] },
      ]);
    },
  },
  {
    id: "mug", name: "Taza", height: 0.56,
    pieces: () => [
      { k: "cyl", c: "#ece6da", p: [0, 0, 0], s: [0.3, 0.03, 0.3] },
      { k: "ring", c: "#e2dbcd", p: [0, 0.03, 0], s: 0.29, tube: 0.05 },
      { k: "cyl", c: "$", p: [0, 0.03, 0], s: [0.17, 0.42, 0.17], top: 1.06 },
      { k: "ring", c: "$", p: [0, 0.45, 0], s: 0.18, tube: 0.09 },
      { k: "cyl", c: "#5b3a25", p: [0, 0.451, 0], s: [0.168, 0.004, 0.168] },
      { k: "sphere", c: "#d9b48a", p: [0.02, 0.456, 0.02], s: [0.07, 0.006, 0.055] },
      { k: "ring", c: "$", p: [-0.19, 0.25, 0], s: [0.1, 0.1, 0.1], tube: 0.22, arc: Math.PI, r: [Math.PI / 2, -Math.PI / 2, 0] },
    ],
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
      const spines: Piece[] = [];
      for (let i = 0; i < 8; i++) for (let j = 0; j < 5; j++) {
        const a = (i / 8) * Math.PI * 2 + (j % 2) * 0.2;
        spines.push({ k: "sphere", c: "#f4f1e6", p: [Math.sin(a) * 0.113, 0.3 + j * 0.085, Math.cos(a) * 0.113], s: 0.007 });
      }
      return [
        { k: "cyl", c: "#ece6da", p: [0, 0, 0], s: [0.19, 0.24, 0.19], top: 1.2 },
        { k: "cyl", c: "$", p: [0, 0.16, 0], s: [0.215, 0.035, 0.215] },
        { k: "cyl", c: "#5a3d2b", p: [0, 0.235, 0], s: [0.22, 0.01, 0.22] },
        { k: "cyl", c: green, p: [0, 0.24, 0], s: [0.105, 0.46, 0.105] },
        { k: "sphere", c: green, p: [0, 0.7, 0], s: [0.105, 0.08, 0.105] },
        ...Array.from({ length: 8 }, (_, i) => { const a = (i / 8) * Math.PI * 2; return { k: "cyl", c: rib, p: [Math.sin(a) * 0.1, 0.25, Math.cos(a) * 0.1], s: [0.014, 0.44, 0.014] } as Piece; }),
        ...spines,
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
          { k: "ring", c: "#e9dcc2", p: P(0, 0.26, 0), s: 0.1 * k, tube: 0.25 },
          { k: "cyl", c: "#e2cfae", p: P(0, 0.38, 0), s: [0.33 * k, 0.025 * k, 0.33 * k] },
          { k: "sphere", c: "#d9473f", p: P(0, 0.4, 0), s: [0.36 * k, 0.24 * k, 0.36 * k], half: true },
          ...spots.map(([a, f]) => { const sf = Math.sin(f * Math.PI / 2), cf = Math.cos(f * Math.PI / 2); return { k: "sphere", c: "#fbf6ec", p: P(Math.cos(a) * sf * 0.35, 0.4 + cf * 0.235, Math.sin(a) * sf * 0.35), s: [0.05 * k, 0.03 * k, 0.05 * k], r: [0, 0, 0] } as Piece; }),
        ];
      };
      return [
        { k: "sphere", c: "#7cb36a", p: [0.05, 0, 0.05], s: [0.42, 0.04, 0.36], half: true },
        ...one(-0.06, -0.04, 1), ...one(0.27, 0.15, 0.55),
        ...[[-0.25, 0.2], [0.05, 0.3], [0.33, -0.12], [-0.3, -0.18], [0.12, -0.25]].map(([x, z], i) => ({ k: "cyl", c: "#6faa5e", p: [x, 0.02, z], s: [0.025, 0.09 + (i % 2) * 0.04, 0.025], top: 0, r: [0.25, 0, i] }) as Piece),
      ];
    },
  },
];

export const figureName = (id: string) => FIGURES.find((f) => f.id === id)?.name ?? id;
