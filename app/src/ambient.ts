import { IconCircuitResistor, IconCube, IconLego, type Icon } from "@tabler/icons-react";
import { drawFigures, mul3, turnY, viewRot, type FigureDraw } from "./decor/figureGL";
import { t } from "./i18n";
import * as stamps from "./spriteGL";

// Ambients: the place where a space's machines are. Each one is a world drawn behind the cube with the cube's own
// camera, so turning or zooming the cube turns and zooms the world around it. The ground covers everything in view and
// fades into the horizon (never a disc with an edge); what is far (sky, skyline, hills) sits on a panorama that turns
// with it. Each world has a light: its pieces are shaded by where they face, and they (and the machines) cast shadows.
//
// - Placa base: the machines on their own circuit board, with chips, capacitors and connectors, traces where data
//   runs, and the silkscreen printed on it (part names, the space's name, the machine's name by its socket).
// - Bloques: a world of bricks on a green baseplate, with paths, trees, houses and the brick figures of the app.

export type AmbientId = "studio" | "board" | "blocks";

/** The time of day of the world of blocks; "auto" follows the clock. */
export type AmbientTime = "day" | "evening" | "night" | "auto";
type Tod = Exclude<AmbientTime, "auto">;
// Names are getters so they are read in the language shown.
export const AMBIENT_TIMES: { id: AmbientTime; readonly name: string }[] = [
  { id: "day", get name() { return t("Día"); } }, { id: "evening", get name() { return t("Tarde"); } },
  { id: "night", get name() { return t("Noche"); } }, { id: "auto", get name() { return t("Según la hora"); } },
];
/** The time of day for "auto": day from 6:30, evening from 17:00, night from 19:30. */
export function resolveTime(t: AmbientTime = "day"): Tod {
  if (t !== "auto") return t;
  const d = new Date(), h = d.getHours() + d.getMinutes() / 60;
  return h >= 6.5 && h < 17 ? "day" : h >= 17 && h < 19.5 ? "evening" : "night";
}

export interface AmbientInfo { id: AmbientId; readonly name: string; readonly desc: string; icon: Icon; times?: boolean }
export const AMBIENTS: AmbientInfo[] = [
  { id: "board", get name() { return t("Placa base"); }, get desc() { return t("Sobre su propio circuito, con chips, pistas y datos que corren."); }, icon: IconCircuitResistor },
  { id: "blocks", get name() { return t("Bloques"); }, get desc() { return t("Un mundo de bloques, con árboles, casas y figuras, de día, de tarde o de noche."); }, icon: IconLego, times: true },
  { id: "studio", get name() { return t("Estudio"); }, get desc() { return t("El fondo gris de la app, sin escenario."); }, icon: IconCube },
];
export const ambientInfo = (id: string) => AMBIENTS.find((a) => a.id === normalizeAmbient(id)) ?? AMBIENTS[2];
/** Ambients from earlier versions become the closest one that exists now. */
export function normalizeAmbient(id: string | undefined): AmbientId {
  if (id === "board" || id === "blocks" || id === "studio") return id;
  if (id === "ocean" || id === "garden") return "blocks";
  if (id === "stars" || id === "city" || id === "mars" || id === "aurora") return "board";
  return "studio";
}

/** What the cube's camera is doing this frame, and what the world can print or show. */
export interface AmbientView {
  g: CanvasRenderingContext2D;
  W: number; H: number; T: number; dt: number;
  yaw: number; pitch: number;
  /** Pixels per world unit (with the zoom), and where the cube's center (y = 1) is on screen. */
  Sz: number; CX: number; CY: number;
  light: boolean; accent: string; reduced: boolean;
  /** The space's name and the machine in front (printed on the board). */
  space?: string; machine?: string;
  /** The time of day (the world of blocks). */
  time?: AmbientTime;
}

/** Moving parts of an ambient, one per canvas. */
export type AmbientState = Record<string, unknown>;

/** The ground under the machines (the cube's bottom is at 0). */
export const FLOOR = -0.9;
/** How far the horizon is, in cube units. */
const DH = 4.2;
/** Where the light starts to fall off, and where the world is no longer drawn (depth along the view, cube units). */
const NEAR = 3.5, FAR = 13;
/** Where the camera looks at first (behind the cube from the starting angle), to place each scene's best part there. */
const FRONT = -Math.PI / 2 - (Math.PI / 4 + 0.15);
const TAU = Math.PI * 2;
const wrap = (a: number) => a - TAU * Math.floor((a + Math.PI) / TAU);
const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));
const hash = (a: number, b: number) => { const s = Math.sin(a * 127.1 + b * 311.7) * 43758.5453; return s - Math.floor(s); };

type V3 = [number, number, number];
const norm = (v: V3): V3 => { const l = Math.hypot(v[0], v[1], v[2]) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };
const sunDir = (az: number, el: number): V3 => [Math.cos(az) * Math.cos(el), Math.sin(el), Math.sin(az) * Math.cos(el)];

/** Each world's light: where it comes from (toward the light), and the shadows it casts. */
const LIGHTS: Record<Exclude<AmbientId, "studio">, { dir: V3; shadow: string; alpha: number; darkAlpha: number }> = {
  blocks: { dir: norm(sunDir(FRONT + 1.05, 0.82)), shadow: "#1d3a19", alpha: 0.2, darkAlpha: 0.3 },
  board: { dir: norm(sunDir(FRONT + 0.55, 1.12)), shadow: "#000000", alpha: 0.22, darkAlpha: 0.4 },
};
/** The world of blocks through the day: the sun high at noon, low and warm in the evening, the moon at night. */
const BLOCK_LIGHTS: Record<Tod, { dir: V3; alpha: number; darkAlpha: number }> = {
  day: { dir: norm(sunDir(FRONT + 1.05, 0.82)), alpha: 0.2, darkAlpha: 0.3 },
  evening: { dir: norm(sunDir(FRONT + 0.35, 0.36)), alpha: 0.24, darkAlpha: 0.32 },
  night: { dir: norm(sunDir(FRONT - 0.8, 0.95)), alpha: 0.14, darkAlpha: 0.2 },
};
/** The light of an ambient, for the machines' own shadows; null for none. */
export function ambientLight(id: AmbientId, light: boolean, time?: AmbientTime): { dir: V3; color: string; alpha: number } | null {
  if (id === "studio") return null;
  const l = id === "blocks" ? { ...LIGHTS.blocks, ...BLOCK_LIGHTS[resolveTime(time)] } : LIGHTS[id];
  return { dir: l.dir, color: l.shadow, alpha: light ? l.alpha : l.darkAlpha };
}
/** How the time of day colors everything in the world (multiplied over it, the machine included); null at noon. */
export function ambientTint(id: AmbientId, time?: AmbientTime): string | null {
  if (id !== "blocks") return null;
  const t = resolveTime(time);
  return t === "evening" ? "#ffc89a" : t === "night" ? "#4f5f92" : null;
}

// ---------------------------------------------------------------------------------------------------------------
// The camera and drawing helpers.

interface F extends AmbientView { tod: Tod; fog?: string; yNear: number; yFar: number; p: number; cy: number; sy: number; cp: number; sp: number; K: number; Kv: number; hz: number; a: number; st: AmbientState; dpr: number }

function frame(v: AmbientView, alpha: number, st: AmbientState): F {
  // From below, the world keeps a low angle instead of flipping the ground over the sky.
  const p = clamp(Math.atan2(Math.sin(v.pitch), Math.cos(v.pitch)), 0.06, 1.45);
  const cp = Math.cos(p), sp = Math.sin(p), K = DH * v.Sz;
  // No horizon: the ground goes on under the whole view (as an orthographic plane does). Its details fade out as the
  // light falls off with distance, between NEAR and FAR (depths along the view), and nothing is drawn past FAR.
  const yAt = (z1: number) => v.CY - ((FLOOR - 1) * cp - z1 * sp) * v.Sz;
  return { ...v, p, cy: Math.cos(v.yaw), sy: Math.sin(v.yaw), cp, sp, K, Kv: K * 0.75, hz: Math.max(-80, yAt(-FAR)), yNear: yAt(-NEAR), yFar: yAt(-FAR), a: alpha, st, dpr: window.devicePixelRatio || 1, tod: resolveTime(v.time) };
}
/** A world point on screen: x, y and its depth (bigger is nearer). */
function proj(f: F, x: number, y: number, z: number): V3 {
  const x1 = x * f.cy - z * f.sy, z1 = x * f.sy + z * f.cy, yy = y - 1;
  return [f.CX + x1 * f.Sz, f.CY - (yy * f.cp - z1 * f.sp) * f.Sz, yy * f.sp + z1 * f.cp];
}
/** Where the camera looks (azimuth): turning toward the light puts the world against the light. */
const viewAz = (f: F) => -Math.PI / 2 - f.yaw;
const alphaOf = (f: F, a: number) => { f.g.globalAlpha = clamp(f.a * a, 0, 1); };

/** The ground in view, in world units: the box around what the screen shows from its bottom edge to the horizon. */
function groundBox(f: F) {
  const yb = f.H + 40, yt = Math.max(f.hz + 1, -40);
  const un = (sx: number, sy: number): [number, number] => {
    const x1 = (sx - f.CX) / f.Sz, z1 = ((FLOOR - 1) * f.cp - (f.CY - sy) / f.Sz) / f.sp;
    return [x1 * f.cy + z1 * f.sy, -x1 * f.sy + z1 * f.cy];
  };
  const c = [un(-40, yb), un(f.W + 40, yb), un(-40, yt), un(f.W + 40, yt)];
  return { x0: Math.min(...c.map((p) => p[0])), x1: Math.max(...c.map((p) => p[0])), z0: Math.min(...c.map((p) => p[1])), z1: Math.max(...c.map((p) => p[1])) };
}
/** How clear things on the ground are at a screen height: full near the viewer, lost in the haze at the horizon. */
const clear = (f: F, y: number) => clamp((y - f.yFar) / Math.max(1, f.yNear - f.yFar), 0, 1) ** 0.8;

/** Draws on the ground plane as if it were paper lying there: x along the world's x, y along its z. */
function onPlane(f: F, x: number, z: number, rot: number, fn: () => void, y = FLOOR) {
  const o = proj(f, x, y, z), c = Math.cos(rot), s = Math.sin(rot);
  const ex = proj(f, x + c, y, z + s), ez = proj(f, x - s, y, z + c);
  const g = f.g;
  g.save();
  g.transform(ex[0] - o[0], ex[1] - o[1], ez[0] - o[0], ez[1] - o[1], o[0], o[1]);
  fn();
  g.restore();
}

const parsed = new Map<string, number[]>();
const rgbOf = (c: string) => {
  let v = parsed.get(c);
  if (!v) { const h = c.replace("#", ""); v = [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)); parsed.set(c, v); }
  return v;
};
const shadeCache = new Map<string, string>();
/** A color lit by `k` (0 dark, 1 its own color, above 1 brighter), cached. */
function shade(c: string, k: number) {
  const q = Math.round(k * 40) / 40, key = c + q;
  let s = shadeCache.get(key);
  if (!s) {
    const [r, g, b] = rgbOf(c);
    const f = (n: number) => Math.round(clamp(q <= 1 ? n * q : n + (255 - n) * (q - 1), 0, 255)).toString(16).padStart(2, "0");
    s = `#${f(r)}${f(g)}${f(b)}`;
    if (shadeCache.size > 3000) shadeCache.clear();
    shadeCache.set(key, s);
  }
  return s;
}
const mix = (a: string, b: string, t: number) => {
  const x = rgbOf(a), y = rgbOf(b);
  return "#" + x.map((c, i) => Math.round(c + (y[i] - c) * t).toString(16).padStart(2, "0")).join("");
};

/** A solid box lit by the world's light: each face as bright as it faces the light. */
interface Box { x: number; y: number; z: number; w: number; h: number; d: number; color: string; studs?: boolean; rot?: number; round?: boolean; glow?: boolean }
const FACES: [V3, number[]][] = [[[0, 1, 0], [4, 5, 6, 7]], [[1, 0, 0], [1, 2, 6, 5]], [[-1, 0, 0], [0, 3, 7, 4]], [[0, 0, 1], [3, 2, 6, 7]], [[0, 0, -1], [0, 1, 5, 4]]];
function corners(b: Box): V3[] {
  const a = b.w / 2, c = b.d / 2, r = b.rot ?? 0, co = Math.cos(r), si = Math.sin(r), out: V3[] = [];
  for (const [u, v] of [[-a, -c], [a, -c], [a, c], [-a, c]]) out.push([b.x + u * co - v * si, b.y, b.z + u * si + v * co]);
  for (let i = 0; i < 4; i++) out.push([out[i][0], b.y + b.h, out[i][2]]);
  return out;
}
function drawBox(f: F, b: Box, L: V3, fade: number, edge?: string) {
  const g = f.g, c = corners(b), P = c.map((p) => proj(f, ...p)), r = b.rot ?? 0, co = Math.cos(r), si = Math.sin(r);
  // The view direction in world space (from the scene toward the camera).
  const vx = -f.sy * f.cp, vz = f.cy * f.cp, vy = f.sp;
  for (const [n0, idx] of FACES) {
    const n: V3 = n0[1] ? n0 : [n0[0] * co - n0[2] * si, 0, n0[0] * si + n0[2] * co];
    if (n[0] * vx + n[1] * vy + n[2] * vz <= 0) continue;
    const lit = 0.58 + 0.5 * Math.max(0, n[0] * L[0] + n[1] * L[1] + n[2] * L[2]);
    g.beginPath(); idx.forEach((i, k) => (k ? g.lineTo(P[i][0], P[i][1]) : g.moveTo(P[i][0], P[i][1]))); g.closePath();
    // Windows that light up at dusk: their faces are kept to be drawn lit over the evening and night colors.
    if (b.glow && f.tod !== "day") ((f.st._glow ??= []) as number[][]).push(idx.flatMap((i) => [P[i][0], P[i][1]]), [fade]);
    // Far away it melts into the haze by its color, staying solid (never see-through).
    const c = shade(b.color, lit);
    alphaOf(f, f.fog ? 1 : fade); g.fillStyle = f.fog && fade < 0.98 ? mix(c, f.fog, (1 - fade) * 0.9) : c; g.fill();
    if (edge) { alphaOf(f, fade * 0.5); g.strokeStyle = edge; g.lineWidth = 1; g.stroke(); }
  }
}
/** The shadow a set of boxes casts on the ground, away from the light. */
function castShadow(f: F, boxes: Box[], L: V3, color: string, alpha: number, ground = FLOOR) {
  const pts: [number, number][] = [];
  for (const b of boxes) for (const p of corners(b)) {
    const t = (p[1] - ground) / L[1];
    const q = proj(f, p[0] - L[0] * t, ground, p[2] - L[2] * t);
    pts.push([q[0], q[1]]);
  }
  const h = hull(pts);
  if (h.length < 3) return;
  const g = f.g;
  g.beginPath(); h.forEach((p, i) => (i ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1]))); g.closePath();
  alphaOf(f, alpha); g.fillStyle = color; g.fill();
}
function hull(pts: [number, number][]) {
  pts = pts.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cr = (o: number[], a: number[], b: number[]) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lo: [number, number][] = [], up: [number, number][] = [];
  for (const p of pts) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); }
  for (const p of pts.reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); }
  return lo.slice(0, -1).concat(up.slice(0, -1));
}

/** The ground under the whole view: its own color where the machines are, the light falling off with distance. */
function plane(f: F, near: string, far: string) {
  const g = f.g, gr = g.createLinearGradient(0, Math.min(f.yFar, f.yNear - 1), 0, f.yNear);
  gr.addColorStop(0, far); gr.addColorStop(1, near);
  alphaOf(f, 1); g.fillStyle = gr; g.fillRect(0, 0, f.W, f.H);
}

/** Figures of the app standing in the world, drawn on the GPU like the ones on the cube. */
function figures(f: F, list: { id: string; x: number; z: number; rot: number; size: number; y?: number }[], color: string) {
  if (!list.length) return;
  const V = viewRot(f.yaw, f.p);
  const draws: FigureDraw[] = list.map((it) => {
    const y = it.y ?? FLOOR, o = proj(f, it.x, y, it.z), ax = proj(f, it.x + 1, y, it.z), ay = proj(f, it.x, y + 1, it.z), az = proj(f, it.x, y, it.z + 1);
    const A = [ax[0] - o[0], ax[1] - o[1], ax[2] - o[2], ay[0] - o[0], ay[1] - o[1], ay[2] - o[2], az[0] - o[0], az[1] - o[1], az[2] - o[2]] as const;
    return { id: it.id, m: mul3([...A], turnY(it.rot, it.size)), t: o, n: mul3(V, turnY(it.rot)) };
  });
  f.g.globalAlpha = f.a;
  drawFigures(f.g, draws, color, f.W, f.H, f.dpr);
  f.g.globalAlpha = 1;
}

// ---------------------------------------------------------------------------------------------------------------
// Bloques

const STUD = 0.25;
/** A stud seen from above at this zoom and tilt: drawn once, then stamped all over the baseplate. */
function studSprite(f: F, base: string, top: string, rim: string) {
  // Drawn once at a fixed size for the camera's tilt (in coarse steps) and scaled to the zoom when stamped: a sprite
  // rebuilt at every small change of zoom or tilt made the baseplate flicker while the camera moved.
  const R0 = 24, tilt = Math.round(f.sp * 16) / 16, ct = Math.sqrt(Math.max(0, 1 - tilt * tilt));
  const key = `${tilt}|${base}|${f.dpr}`, r = STUD * 0.29 * f.Sz, k = r / R0;
  const st = f.st as { stud?: { key: string; c: HTMLCanvasElement; pad: number; cw: number; ch: number } };
  if (st.stud?.key !== key) {
    const c = document.createElement("canvas"), pad = 2, h = R0 * ct * 0.8, cw = R0 * 2 + pad * 2, ch = R0 * 2 * tilt + h + pad * 2;
    c.width = Math.ceil(cw * f.dpr); c.height = Math.ceil(ch * f.dpr);
    const x = c.getContext("2d")!;
    x.scale(f.dpr, f.dpr);
    const cx = R0 + pad, cyT = pad + R0 * tilt, cyB = cyT + h;
    // Side of the stud, then its top, then a small shine toward the light.
    x.fillStyle = base; x.beginPath(); x.ellipse(cx, cyB, R0, R0 * tilt, 0, 0, TAU); x.fill(); x.fillRect(cx - R0, cyT, R0 * 2, h);
    x.fillStyle = top; x.beginPath(); x.ellipse(cx, cyT, R0, R0 * tilt, 0, 0, TAU); x.fill();
    x.strokeStyle = rim; x.lineWidth = R0 * 0.12; x.beginPath(); x.ellipse(cx, cyT, R0 * 0.98, R0 * tilt * 0.98, 0, Math.PI * 1.05, Math.PI * 1.75); x.stroke();
    st.stud = { key, c, pad, cw, ch };
  }
  const sd = st.stud!;
  // Where to stamp it: its size at this zoom, and how far above the stud's center its top-left corner is.
  return { key, c: sd.c, r, w: sd.cw * k, h: sd.ch * k, up: (sd.pad + R0 * tilt) * k };
}

/** The paths of smooth tiles: a ring around the machines and roads that leave it. */
const onPath = (x: number, z: number) => {
  const r = Math.hypot(x, z);
  return Math.abs(r - 2.05) < 0.3 || (Math.abs(x + z * 0.2) < 0.3 && z > 2.0 && z < 40) || (Math.abs(z - x * 0.15) < 0.3 && x < -2.0 && x > -40);
};
/** A pond of blue plates. */
const onWater = (x: number, z: number) => Math.hypot(x - 3.6, z + 2.6) < 1.05 || Math.hypot(x - 4.4, z + 1.9) < 0.75;

type Thing = { boxes: Box[]; depth: number; fig?: { id: string; x: number; z: number; rot: number; size: number } };

/** What stands on a cell of the world: trees, houses, flowers, rocks or nothing, always the same for that cell. */
function thingAt(i: number, j: number, cell: number): Box[] | null {
  const h = hash(i * 3.7 + 1, j * 5.3 + 2);
  const x = (i + 0.5) * cell + (hash(i, j) - 0.5) * cell * 0.4, z = (j + 0.5) * cell + (hash(j, i) - 0.5) * cell * 0.4;
  const snap = (v: number) => Math.round(v / STUD) * STUD;
  const X = snap(x), Z = snap(z);
  if (Math.hypot(X, Z) < 2.7 || onPath(X, Z) || onWater(X, Z) || onPath(X + 0.5, Z) || onPath(X - 0.5, Z) || onPath(X, Z + 0.5) || onPath(X, Z - 0.5)) return null;
  const B = 0.12, y = FLOOR;
  if (h < 0.3) {
    // A round tree: a trunk and a crown of green bricks, smaller as it goes up.
    const s = 0.8 + hash(i, j * 2) * 0.5, green = ["#5fae4e", "#4f9c45", "#6cb85a"][Math.floor(hash(i * 2, j) * 3)];
    return [
      { x: X, y, z: Z, w: 0.25, h: B * 4 * s, d: 0.25, color: "#8a5a34" },
      { x: X, y: y + B * 4 * s, z: Z, w: 1.0 * s, h: B * 3, d: 1.0 * s, color: green, studs: true },
      { x: X, y: y + B * (4 * s + 3), z: Z, w: 0.75 * s, h: B * 3, d: 0.75 * s, color: shade(green, 1.08), studs: true },
      { x: X, y: y + B * (4 * s + 6), z: Z, w: 0.5 * s, h: B * 2, d: 0.5 * s, color: shade(green, 1.15), studs: true },
    ];
  }
  if (h < 0.42) {
    // A pine: stepped dark green layers.
    const s = 0.9 + hash(j, i * 3) * 0.5;
    return [
      { x: X, y, z: Z, w: 0.25, h: B * 2, d: 0.25, color: "#7a4e2c" },
      { x: X, y: y + B * 2, z: Z, w: 0.9 * s, h: B * 2, d: 0.9 * s, color: "#2f7a45", studs: true },
      { x: X, y: y + B * 4, z: Z, w: 0.65 * s, h: B * 2, d: 0.65 * s, color: "#358a4d", studs: true },
      { x: X, y: y + B * 6, z: Z, w: 0.4 * s, h: B * 3, d: 0.4 * s, color: "#3c9956", studs: true },
    ];
  }
  if (h < 0.5) {
    // A small house: walls, a window band and a two-step roof.
    const wall = ["#efe8da", "#e8d9b8", "#dfe6ea"][Math.floor(hash(i, j * 7) * 3)], roof = ["#cc4f43", "#3f6fb5", "#d9a03a"][Math.floor(hash(i * 5, j) * 3)], r = hash(i * 9, j) < 0.5 ? 0 : Math.PI / 2;
    return [
      { x: X, y, z: Z, w: 1.25, h: B * 5, d: 1.0, color: wall, rot: r },
      { x: X, y: y + B * 2, z: Z, w: 1.27, h: B, d: 1.02, color: "#7da9c9", rot: r, glow: true },
      { x: X, y: y + B * 5, z: Z, w: 1.4, h: B * 1.5, d: 1.15, color: roof, rot: r },
      { x: X, y: y + B * 6.5, z: Z, w: 1.4, h: B * 1.5, d: 0.6, color: shade(roof, 1.08), rot: r, studs: true },
    ];
  }
  if (h < 0.62) {
    // Flowers: round plates on stems in a small patch.
    const out: Box[] = [], cols = ["#f2c14e", "#ee8fbd", "#f6f2ea", "#a796f2", "#f08a84"];
    for (let k = 0; k < 4; k++) {
      const fx = X + (hash(i + k, j) - 0.5) * 0.8, fz = Z + (hash(i, j + k) - 0.5) * 0.8;
      out.push({ x: snap(fx), y, z: snap(fz), w: 0.06, h: B * 1.6, d: 0.06, color: "#3f8a3a" });
      out.push({ x: snap(fx), y: y + B * 1.6, z: snap(fz), w: 0.2, h: B * 0.6, d: 0.2, color: cols[(((i * 3 + j + k) % 5) + 5) % 5], studs: true });
    }
    return out;
  }
  if (h < 0.68) {
    // Rocks: gray bricks stacked off center.
    return [
      { x: X, y, z: Z, w: 0.75, h: B * 2, d: 0.5, color: "#9aa0a6", studs: true },
      { x: X + 0.12, y: y + B * 2, z: Z - 0.06, w: 0.5, h: B * 1.5, d: 0.25, color: "#aeb4b9", studs: true },
    ];
  }
  if (h < 0.72) {
    // A fence: posts and a rail.
    const out: Box[] = [];
    for (let k = -2; k <= 2; k++) out.push({ x: X + k * 0.25, y, z: Z, w: 0.08, h: B * 3, d: 0.08, color: "#b07a48" });
    out.push({ x: X, y: y + B * 2, z: Z, w: 1.1, h: B * 0.6, d: 0.08, color: "#c08a55" });
    return out;
  }
  return null;
}

/** Figures of the app living in the world: some standing by the path, one walking around it. */
const WORLD_FIGURES = [
  { id: "lucky-cat", x: -1.2, z: -2.9, rot: 0.6, size: 0.94 },
  { id: "robot", x: 2.9, z: 1.4, rot: -2.2, size: 0.88 },
  { id: "bear", x: -3.0, z: 1.5, rot: 1.2, size: 0.94 },
  { id: "penguin", x: 3.3, z: -3.6, rot: 2.6, size: 0.83 },
  { id: "bonsai", x: -3.6, z: -1.2, rot: 0.2, size: 0.88 },
  { id: "bunny", x: 1.4, z: 3.3, rot: -0.8, size: 0.83 },
];

function drawBlocks(f: F) {
  const g = f.g, Lt = f.light, L = BLOCK_LIGHTS[f.tod].dir;
  f.st._glow = [];
  plane(f, Lt ? "#5b9a4e" : "#4a8340", Lt ? "#3f7a36" : "#24451f");
  const box = groundBox(f);
  // Paths of smooth tan tiles  const box = groundBox(f);
  // Paths of smooth tan tiles and a pond of blue plates, under everything else.
  const tile = 0.5, i0 = Math.floor(box.x0 / tile), i1 = Math.ceil(box.x1 / tile), j0 = Math.floor(box.z0 / tile), j1 = Math.ceil(box.z1 / tile);
  if ((i1 - i0) * (j1 - j0) < 60000) for (let i = i0; i <= i1; i++) for (let j = j0; j <= j1; j++) {
    const x = (i + 0.5) * tile, z = (j + 0.5) * tile, path = onPath(x, z), water = !path && onWater(x, z);
    if (!path && !water) continue;
    const a = proj(f, i * tile, FLOOR, j * tile), b = proj(f, (i + 1) * tile, FLOOR, j * tile), c = proj(f, (i + 1) * tile, FLOOR, (j + 1) * tile), d = proj(f, i * tile, FLOOR, (j + 1) * tile);
    if (Math.max(a[1], c[1]) < f.hz) continue;
    const k = clear(f, (a[1] + c[1]) / 2);
    g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.lineTo(c[0], c[1]); g.lineTo(d[0], d[1]); g.closePath();
    const col = path ? (hash(i, j) < 0.15 ? "#c9b07e" : "#d8c08d") : (hash(i, j) < 0.2 ? "#5aa0d0" : "#4f93c4");
    alphaOf(f, k); g.fillStyle = col; g.fill();
    alphaOf(f, k * 0.35); g.strokeStyle = path ? "#a88f5e" : "#3d7aa6"; g.lineWidth = 1; g.stroke();
    // Water glints that move.
    if (water && Math.sin(f.T * 2 + i * 1.3 + j * 0.7) > 0.85) { const m = proj(f, x, FLOOR, z); alphaOf(f, k * 0.8); g.fillStyle = "#e6f3fb"; g.fillRect(m[0] - 3, m[1], 6, 1.5); }
  }
  // The baseplate's studs, everywhere in view, fading into the haze; seams every eight studs.
  const sp = studSprite(f, Lt ? "#4b8a40" : "#3d7535", Lt ? "#6aae5b" : "#5a9a4c", "rgba(255,255,255,.45)");
  if (sp.r >= 1.2) {
    const s0 = Math.floor(box.x0 / STUD), s1 = Math.ceil(box.x1 / STUD), t0 = Math.floor(box.z0 / STUD), t1 = Math.ceil(box.z1 / STUD);
    if ((s1 - s0) * (t1 - t0) < 90000) {
      const w = sp.w, h = sp.h;
      // Stamped on the GPU in one draw (thousands of them with the camera low); one by one only without WebGL.
      // Drawn far to near, so a nearer stud covers the one behind it as before.
      const studs: [number, number, number][] = [];
      for (let i = s0; i <= s1; i++) for (let j = t0; j <= t1; j++) {
        const x = (i + 0.5) * STUD, z = (j + 0.5) * STUD;
        if (onPath(x, z) || onWater(x, z)) continue;
        const p = proj(f, x, FLOOR, z);
        if (p[1] < f.hz - 2 || p[1] > f.H + h || p[0] < -w || p[0] > f.W + w) continue;
        const a = clamp(f.a * clear(f, p[1]), 0, 1);
        if (a > 0.01) studs.push([p[0], p[1], a]);
      }
      studs.sort((a, b) => a[1] - b[1]);
      stamps.begin();
      for (const s of studs) stamps.add(s[0], s[1], s[2]);
      if (!stamps.draw(g, sp.c, w, h, sp.up, f.W, f.H, f.dpr)) {
        for (const s of studs) { g.globalAlpha = s[2]; g.drawImage(sp.c, s[0] - w / 2, s[1] - sp.up, w, h); }
      }
    }
  }
  // Far away things lose the light, like the ground under them.
  f.fog = Lt ? "#3f7a36" : "#24451f";
  // The shadows of clouds passing over the world.
  if (!f.reduced) for (let k = 0; k < 4; k++) {
    const span = 26, cx = ((hash(k, 21) * span + f.T * 0.25) % span) - span / 2, cz = (hash(k, 22) - 0.5) * span * 0.6;
    const r = 1.6 + hash(k, 23) * 1.4;
    onPlane(f, cx, cz, 0, () => {
      const gr = g.createRadialGradient(0, 0, 0, 0, 0, r);
      gr.addColorStop(0, "rgba(10,30,10,.22)"); gr.addColorStop(1, "rgba(10,30,10,0)");
      g.globalAlpha = f.a; g.fillStyle = gr; g.scale(1.6, 1); g.fillRect(-r, -r, r * 2, r * 2);
    }, FLOOR + 0.001);
  }
  // Things standing in the world, each with its shadow; nearest drawn last.
  const things: Thing[] = [], cell = 1.25;
  const ci0 = Math.floor(box.x0 / cell) - 1, ci1 = Math.ceil(box.x1 / cell) + 1, cj0 = Math.floor(box.z0 / cell) - 1, cj1 = Math.ceil(box.z1 / cell) + 1;
  if ((ci1 - ci0) * (cj1 - cj0) < 6000) for (let i = ci0; i <= ci1; i++) for (let j = cj0; j <= cj1; j++) {
    const boxes = thingAt(i, j, cell);
    if (!boxes) continue;
    const c = proj(f, boxes[0].x, FLOOR, boxes[0].z);
    if (c[1] < f.hz - 4 || c[0] < -200 || c[0] > f.W + 200 || c[1] > f.H + 250) continue;
    things.push({ boxes, depth: c[2] });
  }
  // A duck walks around the path.
  const walk = f.reduced ? 0.3 : f.T * 0.12;
  const figs = WORLD_FIGURES.concat([{ id: "duck", x: Math.cos(walk) * 2.05, z: Math.sin(walk) * 2.05, rot: -walk + Math.PI, size: 0.7 }]);
  for (const fg of figs) { const c = proj(f, fg.x, FLOOR, fg.z); if (c[1] > f.hz) things.push({ boxes: [], depth: c[2], fig: fg }); }
  const shadowCol = LIGHTS.blocks.shadow, sa = (Lt ? 0.2 : 0.28) * (f.tod === "night" ? 0.6 : f.tod === "evening" ? 1.15 : 1);
  for (const t of things) {
    const k = clear(f, proj(f, t.fig?.x ?? t.boxes[0].x, FLOOR, t.fig?.z ?? t.boxes[0].z)[1]);
    if (t.fig) castShadow(f, [{ x: t.fig.x, y: FLOOR, z: t.fig.z, w: 0.3 * t.fig.size, h: 0.45 * t.fig.size, d: 0.3 * t.fig.size, color: "" }], L, shadowCol, sa * k);
    else castShadow(f, t.boxes, L, shadowCol, sa * k);
  }
  things.sort((a, b) => a.depth - b.depth);
  const studTop = (b: Box, k: number) => {
    if (!b.studs || sp.r < 1.6) return;
    const nx = Math.max(1, Math.round(b.w / STUD)), nz = Math.max(1, Math.round(b.d / STUD)), r = b.rot ?? 0, co = Math.cos(r), si = Math.sin(r);
    if (nx * nz > 30) return;
    const top = b.y + b.h, w = sp.w, h = sp.h, sc = Math.min(1, b.w / STUD, b.d / STUD);
    for (let u = 0; u < nx; u++) for (let v = 0; v < nz; v++) {
      const lx = (u + 0.5) * (b.w / nx) - b.w / 2, lz = (v + 0.5) * (b.d / nz) - b.d / 2;
      const p = proj(f, b.x + lx * co - lz * si, top, b.z + lx * si + lz * co);
      alphaOf(f, k);
      g.drawImage(studTint(b.color), p[0] - (w * sc) / 2, p[1] - sp.up * sc, w * sc, h * sc);
    }
  };
  // Studs on top of a brick take its color.
  const tints = (f.st._tints ??= new Map<string, HTMLCanvasElement>()) as Map<string, HTMLCanvasElement>;
  if ((f.st._tintKey as string) !== sp.key) { tints.clear(); f.st._tintKey = sp.key; }
  const studTint = (color: string) => {
    let c = tints.get(color);
    if (!c) {
      c = document.createElement("canvas"); c.width = sp.c.width; c.height = sp.c.height;
      const x = c.getContext("2d")!;
      x.drawImage(sp.c, 0, 0);
      x.globalCompositeOperation = "source-atop"; x.fillStyle = color; x.globalAlpha = 0.85; x.fillRect(0, 0, c.width, c.height);
      x.globalAlpha = 0.35; x.fillStyle = "#ffffff"; x.globalCompositeOperation = "source-atop";
      tints.set(color, c);
    }
    return c;
  };
  const figDraws: { id: string; x: number; z: number; rot: number; size: number }[] = [];
  for (const t of things) {
    if (t.fig) { figDraws.push(t.fig); continue; }
    const k = clear(f, proj(f, t.boxes[0].x, FLOOR, t.boxes[0].z)[1]);
    for (const b of t.boxes) { drawBox(f, b, L, k, "rgba(0,0,0,.25)"); studTop(b, k); }
  }
  figures(f, figDraws, Lt ? "#2f5bd3" : "#7d9cf0");
}

// ---------------------------------------------------------------------------------------------------------------
// Placa base

const BOARD = {
  dark: { top: "#0d100f", horizon: "#1a201d", near: "#151b18", far: "#1a201d", farDark: "#0c0f0e", trace: "#2c4a3d", traceLit: "#4d7f69", pad: "#9aa59e", silk: "#d9dfd8", chip: "#1c2123", pin: "#a7aeb0", cap: "#2a3036", capTop: "#59646b", gold: "#b89a5a", glow: "rgba(125,156,240,.18)" },
  light: { top: "#dfe5e1", horizon: "#eef2ef", near: "#e6ede8", far: "#eef2ef", farDark: "#c9d2cc", trace: "#c3d4c9", traceLit: "#a9c2b2", pad: "#c7b27a", silk: "#2a2f2c", chip: "#26292b", pin: "#9aa1a3", cap: "#2f3438", capTop: "#6a747a", gold: "#c2a25a", glow: "rgba(47,91,211,.12)" },
};
type BoardPal = typeof BOARD.dark;

/** One part on a cell of the board, always the same for that cell: a chip, a capacitor, a row of small parts, a
 *  crystal or a connector, with its name printed beside it. */
function partAt(i: number, j: number, cell: number, P: BoardPal) {
  const h = hash(i * 2.3 + 7, j * 4.1 + 3);
  const X = (i + 0.5) * cell + (hash(i, j) - 0.5) * 0.6, Z = (j + 0.5) * cell + (hash(j, i) - 0.5) * 0.6, y = FLOOR;
  if (Math.hypot(X, Z) < 2.6) return null;
  const n = Math.floor(hash(i * 7, j * 3) * 90) + 1, r = hash(i, j * 9) < 0.5 ? 0 : Math.PI / 2;
  if (h < 0.22) {
    const s = 0.7 + hash(i, j * 5) * 0.6;
    return { kind: "chip" as const, boxes: [{ x: X, y, z: Z, w: s, h: 0.06, d: s, color: P.chip, rot: r }] as Box[], label: `U${n}`, x: X, z: Z, s, r };
  }
  if (h < 0.34) return { kind: "cap" as const, boxes: [] as Box[], label: `C${n}`, x: X, z: Z, s: 0.12 + hash(i * 3, j) * 0.07, r };
  if (h < 0.52) {
    const out: Box[] = [];
    for (let k = 0; k < 6; k++) out.push({ x: X + (k - 2.5) * 0.12, y, z: Z, w: 0.07, h: 0.035, d: 0.13, color: hash(k, i + j) < 0.5 ? "#3a332c" : "#7a6a52", rot: r });
    return { kind: "row" as const, boxes: out, label: `R${n}`, x: X, z: Z, s: 0.8, r };
  }
  if (h < 0.58) return { kind: "xtal" as const, boxes: [{ x: X, y, z: Z, w: 0.36, h: 0.09, d: 0.16, color: "#b9c0c2", rot: r }] as Box[], label: `Y${n % 9 + 1}`, x: X, z: Z, s: 0.4, r };
  if (h < 0.66) {
    const len = 6 + Math.floor(hash(i, j * 11) * 6), out: Box[] = [{ x: X, y, z: Z, w: len * 0.1, h: 0.08, d: 0.2, color: "#1f2224", rot: r }];
    return { kind: "header" as const, boxes: out, label: `J${n % 20 + 1}`, x: X, z: Z, s: len * 0.1, r, len };
  }
  return null;
}

function drawBoard(f: F) {
  const g = f.g, Lt = f.light, P = Lt ? BOARD.light : BOARD.dark, L = LIGHTS.board.dir, lightAz = Math.atan2(L[2], L[0]);
  plane(f, P.near, P.farDark);
  const box = groundBox(f);
  // The board's sheen  const box = groundBox(f);
  // The board's sheen: looking toward the light the copper shines more.
  const toward = 0.5 + 0.5 * Math.cos(wrap(lightAz - viewAz(f)));
  // Traces: buses of parallel lines that run along the board and turn at 45°, ending on vias.
  const lane = 0.11, run = 3.2, tw = Math.max(1, f.Sz * 0.012);
  const traces: { a: V3; b: V3; c: V3; k: number; len: number; id: number }[] = [];
  const addRuns = (along: "x" | "z") => {
    const [u0, u1, v0, v1] = along === "x" ? [box.x0, box.x1, box.z0, box.z1] : [box.z0, box.z1, box.x0, box.x1];
    const k0 = Math.floor(v0 / lane), k1 = Math.ceil(v1 / lane), b0 = Math.floor(u0 / run) - 1, b1 = Math.ceil(u1 / run) + 1;
    if ((k1 - k0) * (b1 - b0) > 40000) return;
    for (let k = k0; k <= k1; k++) for (let b = b0; b <= b1; b++) {
      const seed = along === "x" ? 1 : 2, bus = Math.floor(k / 5);
      if (hash(bus * 1.3 + seed, b * 0.7) > 0.3 || hash(k * 0.9, b + seed) > 0.85) continue;
      const s = b * run + hash(bus, b * 3 + seed) * 0.8, e = s + 1.2 + hash(bus * 2, b + seed) * 1.6, v = k * lane, turn = (k % 5) * 0.06 + 0.15, dir = hash(bus, b + 9) < 0.5 ? 1 : -1;
      const pt = (u: number, w: number): V3 => (along === "x" ? [u, FLOOR, w] : [w, FLOOR, u]);
      if (Math.hypot(...(along === "x" ? [s, v] : [v, s])) < 2.4 && Math.hypot(...(along === "x" ? [e, v] : [v, e])) < 2.4) continue;
      traces.push({ a: pt(s, v), b: pt(e, v), c: pt(e + turn, v + turn * dir), k, len: e - s, id: k * 131 + b * 17 + seed });
    }
  };
  addRuns("x"); addRuns("z");
  g.lineCap = "round"; g.lineJoin = "round";
  const traceCol = mix(P.trace, P.traceLit, toward);
  for (const t of traces) {
    const a = proj(f, ...t.a), b = proj(f, ...t.b), c = proj(f, ...t.c);
    if (Math.max(a[1], b[1]) < f.hz) continue;
    const k = clear(f, (a[1] + b[1]) / 2);
    g.beginPath(); g.moveTo(a[0], a[1]); g.lineTo(b[0], b[1]); g.lineTo(c[0], c[1]);
    alphaOf(f, k); g.strokeStyle = traceCol; g.lineWidth = tw; g.stroke();
    for (const q of [a, c]) { g.beginPath(); g.ellipse(q[0], q[1], tw * 1.6, tw * 1.6 * f.sp, 0, 0, TAU); alphaOf(f, k); g.fillStyle = P.pad; g.fill(); }
  }
  // Data running along the traces in the accent color, as on the cube's board.
  if (!f.reduced) for (const t of traces) {
    if (hash(t.id, 5) > 0.35) continue;
    const u = ((f.T * (0.35 + hash(t.id, 6) * 0.5)) / Math.max(0.5, t.len) + hash(t.id, 7)) % 1;
    const p = proj(f, t.a[0] + (t.b[0] - t.a[0]) * u, FLOOR, t.a[2] + (t.b[2] - t.a[2]) * u);
    if (p[1] < f.hz) continue;
    const k = clear(f, p[1]);
    alphaOf(f, k * 0.35); g.fillStyle = f.accent; g.beginPath(); g.ellipse(p[0], p[1], tw * 4, tw * 4 * f.sp, 0, 0, TAU); g.fill();
    alphaOf(f, k); g.beginPath(); g.ellipse(p[0], p[1], tw * 1.4, tw * 1.4 * f.sp, 0, 0, TAU); g.fill();
  }
  // The socket the machine sits on, with its name printed beside it, and the space's name on the board.
  const silk = (text: string, x: number, z: number, size: number, rot: number, al = 0.6, align: CanvasTextAlign = "center") => {
    const p = proj(f, x, FLOOR, z);
    if (p[1] < f.hz) return;
    onPlane(f, x, z, rot, () => {
      g.font = `600 1px "DM Mono", "Cascadia Mono", Consolas, monospace`;
      g.scale(size, size);
      g.textAlign = align; g.textBaseline = "middle";
      alphaOf(f, al * clear(f, p[1])); g.fillStyle = P.silk; g.fillText(text, 0, 0);
    });
  };
  onPlane(f, 0, 0, 0, () => {
    alphaOf(f, 0.55); g.strokeStyle = P.silk; g.lineWidth = 0.02;
    g.strokeRect(-1.35, -1.35, 2.7, 2.7);
    for (const [sx, sz] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) { g.beginPath(); g.moveTo(sx * 1.5, sz * 1.2); g.lineTo(sx * 1.5, sz * 1.5); g.lineTo(sx * 1.2, sz * 1.5); g.lineWidth = 0.04; g.stroke(); }
    g.beginPath(); g.arc(-1.2, -1.2, 0.05, 0, TAU); g.fillStyle = P.silk; g.fill();
    // Fine pins of the socket all around.
    g.lineWidth = 0.012;
    for (let k = -10; k <= 10; k++) { const v = k * 0.12; for (const [x0, z0, x1, z1] of [[v, -1.42, v, -1.52], [v, 1.42, v, 1.52], [-1.42, v, -1.52, v], [1.42, v, 1.52, v]]) { g.beginPath(); g.moveTo(x0, z0); g.lineTo(x1, z1); g.stroke(); } }
  });
  if (f.machine) silk(f.machine.toUpperCase(), 0, 1.75, 0.2, 0, 0.75);
  silk(`${(f.space ?? "GpuVM").toUpperCase()} · REV 1.0`, -1.45, -1.78, 0.13, 0, 0.55, "left");
  silk("GPUVM-B760", 2.2, -0.2, 0.16, Math.PI / 2, 0.45);
  f.fog = P.farDark;
  // The parts, each with its shadow and its name; nearest drawn last.
  const parts: (NonNullable<ReturnType<typeof partAt>> & { depth: number })[] = [], cell = 1.1;
  const ci0 = Math.floor(box.x0 / cell) - 1, ci1 = Math.ceil(box.x1 / cell) + 1, cj0 = Math.floor(box.z0 / cell) - 1, cj1 = Math.ceil(box.z1 / cell) + 1;
  if ((ci1 - ci0) * (cj1 - cj0) < 8000) for (let i = ci0; i <= ci1; i++) for (let j = cj0; j <= cj1; j++) {
    const pt = partAt(i, j, cell, P);
    if (!pt) continue;
    const c = proj(f, pt.x, FLOOR, pt.z);
    if (c[1] < f.hz - 4 || c[0] < -120 || c[0] > f.W + 120 || c[1] > f.H + 120) continue;
    parts.push({ ...pt, depth: c[2] });
  }
  const sa = Lt ? 0.16 : 0.35;
  for (const pt of parts) {
    const k = clear(f, proj(f, pt.x, FLOOR, pt.z)[1]);
    if (pt.kind === "cap") castShadow(f, [{ x: pt.x, y: FLOOR, z: pt.z, w: pt.s * 2, h: pt.s * 3.2, d: pt.s * 2, color: "" }], L, "#000000", sa * k);
    else castShadow(f, pt.boxes, L, "#000000", sa * k);
  }
  parts.sort((a, b) => a.depth - b.depth);
  for (const pt of parts) {
    const k = clear(f, proj(f, pt.x, FLOOR, pt.z)[1]), co = Math.cos(pt.r), si = Math.sin(pt.r);
    if (pt.kind === "chip") {
      // Pins on every side, the body, its pin-1 dot and its printed name.
      onPlane(f, pt.x, pt.z, pt.r, () => {
        g.strokeStyle = P.pin; g.lineWidth = 0.025; alphaOf(f, k);
        const n = Math.max(4, Math.round(pt.s / 0.07)), half = pt.s / 2;
        g.beginPath();
        for (let q = 0; q < n; q++) { const v = -half + ((q + 0.5) * pt.s) / n; g.moveTo(v, -half - 0.07); g.lineTo(v, half + 0.07); g.moveTo(-half - 0.07, v); g.lineTo(half + 0.07, v); }
        g.stroke();
      });
      drawBox(f, pt.boxes[0], L, k);
      onPlane(f, pt.x, pt.z, pt.r, () => {
        g.beginPath(); g.arc(-pt.s / 2 + 0.09, -pt.s / 2 + 0.09, 0.035, 0, TAU); alphaOf(f, k * 0.6); g.fillStyle = P.pin; g.fill();
        g.font = `600 1px "DM Mono", Consolas, monospace`; g.textAlign = "center"; g.textBaseline = "middle";
        g.save(); g.scale(0.11, 0.11); alphaOf(f, k * 0.5); g.fillStyle = Lt ? "#aab0b2" : "#8a9295"; g.fillText("GPUVM", 0, 0); g.restore();
      }, FLOOR + 0.061);
      silk(pt.label, pt.x + (pt.s / 2 + 0.22) * co, pt.z + (pt.s / 2 + 0.22) * si, 0.12, pt.r);
    } else if (pt.kind === "cap") {
      // An electrolytic capacitor: a can with its stripe and the cross on top.
      const hgt = pt.s * 2.4, top = proj(f, pt.x, FLOOR + hgt, pt.z), bot = proj(f, pt.x, FLOOR, pt.z), rx = pt.s * f.Sz, ry = rx * f.sp;
      if (bot[1] < f.hz) continue;
      const side = shade(P.cap, 0.75 + 0.35 * toward);
      alphaOf(f, k); g.fillStyle = side;
      g.beginPath(); g.ellipse(bot[0], bot[1], rx, ry, 0, 0, Math.PI); g.lineTo(top[0] - rx, top[1]); g.ellipse(top[0], top[1], rx, ry, 0, Math.PI, 0, true); g.closePath(); g.fill();
      g.fillStyle = shade(P.cap, 1.25); g.fillRect(bot[0] + rx * 0.35, top[1], rx * 0.35, bot[1] - top[1]);
      g.beginPath(); g.ellipse(top[0], top[1], rx, ry, 0, 0, TAU); g.fillStyle = P.capTop; g.fill();
      g.strokeStyle = shade(P.capTop, 0.6); g.lineWidth = 1; g.beginPath(); g.moveTo(top[0] - rx * 0.6, top[1]); g.lineTo(top[0] + rx * 0.6, top[1]); g.moveTo(top[0], top[1] - ry * 0.6); g.lineTo(top[0], top[1] + ry * 0.6); g.stroke();
      silk(pt.label, pt.x + pt.s + 0.18, pt.z, 0.11, 0);
    } else if (pt.kind === "header") {
      drawBox(f, pt.boxes[0], L, k);
      const len = (pt as { len?: number }).len ?? 6;
      for (let q = 0; q < len; q++) for (const w of [-0.05, 0.05]) {
        const u = (q - (len - 1) / 2) * 0.1, base = proj(f, pt.x + u * co - w * si, FLOOR + 0.08, pt.z + u * si + w * co), tip = proj(f, pt.x + u * co - w * si, FLOOR + 0.2, pt.z + u * si + w * co);
        g.beginPath(); g.moveTo(base[0], base[1]); g.lineTo(tip[0], tip[1]); alphaOf(f, k); g.strokeStyle = P.gold; g.lineWidth = Math.max(1, f.Sz * 0.012); g.stroke();
      }
      silk(pt.label, pt.x - (pt.s / 2 + 0.2) * co, pt.z - (pt.s / 2 + 0.2) * si, 0.11, pt.r);
    } else {
      for (const b of pt.boxes) drawBox(f, b, L, k);
      silk(pt.label, pt.x + 0.3 * si, pt.z - 0.3 * co, 0.1, pt.r);
    }
  }
}

const DRAW: Record<Exclude<AmbientId, "studio">, (f: F) => void> = { board: drawBoard, blocks: drawBlocks };

/** Draws an ambient behind the cube, at `alpha` (to fade from one to another). Returns false for none (Estudio). */
export function drawAmbient(id: AmbientId, v: AmbientView, state: AmbientState, alpha = 1): boolean {
  if (id === "studio") return false;
  const draw = DRAW[id];
  if (!draw) return false;
  const g = v.g;
  void DH;
  g.save();
  draw(frame(v, alpha, state));
  g.restore();
  g.globalAlpha = 1;
  return true;
}
/** What shines by itself after the time of day has colored the world: lit windows, and fireflies at night. */
export function drawAmbientGlow(id: AmbientId, v: AmbientView, state: AmbientState, alpha = 1) {
  if (id !== "blocks") return;
  const t = resolveTime(v.time);
  if (t === "day") return;
  const g = v.g, list = (state._glow ?? []) as number[][];
  g.save();
  for (let i = 0; i < list.length; i += 2) {
    const p = list[i], k = list[i + 1][0];
    g.beginPath(); for (let j = 0; j < p.length; j += 2) (j ? g.lineTo(p[j], p[j + 1]) : g.moveTo(p[j], p[j + 1])); g.closePath();
    g.globalAlpha = alpha * k * (t === "night" ? 0.95 : 0.55); g.fillStyle = "#ffd27a"; g.fill();
  }
  if (t === "night" && !v.reduced) {
    g.fillStyle = "#e8f59a";
    for (let i = 0; i < 40; i++) {
      const x = (hash(i, 1) * 1.2 - 0.1) * v.W + Math.sin(v.T * 0.4 + i) * 18, y = (0.25 + hash(i, 2) * 0.75) * v.H + Math.sin(v.T * 0.7 + i * 2) * 10;
      const on = Math.max(0, Math.sin(v.T * 1.6 + i * 2.3)) ** 2;
      g.globalAlpha = alpha * on * 0.35; g.beginPath(); g.arc(x, y, 5, 0, TAU); g.fill();
      g.globalAlpha = alpha * on; g.fillRect(x - 1.5, y - 1.5, 3, 3);
    }
  }
  g.restore();
}

/** Whether the ambient paints its own world (everything but Estudio). */
export const hasScene = (id: AmbientId) => id !== "studio";

/** The floor point under a world point, along the light (for shadows drawn by the cube). */
export function shadowPoint(p: V3, L: V3): V3 {
  const t = (p[1] - FLOOR) / L[1];
  return [p[0] - L[0] * t, FLOOR, p[2] - L[2] * t];
}
