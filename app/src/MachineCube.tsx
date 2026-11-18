import { useEffect, useRef } from "react";
import { animFps, onAnimBudget, animDpr, paceFrame } from "./animBudget";
import type { VmOverview } from "./types";
import { useDecor, decorColor, colorOfDecor, saveDecor, ledTop, LED_STEP, newId, LED_COLORS, type Decor, type Face } from "./decor/store";
import { ledColumns } from "./decor/ledFont";
import { t } from "./i18n";
import { stickerImage } from "./decor/stickers";
import { figureHeight } from "./decor/figures";
import { FLOOR, ambientLight, ambientTint, drawAmbient, drawAmbientGlow, hasScene, normalizeAmbient, resolveTime, type AmbientId, type AmbientState, type AmbientTime } from "./ambient";
import { drawFigures as drawFiguresGL, mul3, turnY, viewRot, type FigureDraw } from "./decor/figureGL";

/** What the cube shows: the machine's pieces, how much each one is working, and what it has installed. */
export interface CubeMachine {
  /** "on" draws the hologram, "starting" builds it from the bottom up, "off" leaves a faint ghost. */
  power: "on" | "starting" | "off";
  cores: number;
  memoryGB: number;
  gpuPercent: number;
  diskGB: number;
  /** Use of each piece, 0 to 100. */
  usage: { cpu: number; gpu: number; mem: number; disk: number };
  /** Catalog ids of the apps in the machine. */
  apps: string[];
  /** How many kinds of things the Windows cleanup keeps out (0 for none). */
  removed: number;
}

/** Brand colors for the catalog apps; anything else gets a muted color from its id. */
const APP_COLORS: Record<string, string> = {
  steam: "#66c0f4", discord: "#8b8cf7", spotify: "#1db954", chrome: "#f0b429", firefox: "#f97316", "7zip": "#9ca3af",
  vlc: "#f08a24", obs: "#c084fc", epic: "#e5e7eb", vscode: "#4cc2ff", notepadplusplus: "#7dd19c", gog: "#c46f8e",
};
const MUTED = ["#4f9a86", "#c4775e", "#8a7fd0", "#c9a24f", "#c46f8e"];
const appColor = (id: string) => APP_COLORS[id] ?? MUTED[[...id].reduce((a, c) => a + c.charCodeAt(0), 0) % MUTED.length];
/** Where the apps float inside the cube: scattered, not in a ring, so they don't steal the eye. */
const APP_SPOTS: V3[] = [[-0.72, 1.05, -0.62], [0.74, 0.95, -0.18], [-0.78, 0.7, 0.25], [0.66, 1.62, 0.62], [-0.55, 1.72, 0.7], [0.18, 1.0, -0.82], [0.82, 1.3, -0.74], [-0.25, 0.85, 0.8]];
/** Where app number `i` of `n` floats: the first ones in fixed spots, the rest spread through the upper half of the
 *  cube by a golden-angle spiral, so any number of apps fits. */
const appSpot = (i: number, n: number): V3 => {
  if (i < APP_SPOTS.length) return APP_SPOTS[i];
  const t = i - APP_SPOTS.length, a = t * 2.39996, r = 0.3 + 0.55 * ((t * 0.618) % 1);
  return [Math.max(-0.85, Math.min(0.85, Math.cos(a) * r)), 0.7 + ((t * 0.371 + n * 0.01) % 1) * 1.15, Math.max(-0.85, Math.min(0.85, Math.sin(a) * r))];
};
/** The apps' size: smaller the more there are. */
const appSize = (n: number) => (n <= APP_SPOTS.length ? 0.1 : Math.max(0.045, 0.1 * Math.sqrt(APP_SPOTS.length / n)));
/** Resource colors, the same as the chips (processor, memory, GPU, disk). */
const PART = { cpu: "--res-cpu", mem: "--res-mem", gpu: "--res-gpu", disk: "--res-disk" } as const;

type V3 = [number, number, number];
type V2 = [number, number];

const parsed = new Map<string, number[]>();
const hex = (c: string): number[] => {
  const hit = parsed.get(c);
  if (hit) return hit;
  const out = parseHex(c);
  if (parsed.size > 500) parsed.clear();
  parsed.set(c, out);
  return out;
};
const parseHex = (c: string): number[] => {
  const s = c.trim();
  if (s.startsWith("rgb")) return s.replace(/[^\d,.]/g, "").split(",").slice(0, 3).map(Number);
  const h = s.replace("#", "");
  const f = h.length === 3 ? h.split("").map((x) => x + x).join("") : h;
  return [0, 2, 4].map((i) => parseInt(f.slice(i, i + 2), 16));
};
const mixHex = (a: string, b: string, t: number) => {
  const x = hex(a), y = hex(b);
  return "#" + x.map((c, i) => Math.round(c + (y[i] - c) * t).toString(16).padStart(2, "0")).join("");
};
/** A color lit by `k`: darker below 1, toward white above it (cached, a frame asks for the same few many times). */
const shades = new Map<string, string>();
const shadeHex = (c: string, k: number) => {
  const q = Math.round(k * 40) / 40, key = c + "|" + q;
  let s = shades.get(key);
  if (!s) { s = q <= 1 ? mixHex(c, "#000000", 1 - q) : mixHex(c, "#ffffff", Math.min(1, q - 1)); if (shades.size > 2000) shades.clear(); shades.set(key, s); }
  return s;
};
const rgba = (c: string, a: number) => `rgba(${hex(c).join(",")},${Math.max(0, Math.min(1, a))})`;

/** Jagged lightning between two screen points (midpoint displacement). */
function bolt(x1: number, y1: number, x2: number, y2: number, d: number): V2[] {
  let p: V2[] = [[x1, y1], [x2, y2]];
  for (let k = 0; k < 5; k++) {
    const q: V2[] = [p[0]];
    for (let i = 1; i < p.length; i++) {
      const a = p[i - 1], b = p[i], dx = b[0] - a[0], dy = b[1] - a[1], L = Math.hypot(dx, dy) || 1, o = (Math.random() - 0.5) * d;
      q.push([(a[0] + b[0]) / 2 - (dy / L) * o, (a[1] + b[1]) / 2 + (dx / L) * o], b);
    }
    p = q;
    d /= 2;
  }
  return p;
}

function hull(pts: V2[]): V2[] {
  pts = pts.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  const cr = (o: V2, a: V2, b: V2) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
  const lo: V2[] = [], up: V2[] = [];
  for (const p of pts) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], p) <= 0) lo.pop(); lo.push(p); }
  for (const p of pts.reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], p) <= 0) up.pop(); up.push(p); }
  return lo.slice(0, -1).concat(up.slice(0, -1));
}
const inHull = (h: V2[], x: number, y: number) => h.every((a, i) => { const b = h[(i + 1) % h.length]; return (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]) >= 0; });

const CORNERS: V3[] = [];
for (const x of [-1, 1]) for (const y of [0, 2]) for (const z of [-1, 1]) CORNERS.push([x, y, z]);
const EDGES: [V3, V3][] = [];
for (let i = 0; i < 8; i++) for (let j = i + 1; j < 8; j++) {
  const a = CORNERS[i], b = CORNERS[j];
  if (Number(a[0] !== b[0]) + Number(a[1] !== b[1]) + Number(a[2] !== b[2]) === 1) EDGES.push([a, b]);
}
const CUBE_FACES: [V3, V3[]][] = [
  [[1, 0, 0], [[1, 0, -1], [1, 0, 1], [1, 2, 1], [1, 2, -1]]], [[-1, 0, 0], [[-1, 0, -1], [-1, 0, 1], [-1, 2, 1], [-1, 2, -1]]],
  [[0, 0, 1], [[-1, 0, 1], [1, 0, 1], [1, 2, 1], [-1, 2, 1]]], [[0, 0, -1], [[-1, 0, -1], [1, 0, -1], [1, 2, -1], [-1, 2, -1]]],
  [[0, 1, 0], [[-1, 2, -1], [1, 2, -1], [1, 2, 1], [-1, 2, 1]]], [[0, -1, 0], [[-1, 0, -1], [1, 0, -1], [1, 0, 1], [-1, 0, 1]]],
];
const ELECTRODES: V3[] = [[-0.86, 1.94, -0.86], [0.86, 1.94, -0.86], [-0.86, 1.94, 0.86], [0.86, 1.94, 0.86]];

/** The motherboard's traces (x, z on its top), built once. */
const TRACES: V2[][] = (() => {
  const t: V2[][] = [];
  const route = (a: V2, b: V2): V2[] => [a, [(a[0] + b[0]) / 2, a[1]], [(a[0] + b[0]) / 2, b[1]], b];
  const list: V2[][] = [[[-0.38, -0.02], [0.24, -0.02]], [[-0.08, -0.32], [0.12, -0.32]], [[-0.38, -0.02], [-0.38, 0.18], [0.1, 0.18], [0.1, 0.32]],
    [[-0.62, -0.32], [-0.76, -0.32]], [[0.2, 0.1], [0.7, 0.1], [0.84, 0.5]], [[-0.5, -0.02], [-0.55, 0.32]], [[0.02, 0.62], [0.6, 0.62]],
    [[0.15, 0.78], [0.6, 0.75]], [[-0.2, 0.5], [-0.2, 0.85]], [[0.5, -0.02], [0.84, -0.2]]];
  for (const l of list) t.push(l.length > 2 ? l : route(l[0], l[1]));
  for (let i = 0; i < 14; i++) { const z = -0.66 + i * 0.045; t.push([[-0.08, z], [0.04, z], [0.04 + (i % 3) * 0.02, z + 0.02], [0.12, z + 0.02]]); }
  for (let i = 0; i < 10; i++) { const x = -0.12 + i * 0.06; t.push([[x, 0.16], [x, 0.22], [x + 0.02, 0.26], [x + 0.02, 0.3]]); }
  return t;
})();

/** What the Personalizar panel puts in a drag to drop on the cube: "sticker|<id>" or "figure|<id>". */
export const DND = "application/x-gpuvm-decor";
/** Each face of the glass seen from outside: its center, its right (U) and up (V) directions and its normal. */
const FRAMES: Record<Face, { c: V3; U: V3; V: V3; n: V3 }> = {
  front: { c: [0, 1, 1.006], U: [1, 0, 0], V: [0, 1, 0], n: [0, 0, 1] },
  right: { c: [1.006, 1, 0], U: [0, 0, -1], V: [0, 1, 0], n: [1, 0, 0] },
  back: { c: [0, 1, -1.006], U: [-1, 0, 0], V: [0, 1, 0], n: [0, 0, -1] },
  left: { c: [-1.006, 1, 0], U: [0, 0, 1], V: [0, 1, 0], n: [-1, 0, 0] },
  top: { c: [0, 2.006, 0], U: [1, 0, 0], V: [0, 0, -1], n: [0, 1, 0] },
};
const FACE_LIST = Object.keys(FRAMES) as Face[];
const add3 = (a: V3, b: V3, k: number): V3 => [a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k];
const onFace = (f: Face, u: number, v: number): V3 => add3(add3(FRAMES[f].c, FRAMES[f].U, u), FRAMES[f].V, v);
const clamp = (v: number, a: number, b: number) => Math.min(b, Math.max(a, v));
/** The snapping grid: a face (2 units) has 8 cells a side and things settle on their half cells. */
const CELL = 0.25, SNAP = CELL / 2;
const snap = (v: number, step = SNAP) => Math.round(v / step) * step;
const segDist = (x: number, y: number, a: V3, b: V3) => {
  const dx = b[0] - a[0], dy = b[1] - a[1], t = clamp(((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy || 1), 0, 1);
  return Math.hypot(x - a[0] - dx * t, y - a[1] - dy * t);
};
/** A figure's size on the cube at size 1. */
const FIG = 0.62;
/** A picked sticker: the same image under a soft layer of the selection color. */
// Where each machine's cube was last drawn on screen (page pixels): a cube that appears on another page right after
// (Home to the machine, and back) starts there and glides to its place, as if the same cube moved.
const lastCube = new Map<string, { x: number; y: number; s: number; t: number; canvas: HTMLCanvasElement }>();
const ARRIVE_MS = 650;
const tints = new WeakMap<HTMLCanvasElement, { color: string; c: HTMLCanvasElement }>();
function stickerTinted(img: HTMLCanvasElement, color: string) {
  const hit = tints.get(img);
  if (hit && hit.color === color) return hit.c;
  const c = document.createElement("canvas");
  c.width = img.width; c.height = img.height;
  const x = c.getContext("2d")!;
  x.drawImage(img, 0, 0);
  x.globalCompositeOperation = "source-atop";
  x.globalAlpha = 0.3; x.fillStyle = color; x.fillRect(0, 0, c.width, c.height);
  tints.set(img, { color, c });
  return c;
}
/** The back of a sticker, seen through the glass from the other side: its paper, without the art. */
const backs = new WeakMap<HTMLCanvasElement, HTMLCanvasElement>();
function stickerBack(img: HTMLCanvasElement) {
  let b = backs.get(img);
  if (!b) {
    b = document.createElement("canvas");
    b.width = img.width; b.height = img.height;
    const x = b.getContext("2d")!;
    x.drawImage(img, 0, 0);
    x.globalCompositeOperation = "source-in";
    x.fillStyle = "#e9e5dc"; x.fillRect(0, 0, b.width, b.height);
    backs.set(img, b);
  }
  return b;
}

const START_YAW = Math.PI / 4 + 0.15, START_PITCH = 0.55;
const MAX_NEIGHBORS = 8;
/** The constellation's size grows with the machines in it, and the camera steps back to keep it all in view. */
const ringRadius = (count: number) => 1.45 + count * 0.12;
const restZoom = (count: number) => Math.min(0.6, 2.3 / (ringRadius(count) + 0.9));

/** The space as the last cube left it, so opening another machine continues it: the one that was in front goes back
 *  among the others and the new one comes forward, from the same angle. */
let lastSpace: { name: string; yaw: number; pitch: number; at: number } | null = null;

/** The machine as a hologram inside a glass cube: motherboard, processor, memory, graphics card and disk drawn in
 *  detail, the apps floating around, the machine's screen projected above, and lightning from the cube's top
 *  corners to whatever piece is working, more often the harder it works. What the cleanup keeps out comes from
 *  outside and bounces off the glass. It turns in any direction by dragging, zooms with the wheel toward the
 *  pointer, moves with a right drag, and goes back to its first view with a double click. */
/** Another machine in the same space, drawn small under this one and as a star of the constellation at rest. */
export interface CubeNeighbor { name: string; machine: CubeMachine }

/** The fixed views of the cube, for decorating each face straight on. */
export type CubeView = "front" | "right" | "back" | "left" | "top";
const VIEWS: Record<CubeView, { yaw: number; pitch: number }> = {
  front: { yaw: 0, pitch: 0.12 }, right: { yaw: Math.PI / 2, pitch: 0.12 }, back: { yaw: Math.PI, pitch: 0.12 }, left: { yaw: -Math.PI / 2, pitch: 0.12 }, top: { yaw: 0, pitch: Math.PI / 2 - 0.02 },
};

/** Editing the decoration on the cube: stickers and figures are picked, dragged and dropped right on it. */
export interface CubeEdit {
  /** What is picked: one or several stickers and figures. */
  selected: string[];
  onSelect: (ids: string[]) => void;
  /** Right click on a sticker or figure, at a point of the window. */
  onMenu: (id: string, x: number, y: number) => void;
  /** While decorating, the machine stays in front instead of drifting off into the constellation. */
  holdStill?: boolean;
  /** A fixed view to decorate from (front, a side, the top): the cube goes there and stays still until it is cleared. */
  view?: CubeView | null;
  /** Where moved stickers and figures are saved (the machine's decoration by default). */
  write?: (d: Decor) => void;
}

export function MachineCube({ machine, name = "", others = [], className, perPart = false, decorOf, edit, decorShown, spin = 0, ambient: ambientIn = "studio", spaceName, time, travel = false }: {
  /** The time of day of the world (blocks). */
  time?: AmbientTime;
  /** The place where the machines float (the space's ambient); changing it fades from one to the other. */
  ambient?: AmbientId;
  /** The ambient's style and time of day. */
  /** The space's name, printed on the board. */
  spaceName?: string;
  machine: CubeMachine; name?: string; others?: CubeNeighbor[]; className?: string; perPart?: boolean;
  /** Whose decoration to show (the machine's name; `name` can be a name still being typed). */
  decorOf?: string;
  /** A decoration to show instead of a machine's own (Home's showcase, a draft in Crear máquina). */
  decorShown?: Decor;
  /** Each time it changes, the cube turns once quickly while the hologram rebuilds (a new decoration arriving). */
  spin?: number;
  edit?: CubeEdit;
  /** The same machine's cube on Home and on its page: it flies from one to the other when the page changes. Other
   *  cubes (the opening stage, dialogs) keep their own entrance. */
  travel?: boolean;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const owner = decorOf ?? name;
  const decor = useDecor(owner);
  const decorRef = useRef({ decor, owner });
  decorRef.current = { decor: decorShown ?? decor, owner };
  const spins = useRef(spin);
  spins.current = spin;
  const editRef = useRef(edit);
  editRef.current = edit;
  // What changed since the last render: one piece gets a close-up, several at once (a profile) get a sequence.
  const prev = useRef<CubeMachine | null>(null);
  const requests = useRef<string[][]>([]);
  const born = useRef(performance.now());
  const prevOwner = useRef(decorOf ?? name);
  useEffect(() => {
    const p = prev.current;
    prev.current = machine;
    // Another machine in front (a space changed) is not a change of pieces.
    const who = decorOf ?? name, other = prevOwner.current !== who;
    prevOwner.current = who;
    if (other) { born.current = performance.now(); return; }
    // What arrives while the page is still loading (the installed apps, the saved level) is not a change.
    if (!p || performance.now() - born.current < 1500) return;
    const parts: string[] = [];
    if (p.cores !== machine.cores) parts.push("cpu");
    if (p.memoryGB !== machine.memoryGB) parts.push("mem");
    if (p.gpuPercent !== machine.gpuPercent) parts.push("gpu");
    if (p.diskGB !== machine.diskGB) parts.push("disk");
    for (const id of machine.apps) if (!p.apps.includes(id)) parts.push(`app:${machine.apps.indexOf(id)}`);
    if (p.removed !== machine.removed) parts.push("cleanup");
    if (parts.length) requests.current.push(parts);
  });
  // The name is engraved on the board's serial plate; typing it takes the camera there.
  const plateName = useRef(name);
  useEffect(() => {
    if (plateName.current === name) return;
    plateName.current = name;
    if (performance.now() - born.current >= 1500) requests.current.push(["plate"]);
  }, [name]);
  // Up to eight neighbors share the space: more would only crowd it (the sidebar lists every machine).
  const space = useRef({ others: others.slice(0, MAX_NEIGHBORS), name });
  space.current = { others: others.slice(0, MAX_NEIGHBORS), name };
  const data = useRef(machine);
  data.current = machine;
  const colors = useRef(perPart);
  colors.current = perPart;
  const ambient = normalizeAmbient(ambientIn);
  const place = useRef(ambient);
  place.current = ambient;
  const labels = useRef({ space: spaceName, machine: name });
  labels.current = { space: spaceName, machine: decorOf ?? name };
  const timeRef = useRef(time);
  timeRef.current = time;

  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const g = cv.getContext("2d")!;
    const holo = document.createElement("canvas"), h = holo.getContext("2d")!;
    const screen = document.createElement("canvas"), s2 = screen.getContext("2d")!;
    screen.width = 480; screen.height = 270;
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    const view = { yaw: START_YAW, pitch: START_PITCH, vy: 0, vp: 0, zoom: 1, ox: 0, oy: 0 };
    // Coming from another machine's page: swap places with it instead of starting over.
    const mountedAt = performance.now();
    const before = lastSpace;
    const swap = { from: -1, t: 1, started: false, yaw: START_YAW };
    // The same machine's cube was on screen a moment ago somewhere else: start from there.
    const came = travel ? lastCube.get(decorRef.current.owner) : undefined;
    const arrive = came && came.canvas !== cv && performance.now() - came.t < 1500 && !reduced
      ? { ...came, k: 0, t0: performance.now(), box: cv.getBoundingClientRect(), style: cv.getAttribute("style") } : null;
    // On its way it flies over the whole window (its own box would cut it), with only the cube drawn; at its place the
    // canvas goes back into its box and the world and the neighbors fade in around it.
    if (arrive) cv.style.cssText += ";position:fixed;left:0;top:0;width:100vw;height:100vh;z-index:40;pointer-events:none";
    let landed = arrive ? 0 : 1;
    let spun = spins.current;
    if (before && before.name !== space.current.name && performance.now() - before.at < 2500) {
      swap.from = space.current.others.findIndex((o) => o.name === before.name);
      if (swap.from >= 0) { swap.t = 0; swap.yaw = before.yaw; view.yaw = before.yaw; view.pitch = before.pitch; }
    }
    // The ambient being shown, and the one it is fading from.
    const scene = { cur: place.current, prev: null as AmbientId | null, k: 1, states: new Map<AmbientId, AmbientState>() };
    const stateOf = (id: AmbientId) => { let s = scene.states.get(id); if (!s) { s = {}; scene.states.set(id, s); } return s; };
    let drag: { x: number; y: number; pan: boolean } | null = null;
    const reset = () => Object.assign(view, { yaw: START_YAW, pitch: START_PITCH, vy: 0, vp: 0, zoom: 1, ox: 0, oy: 0 });
    // The camera's close-ups: a list of shots, then back to where the person left the view.
    type Shot = { p: V3; zoom: number; yaw: number; pitch: number; hold: number };
    type ViewState = { yaw: number; pitch: number; zoom: number; ox: number; oy: number };
    const cam = { shots: [] as Shot[], i: 0, t: 0, k: 6, home: null as ViewState | null, back: 0, rebuild: -1, rebuildSpeed: 1 };
    const stopCam = () => { cam.shots = []; cam.home = null; cam.back = 0; idleSince = performance.now(); };
    // When the person stops moving it, it drifts back to the middle on its own after a while.
    let idleSince = performance.now();
    // A sticker or figure being dragged: a working copy is drawn while it moves and saved when it is let go.
    const writeDecor = (d: Decor) => (editRef.current?.write ?? ((x: Decor) => saveDecor(decorRef.current.owner, x)))(d);
    let held: { kind: "sticker" | "figure" | "led"; id: string; du: number; dv: number; group?: Group } | null = null;
    // Several picked and one of them dragged: all of them keep their places relative to it.
    type Group = { st: Map<string, { u: number; v: number }>; fg: Map<string, { x: number; z: number }>; face: Face | null; u0: number; v0: number; x0: number; z0: number };
    // Shift and drag on empty space draws a marquee that picks what is inside.
    let marquee: { x0: number; y0: number; x1: number; y1: number; add: string[] } | null = null;
    // Right button held on a sticker or figure and dragged sideways turns it, settling every 15°; a right click that
    // does not move opens its menu instead.
    // The turn follows the pointer around the piece like a dial (any number of turns, either way); right on the
    // piece, where the angle means nothing, a sideways move turns it instead.
    let turning: { id: string; ids: Map<string, number>; x: number; moved: boolean; at: V2; c: V2; last: V2; deg: number } | null = null;
    let work: Decor | null = null;
    const local = (e: { clientX: number; clientY: number }): V2 => { const r = cv.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
    const down = (e: PointerEvent) => {
      const ed = editRef.current;
      if (ed && e.button !== 1) {
        const [x, y] = local(e), hit = pick(x, y);
        // The menu opens on the contextmenu event that follows, which is also the one the browser's own menu
        // would answer: opening it here let that event land on our menu and show the browser's on top.
        if (e.button === 2 && hit) {
          if (hit.kind === "led") return;
          const ids = ed.selected.includes(hit.id) ? ed.selected : [hit.id];
          ed.onSelect(ids); menuFor = hit.id;
          const d = decorRef.current.decor, rots = new Map<string, number>();
          for (const t of [...d.stickers, ...d.figures]) if (ids.includes(t.id)) rots.set(t.id, t.rot);
          const st = d.stickers.find((s) => s.id === hit.id), fg = d.figures.find((f) => f.id === hit.id);
          const cp = st ? P(...onFace(st.face, st.u, st.v)) : fg ? P(fg.x, 2 + figureHeight(fg.figure) * fg.size * FIG * 0.4, fg.z) : [x, y];
          stopCam(); work = d; turning = { id: hit.id, ids: rots, x: e.clientX, moved: false, at: [x, y], c: [cp[0], cp[1]], last: [x, y], deg: 0 };
          try { cv.setPointerCapture(e.pointerId); } catch { /* not a real pointer */ }
          cv.classList.add("turning");
          return;
        }
        if (e.button === 0 && hit && hit.kind !== "led" && (e.shiftKey || e.ctrlKey || e.metaKey)) {
          ed.onSelect(ed.selected.includes(hit.id) ? ed.selected.filter((i) => i !== hit.id) : [...ed.selected, hit.id]);
          return;
        }
        if (e.button === 0 && !hit && e.shiftKey) {
          marquee = { x0: x, y0: y, x1: x, y1: y, add: e.ctrlKey ? ed.selected : [] };
          try { cv.setPointerCapture(e.pointerId); } catch { /* not a real pointer */ }
          return;
        }
        if (e.button === 0 && hit) {
          stopCam();
          held = { ...hit, du: 0, dv: 0 };
          work = decorRef.current.decor;
          const st = work.stickers.find((t) => t.id === hit.id);
          if (st) { const [u, v] = faceUV(st.face, x, y); held.du = st.u - u; held.dv = st.v - v; }
          if (hit.kind === "led") { const f = sideAt(x, y); if (f) held.dv = ledTop(work.led?.y) - faceUV(f, x, y)[1]; }
          const fg = work.figures.find((t) => t.id === hit.id);
          if (fg) { const [X, Z] = planeXZ(x, y); held.du = fg.x - X; held.dv = fg.z - Z; }
          if (hit.kind !== "led") {
            const ids = ed.selected.includes(hit.id) && ed.selected.length > 1 ? ed.selected : [hit.id];
            ed.onSelect(ids);
            if (ids.length > 1) {
              const [u0, v0] = st ? faceUV(st.face, x, y) : [0, 0], [x0, z0] = planeXZ(x, y);
              held.group = {
                st: new Map(work.stickers.filter((t) => ids.includes(t.id)).map((t) => [t.id, { u: t.u, v: t.v }])),
                fg: new Map(work.figures.filter((t) => ids.includes(t.id)).map((t) => [t.id, { x: t.x, z: t.z }])),
                face: st ? st.face : null, u0, v0, x0, z0,
              };
            }
          }
          cv.setPointerCapture(e.pointerId); cv.classList.add("holding");
          return;
        }
        if (e.button === 0) ed.onSelect([]);
      }
      // The left button turns it; the right one (outside decorating) and the wheel pressed move it around.
      if (e.button === 1) e.preventDefault();
      stopCam(); drag = { x: e.clientX, y: e.clientY, pan: e.button === 2 || e.button === 1 }; cv.setPointerCapture(e.pointerId); cv.classList.add(drag.pan ? "panning" : "dragging");
    };
    const move = (e: PointerEvent) => {
      // A button let go where the cube never heard it (outside the window, over another app): the turn or drag
      // still ends, and is kept, instead of going back.
      if ((turning || held || drag) && e.buttons === 0) { up(); return; }
      if (turning && work) {
        const dx = e.clientX - turning.x;
        if (Math.abs(dx) > 4) { turning.moved = true; menuFor = null; }
        if (!turning.moved) return;
        // Far enough from the piece, the change of angle around it; on it, the sideways move.
        const [px, py] = local(e), [lx, ly] = turning.last, [cx, cy] = turning.c;
        if (Math.hypot(px - cx, py - cy) > 26 && Math.hypot(lx - cx, ly - cy) > 26) {
          let d = Math.atan2(py - cy, px - cx) - Math.atan2(ly - cy, lx - cx);
          if (d > Math.PI) d -= Math.PI * 2; else if (d < -Math.PI) d += Math.PI * 2;
          turning.deg += (d * 180) / Math.PI;
        } else turning.deg += (px - lx) * 0.9;
        turning.last = [px, py];
        // Every picked one turns by the same steps of 15°.
        const turnBy = Math.round(turning.deg / 15) * 15, rots = turning.ids, at = (r: number) => (((r + turnBy) % 360) + 360) % 360;
        work = { ...work, stickers: work.stickers.map((t) => (rots.has(t.id) ? { ...t, rot: at(rots.get(t.id)!) } : t)), figures: work.figures.map((t) => (rots.has(t.id) ? { ...t, rot: at(rots.get(t.id)!) } : t)) };
        turning.at = local(e);
        idleSince = performance.now();
        return;
      }
      if (marquee) { [marquee.x1, marquee.y1] = local(e); return; }
      if (held) { moveHeld(...local(e)); idleSince = performance.now(); return; }
      if (!drag) { if (editRef.current) cv.classList.toggle("grab", !!pick(...local(e))); return; }
      const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (drag.pan) { view.ox += dx; view.oy += dy; } else if (editRef.current?.view) { /* a fixed view does not turn */ } else { view.vy = dx * 0.01; view.vp = dy * 0.01; view.yaw += view.vy; view.pitch += view.vp; }
      drag.x = e.clientX; drag.y = e.clientY;
      idleSince = performance.now();
    };
    const up = () => {
      if (marquee) {
        // What has its center inside the marquee gets picked.
        const b = marquee, x0 = Math.min(b.x0, b.x1), x1 = Math.max(b.x0, b.x1), y0 = Math.min(b.y0, b.y1), y1 = Math.max(b.y0, b.y1);
        const d = decorRef.current.decor, inside = (p: V3) => p[0] >= x0 && p[0] <= x1 && p[1] >= y0 && p[1] <= y1;
        const ids = [...d.stickers.filter((s) => vis(...FRAMES[s.face].n) && inside(P(...onFace(s.face, s.u, s.v)))).map((s) => s.id),
          ...d.figures.filter((f) => inside(P(f.x, 2 + figureHeight(f.figure) * f.size * FIG * 0.4, f.z))).map((f) => f.id)];
        if (Math.abs(x1 - x0) > 4 || Math.abs(y1 - y0) > 4) editRef.current?.onSelect([...new Set([...b.add, ...ids])]);
        marquee = null;
        return;
      }
      if (turning && turning.moved && work) writeDecor(work);
      if (turning) { turning = null; work = null; cv.classList.remove("turning"); return; }
      if (held && work) writeDecor(work);
      held = null; work = null; cv.classList.remove("holding");
      drag = null; cv.classList.remove("dragging", "panning");
    };
    // Stickers and figures dragged from the Personalizar panel land where they are dropped.
    const over = (e: DragEvent) => { if (editRef.current && e.dataTransfer?.types.includes(DND)) { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; } };
    const dropped = (e: DragEvent) => {
      const ed = editRef.current, what = e.dataTransfer?.getData(DND);
      if (!ed || !what) return;
      e.preventDefault();
      const [kind, id] = what.split("|");
      const [x, y] = local(e), d = decorRef.current.decor, nid = newId();
      if (kind === "sticker") {
        const at = faceAt(x, y) ?? { face: "front" as Face, u: 0, v: 0 }, m = 1 - 0.35;
        writeDecor({ ...d, stickers: [...d.stickers, { id: nid, sticker: id, face: at.face, u: clamp(at.u, -m, m), v: clamp(at.v, -m, m), rot: 0, size: 0.7 }] });
      } else {
        const [X, Z] = planeXZ(x, y);
        writeDecor({ ...d, figures: [...d.figures, { id: nid, figure: id, x: clamp(X, -0.8, 0.8), z: clamp(Z, -0.8, 0.8), rot: 0, size: 1 }] });
      }
      ed.onSelect([nid]);
    };
    cv.addEventListener("dragover", over);
    cv.addEventListener("drop", dropped);
    const wheel = (e: WheelEvent) => {
      e.preventDefault();
      stopCam();
      const r = cv.getBoundingClientRect(), mx = e.clientX - r.left, my = e.clientY - r.top;
      const z0 = view.zoom, z1 = Math.max(0.6, Math.min(6, z0 * Math.exp(-e.deltaY * 0.0015))), k = z1 / z0;
      const cx = cv.clientWidth / 2 + view.ox, cy = cv.clientHeight / 2 + view.oy;
      view.ox = mx - (mx - cx) * k - cv.clientWidth / 2;
      view.oy = my - (my - cy) * k - cv.clientHeight / 2;
      view.zoom = z1;
    };
    let menuFor: string | null = null;
    const menu = (e: MouseEvent) => {
      e.preventDefault();
      if (menuFor && editRef.current) editRef.current.onMenu(menuFor, e.clientX, e.clientY);
      menuFor = null;
    };
    cv.addEventListener("pointerdown", down);
    cv.addEventListener("pointermove", move);
    cv.addEventListener("pointerup", up);
    cv.addEventListener("pointercancel", up);
    // Released outside the cube (the panel is narrow and a turn goes wide): the window still hears it.
    window.addEventListener("pointerup", up);
    cv.addEventListener("wheel", wheel, { passive: false });
    cv.addEventListener("contextmenu", menu);
    cv.addEventListener("dblclick", reset);
    // The pressed wheel moves the cube instead of the browser's scrolling arrows.
    const noAutoScroll = (e: MouseEvent) => { if (e.button === 1) e.preventDefault(); };
    cv.addEventListener("mousedown", noAutoScroll);
    cv.addEventListener("auxclick", noAutoScroll);

    // Projection state for the current frame.
    let W = 0, H = 0, Sz = 1, CX = 0, CY = 0, cyw = 1, syw = 0, cpt = 1, spt = 0, T = 0, fan = 0, HA = 1, bootY = 9, scanY = -9, under = false;
    let ctx: CanvasRenderingContext2D = h;
    // Half the visible height of the canvas, in cube units at the normal zoom.
    let HALF = 2, HALFW = 1.55;
    let accent = "#7d9cf0", light = false, uiAccent = "#7d9cf0";
    const part = { cpu: accent, mem: accent, gpu: accent, disk: accent, board: accent };

    // Where the machine being drawn sits in the space and its size (the cube's own center is y = 1).
    const OBJ = { x: 0, y: 0, z: 0, s: 1 };
    let FADE = 1;
    const P = (x: number, y: number, z: number): V3 => {
      x = OBJ.x + x * OBJ.s; z = OBJ.z + z * OBJ.s; y = 1 + OBJ.y + (y - 1) * OBJ.s;
      const x1 = x * cyw - z * syw, z1 = x * syw + z * cyw, yy = y - 1, y2 = yy * cpt - z1 * spt, z2 = yy * spt + z1 * cpt;
      return [CX + x1 * Sz, CY - y2 * Sz, z2];
    };
    const vis = (nx: number, ny: number, nz: number) => ny * spt + (nx * syw + nz * cyw) * cpt > 0;
    // Where a screen point falls on a face of the glass (u, v from -1 to 1) or on the cube's top (x, z).
    const solve = (o: V3, a: V3, b: V3, x: number, y: number): V2 => {
      const ax = a[0] - o[0], ay = a[1] - o[1], bx = b[0] - o[0], by = b[1] - o[1], det = ax * by - ay * bx || 1e-9, dx = x - o[0], dy = y - o[1];
      return [(dx * by - dy * bx) / det, (ax * dy - ay * dx) / det];
    };
    function faceUV(f: Face, x: number, y: number): V2 {
      const F = FRAMES[f];
      return solve(P(...F.c), P(...add3(F.c, F.U, 1)), P(...add3(F.c, F.V, 1)), x, y);
    }
    function faceAt(x: number, y: number, prefer?: Face): { face: Face; u: number; v: number } | null {
      for (const f of prefer ? [prefer, ...FACE_LIST.filter((q) => q !== prefer)] : FACE_LIST) {
        if (!vis(...FRAMES[f].n)) continue;
        const [u, v] = faceUV(f, x, y);
        if (Math.abs(u) <= 1 && Math.abs(v) <= 1) return { face: f, u, v };
      }
      return null;
    }
    function planeXZ(x: number, y: number): V2 { return solve(P(0, 2, 0), P(1, 2, 0), P(0, 2, 1), x, y); }
    function pick(x: number, y: number): { kind: "sticker" | "figure" | "led"; id: string } | null {
      const d = work ?? decorRef.current.decor;
      for (let i = d.figures.length - 1; i >= 0; i--) {
        const f = d.figures[i], sc = f.size * FIG, h = figureHeight(f.figure) * sc;
        const a = P(f.x, 2, f.z), b = P(f.x, 2 + h, f.z), e = P(f.x + 0.3 * sc, 2, f.z);
        if (segDist(x, y, a, b) < Math.max(10, Math.hypot(e[0] - a[0], e[1] - a[1]))) return { kind: "figure", id: f.id };
      }
      for (let i = d.stickers.length - 1; i >= 0; i--) {
        const s = d.stickers[i];
        if (!vis(...FRAMES[s.face].n)) continue;
        const [u, v] = faceUV(s.face, x, y), h = s.size * 0.42;
        if (Math.abs(u - s.u) <= h && Math.abs(v - s.v) <= h) return { kind: "sticker", id: s.id };
      }
      // The LED strip, anywhere along it on a side in view.
      if (d.led) {
        const f = sideAt(x, y), top = ledTop(d.led.y);
        if (f) { const v = faceUV(f, x, y)[1]; if (v <= top + LED_STEP && v >= top - LED_STEP * 7) return { kind: "led", id: "led" }; }
      }
      return null;
    }
    /** The side face (not the top) under a screen point, if one is in view there. */
    function sideAt(x: number, y: number): Face | null {
      for (const f of ["front", "right", "back", "left"] as Face[]) {
        if (!vis(...FRAMES[f].n)) continue;
        const [u, v] = faceUV(f, x, y);
        if (Math.abs(u) <= 1 && Math.abs(v) <= 1.05) return f;
      }
      return null;
    }
    function moveHeld(x: number, y: number) {
      if (!held || !work) return;
      const id = held.id;
      if (held.group) {
        // The group moves by the dragged one's step, snapped to the cells; each keeps inside its face or the top.
        const G = held.group;
        let du = 0, dv = 0;
        if (G.face) { const [u, v] = faceUV(G.face, x, y); du = snap(u - G.u0); dv = snap(v - G.v0); }
        const [X, Z] = planeXZ(x, y), dx = snap(X - G.x0), dz = snap(Z - G.z0);
        work = {
          ...work,
          stickers: work.stickers.map((t) => { const s0 = G.st.get(t.id); if (!s0) return t; const m = 1 - t.size / 2; return { ...t, u: clamp(s0.u + du, -m, m), v: clamp(s0.v + dv, -m, m) }; }),
          figures: work.figures.map((f) => { const f0 = G.fg.get(f.id); if (!f0) return f; return { ...f, x: clamp(f0.x + dx, -0.875, 0.875), z: clamp(f0.z + dz, -0.875, 0.875) }; }),
        };
        return;
      }
      if (held.kind === "led") {
        // Up and down the glass: the strip follows the pointer on whichever side it is over.
        const f = sideAt(x, y);
        if (!f || !work.led) return;
        const raw = clamp(faceUV(f, x, y)[1] + held.dv, ledTop(0), ledTop(1));
        // The height settles every 5 %, so it is easy to line up with stickers.
        const top = ledTop(snap((raw - ledTop(0)) / (ledTop(1) - ledTop(0)), 0.05));
        work = { ...work, led: { ...work.led, y: (top - ledTop(0)) / (ledTop(1) - ledTop(0)) } };
        return;
      }
      if (held.kind === "figure") {
        const [X, Z] = planeXZ(x, y);
        work = { ...work, figures: work.figures.map((f) => (f.id === id ? { ...f, x: clamp(snap(X + held!.du), -0.875, 0.875), z: clamp(snap(Z + held!.dv), -0.875, 0.875) } : f)) };
        return;
      }
      const s = work.stickers.find((t) => t.id === id);
      if (!s) return;
      const at = faceAt(x, y, s.face);
      if (!at) return;
      // On another face the grab offset no longer means anything: the sticker centers on the pointer.
      if (at.face !== s.face) { held.du = 0; held.dv = 0; }
      const m = 1 - s.size / 2;
      work = { ...work, stickers: work.stickers.map((t) => (t.id === id ? { ...t, face: at.face, u: clamp(snap(at.u + held!.du), -m, m), v: clamp(snap(at.v + held!.dv), -m, m) } : t)) };
    }
    // How bright the hologram is at a height: built from the bottom up while starting, brighter where the scan passes.
    const amp = (y: number) => FADE * HA * Math.max(0, Math.min(1, (bootY - y) / 0.15)) * (1 + Math.max(0, 1 - Math.abs(y - scanY) / 0.18) * 0.6);
    const path = (pts: V3[], close: boolean) => { ctx.beginPath(); pts.forEach((p, i) => (i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))); if (close) ctx.closePath(); };
    const seg = (a: V3, b: V3, col: string, al: number, lw = 1.1) => {
      const k = amp((a[1] + b[1]) / 2) * al;
      if (k <= 0.004) return;
      const p = P(...a), q = P(...b);
      ctx.beginPath(); ctx.moveTo(p[0], p[1]); ctx.lineTo(q[0], q[1]);
      ctx.strokeStyle = rgba(col, k); ctx.lineWidth = lw; ctx.stroke();
    };
    const quad = (q3: V3[], col: string, fa: number, sa: number, lw = 1.1) => {
      const k = amp(q3.reduce((s, p) => s + p[1], 0) / q3.length);
      if (k <= 0.004) return;
      path(q3.map((p) => P(...p)), true);
      if (fa) { ctx.fillStyle = rgba(col, fa * k); ctx.fill(); }
      if (sa) { ctx.strokeStyle = rgba(col, sa * k); ctx.lineWidth = lw; ctx.stroke(); }
    };
    const rT = (x: number, y: number, z: number, w: number, d: number, col: string, fa: number, sa: number, lw?: number) =>
      quad([[x - w / 2, y, z - d / 2], [x + w / 2, y, z - d / 2], [x + w / 2, y, z + d / 2], [x - w / 2, y, z + d / 2]], col, fa, sa, lw);
    const lT = (x1: number, z1: number, x2: number, z2: number, y: number, col: string, al: number, lw?: number) => seg([x1, y, z1], [x2, y, z2], col, al, lw);
    const dot = (x: number, y: number, z: number, col: string, al: number, r = 0.006) => {
      const k = amp(y) * al;
      if (k <= 0.004) return;
      const p = P(x, y, z), s = Math.max(1, r * Sz * OBJ.s);
      ctx.fillStyle = rgba(col, k); ctx.fillRect(p[0] - s / 2, p[1] - s / 2, s, s);
    };
    const box = (x: number, y: number, z: number, w: number, hh: number, d: number, col: string, al = 1, fill = 0.18) => {
      const a = w / 2, b = d / 2, c: V3[] = [];
      for (const i of [-1, 1]) for (const j of [0, 1]) for (const k of [-1, 1]) c.push([x + i * a, y + j * hh, z + k * b]);
      const cd = P(x, y + hh / 2, z)[2];
      const faces: [V3, V3[]][] = [
        [[1, 0, 0], [[x + a, y, z - b], [x + a, y, z + b], [x + a, y + hh, z + b], [x + a, y + hh, z - b]]],
        [[-1, 0, 0], [[x - a, y, z - b], [x - a, y, z + b], [x - a, y + hh, z + b], [x - a, y + hh, z - b]]],
        [[0, 0, 1], [[x - a, y, z + b], [x + a, y, z + b], [x + a, y + hh, z + b], [x - a, y + hh, z + b]]],
        [[0, 0, -1], [[x - a, y, z - b], [x + a, y, z - b], [x + a, y + hh, z - b], [x - a, y + hh, z - b]]],
        [[0, 1, 0], [[x - a, y + hh, z - b], [x + a, y + hh, z - b], [x + a, y + hh, z + b], [x - a, y + hh, z + b]]],
        [[0, -1, 0], [[x - a, y, z - b], [x + a, y, z - b], [x + a, y, z + b], [x - a, y, z + b]]],
      ];
      for (const [n, q] of faces) if (vis(...n)) quad(q, col, fill * al * (n[1] ? 1 : 0.75), 0);
      for (let i = 0; i < 8; i++) for (let j = i + 1; j < 8; j++) {
        const p = c[i], q = c[j];
        if (Number(p[0] !== q[0]) + Number(p[1] !== q[1]) + Number(p[2] !== q[2]) !== 1) continue;
        const front = (P(...p)[2] + P(...q)[2]) / 2 >= cd - 0.001;
        seg(p, q, col, al * (front ? 1 : 0.3), front ? 1.3 : 0.8);
      }
    };
    const circ = (c: V3, u: V3, w: V3, r: number, a0: number, a1: number, n: number): V3[] => {
      const p: V3[] = [];
      for (let i = 0; i <= n; i++) {
        const a = a0 + ((a1 - a0) * i) / n, co = Math.cos(a) * r, si = Math.sin(a) * r;
        p.push([c[0] + u[0] * co + w[0] * si, c[1] + u[1] * co + w[1] * si, c[2] + u[2] * co + w[2] * si]);
      }
      return p;
    };
    const flat = (c: V3, r: number, a0 = 0, a1 = Math.PI * 2, n = 24) => circ(c, [1, 0, 0], [0, 0, 1], r, a0, a1, n);
    const line3 = (pts: V3[], col: string, al: number, lw = 1.1, fill = 0) => {
      const k = amp(pts[0][1]) * al;
      if (k <= 0.004) return;
      path(pts.map((p) => P(...p)), !!fill);
      if (fill) { ctx.fillStyle = rgba(col, fill * k); ctx.fill(); }
      ctx.strokeStyle = rgba(col, k); ctx.lineWidth = lw; ctx.stroke();
    };
    const cyl = (x: number, y: number, z: number, r: number, hh: number, col: string, al: number) => {
      line3(flat([x, y + hh, z], r, 0, Math.PI * 2, 14), col, al, 1, 0.2);
      line3(flat([x, y, z], r, 0, Math.PI * 2, 14), col, al * 0.4, 0.8);
      seg([x + r * cyw, y, z - r * syw], [x + r * cyw, y + hh, z - r * syw], col, al * 0.7);
      seg([x - r * cyw, y, z + r * syw], [x - r * cyw, y + hh, z + r * syw], col, al * 0.7);
    };
    let seed = 1;
    const rnd = () => (seed = (seed * 16807) % 2147483647) / 2147483647;
    const bright = (c: string, t: number) => mixHex(c, light ? "#000000" : "#ffffff", t);

    const pulses: { t: number; p: number; sp: number }[] = [];
    const board = (on: number, act: number) => {
      const col = part.board, y = 0.05;
      box(0, 0, 0, 1.78, 0.05, 1.78, col, 0.75, 0.1);
      for (const [a, b] of [[-0.82, -0.82], [0.82, -0.82], [-0.82, 0.82], [0.82, 0.82], [0, -0.82], [0, 0.82], [-0.82, 0], [0.82, 0]]) {
        line3(flat([a, y, b], 0.03, 0, Math.PI * 2, 14), col, 0.8);
        line3(flat([a, y, b], 0.016, 0, Math.PI * 2, 10), col, 0.6, 0.9);
      }
      for (const t of TRACES) for (let i = 1; i < t.length; i++) lT(t[i - 1][0], t[i - 1][1], t[i][0], t[i][1], y, col, 0.32, 0.9);
      // Data running along the traces, more of it and faster the busier the machine.
      if (on && Math.random() < 0.2 + act * 1.2) pulses.push({ t: Math.floor(Math.random() * TRACES.length), p: 0, sp: 0.5 + act * 1.8 });
      for (const u of pulses) {
        u.p += u.sp / 60;
        const tr = TRACES[u.t], L: number[] = [];
        let tot = 0;
        for (let i = 1; i < tr.length; i++) { const l = Math.hypot(tr[i][0] - tr[i - 1][0], tr[i][1] - tr[i - 1][1]); L.push(l); tot += l; }
        let d = u.p * tot;
        for (let i = 0; i < L.length; i++) {
          if (d <= L[i]) { const f = L[i] ? d / L[i] : 0; dot(tr[i][0] + (tr[i + 1][0] - tr[i][0]) * f, y + 0.002, tr[i][1] + (tr[i + 1][1] - tr[i][1]) * f, bright(accent, 0.5), 1, 0.012); break; }
          d -= L[i];
        }
      }
      for (let i = pulses.length - 1; i >= 0; i--) if (pulses[i].p > 1) pulses.splice(i, 1);
      seed = 11;
      for (let i = 0; i < 70; i++) { const x = -0.8 + rnd() * 1.6, z = -0.8 + rnd() * 1.6; if (Math.abs(x + 0.38) < 0.36 && Math.abs(z + 0.32) < 0.36) continue; dot(x, y + 0.001, z, col, 0.5, 0.008); }
      // Power stages around the socket, under finned heatsinks.
      for (let i = 0; i < 7; i++) { const x = -0.66 + i * 0.085; box(x, y, -0.76, 0.06, 0.06, 0.06, col, 0.85, 0.15); rT(x, y + 0.061, -0.76, 0.03, 0.03, col, 0, 0.5); }
      for (let i = 0; i < 6; i++) box(-0.76, y, -0.6 + i * 0.085, 0.06, 0.06, 0.06, col, 0.85, 0.15);
      box(-0.37, y + 0.06, -0.76, 0.62, 0.09, 0.09, col, 0.9, 0.14);
      for (let i = 0; i < 16; i++) seg([-0.67 + i * 0.04, y + 0.15, -0.8], [-0.67 + i * 0.04, y + 0.15, -0.72], col, 0.6);
      box(-0.76, y + 0.06, -0.36, 0.09, 0.09, 0.5, col, 0.9, 0.14);
      for (let i = 0; i < 12; i++) seg([-0.8, y + 0.15, -0.59 + i * 0.04], [-0.72, y + 0.15, -0.59 + i * 0.04], col, 0.6);
      // 8-pin processor power, rear ports, 24-pin power, SATA ports.
      box(-0.72, y, -0.86, 0.12, 0.05, 0.05, col, 0.9, 0.15);
      for (let i = 0; i < 4; i++) for (let j = 0; j < 2; j++) dot(-0.765 + i * 0.03, y + 0.051, -0.875 + j * 0.025, col, 0.9);
      box(-0.86, y, -0.2, 0.06, 0.22, 0.62, col, 0.85, 0.12);
      for (const [z, hh, w] of [[-0.44, 0.06, 0.08], [-0.3, 0.1, 0.12], [-0.12, 0.06, 0.1], [0.02, 0.12, 0.08]])
        quad([[-0.83, y + 0.04, z], [-0.83, y + 0.04, z + w], [-0.83, y + 0.04 + hh, z + w], [-0.83, y + 0.04 + hh, z]], col, 0.15, 0.85);
      box(0.84, y, -0.36, 0.05, 0.08, 0.26, col, 0.9, 0.15);
      for (let i = 0; i < 12; i++) for (let j = 0; j < 2; j++) dot(0.83 + j * 0.02, y + 0.081, -0.47 + i * 0.02, col, 0.9);
      for (const z of [0.42, 0.54]) for (const x of [0.82, 0.86]) box(x, y, z, 0.035, 0.05, 0.09, col, 0.85, 0.15);
      // Chipset heatsink, battery, BIOS chip, spare PCIe slot, M.2 drive under its heatsink.
      box(0.66, y, 0.72, 0.3, 0.07, 0.26, col, 0.95, 0.16);
      for (let i = 0; i < 9; i++) seg([0.53 + i * 0.032, y + 0.07, 0.6], [0.53 + i * 0.032, y + 0.07, 0.84], col, 0.7);
      rT(0.66, y + 0.071, 0.72, 0.12, 0.08, col, 0.15, 0.8);
      line3(flat([0.12, y + 0.03, 0.76], 0.07, 0, Math.PI * 2, 26), col, 1, 1.2, 0.15);
      line3(flat([0.12, y + 0.03, 0.76], 0.055, 0, Math.PI * 2, 22), col, 0.5, 0.9);
      box(0.12, y, 0.66, 0.03, 0.03, 0.04, col, 0.8, 0.1);
      box(-0.08, y, 0.58, 0.07, 0.015, 0.07, col, 0.95, 0.25);
      for (let i = 0; i < 4; i++) { lT(-0.115, 0.555 + i * 0.016, -0.13, 0.555 + i * 0.016, y + 0.005, col, 0.8); lT(-0.045, 0.555 + i * 0.016, -0.03, 0.555 + i * 0.016, y + 0.005, col, 0.8); }
      box(0.25, y, 0.62, 0.82, 0.035, 0.06, col, 0.9, 0.12);
      for (let i = 0; i < 20; i++) dot(-0.14 + i * 0.04, y + 0.036, 0.62, col, 0.7);
      box(0.3, y, 0.12, 0.62, 0.02, 0.13, col, 0.9, 0.12);
      box(0.28, y + 0.02, 0.12, 0.54, 0.04, 0.11, col, 0.95, 0.18);
      for (let i = 0; i < 12; i++) seg([0.03 + i * 0.045, y + 0.06, 0.07], [0.03 + i * 0.045, y + 0.06, 0.17], col, 0.6);
      box(0.6, y, 0.12, 0.03, 0.03, 0.03, col, 0.9, 0.2);
      for (const [a, b] of [[-0.25, 0.85], [-0.15, 0.85], [0.3, 0.86], [0.4, 0.86]]) box(a, y, b, 0.06, 0.04, 0.03, col, 0.8, 0.15);
      for (const [a, b] of [[-0.58, 0.86], [-0.5, 0.86], [-0.42, 0.86], [0.72, -0.84], [0.62, -0.84]]) cyl(a, y, b, 0.025, 0.07, col, 0.85);
      for (const [a, b] of [[0.5, -0.82], [-0.02, -0.82]]) { box(a, y, b, 0.07, 0.04, 0.03, col, 0.85, 0.15); for (let i = 0; i < 4; i++) dot(a - 0.025 + i * 0.017, y + 0.041, b, col, 0.9); }
      // Seen from below: the solder side, with the socket's backplate and the slots' pins.
      if (under) {
        const yb = 0;
        rT(-0.38, yb, -0.32, 0.48, 0.48, col, 0.08, 0.9, 1.3);
        line3(flat([-0.38, yb, -0.32], 0.14, 0, Math.PI * 2, 30), col, 0.6, 1);
        for (const [a, b] of [[-0.6, -0.54], [-0.16, -0.54], [-0.6, -0.1], [-0.16, -0.1]]) line3(flat([a, yb, b], 0.025, 0, Math.PI * 2, 10), col, 0.9, 1.1, 0.2);
        for (let i = 0; i < 18; i++) for (let j = 0; j < 18; j++) if ((i + j) % 2 === 0) dot(-0.56 + i * 0.021, yb, -0.5 + j * 0.021, col, 0.55);
        for (let s = 0; s < 8; s++) for (let i = 0; i < 24; i++) dot(0.22 + s * 0.088, yb, -0.68 + i * 0.027, col, 0.5);
        for (let i = 0; i < 36; i++) dot(-0.14 + i * 0.027, yb, 0.62, col, 0.55);
        seed = 21;
        for (let i = 0; i < 26; i++) { const a = [-0.8 + rnd() * 1.6, -0.8 + rnd() * 1.6], b = [a[0] + (rnd() - 0.5) * 0.8, a[1] + (rnd() - 0.5) * 0.8]; lT(a[0], a[1], b[0], a[1], yb, col, 0.3); lT(b[0], a[1], b[0], b[1], yb, col, 0.3); }
        rT(0.3, yb, 0.12, 0.5, 0.1, col, 0.05, 0.6);
        for (let i = 0; i < 16; i++) dot(0.08 + i * 0.03, yb, 0.12, col, 0.6);
      }
    };

    const cpu = (m: CubeMachine, on: number, act: number) => {
      const col = part.cpu, x = -0.38, z = -0.32, y = 0.05;
      box(x, y, z, 0.6, 0.02, 0.6, col, 0.9, 0.12);
      for (const [a, b] of [[x - 0.27, z - 0.27], [x + 0.27, z - 0.27], [x - 0.27, z + 0.27], [x + 0.27, z + 0.27]]) line3(flat([a, y + 0.021, b], 0.018, 0, 7, 8), col, 0.9, 1);
      quad([[x - 0.26, y + 0.03, z - 0.26], [x + 0.26, y + 0.03, z - 0.26], [x + 0.26, y + 0.03, z + 0.26], [x - 0.26, y + 0.03, z + 0.26]], col, 0, 0.9, 1.2);
      quad([[x - 0.21, y + 0.035, z - 0.26], [x + 0.21, y + 0.035, z - 0.26], [x + 0.21, y + 0.035, z - 0.21], [x - 0.21, y + 0.035, z - 0.21]], col, 0.1, 0.8);
      quad([[x - 0.21, y + 0.035, z + 0.21], [x + 0.21, y + 0.035, z + 0.21], [x + 0.21, y + 0.035, z + 0.26], [x - 0.21, y + 0.035, z + 0.26]], col, 0.1, 0.8);
      seg([x + 0.29, y + 0.03, z - 0.24], [x + 0.29, y + 0.03, z + 0.3], col, 1, 1.6);
      seg([x + 0.29, y + 0.03, z + 0.3], [x + 0.2, y + 0.03, z + 0.3], col, 1, 1.6);
      for (let i = 0; i < 12; i++) { const o = -0.22 + i * 0.04; dot(x + o, y + 0.022, z - 0.285, col, 0.8); dot(x + o, y + 0.022, z + 0.285, col, 0.8); dot(x - 0.285, y + 0.022, z + o, col, 0.8); }
      box(x, y + 0.02, z, 0.42, 0.03, 0.42, col, 1, 0.15);
      const yi = y + 0.05;
      quad([[x - 0.19, yi, z - 0.17], [x - 0.17, yi, z - 0.19], [x + 0.17, yi, z - 0.19], [x + 0.19, yi, z - 0.17], [x + 0.19, yi, z + 0.17], [x + 0.17, yi, z + 0.19], [x - 0.17, yi, z + 0.19], [x - 0.19, yi, z + 0.17]], col, 0.18, 1, 1.3);
      // One cell per thread given to the machine (up to 16), flickering faster the harder it works.
      const n = Math.min(16, Math.round(m.cores)), yt = yi + 0.001;
      for (let i = 0; i < 16; i++) {
        const u = -0.135 + (i % 4) * 0.09, w = -0.135 + Math.floor(i / 4) * 0.09, lit = i < n;
        const f = lit ? (on ? 0.5 + 0.5 * (0.5 + 0.5 * Math.sin(T * (2 + act * 12) + i * 1.7)) * Math.max(0.35, act) : 0.3) : 0;
        rT(x + u, yt, z + w, 0.074, 0.074, lit ? bright(col, 0.3) : col, lit ? f * 0.85 : 0, lit ? 1 : 0.4, 1);
        if (lit) { rT(x + u - 0.012, yt + 0.001, z + w - 0.012, 0.03, 0.03, col, 0, 0.6 * f, 0.8); lT(x + u + 0.012, z + w + 0.004, x + u + 0.03, z + w + 0.004, yt + 0.001, col, 0.5 * f); }
      }
      rT(x, yt, z + 0.17, 0.3, 0.012, col, 0.3, 0);
    };

    const ram = (m: CubeMachine, on: number, use: number) => {
      const col = part.mem, x0 = 0.2, z = -0.36, y = 0.05, k = Math.max(1, Math.min(8, Math.round(m.memoryGB / 4)));
      for (let i = 0; i < 8; i++) {
        const x = x0 + i * 0.088;
        box(x, y, z, 0.045, 0.045, 0.68, col, 0.6, 0.08);
        box(x, y + 0.045, z - 0.36, 0.05, 0.04, 0.04, col, 0.7, 0.15);
        box(x, y + 0.045, z + 0.36, 0.05, 0.04, 0.04, col, 0.7, 0.15);
        if (i >= k) continue;
        // A module per 4 GB: board, chips, heat spreader, gold contacts and a light bar that fills with use.
        const yy = y + 0.045, hh = 0.5, top = yy + hh;
        box(x, yy, z, 0.012, hh * 0.95, 0.62, col, 0.7, 0.1);
        box(x, yy + 0.09, z, 0.032, hh * 0.82, 0.64, col, 1, 0.16);
        for (const sx of [1, -1]) {
          if (!vis(sx, 0, 0)) continue;
          const X = x + sx * 0.017;
          for (let c = 0; c < 14; c++) if (c !== 6) seg([X, yy + 0.005, z - 0.29 + c * 0.042], [X, yy + 0.06, z - 0.29 + c * 0.042], bright(col, 0.2), 0.8, 1.2);
          const X2 = x + sx * 0.007;
          for (let c = 0; c < 4; c++) { const zz = z - 0.22 + c * 0.148; quad([[X2, yy + 0.06, zz - 0.05], [X2, yy + 0.06, zz + 0.05], [X2, yy + 0.09, zz + 0.05], [X2, yy + 0.09, zz - 0.05]], col, 0.15, 0.8); }
          quad([[X, yy + 0.18, z - 0.26], [X, yy + 0.18, z + 0.26], [X, yy + 0.34, z + 0.26], [X, yy + 0.34, z - 0.26]], col, 0.04, 0.55);
          for (let c = 0; c < 6; c++) seg([X, yy + 0.36, z - 0.28 + c * 0.11], [X, yy + 0.42, z - 0.24 + c * 0.11], col, 0.45);
          seg([X, yy + 0.2, z - 0.3], [X, yy + 0.38, z - 0.3], col, 0.5);
        }
        const lv = Math.max(0.03, use);
        quad([[x - 0.006, top, z - 0.3], [x + 0.006, top, z - 0.3], [x + 0.006, top, z - 0.3 + 0.6 * lv], [x - 0.006, top, z - 0.3 + 0.6 * lv]], bright(col, 0.35), on ? 0.95 : 0.3, on ? 1 : 0.3, 1.4);
        seg([x, top, z - 0.3], [x, top, z + 0.3], col, 0.5);
      }
    };

    const gpu = (m: CubeMachine, on: number, act: number) => {
      const col = part.gpu, x = 0.35, z = 0.32, y = 0.05, w = 1.0;
      box(x, y, z, w, 0.03, 0.08, col, 0.8, 0.12);
      for (let i = 0; i < 30; i++) dot(x - 0.46 + i * 0.032, y + 0.031, z, col, 0.7);
      const yy = y + 0.03, hh = 0.44, ym = yy + hh / 2, tt = yy + hh;
      box(x, yy, z - 0.07, w, hh, 0.02, col, 0.85, 0.12);
      for (let i = 0; i < 24; i++) dot(x - 0.45 + i * 0.04, yy + 0.012, z - 0.07, bright(col, 0.3), 0.9, 0.01);
      box(x, yy + 0.03, z + 0.01, w * 0.98, hh - 0.03, 0.14, col, 1, 0.15);
      box(x, yy + 0.03, z - 0.095, w * 0.98, hh - 0.03, 0.012, col, 0.9, 0.1);
      if (vis(0, 0, -1)) { const Z = z - 0.102; for (let r = 0; r < 6; r++) for (let c = 0; c < 16; c++) { const xx = x - 0.4 + c * 0.052, yv = yy + 0.12 + r * 0.045; seg([xx, yv, Z], [xx + 0.03, yv, Z], col, 0.45, 1.2); } }
      for (let i = 0; i < 40; i++) seg([x - 0.47 + i * 0.024, tt, z - 0.05], [x - 0.47 + i * 0.024, tt, z + 0.07], col, 0.4, 0.9);
      for (const o of [-0.36, -0.18, 0, 0.18]) { const pts: V3[] = []; for (let s = 0; s <= 10; s++) { const a = (s / 10) * Math.PI; pts.push([x + o, tt + 0.04 + Math.sin(a) * 0.05, z - Math.cos(a) * 0.05]); } line3(pts, bright(col, 0.25), 0.95, 2.2); }
      box(x + 0.32, tt, z + 0.04, 0.14, 0.05, 0.06, col, 1, 0.2);
      for (let i = 0; i < 6; i++) for (let j = 0; j < 2; j++) dot(x + 0.27 + i * 0.02, tt + 0.051, z + 0.03 + j * 0.02, col, 1);
      box(x - w / 2 - 0.01, yy - 0.02, z - 0.02, 0.012, hh + 0.06, 0.2, col, 1, 0.2);
      if (vis(-1, 0, 0)) for (const [yp, hp] of [[yy + 0.06, 0.07], [yy + 0.16, 0.07], [yy + 0.26, 0.07], [yy + 0.36, 0.05]])
        quad([[x - w / 2 - 0.017, yp, z - 0.07], [x - w / 2 - 0.017, yp, z + 0.03], [x - w / 2 - 0.017, yp + hp, z + 0.03], [x - w / 2 - 0.017, yp + hp, z - 0.07]], col, 0.2, 1);
      if (vis(0, 0, 1)) {
        const Z = z + 0.082;
        [-0.3, 0, 0.3].forEach((fx, fi) => {
          const c: V3 = [x + fx, ym, Z], U: V3 = [1, 0, 0], V: V3 = [0, 1, 0];
          quad([[c[0] - 0.15, ym - 0.17, Z], [c[0] + 0.15, ym - 0.17, Z], [c[0] + 0.15, ym + 0.17, Z], [c[0] - 0.15, ym + 0.17, Z]], col, 0, 0.35);
          line3(circ(c, U, V, 0.14, 0, Math.PI * 2, 36), col, 1, 1.4, 0.05);
          line3(circ(c, U, V, 0.125, 0, Math.PI * 2, 36), col, 0.4, 0.8);
          line3(circ(c, U, V, 0.04, 0, Math.PI * 2, 16), col, 1, 1.2, 0.3);
          line3(circ(c, U, V, 0.022, 0, Math.PI * 2, 12), col, 0.6, 1);
          for (let b = 0; b < 11; b++) {
            const a = fan * (fi % 2 ? -1 : 1) + (b * Math.PI * 2) / 11, pts: V3[] = [];
            for (let s = 0; s <= 5; s++) { const r = 0.042 + s * 0.017, aa = a + s * 0.12; pts.push([c[0] + Math.cos(aa) * r, c[1] + Math.sin(aa) * r, Z]); }
            line3(pts, col, 0.55 + 0.45 * act, 1.2);
          }
        });
        // The share of the GPU given to the machine, as a strip of ten lights.
        const lit = Math.round(m.gpuPercent / 10);
        for (let i = 0; i < 10; i++) {
          const xx = x - 0.45 + i * 0.09, o = i < lit;
          quad([[xx, yy + 0.05, Z], [xx + 0.075, yy + 0.05, Z], [xx + 0.075, yy + 0.065, Z], [xx, yy + 0.065, Z]], o ? bright(col, 0.35) : col, o ? (on ? 0.6 + 0.4 * act : 0.3) : 0, o ? 1 : 0.35);
        }
        seg([x - 0.47, tt - 0.02, Z], [x + 0.47, tt - 0.02, Z], col, 0.5);
      }
    };

    const disk = (m: CubeMachine, on: number, use: number) => {
      const col = part.disk, x = -0.55, z = 0.6, y = 0.05, w = 0.42, d = 0.5;
      box(x, y, z, w, 0.03, d, col, 0.8, 0.1);
      box(x, y + 0.03, z, w, 0.08, d, col, 1, 0.1);
      const yt = y + 0.11;
      for (const [a, b] of [[x - w / 2 + 0.03, z - d / 2 + 0.03], [x + w / 2 - 0.03, z - d / 2 + 0.03], [x - w / 2 + 0.03, z + d / 2 - 0.03], [x + w / 2 - 0.03, z + d / 2 - 0.03], [x - w / 2 + 0.03, z], [x + w / 2 - 0.03, z]]) {
        line3(flat([a, yt, b], 0.014, 0, Math.PI * 2, 10), col, 0.95, 1);
        lT(a - 0.008, b, a + 0.008, b, yt, col, 0.8);
      }
      const c: V3 = [x, yt, z + 0.06];
      line3(flat(c, 0.17, 0, Math.PI * 2, 48), col, 1, 1.3, 0.06);
      for (let i = 1; i < 6; i++) line3(flat(c, 0.04 + i * 0.022, 0, Math.PI * 2, 36), col, 0.25, 0.8);
      line3(flat(c, 0.04, 0, Math.PI * 2, 16), col, 1, 1.2, 0.25);
      for (let i = 0; i < 6; i++) { const a = (i / 6) * Math.PI * 2; dot(c[0] + Math.cos(a) * 0.026, yt, c[2] + Math.sin(a) * 0.026, col, 1, 0.01); }
      const sp = on ? T * (3 + use * 8) : 0;
      for (let i = 0; i < 4; i++) { const a = sp + (i * Math.PI) / 2; lT(c[0] + Math.cos(a) * 0.05, c[2] + Math.sin(a) * 0.05, c[0] + Math.cos(a) * 0.16, c[2] + Math.sin(a) * 0.16, yt, col, 0.4); }
      // Its size against 512 GB, as a ring around the platter.
      line3(flat([c[0], yt + 0.003, c[2]], 0.19, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(1, m.diskGB / 512), 48), bright(col, 0.35), on ? 1 : 0.3, 2.4);
      const px = x + 0.14, pz = z - 0.17;
      line3(flat([px, yt, pz], 0.035, 0, Math.PI * 2, 14), col, 1, 1.2, 0.2);
      const arm = on ? Math.sin(T * (2 + use * 12)) * (0.15 + 0.25 * use) : 0, ang = 2.2 + arm, ex = px + Math.cos(ang) * 0.24, ez = pz + Math.sin(ang) * 0.24;
      lT(px, pz, ex, ez, yt + 0.01, col, 1, 2);
      lT(px + 0.012, pz, ex, ez, yt + 0.01, col, 0.5, 1);
      rT(ex, yt + 0.01, ez, 0.02, 0.02, bright(col, 0.4), 0.8, 1);
      quad([[px + 0.02, yt, pz - 0.06], [px + 0.08, yt, pz - 0.06], [px + 0.1, yt, pz + 0.04], [px + 0.04, yt, pz + 0.06]], col, 0.15, 0.8);
      box(x, y + 0.03, z - d / 2 - 0.015, 0.18, 0.04, 0.03, col, 0.9, 0.2);
      for (let i = 0; i < 10; i++) dot(x - 0.08 + i * 0.018, y + 0.05, z - d / 2 - 0.031, col, 0.9);
      const q = P(x + 0.17, yt, z + 0.22);
      ctx.beginPath(); ctx.arc(q[0], q[1], Math.max(1.5, 0.012 * Sz), 0, 7);
      ctx.fillStyle = rgba(col, (on && Math.random() < 0.2 + use * 0.8 ? 1 : 0.15) * amp(yt)); ctx.fill();
    };

    // The serial plate on the board: the machine's name as its serial number, typed in letter by letter.
    let shown = plateName.current.toUpperCase(), typedAt = 0;
    const plate = (m: CubeMachine) => {
      const want = (plateName.current || "").toUpperCase();
      if (shown !== want && T - typedAt > 0.07) {
        typedAt = T;
        shown = want.startsWith(shown) ? want.slice(0, shown.length + 1) : shown.slice(0, -1);
      }
      const col = part.board, y = 0.051, x0 = 0.05, z0 = 0.445, w = 0.5, d = 0.13;
      rT(x0 + w / 2, y, z0 + d / 2, w, d, col, 0.07, 0.95, 1.2);
      const k = amp(y);
      if (k <= 0.004) return;
      // Text drawn on the board's plane: one canvas unit is a thousandth of the cube's side.
      const o = P(x0, y, z0), ux = P(x0 + 1, y, z0), vz = P(x0, y, z0 + 1), dpr = animDpr();
      ctx.save();
      ctx.setTransform(dpr * (ux[0] - o[0]) / 1000, dpr * (ux[1] - o[1]) / 1000, dpr * (vz[0] - o[0]) / 1000, dpr * (vz[1] - o[1]) / 1000, dpr * o[0], dpr * o[1]);
      ctx.textBaseline = "alphabetic";
      ctx.textAlign = "left";
      ctx.fillStyle = rgba(col, 0.6 * k);
      ctx.font = "500 13px ui-monospace, monospace";
      ctx.fillStyle = rgba(bright(col, 0.6), 0.95 * k);
      ctx.font = "700 26px ui-monospace, monospace";
      const caret = shown !== want && Math.floor(T * 3) % 2 ? "_" : "";
      ctx.fillText("S/N " + (shown || "—") + caret, 14, 56, w * 1000 - 28);
      ctx.fillStyle = rgba(col, 0.6 * k);
      ctx.font = "500 11px ui-monospace, monospace";
      ctx.fillText(t("{cores} HILOS · {ram} GB · GPU {gpu} % · {disk} GB", { cores: m.cores, ram: m.memoryGB, gpu: m.gpuPercent, disk: m.diskGB }), 14, 74);
      // A barcode made from the name, so every machine's is its own.
      const code = [...(shown || "X")].map((c) => c.charCodeAt(0));
      let bx = 14;
      ctx.fillStyle = rgba(col, 0.85 * k);
      for (let i = 0; bx < w * 1000 - 70; i++) { const v = (code[i % code.length] * (i + 3)) % 7, bw = v < 3 ? 2 : v < 5 ? 4 : 6; ctx.fillRect(bx, 84, bw, 34); bx += bw + 3; }
      ctx.strokeStyle = rgba(col, 0.8 * k);
      ctx.lineWidth = 2;
      for (const [a, b] of [[w * 1000 - 50, 84], [w * 1000 - 30, 84], [w * 1000 - 50, 104]]) ctx.strokeRect(a, b, 14, 14);
      ctx.restore();
    };

    // A neighbor machine, small and with fewer details: its board, processor, memory, graphics card, disk and cube.
    const lite = (m: CubeMachine) => {
      const col = accent, on = m.power !== "off";
      box(0, 0, 0, 1.78, 0.05, 1.78, col, 0.6, 0.06);
      box(-0.38, 0.05, -0.32, 0.46, 0.08, 0.46, col, 0.9, 0.18);
      const n = Math.min(16, m.cores);
      for (let i = 0; i < n; i++) rT(-0.38 - 0.135 + (i % 4) * 0.09, 0.131, -0.32 - 0.135 + Math.floor(i / 4) * 0.09, 0.07, 0.07, col, on ? 0.6 : 0.15, 0);
      const k = Math.max(1, Math.min(8, Math.round(m.memoryGB / 4)));
      for (let i = 0; i < k; i++) box(0.2 + i * 0.088, 0.05, -0.36, 0.03, 0.5, 0.6, col, 0.8, 0.14);
      box(0.35, 0.05, 0.32, 1, 0.47, 0.16, col, 0.9, 0.12);
      if (vis(0, 0, 1)) for (const fx of [-0.3, 0, 0.3]) line3(circ([0.35 + fx, 0.28, 0.401], [1, 0, 0], [0, 1, 0], 0.14, 0, Math.PI * 2, 20), col, 0.8, 1.1);
      box(-0.55, 0.05, 0.6, 0.42, 0.1, 0.5, col, 0.9, 0.1);
      line3(flat([-0.55, 0.151, 0.66], 0.17, 0, Math.PI * 2, 24), col, 0.8, 1.1);
      for (const [a, b] of EDGES) seg(a, b, on ? col : light ? "#9a978f" : "#8a8a8a", 0.9, 1.2);
    };

    // In the world of blocks the machine is built of bricks too: solid pieces lit by the world's sun, with studs on top,
    // instead of the hologram. Each piece keeps its place and size, so the cube reads the same.
    type Brick = { x: number; y: number; z: number; w: number; h: number; d: number; c: string; studs?: boolean; fan?: number };
    let SUN = ambientLight("blocks", false)!.dir;
    const brickFace = (col: string, n: V3, k: number) => shadeHex(col, (0.62 + 0.48 * Math.max(0, n[0] * SUN[0] + n[1] * SUN[1] + n[2] * SUN[2])) * k);
    const studDisc = (x: number, y: number, z: number, r: number, col: string) => {
      const top: V2[] = [], bot: V2[] = [];
      for (let i = 0; i < 12; i++) { const a = (i / 12) * Math.PI * 2, p = P(x + Math.cos(a) * r, y + r * 0.7, z + Math.sin(a) * r), q = P(x + Math.cos(a) * r, y, z + Math.sin(a) * r); top.push([p[0], p[1]]); bot.push([q[0], q[1]]); }
      const g2 = ctx;
      g2.beginPath(); bot.forEach((p, i) => (i ? g2.lineTo(p[0], p[1]) : g2.moveTo(p[0], p[1]))); g2.closePath(); g2.fillStyle = shadeHex(col, 0.7); g2.fill();
      // The side between: the two outlines joined at their widest points.
      g2.beginPath(); g2.moveTo(top[0][0], top[0][1]); g2.lineTo(bot[0][0], bot[0][1]); g2.lineTo(bot[6][0], bot[6][1]); g2.lineTo(top[6][0], top[6][1]); g2.fillStyle = shadeHex(col, 0.78); g2.fill();
      g2.beginPath(); top.forEach((p, i) => (i ? g2.lineTo(p[0], p[1]) : g2.moveTo(p[0], p[1]))); g2.closePath(); g2.fillStyle = shadeHex(col, 1.12); g2.fill();
    };
    const drawBricks = (listIn: Brick[], k: number, studs: boolean) => {
      // (the first brick in the list is the board)
      let list = listIn.slice();
      const g2 = ctx;
      // The board goes first (last when seen from below); the pieces on it, farthest first.
      const depth = (b: Brick) => P(b.x, b.y + b.h / 2, b.z)[2];
      const base = list.shift()!, rest2 = list.sort((a, b) => depth(a) - depth(b));
      list = under ? [...rest2, base] : [base, ...rest2];
      for (const b of list) {
        if (b.y > bootY) continue;
        const a = b.w / 2, c = b.d / 2, y0 = b.y, y1 = b.y + b.h;
        const faces: [V3, V3[]][] = [
          [[0, 1, 0], [[b.x - a, y1, b.z - c], [b.x + a, y1, b.z - c], [b.x + a, y1, b.z + c], [b.x - a, y1, b.z + c]]],
          [[1, 0, 0], [[b.x + a, y0, b.z - c], [b.x + a, y0, b.z + c], [b.x + a, y1, b.z + c], [b.x + a, y1, b.z - c]]],
          [[-1, 0, 0], [[b.x - a, y0, b.z - c], [b.x - a, y0, b.z + c], [b.x - a, y1, b.z + c], [b.x - a, y1, b.z - c]]],
          [[0, 0, 1], [[b.x - a, y0, b.z + c], [b.x + a, y0, b.z + c], [b.x + a, y1, b.z + c], [b.x - a, y1, b.z + c]]],
          [[0, 0, -1], [[b.x - a, y0, b.z - c], [b.x + a, y0, b.z - c], [b.x + a, y1, b.z - c], [b.x - a, y1, b.z - c]]],
          [[0, -1, 0], [[b.x - a, y0, b.z - c], [b.x + a, y0, b.z - c], [b.x + a, y0, b.z + c], [b.x - a, y0, b.z + c]]],
        ];
        g2.globalAlpha = FADE;
        for (const [n, q] of faces) {
          if (!vis(...n)) continue;
          g2.beginPath(); q.forEach((p, i) => { const s = P(...p); if (i) g2.lineTo(s[0], s[1]); else g2.moveTo(s[0], s[1]); }); g2.closePath();
          g2.fillStyle = brickFace(b.c, n, k); g2.fill();
          g2.strokeStyle = "rgba(0,0,0,.18)"; g2.lineWidth = 0.8; g2.stroke();
        }
        // A fan on the card's face: a round tile with blades that turn with the GPU's use.
        if (b.fan !== undefined && vis(0, 0, 1)) for (const fx of [-0.3, 0, 0.3]) {
          const cx = b.x + fx, cy = b.y + b.h / 2, cz = b.z + c + 0.004, r = Math.min(0.13, b.h * 0.4);
          const ring = circ([cx, cy, cz], [1, 0, 0], [0, 1, 0], r, 0, Math.PI * 2, 18).map((p) => P(...p));
          g2.beginPath(); ring.forEach((p, i) => (i ? g2.lineTo(p[0], p[1]) : g2.moveTo(p[0], p[1]))); g2.closePath(); g2.fillStyle = shadeHex("#1d2023", k); g2.fill();
          g2.strokeStyle = shadeHex("#5a6168", k); g2.lineWidth = 1.2;
          for (let q = 0; q < 4; q++) { const an = fan * (1 + b.fan * 6) + q * (Math.PI / 2) + fx, e = P(cx + Math.cos(an) * r * 0.85, cy + Math.sin(an) * r * 0.85, cz), o = P(cx, cy, cz); g2.beginPath(); g2.moveTo(o[0], o[1]); g2.lineTo(e[0], e[1]); g2.stroke(); }
        }
        if (studs && b.studs && vis(0, 1, 0) && Sz * OBJ.s > 60) {
          const step = 0.1, nx = Math.max(1, Math.round(b.w / step)), nz = Math.max(1, Math.round(b.d / step));
          if (nx * nz <= 400) for (let i = 0; i < nx; i++) for (let j = 0; j < nz; j++)
            studDisc(b.x - a + (i + 0.5) * (b.w / nx), y1, b.z - c + (j + 0.5) * (b.d / nz), 0.03, brickFace(b.c, [0, 1, 0], k));
        }
        g2.globalAlpha = 1;
      }
    };
    /** The machine as bricks: board, processor with its cooler, memory sticks, the graphics card with its fans, the disk
     *  and the apps as small bricks in their colors. `full` adds the studs (the one in front). */
    const brickMachine = (m: CubeMachine, on: number, act: number, full: boolean) => {
      const k = on ? 1 : 0.62, col = accent, list: Brick[] = [];
      // Real computer colors: a dark green board, silver and black parts; the machine's color only in small lights.
      list.push({ x: 0, y: 0, z: 0, w: 1.8, h: 0.06, d: 1.8, c: light ? "#3f7a4a" : "#2f5d3a", studs: true });
      list.push({ x: -0.38, y: 0.06, z: -0.32, w: 0.5, h: 0.04, d: 0.5, c: "#8f969c" });
      list.push({ x: -0.38, y: 0.1, z: -0.32, w: 0.4, h: 0.16, d: 0.4, c: "#c9ced2", studs: true });
      list.push({ x: -0.38, y: 0.26, z: -0.32, w: 0.1, h: 0.03, d: 0.1, c: on ? mixHex("#5a6168", col, 0.3 + act * 0.7) : "#5a6168" });
      const sticks = Math.max(1, Math.min(6, Math.round(m.memoryGB / 4)));
      for (let i = 0; i < sticks; i++) {
        list.push({ x: 0.2 + i * 0.088, y: 0.06, z: -0.36, w: 0.05, h: 0.44, d: 0.6, c: "#2b2f33" });
        list.push({ x: 0.2 + i * 0.088, y: 0.5, z: -0.36, w: 0.05, h: 0.06, d: 0.6, c: "#6b7278", studs: true });
      }
      if (m.gpuPercent > 0) {
        list.push({ x: 0.05, y: 0.06, z: 0.32, w: 0.12, h: 0.06, d: 0.16, c: "#2b2f33" }, { x: 0.65, y: 0.06, z: 0.32, w: 0.12, h: 0.06, d: 0.16, c: "#2b2f33" });
        list.push({ x: 0.35, y: 0.12, z: 0.32, w: 1.0, h: 0.42, d: 0.16, c: "#3a3f45", studs: true, fan: m.usage.gpu / 100 });
        list.push({ x: 0.35, y: 0.54, z: 0.32, w: 1.0, h: 0.04, d: 0.16, c: "#5a6168" });
        list.push({ x: -0.1, y: 0.58, z: 0.32, w: 0.06, h: 0.02, d: 0.06, c: on ? col : "#5a6168" });
      }
      list.push({ x: -0.55, y: 0.06, z: 0.6, w: 0.42, h: 0.12, d: 0.5, c: "#c9ced2", studs: true });
      const n = m.apps.length, size = Math.max(0.08, appSize(n) * 1.1);
      m.apps.forEach((id, i) => {
        const p = appSpot(i, n), y = p[1] + Math.sin(T * 1.1 + i * 1.7) * 0.035 * on;
        list.push({ x: p[0], y: y - size / 2, z: p[2], w: size, h: size, d: size, c: appColor(id), studs: true });
      });
      drawBricks(list, k, full);
    };
    /** The machine's screen as a mosaic of square tiles, in a frame of dark bricks. */
    const mosaic = document.createElement("canvas");
    mosaic.width = 32; mosaic.height = 18;
    const brickScreen = (x0: number, y0: number, sw: number, sh: number, alpha: number) => {
      const mg = mosaic.getContext("2d")!;
      mg.clearRect(0, 0, 32, 18);
      mg.fillStyle = light ? "#e9ecef" : "#15181b"; mg.fillRect(0, 0, 32, 18);
      mg.drawImage(screen, 0, 0, 32, 18);
      const g2 = ctx, f = Math.max(4, sw * 0.03);
      g2.globalAlpha = alpha;
      g2.fillStyle = "#24282c"; g2.fillRect(x0 - f, y0 - f, sw + f * 2, sh + f * 2);
      g2.save(); g2.imageSmoothingEnabled = false; g2.drawImage(mosaic, x0, y0, sw, sh); g2.restore();
      // The seams between tiles, and a shine on each so it reads as plastic.
      g2.strokeStyle = "rgba(0,0,0,.35)"; g2.lineWidth = 1;
      g2.beginPath();
      for (let i = 1; i < 32; i++) { const x = x0 + (i * sw) / 32; g2.moveTo(x, y0); g2.lineTo(x, y0 + sh); }
      for (let j = 1; j < 18; j++) { const y = y0 + (j * sh) / 18; g2.moveTo(x0, y); g2.lineTo(x0 + sw, y); }
      g2.stroke();
      g2.fillStyle = "rgba(255,255,255,.08)";
      for (let i = 0; i < 32; i++) for (let j = 0; j < 18; j++) g2.fillRect(x0 + (i * sw) / 32 + 1, y0 + (j * sh) / 18 + 1, Math.max(1, sw / 32 * 0.4), 1);
      g2.globalAlpha = 1;
    };

    const apps = (m: CubeMachine, on: number) => {
      const n = m.apps.length, size = appSize(n);
      m.apps.forEach((id, i) => {
        const p = appSpot(i, n), y = p[1] + Math.sin(T * 1.1 + i * 1.7) * 0.035 * on;
        box(p[0], y, p[2], size, size, size, appColor(id), 0.75, 0.22);
      });
    };

    // The machine's screen: a Windows desktop with its apps on the taskbar, or the Windows logo while it starts.
    // Redrawn at most 30 times a second, or at once when what it shows changes: its waves drift slowly, and redrawing
    // it on every frame was half of the hologram's GPU time (lab 041). The cube around it still moves every frame.
    let screenKey = "", screenT = -1;
    const drawScreen = (m: CubeMachine, bootF: number, landscape: false | "day" | "evening" | "night" = false) => {
      const key = `${bootF >= 1 ? 1 : bootF.toFixed(2)}|${landscape}|${accent}|${light}|${m.apps.join(",")}`;
      // The landscape is still: only a change redraws it.
      if (key === screenKey && (landscape || T - screenT < 1 / 30)) return;
      screenKey = key; screenT = T;
      const w = 480, hh = 270, col = (x: number) => rgba(accent, x);
      s2.clearRect(0, 0, w, hh);
      s2.fillStyle = col(0.07); s2.fillRect(0, 0, w, hh);
      if (landscape && bootF >= 1) {
        // A wallpaper with a landscape: sky, sun, mountains, hills and a lake, made for the tiles of the mosaic.
        // The same time of day as the world around: blue noon, orange evening, a night with stars and the moon.
        const L2 = landscape, night = L2 === "night", eve = L2 === "evening";
        const sky = s2.createLinearGradient(0, 0, 0, hh * 0.6);
        sky.addColorStop(0, night ? "#141c38" : eve ? "#5d5aa0" : "#5f9fd6"); sky.addColorStop(1, night ? "#33406a" : eve ? "#f4a462" : "#cfe4ef");
        s2.fillStyle = sky; s2.fillRect(0, 0, w, hh);
        if (night) { s2.fillStyle = "#ffffff"; for (let i = 0; i < 40; i++) s2.fillRect((i * 97) % w, (i * 53) % (hh * 0.5), 2, 2); }
        s2.fillStyle = night ? "#f1efe6" : eve ? "#ffcf7a" : "#ffe7a8"; s2.beginPath(); s2.arc(w * 0.74, eve ? hh * 0.5 : hh * 0.24, eve ? 30 : 22, 0, 7); s2.fill();
        s2.fillStyle = night ? "#3c4770" : eve ? "#ffd9c0" : "#ffffff"; for (const [cx, cy, cw] of [[90, 50, 70], [300, 36, 54], [400, 80, 40]]) { s2.fillRect(cx - cw / 2, cy, cw, 12); s2.fillRect(cx - cw / 4, cy - 8, cw / 2, 10); }
        const range = (base: number, amp: number, fr: number, ph: number, c: string) => { s2.beginPath(); s2.moveTo(0, hh); for (let x = 0; x <= w; x += 6) s2.lineTo(x, base - Math.abs(Math.sin(x * fr + ph)) * amp - Math.sin(x * fr * 2.3) * amp * 0.25); s2.lineTo(w, hh); s2.closePath(); s2.fillStyle = c; s2.fill(); };
        range(hh * 0.62, 70, 0.012, 0.4, night ? "#2a3352" : eve ? "#8a6f9a" : "#8aa6bf");
        s2.fillStyle = "#f1f5f8"; for (const px of [w * 0.18, w * 0.47]) { s2.beginPath(); s2.moveTo(px - 16, hh * 0.62 - 50); s2.lineTo(px, hh * 0.62 - 68); s2.lineTo(px + 16, hh * 0.62 - 50); s2.fill(); }
        range(hh * 0.7, 34, 0.02, 1.7, night ? "#22402c" : eve ? "#6a7a3e" : "#5f9a55");
        s2.fillStyle = night ? "#22345a" : eve ? "#d8895a" : "#4f93c4"; s2.fillRect(0, hh * 0.72, w, hh * 0.1);
        s2.fillStyle = night ? "#1d3424" : eve ? "#5a6a34" : "#4a8a44"; s2.fillRect(0, hh * 0.82, w, hh * 0.18);
        s2.fillStyle = "rgba(20,24,28,.75)"; s2.fillRect(0, hh - 28, w, 28);
        const icons = Math.min(m.apps.length, 10), startX = w / 2 - ((icons + 1) * 24) / 2;
        for (const [dx, dy] of [[-11, -11], [1, -11], [-11, 1], [1, 1]]) { s2.fillStyle = "#7db7f0"; s2.fillRect(startX + 12 + dx, hh - 14 + dy, 10, 10); }
        m.apps.slice(0, icons).forEach((id, i) => { s2.fillStyle = appColor(id); s2.fillRect(startX + 34 + i * 24, hh - 21, 14, 14); });
        s2.fillStyle = "#e9edf0"; s2.fillRect(w - 46, hh - 18, 32, 3); s2.fillRect(w - 40, hh - 12, 20, 3);
        return;
      }
      if (bootF < 1) {
        const k = Math.max(0, bootF * 1.5 - 0.2);
        for (const [dx, dy] of [[-22, -22], [2, -22], [-22, 2], [2, 2]]) { s2.fillStyle = col(0.9 * Math.min(1, k)); s2.fillRect(w / 2 + dx, hh / 2 - 20 + dy, 20, 20); }
        for (let i = 0; i < 5; i++) { const an = T * 5 - i * 0.5; s2.beginPath(); s2.arc(w / 2 + Math.cos(an) * 14, hh / 2 + 42 + Math.sin(an) * 14, 2.4, 0, 7); s2.fillStyle = col(0.9 - i * 0.15); s2.fill(); }
        return;
      }
      for (let i = 0; i < 7; i++) {
        s2.beginPath();
        for (let x = 0; x <= w; x += 8) { const y = 50 + i * 26 + Math.sin(x * 0.012 + T * 0.35 + i) * 14; x ? s2.lineTo(x, y) : s2.moveTo(x, y); }
        s2.strokeStyle = col(0.14); s2.lineWidth = 1.5; s2.stroke();
      }
      for (let i = 0; i < 4; i++) { s2.fillStyle = col(0.25); s2.fillRect(14, 14 + i * 50, 28, 28); s2.fillStyle = col(0.45); s2.fillRect(14, 46 + i * 50, 28, 3); }
      s2.fillStyle = col(0.22); s2.fillRect(0, hh - 28, w, 28);
      const icons = Math.min(m.apps.length, 10), startX = w / 2 - ((icons + 1) * 24) / 2;
      for (const [dx, dy] of [[-11, -11], [1, -11], [-11, 1], [1, 1]]) { s2.fillStyle = col(0.9); s2.fillRect(startX + 12 + dx, hh - 14 + dy, 10, 10); }
      m.apps.slice(0, icons).forEach((id, i) => { s2.fillStyle = rgba(appColor(id), 0.85); s2.fillRect(startX + 34 + i * 24, hh - 21, 14, 14); });
      s2.fillStyle = col(0.8); s2.fillRect(w - 46, hh - 18, 32, 3); s2.fillRect(w - 40, hh - 12, 20, 3);
    };

    let arcs: { a: V3; b: V3; life: number; j: number; w: number; i: number; local?: boolean; p?: V2[] }[] = [];
    let outside: { x: number; y: number; vx: number; vy: number; life: number; hit: boolean }[] = [];
    let motes: { x: number; y: number; z: number; s: number }[] = [];
    let frame = 0, last = performance.now(), visible = true;
    let scanPattern: CanvasPattern | null = null;
    const css = getComputedStyle(cv);

    // Where each piece sits and the angle that shows it best.
    const SHOTS: Record<string, Omit<Shot, "hold">> = {
      cpu: { p: [-0.38, 0.1, -0.32], zoom: 2.6, yaw: 0.55, pitch: 0.95 },
      mem: { p: [0.5, 0.35, -0.36], zoom: 2.2, yaw: 1.35, pitch: 0.55 },
      gpu: { p: [0.35, 0.3, 0.34], zoom: 2.1, yaw: 0.3, pitch: 0.3 },
      disk: { p: [-0.55, 0.12, 0.6], zoom: 2.8, yaw: 0.45, pitch: 0.85 },
      cleanup: { p: [0, 1, 0], zoom: 0.85, yaw: 0, pitch: 0.45 },
      plate: { p: [0.3, 0.05, 0.51], zoom: 5.2, yaw: 0, pitch: 1.42 },
    };
    const near = (target: number, cur: number) => cur + ((((target - cur) % (Math.PI * 2)) + Math.PI * 3) % (Math.PI * 2)) - Math.PI;
    const shotFor = (part: string): Omit<Shot, "hold"> => {
      if (part.startsWith("app:")) { const spot = appSpot(Number(part.slice(4)), data.current.apps.length); return { p: spot, zoom: 3, yaw: view.yaw, pitch: 0.45 }; }
      if (part === "cleanup") return { ...SHOTS.cleanup, yaw: view.yaw + 0.7 };
      return SHOTS[part];
    };
    const takeRequests = () => {
      const list = requests.current.splice(0);
      if (!list.length) return;
      const parts = [...new Set(list.flat())];
      idleSince = performance.now();
      if (!cam.home) cam.home = { yaw: view.yaw, pitch: view.pitch, zoom: view.zoom, ox: view.ox, oy: view.oy };
      view.vy = view.vp = 0;
      cam.back = 0;
      if (parts.length === 1) {
        // One piece: a close-up that holds while it keeps changing (a slider being dragged), then eases back.
        const s = shotFor(parts[0]);
        const same = cam.shots.length === 1 && cam.shots[0].p === s.p;
        cam.shots = [{ ...s, yaw: near(s.yaw, view.yaw), hold: 1.6 }];
        if (!same) { cam.i = 0; cam.t = 0; } else cam.t = Math.min(cam.t, 0.4);
        cam.k = 5;
      } else {
        // Several at once: a quick sequence around the cube, each piece from its own side, the hologram rebuilding,
        // then a wide turn before going back.
        let yaw = view.yaw;
        cam.shots = parts.map((p, i) => { const s = shotFor(p); yaw = near(s.yaw + (i % 2 ? 0.45 : -0.45), yaw); return { ...s, yaw, zoom: s.zoom * 0.9, hold: 0.75 }; });
        cam.shots.push({ p: [0, 1, 0], zoom: 0.95, yaw: yaw + 1.1, pitch: 0.5, hold: 0.9 });
        cam.i = 0; cam.t = 0; cam.k = 7; cam.rebuild = 0;
      }
    };
    // How far into the constellation the space is: 0 with this machine in front, 1 at rest among the others.
    let rest = 0;
    const stepCamera = (dt: number) => {
      // A fixed view: straight to it and stay there (zoom and moving it around still work).
      const fixed = editRef.current?.view;
      if (fixed) {
        const v = VIEWS[fixed], b = reduced ? 1 : 1 - Math.exp(-dt * 7);
        cam.shots = []; cam.home = null; cam.back = 0; rest += (0 - rest) * b;
        view.vy = 0; view.vp = 0;
        view.yaw += (near(v.yaw, view.yaw) - view.yaw) * b; view.pitch += (v.pitch - view.pitch) * b;
        idleSince = performance.now();
        return;
      }
      if (reduced) { requests.current.length = 0; return; }
      const idleFor = (performance.now() - idleSince) / 1000;
      const wantRest = !drag && !held && !editRef.current?.selected.length && !editRef.current?.holdStill && !cam.shots.length && !(cam.home && cam.back > 0) && idleFor > 8 && space.current.others.length > 0 ? 1 : 0;
      rest += (wantRest - rest) * (1 - Math.exp(-dt * (wantRest ? 0.8 : 2.2)));
      takeRequests();
      const a = 1 - Math.exp(-dt * cam.k);
      const base = Sz / view.zoom || Math.min(W / 3.1, H / 3.75);
      if (cam.shots.length) {
        const s = cam.shots[cam.i];
        if (cam.t === 0) burst(s.p);
        const cy = Math.cos(s.yaw), sy = Math.sin(s.yaw), cp = Math.cos(s.pitch), sp = Math.sin(s.pitch);
        const x1 = s.p[0] * cy - s.p[2] * sy, z1 = s.p[0] * sy + s.p[2] * cy, y2 = (s.p[1] - 1) * cp - z1 * sp;
        const tox = -x1 * base * s.zoom, toy = y2 * base * s.zoom;
        view.yaw += (s.yaw - view.yaw) * a; view.pitch += (s.pitch - view.pitch) * a; view.zoom += (s.zoom - view.zoom) * a;
        view.ox += (tox - view.ox) * a; view.oy += (toy - view.oy) * a;
        cam.t += dt;
        if (cam.t > s.hold) { cam.i++; cam.t = 0; if (cam.i >= cam.shots.length) { cam.shots = []; cam.back = 0.001; } }
      } else if (!cam.home && !drag && rest > 0.02) {
        // At rest the camera steps back so the whole constellation fits, and slowly turns around it.
        const b = 1 - Math.exp(-dt * 1.2);
        view.yaw += dt * 0.12 * rest; view.pitch += (0.5 - view.pitch) * b;
        view.zoom += (1 + (restZoom(space.current.others.length) - 1) * rest - view.zoom) * b; view.ox += -view.ox * b; view.oy += -view.oy * b;
      } else if (!cam.home && !drag && !editRef.current?.selected.length && !editRef.current?.holdStill && performance.now() - idleSince > 4000) {
        // (Never while something is picked or being decorated: the cube stays where the person left it.)
        // Back to the first view: centered, its size, its angle (the nearest turn of it, so it never spins around).
        const b = 1 - Math.exp(-dt * 1.8);
        view.yaw += (near(START_YAW, view.yaw) - view.yaw) * b; view.pitch += (near(START_PITCH, view.pitch) - view.pitch) * b;
        view.zoom += (1 - view.zoom) * b; view.ox += -view.ox * b; view.oy += -view.oy * b;
      } else if (cam.home && cam.back > 0) {
        const hm = cam.home, b = 1 - Math.exp(-dt * 3.5);
        view.yaw += (hm.yaw - view.yaw) * b; view.pitch += (hm.pitch - view.pitch) * b; view.zoom += (hm.zoom - view.zoom) * b;
        view.ox += (hm.ox - view.ox) * b; view.oy += (hm.oy - view.oy) * b;
        cam.back += dt;
        if (cam.back > 2) { Object.assign(view, hm); stopCam(); }
      }
    };
    // A few bolts to the piece the camera goes to.
    const burst = (p: V3) => {
      if (data.current.power === "off") return;
      for (let i = 0; i < 4; i++) arcs.push({ a: ELECTRODES[i], b: [p[0] + (Math.random() - 0.5) * 0.2, p[1], p[2] + (Math.random() - 0.5) * 0.2], life: 0.18 + Math.random() * 0.15, j: 0, w: 1.6, i: 1 });
    };

    // Camera space to world space (the inverse of P's rotation), to keep neighbors in the same corners of the view.
    const fromView = (x1: number, y2: number, z2: number): V3 => {
      const yy = y2 * cpt + z2 * spt, z1 = -y2 * spt + z2 * cpt;
      return [x1 * cyw + z1 * syw, yy, -x1 * syw + z1 * cyw];
    };
    const SLOTS: [number, number][] = [[-1.3, -0.6], [1.3, -0.75], [-1.35, 0.7], [1.35, 0.5], [-1.2, -1.45], [1.2, -1.5]];
    type Spot = { x: number; y: number; z: number; s: number };
    // Where every machine is: this one in front and the others small behind it, or all of them as a constellation.
    const layout = (count: number): Spot[] => {
      const all: Spot[] = [];
      const n = count + 1, R = ringRadius(count), e = rest * rest * (3 - 2 * rest);
      const alive = Math.min(1, Math.max(0, (performance.now() - idleSince) / 1000 - 4));
      for (let i = 0; i < n; i++) {
        const a = (i / n) * Math.PI * 2 + 0.5, bob = Math.sin(T * 0.9 + i * 1.9) * 0.08;
        const star: Spot = { x: Math.cos(a) * R * (i ? 1 : 0.35), y: Math.sin(i * 1.7) * 1.2 + bob, z: Math.sin(a) * R * (i ? 1 : 0.35), s: i ? 0.5 : 0.62 };
        let front: Spot;
        // Left alone, the machine floats a little, as if it breathed.
        if (i === 0) front = { x: 0, y: Math.sin(T * 1.2) * 0.04 * alive, z: 0, s: 1 };
        else {
          // In a row under the cube when the canvas is tall enough, otherwise small at its sides.
          let sx: number, sy: number;
          const j = i - 1;
          // A wide canvas (Home) has room at the sides: right and left of the cube, one under another.
          if (HALFW > 2.7) { const row = Math.floor(j / 2); sx = (j % 2 ? -1 : 1) * Math.min(HALFW - 0.8, 2.5); sy = 0.95 - row * 1.0; }
          else if (HALF > 2.4) { const row = Math.floor(j / 3), inRow = Math.min(3, count - row * 3); sx = (j % 3 - (inRow - 1) / 2) * 0.95; sy = -1.95 - row * 0.85; }
          else [sx, sy] = SLOTS[(i - 1) % SLOTS.length];
          const w = fromView(sx, sy, -3);
          front = { x: w[0], y: w[1], z: w[2], s: HALFW > 2.7 ? 0.36 : HALF > 2.4 ? 0.3 : 0.24 };
        }
        all.push({ x: front.x + (star.x - front.x) * e, y: front.y + (star.y - front.y) * e, z: front.z + (star.z - front.z) * e, s: front.s + (star.s - front.s) * e });
      }
      // Swapping: this machine rises from the place the previous one goes to, and the previous one sinks into it.
      if (swap.from >= 0 && swap.t < 1) {
        const k = swap.from + 1, e2 = swap.t * swap.t * (3 - 2 * swap.t), slot = all[k], home = all[0];
        const mix = (a: Spot, b: Spot, t: number): Spot => ({ x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t, s: a.s + (b.s - a.s) * t });
        all[0] = mix(slot, home, e2);
        all[k] = mix(home, slot, e2);
      }
      return all;
    };

    const draw = (now: number) => {
      const m = data.current, perPart = colors.current;
      // Up to 0.1 s: at 15 frames a second a frame is 67 ms, and a lower clamp slowed the motion down.
      const dt = Math.min(0.1, (now - last) / 1000);
      last = now;
      T += reduced ? 0 : dt;
      const dpr = animDpr();
      W = cv.clientWidth; H = cv.clientHeight;
      if (!W || !H) return;
      // Each layer checked on its own: a remount keeps the canvas's size but starts a new hologram layer.
      const pw = Math.round(W * dpr), ph = Math.round(H * dpr);
      if (cv.width !== pw || cv.height !== ph) { cv.width = pw; cv.height = ph; }
      if (holo.width !== pw || holo.height !== ph) { holo.width = pw; holo.height = ph; }
      light = document.documentElement.dataset.theme === "light";
      // The machine's own color, when it has one, instead of the accent.
      uiAccent = css.getPropertyValue("--accent").trim() || "#7d9cf0";
      accent = colorOfDecor(decorRef.current.decor, light) ?? uiAccent;
      const per = (v: string) => css.getPropertyValue(v).trim() || accent;
      // The whole hologram in the accent color; `perPart` paints each piece in its resource color instead.
      part.cpu = perPart ? per(PART.cpu) : accent; part.mem = perPart ? per(PART.mem) : accent;
      part.gpu = perPart ? per(PART.gpu) : accent; part.disk = perPart ? per(PART.disk) : accent;
      part.board = accent;
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, W, H);
      if (!drag) { view.yaw += view.vy; view.pitch += view.vp; view.vy *= 0.92; view.vp *= 0.92; }
      const on = m.power === "off" ? 0 : 1;
      const bootF = m.power === "starting" ? Math.min(1, ((T % 5) / 4)) : 1;
      const U = { cpu: m.usage.cpu / 100, gpu: m.usage.gpu / 100, mem: m.usage.mem / 100, disk: m.usage.disk / 100 };
      const act = on * Math.max(U.cpu, U.gpu) * bootF;
      fan += on ? (0.5 + U.gpu * 10) * dt : 0;
      stepCamera(dt);
      // A new decoration to show: the same quick turn as switching machines, with the hologram rebuilding.
      if (spins.current !== spun) { spun = spins.current; swap.t = 0; swap.started = false; swap.yaw = view.yaw + Math.PI * 1.1; }
      if (swap.t < 1) {
        // Quick, like a cut in an action scene: the camera whips around while the machines trade places, with a
        // short push in, and the arriving hologram builds fast.
        if (!swap.started) { swap.started = true; cam.rebuild = 0; cam.rebuildSpeed = 3.2; }
        swap.t = Math.min(1, swap.t + dt / 0.6);
        const out = 1 - Math.pow(1 - swap.t, 3);
        view.yaw = swap.yaw - (1 - out) * Math.PI * 1.1;
        view.zoom = 1 + Math.sin(swap.t * Math.PI) * 0.18;
        if (swap.t === 1) view.zoom = 1;
      }
      // Centered in the part of the canvas on screen: a tall one that starts low on the page still shows the whole cube.
      const flying = !!arrive && arrive.k < 1;
      // While flying, the place is worked out for the box it lands in.
      const rect = flying ? arrive!.box : cv.getBoundingClientRect();
      const bw = rect.width, bh = rect.height;
      const top = Math.max(0, -rect.top), bottom = Math.min(bh, window.innerHeight - rect.top), seen = Math.max(bh * 0.4, bottom - top);
      const mid = bottom - top > bh * 0.4 ? (top + bottom) / 2 : bh / 2;
      Sz = Math.min(bw / 3.1, seen / 3.75) * view.zoom;
      HALF = seen / 2 / (Sz / view.zoom);
      HALFW = bw / 2 / (Sz / view.zoom); CX = bw / 2 + view.ox; CY = mid + view.oy;
      if (flying) {
        // By the clock, not by frames: a slow first frame on the new page doesn't make the flight drag.
        arrive.k = Math.min(1, (now - arrive.t0) / ARRIVE_MS);
        const e = 1 - Math.pow(1 - arrive.k, 3);
        CX = arrive.x + (rect.left + CX - arrive.x) * e;
        CY = arrive.y + (rect.top + CY - arrive.y) * e;
        Sz = arrive.s + (Sz - arrive.s) * e;
        if (arrive.k >= 1) {
          if (arrive.style === null) cv.removeAttribute("style"); else cv.setAttribute("style", arrive.style);
          CX -= rect.left; CY -= rect.top;
          scene.k = 0;
        }
      } else if (landed < 1) landed = Math.min(1, landed + dt / 0.45);
      if (travel && decorRef.current.owner && !flying) lastCube.set(decorRef.current.owner, { x: rect.left + CX, y: rect.top + CY, s: Sz, t: performance.now(), canvas: cv });
      cyw = Math.cos(view.yaw); syw = Math.sin(view.yaw); cpt = Math.cos(view.pitch); spt = Math.sin(view.pitch);
      under = vis(0, -1, 0);
      // The place around the machines, drawn with the same camera; a new one fades in over the last.
      if (place.current !== scene.cur) { scene.prev = scene.cur; scene.cur = place.current; scene.k = 0; }
      scene.k = Math.min(1, scene.k + (reduced ? 1 : dt / 0.7));
      if (scene.k >= 1) scene.prev = null;
      const av = { g, W, H, T, dt, yaw: view.yaw, pitch: view.pitch, Sz, CX, CY, light, accent: uiAccent, reduced, space: labels.current.space, machine: labels.current.machine, time: timeRef.current };
      if (scene.prev && hasScene(scene.prev) && !flying) drawAmbient(scene.prev, av, stateOf(scene.prev), 1);
      const fadeIn = scene.prev && hasScene(scene.prev) ? scene.k * scene.k * (3 - 2 * scene.k) : scene.k;
      if (!flying) drawAmbient(scene.cur, av, stateOf(scene.cur), fadeIn);
      const plain = !hasScene(scene.cur);
      const sp = space.current, spots = layout(sp.others.length);
      const setObj = (i: number) => Object.assign(OBJ, spots[i]);
      // In a world, each machine lights the ground under it with its hologram and casts its shadow away from the light.
      const lit = ambientLight(scene.cur, light, timeRef.current);
      if (scene.cur === "blocks" && lit) SUN = lit.dir;
      if (lit && !flying) {
        const keep = { ...OBJ };
        Object.assign(OBJ, { x: 0, y: 0, z: 0, s: 1 });
        const L = lit.dir, count = Math.min(sp.others.length, MAX_NEIGHBORS);
        for (let i = 0; i <= count; i++) {
          const S = spots[i];
          if (!S) continue;
          const pw = i === 0 ? m.power : sp.others[i - 1].machine.power, col = i === 0 ? accent : decorColor(sp.others[i - 1].name, light) ?? uiAccent;
          // The shadow: the glass lets light through, so what darkens the floor is what is inside, the board and its
          // pieces (the lower part of the cube), pushed down along the light.
          const pts: V2[] = [];
          for (const cx of [-0.9, 0.9]) for (const cy of [0, 0.6]) for (const cz of [-0.9, 0.9]) {
            const wx = S.x + cx * S.s, wy = 1 + S.y + (cy - 1) * S.s, wz = S.z + cz * S.s, t = (wy - FLOOR) / L[1];
            const q = P(wx - L[0] * t, FLOOR, wz - L[2] * t);
            pts.push([q[0], q[1]]);
          }
          const hp2 = hull(pts);
          g.beginPath(); hp2.forEach((q, k) => (k ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1]))); g.closePath();
          g.globalAlpha = lit.alpha * 0.75 * fadeIn * (i === 0 ? 1 : 0.7); g.fillStyle = lit.color; g.fill();
          // The hologram's light on the floor, a soft pool in the machine's color while it is on.
          if (pw !== "off") {
            const o = P(S.x, FLOOR, S.z), ex = P(S.x + 1, FLOOR, S.z), ez = P(S.x, FLOOR, S.z + 1);
            g.save();
            g.transform(ex[0] - o[0], ex[1] - o[1], ez[0] - o[0], ez[1] - o[1], o[0], o[1]);
            const rr = 2.2 * S.s, gr = g.createRadialGradient(0, 0, 0, 0, 0, rr);
            gr.addColorStop(0, rgba(col, light ? 0.22 : 0.3)); gr.addColorStop(0.5, rgba(col, light ? 0.08 : 0.12)); gr.addColorStop(1, rgba(col, 0));
            g.globalAlpha = fadeIn; g.fillStyle = gr; g.fillRect(-rr, -rr, rr * 2, rr * 2);
            g.restore();
          }
        }
        g.globalAlpha = 1;
        Object.assign(OBJ, keep);
      }
      setObj(0);
      bootY = on ? (m.power === "starting" ? bootF * 2.6 - 0.1 : 9) : 9;
      // A profile rebuilds the hologram from the bottom up while the camera runs through its pieces.
      if (cam.rebuild >= 0) { cam.rebuild += dt * cam.rebuildSpeed; if (on) bootY = Math.min(bootY, cam.rebuild * 2.2 - 0.1); if (cam.rebuild > 1.4) { cam.rebuild = -1; cam.rebuildSpeed = 1; } }
      HA = on ? 0.94 + Math.random() * 0.06 : 0.14;
      scanY = on && !reduced ? ((T * 0.5) % 2.4) - 0.2 : -9;
      const ink = light ? "#1c1b18" : "#ebe8e1";
      const glass = (a: number) => rgba(ink, a);

      ctx = g;
      const gpoly = (pts: V3[], fill?: string) => { g.beginPath(); pts.forEach((p, i) => (i ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1]))); g.closePath(); if (fill) { g.fillStyle = fill; g.fill(); } };
      for (const [n, q] of CUBE_FACES) if (!vis(...n)) gpoly(q.map((p) => P(...p)), glass(0.012));
      const D = work ?? decorRef.current.decor;
      drawStickers(D, false);
      if (under) drawFigures(D);
      const hp = hull(CORNERS.map((c) => { const p = P(...c); return [p[0], p[1]] as V2; }));
      // What the cleanup keeps out arrives from outside and bounces off the glass.
      if (on && !reduced && rest < 0.1 && outside.length < m.removed && Math.random() < 0.05) {
        const sd = Math.floor(Math.random() * 4);
        const p: V2 = sd === 0 ? [-10, Math.random() * H] : sd === 1 ? [W + 10, Math.random() * H] : sd === 2 ? [Math.random() * W, -10] : [Math.random() * W, H + 10];
        const L = Math.hypot(W / 2 - p[0], H / 2 - p[1]);
        outside.push({ x: p[0], y: p[1], vx: ((W / 2 - p[0]) / L) * 45, vy: ((H / 2 - p[1]) / L) * 45, life: 1, hit: false });
      }
      for (const o of outside) {
        o.x += o.vx * dt; o.y += o.vy * dt;
        if (!o.hit && inHull(hp, o.x, o.y)) { o.hit = true; o.vx *= -1.2; o.vy *= -1.2; }
        if (o.hit) o.life -= dt * 0.9;
        g.globalAlpha = Math.max(0, o.life) * 0.6;
        g.beginPath(); g.roundRect(o.x - 7, o.y - 7, 14, 14, 3); g.fillStyle = per("--pick-bg"); g.fill();
        g.beginPath(); g.moveTo(o.x - 3, o.y - 3); g.lineTo(o.x + 3, o.y + 3); g.moveTo(o.x + 3, o.y - 3); g.lineTo(o.x - 3, o.y + 3);
        g.strokeStyle = glass(0.5); g.lineWidth = 1.2; g.stroke();
        g.globalAlpha = 1;
      }
      outside = outside.filter((o) => o.life > 0 && o.x > -40 && o.x < W + 40 && o.y > -40 && o.y < H + 40);

      // The hologram goes on its own layer: added light in dark, plain ink in light, then cut into scan lines.
      ctx = h;
      h.setTransform(dpr, 0, 0, dpr, 0, 0);
      h.globalCompositeOperation = "source-over";
      h.clearRect(0, 0, W, H);
      h.globalCompositeOperation = light ? "source-over" : "lighter";
      // In front, only as many neighbors as the layout has room for; at rest, all of them join the constellation.
      const room = HALFW > 2.7 ? 6 : HALF > 2.4 ? 6 : 4;
      // In the world of blocks the machines are built of bricks, drawn solid under the glass instead of as a hologram.
      const bricks = scene.cur === "blocks";
      if (bricks) ctx = g;
      sp.others.forEach((o, i) => { if (flying || (i >= room && rest < 0.05)) return; setObj(i + 1); FADE = (o.machine.power === "off" ? 0.5 : 0.8) * (0.55 + 0.45 * rest) * (i >= room ? rest : 1) * landed; if (i === swap.from && swap.t < 1) FADE += (1 - FADE) * (1 - swap.t); const keep = accent; accent = decorColor(o.name, light) ?? keep; if (bricks) { FADE = Math.min(1, FADE + 0.2); brickMachine(o.machine, o.machine.power === "off" ? 0 : 1, 0, false); } else lite(o.machine); accent = keep; });
      setObj(0);
      FADE = 1;
      if (bricks) {
        brickMachine(m, on, act, true);
        // The time of day colors the whole world, the machine included; then what shines by itself is drawn over it.
        const tint = ambientTint(scene.cur, timeRef.current);
        if (tint) {
          g.save(); g.setTransform(dpr, 0, 0, dpr, 0, 0); g.globalCompositeOperation = "multiply"; g.globalAlpha = fadeIn; g.fillStyle = tint; g.fillRect(0, 0, W, H); g.restore();
          drawAmbientGlow(scene.cur, av, stateOf(scene.cur), fadeIn);
        }
        const sk2 = amp(1.45);
        if (on && sk2 > 0.01) {
          drawScreen(m, m.power === "starting" ? Math.max(0, (bootF - 0.55) / 0.45) : 1, resolveTime(timeRef.current));
          const c = P(0, 1.45, 0), sw = 1.55 * Sz * OBJ.s, sh = (sw * 9) / 16;
          brickScreen(c[0] - sw / 2, c[1] - sh / 2, sw, sh, Math.min(1, sk2));
        }
        ctx = h;
      } else {
      board(on, act);
      plate(m);
      cpu(m, on, U.cpu);
      ram(m, on, on ? U.mem : 0);
      gpu(m, on, U.gpu);
      disk(m, on, on ? U.disk : 0);
      apps(m, on);
      if (on && !reduced && Math.random() < 0.3) motes.push({ x: (Math.random() - 0.5) * 1.8, y: 0.05, z: (Math.random() - 0.5) * 1.8, s: 0.25 + Math.random() * 0.4 });
      motes.forEach((p) => (p.y += p.s * dt));
      motes = motes.filter((p) => p.y < 1.95);
      motes.forEach((p) => dot(p.x, p.y, p.z, accent, 0.5 * (1 - p.y / 2), 0.008));
      // The screen, projected from the graphics card, always facing the viewer.
      const sk = amp(1.45);
      if (on && sk > 0.01) {
        drawScreen(m, m.power === "starting" ? Math.max(0, (bootF - 0.55) / 0.45) : 1);
        const c = P(0, 1.45, 0), sw = 1.55 * Sz * OBJ.s, sh = (sw * 9) / 16, x0 = c[0] - sw / 2, y0 = c[1] - sh / 2, em = P(0.35, 0.53, 0.4);
        h.strokeStyle = rgba(accent, 0.12 * sk); h.lineWidth = 1;
        for (const [a, b] of [[x0, y0 + sh], [x0 + sw, y0 + sh], [x0, y0], [x0 + sw, y0]]) { h.beginPath(); h.moveTo(em[0], em[1]); h.lineTo(a, b); h.stroke(); }
        h.beginPath(); h.moveTo(em[0], em[1]); h.lineTo(x0, y0 + sh); h.lineTo(x0 + sw, y0 + sh); h.closePath(); h.fillStyle = rgba(accent, 0.03 * sk); h.fill();
        h.globalAlpha = Math.min(1, sk) * (0.88 + Math.random() * 0.12);
        h.drawImage(screen, x0, y0, sw, sh);
        h.globalAlpha = 1;
        h.strokeStyle = rgba(accent, 0.7 * sk); h.lineWidth = 1.4;
        const L = 14;
        for (const [a, b, sx, sy] of [[x0, y0, 1, 1], [x0 + sw, y0, -1, 1], [x0, y0 + sh, 1, -1], [x0 + sw, y0 + sh, -1, -1]]) { h.beginPath(); h.moveTo(a, b + sy * L); h.lineTo(a, b); h.lineTo(a + sx * L, b); h.stroke(); }
        h.strokeStyle = rgba(accent, 0.25 * sk); h.strokeRect(x0, y0, sw, sh);
      }
      if (on && scanY > 0.1 && scanY < 1.95) quad([[-0.98, scanY, -0.98], [0.98, scanY, -0.98], [0.98, scanY, 0.98], [-0.98, scanY, 0.98]], accent, 0.03, 0.22);
      }
      h.globalCompositeOperation = "destination-out";
      // The scan lines: one row in three, drifting down; one fill with a pattern made once (it was ~130 fills a frame).
      {
        if (!scanPattern) {
          const tile = document.createElement("canvas"); tile.width = 4; tile.height = 3;
          const tg = tile.getContext("2d")!; tg.fillStyle = "rgba(0,0,0,.22)"; tg.fillRect(0, 0, 4, 1);
          scanPattern = h.createPattern(tile, "repeat");
        }
        if (scanPattern) { const dy = (T * 12) % 3; h.save(); h.translate(0, dy); h.fillStyle = scanPattern; h.fillRect(0, -3, W, H + 3); h.restore(); }
      }
      h.globalCompositeOperation = "source-over";
      g.save(); g.setTransform(1, 0, 0, 1, 0, 0); g.globalCompositeOperation = light ? "source-over" : "lighter"; g.drawImage(holo, 0, 0); g.restore();

      // At rest, a few faint stars around the machines.
      ctx = g;
      if (plain && rest > 0.02) for (let i = 0; i < 46; i++) {
        const x = (Math.sin(i * 91.3) * 0.5 + 0.5) * W, y = (Math.sin(i * 47.7) * 0.5 + 0.5) * H;
        g.fillStyle = glass(0.18 * rest * (0.5 + 0.5 * Math.sin(T * 1.5 + i))); g.fillRect(x, y, 1.5, 1.5);
      }
      // The glass in front, its edges and the four electrodes at the top corners.
      for (const [n, q] of CUBE_FACES) if (vis(...n)) gpoly(q.map((p) => P(...p)), on ? rgba(accent, 0.025) : glass(0.015));
      const edge = light ? "#c9c6be" : "#3e3e3e", edgeBack = light ? "#dcd9d1" : "#2a2a2a";
      for (const [a, b] of EDGES) {
        const pa = P(...a), pb = P(...b), front = (pa[2] + pb[2]) / 2 > -0.01;
        g.beginPath(); g.moveTo(pa[0], pa[1]); g.lineTo(pb[0], pb[1]);
        g.strokeStyle = on ? mixHex(front ? edge : edgeBack, accent, (front ? 0.2 : 0.08) + 0.4 * act) : front ? edge : edgeBack;
        g.lineWidth = front ? 1.8 : 1; g.stroke();
      }
      for (const c of CORNERS) { const p = P(...c); g.beginPath(); g.rect(p[0] - 3.5, p[1] - 3.5, 7, 7); g.fillStyle = edge; g.fill(); }
      for (const s of ELECTRODES) {
        const p = P(...s), q = P(s[0], 2, s[2]);
        g.beginPath(); g.moveTo(q[0], q[1]); g.lineTo(p[0], p[1]); g.strokeStyle = edge; g.lineWidth = 2; g.stroke();
        // Square, like the corners: the cube is all straight lines.
        g.beginPath(); g.rect(p[0] - 4.5, p[1] - 4.5, 9, 9); g.fillStyle = on ? mixHex(edge, accent, 0.35 + 0.65 * act) : edge; g.fill();
      }

      // Lightning to each piece as often as it works, thicker and brighter the busier it is; over 55 % it also
      // crackles on the piece itself.
      const targets: Record<keyof typeof U, [V3, number]> = { cpu: [[-0.38, 0.1, -0.32], 0.18], gpu: [[0.35, 0.5, 0.35], 0.4], mem: [[0.5, 0.6, -0.36], 0.28], disk: [[-0.55, 0.12, 0.6], 0.15] };
      if (on && !reduced) for (const k of Object.keys(targets) as (keyof typeof U)[]) {
        const u = U[k], [tp, ts] = targets[k];
        if (Math.random() < (0.012 + Math.pow(u, 1.6) * 0.32) * bootF)
          arcs.push({ a: ELECTRODES[Math.floor(Math.random() * 4)], b: [tp[0] + (Math.random() - 0.5) * ts, tp[1], tp[2] + (Math.random() - 0.5) * ts], life: 0.12 + Math.random() * 0.2, j: 0, w: 0.9 + u * 1.2, i: 0.45 + 0.55 * u });
        if (u > 0.55 && Math.random() < (u - 0.55) * 0.5 * bootF) {
          const r = (): V3 => [tp[0] + (Math.random() - 0.5) * ts, tp[1] + (Math.random() - 0.5) * 0.08, tp[2] + (Math.random() - 0.5) * ts];
          arcs.push({ a: r(), b: r(), life: 0.1, j: 0, w: 0.8, i: 0.8, local: true });
        }
      }
      const drawBolt = (p: V2[], al: number, wd: number) => {
        g.lineCap = "round"; g.lineJoin = "round";
        ([[wd * 3, 0.13], [wd, 0.9]] as const).forEach(([lw, o], j) => {
          g.beginPath(); p.forEach((q, i) => (i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1])));
          // In light the bolt keeps the accent itself and goes thinner: darkened, it read as heavy ink.
          g.strokeStyle = j && !light ? bright(accent, 0.45) : accent; g.globalAlpha = Math.max(0, al * o * (light ? 0.7 : 1)); g.lineWidth = light ? lw * 0.7 : lw; g.stroke();
        });
        g.globalAlpha = 1;
      };
      // Among blocks, a bolt is a chain of small square blocks snapped to a grid, bright at its core.
      const blockBolt = (p: V2[], al: number, wd: number) => {
        const s = Math.max(3, Math.round(2.4 + wd * 1.8)), seen = new Set<string>();
        g.globalAlpha = Math.max(0, Math.min(1, al));
        for (let i = 1; i < p.length; i++) {
          const [x0, y0] = p[i - 1], [x1, y1] = p[i], n = Math.max(1, Math.ceil(Math.hypot(x1 - x0, y1 - y0) / s));
          for (let k = 0; k <= n; k++) {
            const gx = Math.round((x0 + ((x1 - x0) * k) / n) / s) * s, gy = Math.round((y0 + ((y1 - y0) * k) / n) / s) * s, key = gx + "," + gy;
            if (seen.has(key)) continue;
            seen.add(key);
            g.fillStyle = shadeHex(accent, 0.8); g.fillRect(gx - s / 2, gy - s / 2, s, s);
            g.fillStyle = shadeHex(accent, 1.35); g.fillRect(gx - s / 2 + 1, gy - s / 2 + 1, s - 2, Math.max(1, s / 3));
          }
        }
        g.globalAlpha = 1;
      };
      for (const c of arcs) {
        c.life -= dt; c.j -= dt;
        const a = P(...c.a), b = P(...c.b);
        if (c.j <= 0 || !c.p) { c.p = bolt(a[0], a[1], b[0], b[1], Math.hypot(b[0] - a[0], b[1] - a[1]) * (c.local ? 0.5 : 0.35)); c.j = scene.cur === "blocks" ? 0.09 : 0.05; }
        if (scene.cur === "blocks") { blockBolt(c.p, Math.min(1, c.life / 0.08) * c.i, c.w); continue; }
        drawBolt(c.p, Math.min(1, c.life / 0.08) * c.i, c.w);
        if (!c.local && Math.random() < 0.3) { const mid = c.p[Math.floor(c.p.length / 2)]; drawBolt(bolt(mid[0], mid[1], mid[0] + (Math.random() - 0.5) * 40, mid[1] + (Math.random() - 0.5) * 40, 16), c.life * 2 * c.i, 0.7); }
      }
      arcs = arcs.filter((c) => c.life > 0);

      // The decoration, outside the glass: the LED sign, the stickers and the figures on top.
      drawLed(D, m, on);
      if (held) drawGrid(D);
      if (marquee) {
        const bx = Math.min(marquee.x0, marquee.x1), by = Math.min(marquee.y0, marquee.y1), bw = Math.abs(marquee.x1 - marquee.x0), bh = Math.abs(marquee.y1 - marquee.y0);
        g.fillStyle = rgba(uiAccent, 0.1); g.fillRect(bx, by, bw, bh);
        g.strokeStyle = rgba(uiAccent, 0.8); g.lineWidth = 1; g.strokeRect(bx + 0.5, by + 0.5, bw, bh);
      }
      if (turning?.moved) {
        const it = D.stickers.find((t) => t.id === turning!.id) ?? D.figures.find((t) => t.id === turning!.id);
        if (it) {
          const label = `${it.rot > 180 ? it.rot - 360 : it.rot}°`, [lx, ly] = turning.at;
          g.font = "600 12px 'Plus Jakarta Sans', sans-serif";
          const w = g.measureText(label).width + 16;
          g.fillStyle = rgba(accent, 0.9); g.beginPath(); g.roundRect(lx + 14, ly - 26, w, 22, 6); g.fill();
          g.fillStyle = light ? "#ffffff" : "#161616"; g.textBaseline = "middle"; g.fillText(label, lx + 22, ly - 15);
        }
      }
      drawStickers(D, true);
      if (!under) drawFigures(D);
    };

    // While something is dragged, the cells of its face show, and the ones around it light up in the accent.
    function drawGrid(D: Decor) {
      if (!held) return;
      const cells: { f: Face; lit: (cu: number, cv: number) => number }[] = [];
      if (held.kind === "sticker") {
        const s = D.stickers.find((t) => t.id === held!.id);
        if (s) cells.push({ f: s.face, lit: (cu, cv) => 1 - Math.max(Math.abs(cu - s.u), Math.abs(cv - s.v)) / (s.size / 2 + CELL) });
      } else if (held.kind === "figure") {
        const fg = D.figures.find((t) => t.id === held!.id);
        if (fg) { const r = 0.32 * fg.size * FIG + CELL; cells.push({ f: "top", lit: (cu, cv) => 1 - Math.hypot(cu - fg.x, -cv - fg.z) / r }); }
      } else if (D.led) {
        const mid = ledTop(D.led.y) - LED_STEP * 3;
        for (const f of ["front", "right", "back", "left"] as Face[]) if (vis(...FRAMES[f].n)) cells.push({ f, lit: (_cu, cv) => 1 - Math.abs(cv - mid) / (LED_STEP * 4 + CELL) });
      }
      const lines = new Path2D();
      for (const { f, lit } of cells) {
        if (!vis(...FRAMES[f].n)) continue;
        for (let i = 0; i <= 8; i++) {
          const t = -1 + i * CELL;
          let a = P(...onFace(f, t, -1)), b = P(...onFace(f, t, 1));
          lines.moveTo(a[0], a[1]); lines.lineTo(b[0], b[1]);
          a = P(...onFace(f, -1, t)); b = P(...onFace(f, 1, t));
          lines.moveTo(a[0], a[1]); lines.lineTo(b[0], b[1]);
        }
        for (let i = 0; i < 8; i++) for (let j = 0; j < 8; j++) {
          const cu = -1 + (i + 0.5) * CELL, cv = -1 + (j + 0.5) * CELL, k = lit(cu, cv);
          if (k <= 0) continue;
          const h = CELL / 2 - 0.012, q = [[-h, -h], [h, -h], [h, h], [-h, h]].map(([du, dv]) => P(...onFace(f, cu + du, cv + dv)));
          g.beginPath(); q.forEach((p, n) => (n ? g.lineTo(p[0], p[1]) : g.moveTo(p[0], p[1]))); g.closePath();
          g.fillStyle = rgba(accent, Math.min(1, k) * 0.5); g.fill();
        }
      }
      g.strokeStyle = rgba(light ? "#1c1b18" : "#ebe8e1", 0.18); g.lineWidth = 1; g.stroke(lines);
    }

    function drawStickers(D: Decor, front: boolean) {
      const dpr = animDpr();
      for (const s of D.stickers) {
        if (vis(...FRAMES[s.face].n) !== front) continue;
        const img = stickerImage(s.sticker, accent);
        if (!img) continue;
        const o = P(...onFace(s.face, s.u, s.v)), a = P(...onFace(s.face, s.u + 1, s.v)), b = P(...onFace(s.face, s.u, s.v + 1));
        g.save();
        g.setTransform(dpr * (a[0] - o[0]), dpr * (a[1] - o[1]), -dpr * (b[0] - o[0]), -dpr * (b[1] - o[1]), dpr * o[0], dpr * o[1]);
        g.rotate((s.rot * Math.PI) / 180);
        g.globalAlpha = front ? 1 : 0.16;
        const picked = front && !!editRef.current?.selected.includes(s.id);
        g.drawImage(!front ? stickerBack(img) : picked ? stickerTinted(img, uiAccent) : img, -s.size / 2, -s.size / 2, s.size, s.size);
        if (picked) {
          const h = s.size / 2 + 0.025;
          g.globalAlpha = 0.85; g.setLineDash([0.035, 0.025]); g.lineWidth = 0.01;
          g.strokeStyle = light ? "#1c1b18" : "#ebe8e1"; g.strokeRect(-h, -h, h * 2, h * 2);
        }
        g.restore();
      }
    }

    let ledText = "", ledCols: boolean[][] = [];
    function drawLed(D: Decor, m: CubeMachine, on: number) {
      const led = D.led;
      if (!led) return;
      let text = led.text.trim() || decorRef.current.owner || "GpuVM";
      if (led.live) text += on ? `  ·  GPU ${Math.round(m.usage.gpu)} %  ·  CPU ${Math.round(m.usage.cpu)} %` : "  ·  " + t("APAGADA");
      text += "      ";
      if (text !== ledText) { ledText = text; ledCols = ledColumns(text); }
      const n = ledCols.length;
      if (!n) return;
      let color = led.color === "machine" ? accent : LED_COLORS.find((c) => c.id === led.color)?.hex ?? "#ffb547";
      // White dots would vanish on the light theme: there they light up as ink.
      if (light && led.color === "white") color = "#2b2a27";
      // One strip of dots wraps the four sides; the text runs around it to the left, like a ticker.
      const per = 44, step = LED_STEP, top = ledTop(led.y), shift = reduced ? 0 : Math.floor(T * 14);
      const r = Math.max(0.7, step * 0.36 * Sz * OBJ.s);
      const lit = new Path2D(), dark = new Path2D();
      (["front", "right", "back", "left"] as Face[]).forEach((f, fi) => {
        if (!vis(...FRAMES[f].n)) return;
        // The face's origin and directions on screen, once: each dot is then two multiplications.
        const o = P(...onFace(f, 0, 0)), a = P(...onFace(f, 1, 0)), b = P(...onFace(f, 0, 1));
        const ux = a[0] - o[0], uy = a[1] - o[1], vx = b[0] - o[0], vy = b[1] - o[1];
        for (let i = 0; i < per; i++) {
          const col = ledCols[(((fi * per + i + shift) % n) + n) % n], u = -1 + step * (i + 0.5);
          for (let row = 0; row < 7; row++) {
            const v = top - row * step, p = [o[0] + ux * u + vx * v, o[1] + uy * u + vy * v], path = col[row] ? lit : dark;
            // Tiny dots look the same as squares and cost far less than circles.
            if (r < 1.8) path.rect(p[0] - r, p[1] - r, r * 2, r * 2);
            else { path.moveTo(p[0] + r, p[1]); path.arc(p[0], p[1], r, 0, Math.PI * 2); }
          }
        }
      });
      g.fillStyle = rgba(light ? "#1c1b18" : color, light ? 0.07 : 0.11); g.fill(dark);
      g.fillStyle = color; g.fill(lit);
    }

    // The figures go to the GPU: the cube's projection is affine, so three probes give the matrix it uses.
    function drawFigures(D: Decor) {
      if (!D.figures.length) return;
      const o = P(0, 0, 0), ax = P(1, 0, 0), ay = P(0, 1, 0), az = P(0, 0, 1);
      const A = [ax[0] - o[0], ax[1] - o[1], ax[2] - o[2], ay[0] - o[0], ay[1] - o[1], ay[2] - o[2], az[0] - o[0], az[1] - o[1], az[2] - o[2]];
      const V = viewRot(view.yaw, view.pitch);
      const draws: FigureDraw[] = D.figures.map((f) => {
        const turn = (f.rot * Math.PI) / 180;
        const t: V3 = [o[0] + A[0] * f.x + A[3] * 2 + A[6] * f.z, o[1] + A[1] * f.x + A[4] * 2 + A[7] * f.z, o[2] + A[2] * f.x + A[5] * 2 + A[8] * f.z];
        return { id: f.figure, m: mul3(A, turnY(turn, f.size * FIG)), t, n: mul3(V, turnY(turn)), tint: editRef.current?.selected.includes(f.id) ? 0.28 : 0 };
      });
      for (const f of D.figures) {
        if (!editRef.current?.selected.includes(f.id)) continue;
        const sc = f.size * FIG, ring: V3[] = [];
        for (let i = 0; i <= 40; i++) { const a = (i / 40) * Math.PI * 2; ring.push([f.x + Math.cos(a) * 0.36 * sc, 2.004, f.z + Math.sin(a) * 0.36 * sc]); }
        g.beginPath(); ring.forEach((p, i) => { const q = P(...p); if (i) g.lineTo(q[0], q[1]); else g.moveTo(q[0], q[1]); });
        g.setLineDash([4, 4]); g.lineWidth = 1.2; g.strokeStyle = light ? "rgba(28,27,24,.7)" : "rgba(235,232,225,.75)"; g.stroke(); g.setLineDash([]);
      }
      drawFiguresGL(g, draws, accent, W, H, animDpr(), uiAccent);
    }

    // Frames a second from the shared budget (animBudget.ts): every frame while someone looks at it, 30 without the
    // focus, none while a machine's picture covers the app (the VMs share this GPU). The website caps it too.
    let drawnAt = 0;
    const loop = (now: number) => {
      const cap = animFps();
      if (cap === 0) { frame = 0; return; }
      const due = paceFrame(now, drawnAt, cap);
      if (due !== null) { drawnAt = due; draw(now); }
      if (visible && !document.hidden && !reduced) frame = requestAnimationFrame(loop);
    };
    const restart = () => { cancelAnimationFrame(frame); last = performance.now(); if (visible && !document.hidden && animFps() !== 0) frame = requestAnimationFrame(loop); };
    const offBudget = onAnimBudget(restart);
    // Only animates while it is on screen and the window is visible.
    const io = new IntersectionObserver(([e]) => { visible = e.isIntersecting; restart(); });
    io.observe(cv);
    document.addEventListener("visibilitychange", restart);
    // With reduced motion it draws once, and again whenever it is dragged.
    const redraw = () => { if (reduced) requestAnimationFrame((t) => draw(t)); };
    cv.addEventListener("pointermove", redraw);
    cv.addEventListener("wheel", redraw);
    restart();
    return () => {
      // (A mount undone at once, as React's development double mount does, leaves the previous space alone.)
      if (performance.now() - mountedAt > 300) lastSpace = { name: space.current.name, yaw: view.yaw, pitch: view.pitch, at: performance.now() };
      cancelAnimationFrame(frame);
      offBudget();
      io.disconnect();
      document.removeEventListener("visibilitychange", restart);
      cv.removeEventListener("pointerdown", down);
      cv.removeEventListener("pointermove", move);
      cv.removeEventListener("pointermove", redraw);
      cv.removeEventListener("pointerup", up);
      cv.removeEventListener("pointercancel", up);
      cv.removeEventListener("wheel", wheel);
      cv.removeEventListener("wheel", redraw);
      cv.removeEventListener("contextmenu", menu);
      window.removeEventListener("pointerup", up);
      cv.removeEventListener("dblclick", reset);
      cv.removeEventListener("mousedown", noAutoScroll);
      cv.removeEventListener("auxclick", noAutoScroll);
      cv.removeEventListener("dragover", over);
      cv.removeEventListener("drop", dropped);
    };
  }, []);

  return <canvas ref={ref} className={`machine-cube${className ? ` ${className}` : ""}`} aria-hidden="true" />;
}

/** A machine of the list as the cube draws it. */
export function cubeOf(vm: VmOverview, apps: string[] = []): CubeMachine {
  return {
    power: vm.state === "Running" ? "on" : vm.state === "Starting" || vm.state === "Stopping" ? "starting" : "off",
    cores: vm.options?.cpu ?? vm.processorCount,
    memoryGB: vm.options?.memoryGB ?? vm.memoryStartupGB,
    gpuPercent: vm.hasGpu ? vm.options?.gpuPercent ?? 0 : 0,
    diskGB: vm.options?.diskGB ?? 0,
    usage: { cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100, disk: 0 },
    apps,
    removed: CLEANUP_REMOVED[vm.options?.cleanup ?? "none"] ?? 0,
  };
}

/** How many kinds of things each cleanup level keeps out of Windows, for the pieces that bounce off the cube. */
export const CLEANUP_REMOVED: Record<string, number> = { none: 0, privacy: 4, apps: 8, minimal: 12 };
