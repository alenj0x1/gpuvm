import { BRICK, FIGURES, figureBricks, figureExtent, figureHeight, type V3 } from "./figures";

type Mat3 = number[]; // column-major

interface Mesh { pos: number[]; nrm: number[]; col: number[]; mach: number[]; idx: number[] }

const hex = (c: string): V3 => { const h = c.replace("#", ""); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255) as V3; };

const DIRS: { n: V3; quad: V3[] }[] = [
  { n: [1, 0, 0], quad: [[1, 0, 0], [1, 1, 0], [1, 1, 1], [1, 0, 1]] },
  { n: [-1, 0, 0], quad: [[0, 0, 1], [0, 1, 1], [0, 1, 0], [0, 0, 0]] },
  { n: [0, 1, 0], quad: [[0, 1, 0], [0, 1, 1], [1, 1, 1], [1, 1, 0]] },
  { n: [0, -1, 0], quad: [[0, 0, 1], [0, 0, 0], [1, 0, 0], [1, 0, 1]] },
  { n: [0, 0, 1], quad: [[0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]] },
  { n: [0, 0, -1], quad: [[1, 0, 0], [0, 0, 0], [0, 1, 0], [1, 1, 0]] },
];
const STUD_SIDES = 12, STUD_R = 0.3, STUD_H = 0.18;

function brickMesh(id: string): Mesh {
  const m: Mesh = { pos: [], nrm: [], col: [], mach: [], idx: [] };
  const grid = figureBricks(id);
  const add = (pts: V3[], n: V3, c: string) => {
    const base = m.pos.length / 3, machine = c === "$" ? 1 : 0, color = machine ? [1, 1, 1] : hex(c);
    for (const q of pts) { m.pos.push(q[0] * BRICK, q[1] * BRICK, q[2] * BRICK); m.nrm.push(...n); m.col.push(...color); m.mach.push(machine); }
    for (let i = 1; i < pts.length - 1; i++) m.idx.push(base, base + i, base + i + 1);
  };
  for (const [k, c] of grid) {
    const [x, y, z] = k.split(",").map(Number);
    const o: V3 = [x - 0.5, y, z - 0.5];
    for (const d of DIRS) {
      if (grid.has(`${x + d.n[0]},${y + d.n[1]},${z + d.n[2]}`)) continue;
      add(d.quad.map((q) => [o[0] + q[0], o[1] + q[1], o[2] + q[2]] as V3), d.n, c);
    }
    if (grid.has(`${x},${y + 1},${z}`)) continue;
    const ring = (h: number): V3[] => Array.from({ length: STUD_SIDES }, (_, i) => { const a = (i / STUD_SIDES) * Math.PI * 2; return [x + Math.cos(a) * STUD_R, y + 1 + h, z + Math.sin(a) * STUD_R]; });
    const lo = ring(0), hi = ring(STUD_H);
    for (let i = 0; i < STUD_SIDES; i++) {
      const j = (i + 1) % STUD_SIDES, a = ((i + 0.5) / STUD_SIDES) * Math.PI * 2;
      add([lo[i], hi[i], hi[j], lo[j]], [Math.cos(a), 0, Math.sin(a)], c);
    }
    add(hi, [0, 1, 0], c);
  }
  return m;
}

const VS = `#version 300 es
in vec3 aPos; in vec3 aNrm; in vec3 aCol; in float aMach;
uniform mat3 uM; uniform vec3 uT; uniform mat3 uN; uniform vec4 uRect;
out vec3 vN; out vec3 vC; out float vMach;
void main() {
  vec3 s = uM * aPos + uT;
  gl_Position = vec4((s.x - uRect.x) / uRect.z * 2.0 - 1.0, 1.0 - (s.y - uRect.y) / uRect.w * 2.0, clamp(-s.z * 0.04, -1.0, 1.0), 1.0);
  vN = uN * aNrm; vC = aCol; vMach = aMach;
}`;
const FS = `#version 300 es
precision highp float;
in vec3 vN; in vec3 vC; in float vMach;
uniform vec3 uMachine;
uniform vec4 uTint;
out vec4 o;
void main() {
  vec3 n = normalize(vN);
  vec3 L = normalize(vec3(-0.45, 0.75, 0.55));
  float d = max(dot(n, L), 0.0);
  float hemi = 0.5 + 0.5 * n.y;
  vec3 base = mix(vC, uMachine, vMach);
  vec3 col = base * (0.34 + 0.2 * hemi + 0.58 * d);
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  col += vec3(0.3) * pow(max(dot(n, H), 0.0), 40.0);
  col += base * 0.14 * pow(1.0 - max(n.z, 0.0), 3.0);
  col = mix(col, uTint.rgb, uTint.a);
  o = vec4(min(col, vec3(1.0)), 1.0);
}`;

interface GLState {
  canvas: HTMLCanvasElement;
  gl: WebGL2RenderingContext;
  prog: WebGLProgram;
  loc: Record<string, WebGLUniformLocation | null>;
  meshes: Map<string, { vao: WebGLVertexArrayObject; count: number; lo: V3; hi: V3 }>;
}
let state: GLState | null = null;
let small = 0;
let failed = false;

function setup(): GLState | null {
  if (state) return state;
  if (failed) return null;
  const canvas = document.createElement("canvas");
  const gl = canvas.getContext("webgl2", { antialias: true, premultipliedAlpha: true, alpha: true, preserveDrawingBuffer: false });
  if (!gl) { failed = true; return null; }
  const shader = (type: number, src: string) => { const s = gl.createShader(type)!; gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const prog = gl.createProgram()!;
  gl.attachShader(prog, shader(gl.VERTEX_SHADER, VS));
  gl.attachShader(prog, shader(gl.FRAGMENT_SHADER, FS));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) { failed = true; return null; }
  const loc: GLState["loc"] = {};
  for (const u of ["uM", "uT", "uN", "uRect", "uMachine", "uTint"]) loc[u] = gl.getUniformLocation(prog, u);
  canvas.addEventListener("webglcontextlost", (e) => { e.preventDefault(); state = null; });
  state = { canvas, gl, prog, loc, meshes: new Map() };
  return state;
}

function mesh(s: GLState, id: string) {
  const hit = s.meshes.get(id);
  if (hit) return hit;
  if (!FIGURES.some((f) => f.id === id)) return null;
  const m = brickMesh(id);
  const { gl, prog } = s;
  const vao = gl.createVertexArray()!;
  gl.bindVertexArray(vao);
  const attr = (name: string, data: number[], size: number) => {
    const b = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, b);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
    const l = gl.getAttribLocation(prog, name);
    gl.enableVertexAttribArray(l);
    gl.vertexAttribPointer(l, size, gl.FLOAT, false, 0, 0);
  };
  attr("aPos", m.pos, 3); attr("aNrm", m.nrm, 3); attr("aCol", m.col, 3); attr("aMach", m.mach, 1);
  const ib = gl.createBuffer();
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array(m.idx), gl.STATIC_DRAW);
  gl.bindVertexArray(null);
  const lo: V3 = [Infinity, Infinity, Infinity], hi: V3 = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < m.pos.length; i++) { const a = i % 3; lo[a] = Math.min(lo[a], m.pos[i]); hi[a] = Math.max(hi[a], m.pos[i]); }
  const out = { vao, count: m.idx.length, lo, hi };
  s.meshes.set(id, out);
  return out;
}

export interface FigureDraw {
  id: string;
  m: Mat3;
  t: V3;
  n: Mat3;
  tint?: number;
}

export function drawFigures(target: CanvasRenderingContext2D, draws: FigureDraw[], machineColor: string, W: number, H: number, dpr: number, tintColor = "#7d9cf0") {
  if (!draws.length) return;
  const s = setup();
  if (!s) return;
  const { gl, canvas, loc } = s;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  const ready: { d: FigureDraw; me: NonNullable<ReturnType<typeof mesh>> }[] = [];
  for (const d of draws) {
    const me = mesh(s, d.id);
    if (!me) continue;
    ready.push({ d, me });
    for (let c = 0; c < 8; c++) {
      const p = [c & 1 ? me.hi[0] : me.lo[0], c & 2 ? me.hi[1] : me.lo[1], c & 4 ? me.hi[2] : me.lo[2]];
      const sx = d.m[0] * p[0] + d.m[3] * p[1] + d.m[6] * p[2] + d.t[0], sy = d.m[1] * p[0] + d.m[4] * p[1] + d.m[7] * p[2] + d.t[1];
      x0 = Math.min(x0, sx); y0 = Math.min(y0, sy); x1 = Math.max(x1, sx); y1 = Math.max(y1, sy);
    }
  }
  x0 = Math.max(0, Math.floor(x0 - 2)); y0 = Math.max(0, Math.floor(y0 - 2)); x1 = Math.min(W, Math.ceil(x1 + 2)); y1 = Math.min(H, Math.ceil(y1 + 2));
  if (!ready.length || x1 <= x0 || y1 <= y0) return;
  const rw = x1 - x0, rh = y1 - y0, w = Math.max(1, Math.ceil(rw * dpr)), h = Math.max(1, Math.ceil(rh * dpr));
  if (canvas.width < w || canvas.height < h) { canvas.width = Math.max(canvas.width, w); canvas.height = Math.max(canvas.height, h); small = 0; }
  else if (canvas.width * canvas.height > 4 * w * h && ++small > 240) { canvas.width = w; canvas.height = h; small = 0; }
  gl.viewport(0, canvas.height - h, w, h);
  gl.enable(gl.SCISSOR_TEST);
  gl.scissor(0, canvas.height - h, w, h);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.enable(gl.DEPTH_TEST);
  gl.depthFunc(gl.LESS);
  gl.disable(gl.CULL_FACE);
  gl.useProgram(s.prog);
  gl.uniform4f(loc.uRect, x0, y0, rw, rh);
  gl.uniform3fv(loc.uMachine, hex(machineColor));
  const tc = hex(tintColor);
  for (const { d, me } of ready) {
    gl.uniform4f(loc.uTint, tc[0], tc[1], tc[2], d.tint ?? 0);
    gl.uniformMatrix3fv(loc.uM, false, d.m);
    gl.uniform3fv(loc.uT, d.t);
    gl.uniformMatrix3fv(loc.uN, false, d.n);
    gl.bindVertexArray(me.vao);
    gl.drawElements(gl.TRIANGLES, me.count, gl.UNSIGNED_INT, 0);
  }
  gl.bindVertexArray(null);
  target.save();
  target.setTransform(1, 0, 0, 1, 0, 0);
  target.drawImage(canvas, 0, 0, w, h, Math.round(x0 * dpr), Math.round(y0 * dpr), w, h);
  target.restore();
}

export const mul3 = (a: Mat3, b: Mat3): Mat3 => {
  const o: Mat3 = [];
  for (let c = 0; c < 3; c++) for (let r = 0; r < 3; r++) o[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
  return o;
};
export const turnY = (t: number, k = 1): Mat3 => { const c = Math.cos(t) * k, s = Math.sin(t) * k; return [c, 0, -s, 0, k, 0, s, 0, c]; };
export const viewRot = (yaw: number, pitch: number): Mat3 => {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return [cy, -sy * sp, sy * cp, 0, cp, sp, -sy, -cy * sp, cy * cp];
};

const thumbs = new Map<string, HTMLCanvasElement>();
export function figureThumbImage(id: string, size: number, color: string, dpr: number): HTMLCanvasElement {
  const key = `${id}|${size}|${color}|${dpr}`;
  let c = thumbs.get(key);
  if (!c) {
    c = document.createElement("canvas");
    c.width = c.height = Math.round(size * dpr);
    drawFigureThumb(c.getContext("2d")!, id, size, 0.6, color, dpr);
    if (thumbs.size > 200) thumbs.clear();
    thumbs.set(key, c);
  }
  return c;
}

export function drawFigureThumb(target: CanvasRenderingContext2D, id: string, size: number, yaw: number, color: string, dpr: number) {
  if (!FIGURES.some((f) => f.id === id)) return;
  const height = figureHeight(id);
  const V = viewRot(yaw, 0.42), k = (size * 0.6) / Math.max(0.6, figureExtent(id));
  const m: Mat3 = [V[0] * k, -V[1] * k, V[2], V[3] * k, -V[4] * k, V[5], V[6] * k, -V[7] * k, V[8]];
  const c = [m[3] * (-height / 2), m[4] * (-height / 2), m[5] * (-height / 2)];
  drawFigures(target, [{ id, m, t: [size / 2 + c[0], size * 0.54 + c[1], c[2]], n: V }], color, size, size, dpr);
}
