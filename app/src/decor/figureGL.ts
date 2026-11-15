import { FIGURES, type Piece, type V3 } from "./figures";

// The figures drawn on the GPU: each one becomes a smooth mesh once (normals from each piece's real shape) and is
// drawn with light per pixel and a depth buffer, into one shared WebGL canvas that the cube (or a thumbnail) then
// copies in. Drawing them as 2D polygons cost 18 to 70 ms per figure and frame; here a frame with several costs
// well under a millisecond.

type Mat3 = number[]; // column-major

interface Mesh { pos: number[]; nrm: number[]; col: number[]; mach: number[]; idx: number[] }

const hex = (c: string): V3 => { const h = c.replace("#", ""); return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16) / 255) as V3; };
const norm = (v: V3): V3 => { const l = Math.hypot(...v) || 1; return [v[0] / l, v[1] / l, v[2] / l]; };
const rot = (v: V3, r: V3 = [0, 0, 0]): V3 => {
  let [x, y, z] = v;
  const [ax, az, ay] = r;
  if (ax) { const c = Math.cos(ax), s = Math.sin(ax); [y, z] = [y * c - z * s, y * s + z * c]; }
  if (az) { const c = Math.cos(az), s = Math.sin(az); [x, y] = [x * c - y * s, x * s + y * c]; }
  if (ay) { const c = Math.cos(ay), s = Math.sin(ay); [x, z] = [x * c + z * s, -x * s + z * c]; }
  return [x, y, z];
};

/** Adds one piece to the mesh: its points and normals in its own unit shape, then sized, turned and placed. */
function addPiece(m: Mesh, p: Piece) {
  let S: V3 = typeof p.s === "number" ? [p.s, p.s, p.s] : p.s ?? [1, 1, 1];
  const at = p.p ?? [0, 0, 0];
  const machine = p.c === "$" ? 1 : 0, color = machine ? [1, 1, 1] : hex(p.c);
  const base = m.pos.length / 3;
  const pts: V3[] = [], nrms: V3[] = [], tris: number[] = [];
  const grid = (cols: number, rows: number, at0 = 0) => {
    for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) {
      const a = at0 + j * (cols + 1) + i, b = a + 1, c = a + cols + 1, d = c + 1;
      tris.push(a, c, b, b, c, d);
    }
  };
  if (p.k === "sphere") {
    const n = 28, rows = p.half ? 8 : 16;
    for (let j = 0; j <= rows; j++) for (let i = 0; i <= n; i++) {
      const t = (j / 16) * Math.PI, a = (i / n) * Math.PI * 2, v: V3 = [Math.sin(t) * Math.cos(a), Math.cos(t), Math.sin(t) * Math.sin(a)];
      pts.push(v); nrms.push(v);
    }
    grid(n, rows);
  } else if (p.k === "cyl") {
    const n = 28, top = p.top ?? 1;
    for (const [y, r] of [[0, 1], [1, top]]) for (let i = 0; i <= n; i++) {
      const a = (i / n) * Math.PI * 2;
      pts.push([Math.cos(a) * r, y, Math.sin(a) * r]);
      nrms.push(norm([Math.cos(a), 1 - top, Math.sin(a)]));
    }
    grid(n, 1);
    for (const [y, r, ny] of [[0, 1, -1], [1, top, 1]]) {
      if (r <= 0) continue;
      const c = pts.length;
      pts.push([0, y, 0]); nrms.push([0, ny, 0]);
      for (let i = 0; i <= n; i++) { const a = (i / n) * Math.PI * 2; pts.push([Math.cos(a) * r, y, Math.sin(a) * r]); nrms.push([0, ny, 0]); }
      for (let i = 0; i < n; i++) tris.push(c, c + 1 + i, c + 2 + i);
    }
  } else if (p.k === "box") {
    // Built at its real size so the rounded edges stay round whatever its proportions.
    const h: V3 = [S[0] / 2, S[1] / 2, S[2] / 2], r = Math.min(p.round ?? 0, ...h);
    const inner: V3 = [h[0] - r, h[1] - r, h[2] - r], N = r > 0 ? 10 : 1;
    for (const ax of [0, 1, 2]) for (const sd of [-1, 1]) {
      const u = (ax + 1) % 3, w = (ax + 2) % 3, start = pts.length;
      for (let j = 0; j <= N; j++) for (let i = 0; i <= N; i++) {
        const q: V3 = [0, 0, 0];
        q[ax] = sd * h[ax];
        // More points near the edges, where the rounding is.
        const e = (k: number) => { const t = (k / N) * 2 - 1; return Math.sign(t) * Math.pow(Math.abs(t), 0.6); };
        q[u] = e(i) * h[u]; q[w] = e(j) * h[w];
        const c: V3 = [Math.max(-inner[0], Math.min(inner[0], q[0])), Math.max(-inner[1], Math.min(inner[1], q[1])), Math.max(-inner[2], Math.min(inner[2], q[2]))];
        const d: V3 = [q[0] - c[0], q[1] - c[1], q[2] - c[2]], l = Math.hypot(...d);
        const nn: V3 = l > 1e-6 ? [d[0] / l, d[1] / l, d[2] / l] : (() => { const f: V3 = [0, 0, 0]; f[ax] = sd; return f; })();
        pts.push(r > 0 ? [c[0] + nn[0] * r, c[1] + nn[1] * r, c[2] + nn[2] * r] : q);
        nrms.push(r > 0 ? nn : (() => { const f: V3 = [0, 0, 0]; f[ax] = sd; return f; })());
      }
      grid(N, N, start);
    }
    S = [1, 1, 1];
  } else {
    const arc = p.arc ?? Math.PI * 2, n = Math.max(8, Math.round((30 * arc) / (Math.PI * 2))), mm = 12, tube = p.tube ?? 0.2;
    for (let i = 0; i <= n; i++) for (let j = 0; j <= mm; j++) {
      const a = (i / n) * arc, b = (j / mm) * Math.PI * 2, r = 1 + Math.cos(b) * tube;
      pts.push([Math.cos(a) * r, Math.sin(b) * tube, Math.sin(a) * r]);
      nrms.push([Math.cos(b) * Math.cos(a), Math.sin(b), Math.cos(b) * Math.sin(a)]);
    }
    for (let i = 0; i < n; i++) for (let j = 0; j < mm; j++) {
      const a = i * (mm + 1) + j, b = a + 1, c = a + mm + 1, d = c + 1;
      tris.push(a, c, b, b, c, d);
    }
  }
  for (let i = 0; i < pts.length; i++) {
    const v = rot([pts[i][0] * S[0], pts[i][1] * S[1], pts[i][2] * S[2]], p.r);
    const nn = rot(norm([nrms[i][0] / S[0], nrms[i][1] / S[1], nrms[i][2] / S[2]]), p.r);
    m.pos.push(v[0] + at[0], v[1] + at[1], v[2] + at[2]);
    m.nrm.push(...nn);
    m.col.push(...color);
    m.mach.push(machine);
  }
  for (const t of tris) m.idx.push(base + t);
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
  const def = FIGURES.find((f) => f.id === id);
  if (!def) return null;
  const m: Mesh = { pos: [], nrm: [], col: [], mach: [], idx: [] };
  for (const p of def.pieces()) addPiece(m, p);
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
  const def = FIGURES.find((f) => f.id === id);
  if (!def) return;
  const V = viewRot(yaw, 0.42), k = (size * 0.62) / Math.max(0.6, def.height);
  const m: Mat3 = [V[0] * k, -V[1] * k, V[2], V[3] * k, -V[4] * k, V[5], V[6] * k, -V[7] * k, V[8]];
  const c = [m[3] * (-def.height / 2), m[4] * (-def.height / 2), m[5] * (-def.height / 2)];
  drawFigures(target, [{ id, m, t: [size / 2 + c[0], size * 0.54 + c[1], c[2]], n: V }], color, size, size, dpr);
}
