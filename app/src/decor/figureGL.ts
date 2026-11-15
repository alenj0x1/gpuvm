import { BRICK, FIGURES, figureBricks, figureExtent, figureHeight, type V3 } from "./figures";

// The figures drawn on the GPU: each one becomes a mesh of its blocks once and is drawn with light per pixel and a
// depth buffer, into one shared WebGL canvas that the cube (or a thumbnail) then
// copies in. Drawing them as 2D polygons cost 18 to 70 ms per figure and frame; here a frame with several costs
// well under a millisecond.

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

/** The figure's blocks as one mesh: only the faces no other block covers, and a stud on every free top. */
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
    // Blocks are centered on x and z, standing on y = 0.
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
uniform mat3 uM; uniform vec3 uT; uniform mat3 uN; uniform vec2 uSize;
out vec3 vN; out vec3 vC; out float vMach;
void main() {
  vec3 s = uM * aPos + uT;
  gl_Position = vec4(s.x / uSize.x * 2.0 - 1.0, 1.0 - s.y / uSize.y * 2.0, clamp(-s.z * 0.04, -1.0, 1.0), 1.0);
  vN = uN * aNrm; vC = aCol; vMach = aMach;
}`;
const FS = `#version 300 es
precision highp float;
in vec3 vN; in vec3 vC; in float vMach;
uniform vec3 uMachine;
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
  o = vec4(min(col, vec3(1.0)), 1.0);
}`;

interface GLState {
  canvas: HTMLCanvasElement;
  gl: WebGL2RenderingContext;
  prog: WebGLProgram;
  loc: Record<string, WebGLUniformLocation | null>;
  meshes: Map<string, { vao: WebGLVertexArrayObject; count: number }>;
}
let state: GLState | null = null;
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
  for (const u of ["uM", "uT", "uN", "uSize", "uMachine"]) loc[u] = gl.getUniformLocation(prog, u);
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
  const out = { vao, count: m.idx.length };
  s.meshes.set(id, out);
  return out;
}

export interface FigureDraw {
  id: string;
  /** Model point to screen: x and y in CSS pixels of the target, z its depth (bigger is nearer). Column-major. */
  m: Mat3;
  t: V3;
  /** Model direction to view space (x right, y up, z toward the viewer). Column-major. */
  n: Mat3;
}

/** Draws the figures into `target` (a 2D context the size of W × H CSS pixels), over what it already has. */
export function drawFigures(target: CanvasRenderingContext2D, draws: FigureDraw[], machineColor: string, W: number, H: number, dpr: number) {
  if (!draws.length) return;
  const s = setup();
  if (!s) return;
  const { gl, canvas, loc } = s;
  const w = Math.max(1, Math.ceil(W * dpr)), h = Math.max(1, Math.ceil(H * dpr));
  // The canvas only grows: switching sizes every frame (cube, then a thumbnail) would reallocate it each time.
  if (canvas.width < w || canvas.height < h) { canvas.width = Math.max(canvas.width, w); canvas.height = Math.max(canvas.height, h); }
  gl.viewport(0, canvas.height - h, w, h);
  gl.enable(gl.SCISSOR_TEST);
  gl.scissor(0, canvas.height - h, w, h);
  gl.clearColor(0, 0, 0, 0);
  gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
  gl.enable(gl.DEPTH_TEST);
  gl.depthFunc(gl.LESS);
  gl.disable(gl.CULL_FACE);
  gl.useProgram(s.prog);
  gl.uniform2f(loc.uSize, W, H);
  gl.uniform3fv(loc.uMachine, hex(machineColor));
  for (const d of draws) {
    const me = mesh(s, d.id);
    if (!me) continue;
    gl.uniformMatrix3fv(loc.uM, false, d.m);
    gl.uniform3fv(loc.uT, d.t);
    gl.uniformMatrix3fv(loc.uN, false, d.n);
    gl.bindVertexArray(me.vao);
    gl.drawElements(gl.TRIANGLES, me.count, gl.UNSIGNED_INT, 0);
  }
  gl.bindVertexArray(null);
  target.save();
  target.setTransform(1, 0, 0, 1, 0, 0);
  target.drawImage(canvas, 0, 0, w, h, 0, 0, w, h);
  target.restore();
}

export const mul3 = (a: Mat3, b: Mat3): Mat3 => {
  const o: Mat3 = [];
  for (let c = 0; c < 3; c++) for (let r = 0; r < 3; r++) o[c * 3 + r] = a[r] * b[c * 3] + a[3 + r] * b[c * 3 + 1] + a[6 + r] * b[c * 3 + 2];
  return o;
};
/** Turn around the vertical axis (the same direction the cube uses), times a uniform size. */
export const turnY = (t: number, k = 1): Mat3 => { const c = Math.cos(t) * k, s = Math.sin(t) * k; return [c, 0, -s, 0, k, 0, s, 0, c]; };
/** The view rotation of a camera at `yaw` and `pitch`, as the cube's projection uses it. */
export const viewRot = (yaw: number, pitch: number): Mat3 => {
  const cy = Math.cos(yaw), sy = Math.sin(yaw), cp = Math.cos(pitch), sp = Math.sin(pitch);
  return [cy, -sy * sp, sy * cp, 0, cp, sp, -sy, -cy * sp, cy * cp];
};

/** A thumbnail: the figure seen a little from above, turned `yaw`, filling a `size` px square. */
export function drawFigureThumb(target: CanvasRenderingContext2D, id: string, size: number, yaw: number, color: string, dpr: number) {
  if (!FIGURES.some((f) => f.id === id)) return;
  const height = figureHeight(id);
  const V = viewRot(yaw, 0.42), k = (size * 0.6) / Math.max(0.6, figureExtent(id));
  const m: Mat3 = [V[0] * k, -V[1] * k, V[2], V[3] * k, -V[4] * k, V[5], V[6] * k, -V[7] * k, V[8]];
  const c = [m[3] * (-height / 2), m[4] * (-height / 2), m[5] * (-height / 2)];
  drawFigures(target, [{ id, m, t: [size / 2 + c[0], size * 0.54 + c[1], c[2]], n: V }], color, size, size, dpr);
}
