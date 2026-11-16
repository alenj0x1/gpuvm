// Many copies of one small image stamped on the GPU: the studs of the blocks world's baseplate. Stamped one by one
// with the 2D canvas they were ~2,600 drawImage calls per frame with the camera low (the frame went from 5 to 28 ms
// while turning); here they are one instanced draw into a shared WebGL canvas that the scene copies in once.

const VS = `#version 300 es
in vec2 aCorner; in vec3 aInst;
uniform vec2 uSize; uniform vec2 uView; uniform float uUp;
out vec2 vUV; out float vA;
void main() {
  vec2 p = aInst.xy + vec2((aCorner.x - 0.5) * uSize.x, aCorner.y * uSize.y - uUp);
  gl_Position = vec4(p.x / uView.x * 2.0 - 1.0, 1.0 - p.y / uView.y * 2.0, 0.0, 1.0);
  vUV = aCorner; vA = aInst.z;
}`;
const FS = `#version 300 es
precision mediump float;
in vec2 vUV; in float vA; uniform sampler2D uTex; out vec4 o;
void main() { o = texture(uTex, vUV) * vA; }`;

interface GL { c: HTMLCanvasElement; gl: WebGL2RenderingContext; prog: WebGLProgram; inst: WebGLBuffer; tex: WebGLTexture; texOf: HTMLCanvasElement | null; texs: Map<HTMLCanvasElement, WebGLTexture>; u: Record<string, WebGLUniformLocation | null> }
let ctx: GL | null | undefined;

function setup(): GL | null {
  const c = document.createElement("canvas");
  const gl = c.getContext("webgl2", { premultipliedAlpha: true, alpha: true, antialias: false, preserveDrawingBuffer: false });
  if (!gl) return null;
  const sh = (type: number, src: string) => { const s = gl.createShader(type)!; gl.shaderSource(s, src); gl.compileShader(s); return s; };
  const prog = gl.createProgram()!;
  gl.attachShader(prog, sh(gl.VERTEX_SHADER, VS)); gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FS)); gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) return null;
  gl.useProgram(prog);
  const quad = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, quad);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);
  const aCorner = gl.getAttribLocation(prog, "aCorner");
  gl.enableVertexAttribArray(aCorner); gl.vertexAttribPointer(aCorner, 2, gl.FLOAT, false, 0, 0);
  const inst = gl.createBuffer()!; gl.bindBuffer(gl.ARRAY_BUFFER, inst);
  const aInst = gl.getAttribLocation(prog, "aInst");
  gl.enableVertexAttribArray(aInst); gl.vertexAttribPointer(aInst, 3, gl.FLOAT, false, 0, 0); gl.vertexAttribDivisor(aInst, 1);
  const tex = gl.createTexture()!; gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
  gl.enable(gl.BLEND); gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  const u = Object.fromEntries(["uSize", "uView", "uUp", "uTex"].map((n) => [n, gl.getUniformLocation(prog, n)]));
  return { c, gl, prog, inst, tex, texOf: null, texs: new Map(), u };
}

let buf = new Float32Array(3 * 4096);
let count = 0;
/** Starts a batch: then add() each copy and draw() them all. */
export function begin() { count = 0; }
/** One copy, its anchor at (x, y) in CSS pixels, with this opacity. */
export function add(x: number, y: number, alpha: number) {
  if ((count + 1) * 3 > buf.length) { const b = new Float32Array(buf.length * 2); b.set(buf); buf = b; }
  buf[count * 3] = x; buf[count * 3 + 1] = y; buf[count * 3 + 2] = alpha; count++;
}

/** Draws the batch onto `g` (whose transform scales CSS pixels by dpr): each copy is `image` at w × h, its top `up`
 *  pixels above the anchor. Returns false when WebGL is not available, so the caller stamps them itself. */
export function draw(g: CanvasRenderingContext2D, image: HTMLCanvasElement, w: number, h: number, up: number, W: number, H: number, dpr: number): boolean {
  if (ctx === undefined) ctx = setup();
  if (!ctx) return false;
  if (!count) return true;
  const { c, gl, u } = ctx;
  // Several scenes share this canvas (the website shows a few cubes at once): it only grows, each draws in its
  // top-left corner, and each sprite keeps its own texture, so nothing is reallocated or uploaded again per call.
  const pw = Math.round(W * dpr), ph = Math.round(H * dpr);
  if (c.width < pw || c.height < ph) { c.width = Math.max(c.width, pw); c.height = Math.max(c.height, ph); }
  gl.viewport(0, c.height - ph, pw, ph);
  gl.enable(gl.SCISSOR_TEST); gl.scissor(0, c.height - ph, pw, ph);
  gl.clearColor(0, 0, 0, 0); gl.clear(gl.COLOR_BUFFER_BIT);
  let tex = ctx.texs.get(image);
  if (!tex) {
    // A handful are kept (one per tilt step and color); the oldest goes when there are more.
    if (ctx.texs.size >= 12) { const [old, t] = ctx.texs.entries().next().value!; gl.deleteTexture(t); ctx.texs.delete(old); }
    tex = gl.createTexture()!;
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, image);
    ctx.texs.set(image, tex);
  }
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.uniform2f(u.uSize, w, h); gl.uniform2f(u.uView, W, H); gl.uniform1f(u.uUp, up); gl.uniform1i(u.uTex, 0);
  gl.bindBuffer(gl.ARRAY_BUFFER, ctx.inst);
  gl.bufferData(gl.ARRAY_BUFFER, buf.subarray(0, count * 3), gl.DYNAMIC_DRAW);
  gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, count);
  g.save();
  g.globalAlpha = 1;
  g.drawImage(c, 0, 0, pw, ph, 0, 0, W, H);
  g.restore();
  return true;
}
