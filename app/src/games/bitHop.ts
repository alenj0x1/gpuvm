import type { GameDef, GameHost, GameInstance } from "./types";
import { drawFigureThumb } from "../decor/figureGL";

// "Bit a bit": your machine keeps going forward and falls unless you make it jump; it has to get through the gaps
// between columns. The world is picked on the start card: the studio (pillars of hologram on the app's gray), a
// motherboard (towers of capacitors and chips) or a world of blocks (brick towers on a baseplate). Bits of data float
// in some gaps and count double. The gaps narrow and the columns come faster as the score grows. In a demo (the
// gallery's card) the machine plays by itself.

type World = "studio" | "board" | "blocks";
interface Column { x: number; gapY: number; gap: number; passed: boolean; bit: boolean; seed: number }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }

const rgba = (hex: string, a: number) => { const h = hex.replace("#", ""); return `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`; };
const BRICK_COLORS = ["#cc4f43", "#d9a03a", "#3f6fb5", "#4f9c45", "#e9e3d6"];

/** The machine as a small glass cube with its color, seen from a corner, tilted by how it moves. */
function cube(g: CanvasRenderingContext2D, x: number, y: number, s: number, color: string, tilt: number) {
  g.save(); g.translate(x, y); g.rotate(tilt);
  g.fillStyle = rgba(color, 0.18); g.fillRect(-s, -s, s * 2, s * 2);
  g.strokeStyle = color; g.lineWidth = 2; g.strokeRect(-s, -s, s * 2, s * 2);
  g.beginPath(); g.moveTo(-s, -s); g.lineTo(-s * 0.45, -s * 1.5); g.lineTo(s * 1.55, -s * 1.5); g.lineTo(s, -s); g.moveTo(s * 1.55, -s * 1.5); g.lineTo(s * 1.55, s * 0.5); g.lineTo(s, s); g.stroke();
  g.fillStyle = rgba(color, 0.6); g.fillRect(-s * 0.7, s * 0.4, s * 1.4, s * 0.3); g.fillRect(-s * 0.35, -s * 0.2, s * 0.6, s * 0.5);
  g.restore();
}

/** The world behind: the board's traces, the blocks' sky and baseplate, or the stars. */
function background(g: CanvasRenderingContext2D, w: number, h: number, world: World, scroll: number, light: boolean, t: number) {
  if (world === "board") {
    g.fillStyle = light ? "#e4ebe6" : "#121814"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "#c3d4c9" : "#25402f"; g.lineWidth = 2;
    const off = scroll * 0.4;
    for (let row = 0; row < h / 20 + 1; row++) {
      const y = 10 + row * 20;
      g.beginPath();
      for (let x = -((off + row * 137) % 380); x < w; x += 380) { const len = 160 + ((row * 53) % 140); g.moveTo(x, y); g.lineTo(x + len, y); g.lineTo(x + len + 14, y + (row % 2 ? 14 : -14)); }
      g.stroke();
    }
    g.fillStyle = light ? "#c7b27a" : "#7f8f86";
    for (let row = 0; row < h / 20 + 1; row++) for (let x = -((off + row * 137) % 380); x < w; x += 380) { g.beginPath(); g.arc(x, 10 + row * 20, 3, 0, 7); g.fill(); }
  } else if (world === "blocks") {
    const sky = g.createLinearGradient(0, 0, 0, h); sky.addColorStop(0, light ? "#8fbfe2" : "#4d7899"); sky.addColorStop(1, light ? "#e6f0ea" : "#a7c0bb");
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.fillStyle = light ? "#ffffff" : "#e3e9ec";
    for (let k = 0; k < 5; k++) { const x = ((k * 260 - scroll * 0.2) % (w + 260) + w + 260) % (w + 260) - 130, y = 30 + (k * 47) % (h * 0.4), u = 14; g.fillRect(x, y, u * 6, u); g.fillRect(x + u, y - u, u * 3, u); }
    g.fillStyle = light ? "#9fc6a4" : "#5f8a6c";
    for (let x = -((scroll * 0.35) % 60); x < w; x += 60) g.fillRect(x, h - 70 - ((Math.floor((x + scroll * 0.35) / 60) * 37) % 3) * 14, 60, 80);
  } else {
    // The studio: the app's own gray with a faint grid going by.
    g.fillStyle = light ? "#f2f1ee" : "#161616"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "rgba(28,27,24,.06)" : "rgba(235,232,225,.05)"; g.lineWidth = 1;
    const off = (scroll * 0.3) % 48;
    g.beginPath();
    for (let x = -off; x < w; x += 48) { g.moveTo(x, 0); g.lineTo(x, h); }
    for (let y = 0; y < h; y += 48) { g.moveTo(0, y); g.lineTo(w, y); }
    g.stroke();
    void t;
  }
}

/** A column from `y0` to `y1` (one half of a pair), drawn as the world's own kind of tower, with its cap at `capAt`. */
function column(g: CanvasRenderingContext2D, x: number, cw: number, y0: number, y1: number, capAt: number, world: World, light: boolean, seed: number) {
  if (y1 <= y0) return;
  if (world === "board") {
    // A stack of capacitors and chips: dark cans with silver tops, a chip at the end.
    g.fillStyle = light ? "#2f3438" : "#262c31"; g.fillRect(x, y0, cw, y1 - y0);
    g.fillStyle = light ? "#4a535a" : "#3a434a"; g.fillRect(x + cw * 0.62, y0, cw * 0.14, y1 - y0);
    for (let y = y0 + 34; y < y1; y += 34) { g.fillStyle = light ? "#6a747a" : "#59646b"; g.fillRect(x - 2, y - 3, cw + 4, 4); }
    const cy = capAt < y1 ? y1 - 18 : y0, chip = 18;
    g.fillStyle = light ? "#26292b" : "#1c2123"; g.fillRect(x - 8, cy, cw + 16, chip);
    g.fillStyle = light ? "#9aa1a3" : "#a7aeb0";
    for (let k = 0; k < 7; k++) { g.fillRect(x - 6 + k * ((cw + 12) / 7), cy - 3, 3, 3); g.fillRect(x - 6 + k * ((cw + 12) / 7), cy + chip, 3, 3); }
  } else if (world === "blocks") {
    // A tower of bricks in alternating colors, with studs on the brick that faces the gap.
    const bh = 22;
    for (let y = y0, k = 0; y < y1; y += bh, k++) {
      const c = BRICK_COLORS[(seed + k) % BRICK_COLORS.length];
      g.fillStyle = c; g.fillRect(x, y, cw, Math.min(bh, y1 - y));
      g.fillStyle = "rgba(0,0,0,.15)"; g.fillRect(x, y + bh - 4, cw, 4);
      g.fillStyle = "rgba(255,255,255,.18)"; g.fillRect(x + 3, y + 3, cw * 0.3, 3);
    }
    if (capAt >= y1) for (let k = 0; k < 3; k++) { g.fillStyle = BRICK_COLORS[seed % BRICK_COLORS.length]; g.fillRect(x + 6 + k * ((cw - 12) / 3), y1, (cw - 12) / 3 - 6, 6); }
  } else {
    // A pillar of hologram: outlined in the app's ink, with scan lines and corner marks at the gap.
    const ink = light ? "28,27,24" : "235,232,225";
    g.fillStyle = `rgba(${ink},.05)`; g.fillRect(x, y0, cw, y1 - y0);
    g.strokeStyle = `rgba(${ink},.18)`; g.lineWidth = 1; g.beginPath();
    for (let y = y0 + 3; y < y1; y += 5) { g.moveTo(x, y); g.lineTo(x + cw, y); }
    g.stroke();
    g.strokeStyle = `rgba(${ink},.7)`; g.lineWidth = 1.4; g.strokeRect(x + 0.5, y0, cw - 1, y1 - y0);
    const e = capAt < y1 ? y1 : y0, d = capAt < y1 ? -1 : 1;
    g.strokeStyle = `rgba(${ink},.95)`; g.lineWidth = 2.4; g.beginPath(); g.moveTo(x - 4, e + d * 8); g.lineTo(x - 4, e); g.lineTo(x + cw + 4, e); g.lineTo(x + cw + 4, e + d * 8); g.stroke();
  }
}

function create(canvas: HTMLCanvasElement, host: GameHost): GameInstance {
  const g = canvas.getContext("2d")!;
  let world = (["studio", "board", "blocks"].includes(host.mode) ? host.mode : "studio") as World;
  const demo = !!host.demo;
  // A change of world fades the new one in over the last; a change of machine sends the old one up and away.
  let prevWorld: World | null = null, fade = 1;
  let leaving: { x: number; y: number; vx: number; vy: number; color: string }[] = [];
  let W = 0, H = 0, dpr = 1;
  const resize = () => { dpr = Math.min(2, window.devicePixelRatio || 1); W = canvas.clientWidth; H = canvas.clientHeight; canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); };
  resize();
  const ro = new ResizeObserver(resize);
  ro.observe(canvas);
  // The machine's first figure rides on it.
  const sprite = document.createElement("canvas");
  const paint = () => { sprite.width = sprite.height = 64 * dpr; drawFigureThumb(sprite.getContext("2d")!, host.player.figures[0] ?? "duck", 64, 0.7, host.player.color, dpr); };
  paint();

  const me = { x: 0, y: 0, vy: 0 };
  let cols: Column[] = [], sparks: Spark[] = [], score = 0, scroll = 0, t = 0, waiting = true, running = false, over = false, frame = 0, last = 0, hudAt = 0, nextAt = 0;
  const unit = () => Math.max(0.7, H / 520);
  const reset = () => {
    Object.assign(me, { x: W * 0.28, y: H * 0.45, vy: 0 });
    cols = []; sparks = []; score = 0; scroll = 0; t = 0; waiting = true; over = false; nextAt = W * 0.9;
  };
  const flap = () => { if (!running || over) return; waiting = false; me.vy = -430 * unit(); for (let i = 0; i < 4; i++) sparks.push({ x: me.x - 14, y: me.y + 12, vx: -60 - Math.random() * 80, vy: 40 + Math.random() * 80, life: 0.4, color: host.player.color, size: 3 }); };
  const crash = () => {
    if (demo) { reset(); return; }
    over = true; running = false;
    for (let i = 0; i < 40; i++) { const a = Math.random() * Math.PI * 2, v = 80 + Math.random() * 260; sparks.push({ x: me.x, y: me.y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 0.6 + Math.random() * 0.5, color: i % 2 ? host.player.color : "#ff6b6b", size: 3 + Math.random() * 4 }); }
    host.onHud({ score, lives: 0 }); host.onOver(score);
  };
  const step = (dt: number) => {
    t += dt;
    const speed = Math.min(320, 170 + score * 3.5) * unit(), cw = 64 * unit();
    // In a demo it jumps by itself, whenever it sinks below the middle of the next gap.
    if (demo) {
      if (waiting) flap();
      const next = cols.find((c) => c.x + 64 * unit() > me.x - 10);
      const aimY = next ? next.gapY + next.gap * 0.12 : H * 0.5;
      if (me.y > aimY && me.vy > -40) flap();
    }
    if (waiting) { me.y = H * 0.45 + Math.sin(t * 3) * 8; return; }
    me.vy += 1350 * unit() * dt; me.y += me.vy * dt;
    scroll += speed * dt;
    nextAt -= speed * dt;
    if (nextAt <= W) {
      const gap = Math.max(118, 168 - score * 1.6) * unit(), margin = 50 * unit();
      cols.push({ x: W + 10, gapY: margin + gap / 2 + Math.random() * (H - margin * 2 - gap), gap, passed: false, bit: Math.random() < 0.35, seed: Math.floor(Math.random() * 5) });
      nextAt = W + 230 * unit() + Math.random() * 60 * unit();
    }
    for (const c of cols) {
      c.x -= speed * dt;
      if (!c.passed && c.x + cw < me.x) { c.passed = true; score += 1; }
      if (c.bit && Math.hypot(me.x - (c.x + cw / 2), me.y - c.gapY) < 26 * unit()) { c.bit = false; score += 1; for (let i = 0; i < 12; i++) sparks.push({ x: me.x, y: me.y, vx: (Math.random() - 0.5) * 260, vy: (Math.random() - 0.5) * 260, life: 0.5, color: host.player.color, size: 3 }); }
      // Hitting a column: the cube's box against the column outside the gap.
      const r = 15 * unit();
      if (me.x + r > c.x && me.x - r < c.x + cw && (me.y - r < c.gapY - c.gap / 2 || me.y + r > c.gapY + c.gap / 2)) { crash(); return; }
    }
    cols = cols.filter((c) => c.x > -cw - 20);
    if (me.y > H - 12 || me.y < 8) crash();
  };
  const draw = (dt: number) => {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    fade = Math.min(1, fade + dt / 0.7);
    if (prevWorld && fade < 1) { background(g, W, H, prevWorld, scroll, host.light, t); g.globalAlpha = fade * fade * (3 - 2 * fade); }
    background(g, W, H, world, scroll, host.light, t);
    g.globalAlpha = 1;
    const cw = 64 * unit();
    for (const c of cols) {
      column(g, c.x, cw, -10, c.gapY - c.gap / 2, c.gapY - c.gap / 2, world, host.light, c.seed);
      column(g, c.x, cw, c.gapY + c.gap / 2, H + 10, -1, world, host.light, c.seed + 2);
      if (c.bit) { const y = c.gapY + Math.sin(t * 4 + c.seed) * 5, s = 9 * unit(); g.fillStyle = host.player.color; g.fillRect(c.x + cw / 2 - s / 2, y - s / 2, s, s); g.strokeStyle = rgba(host.player.color, 0.4); g.lineWidth = 4; g.strokeRect(c.x + cw / 2 - s, y - s, s * 2, s * 2); }
    }
    if (!over) {
      const tilt = waiting ? 0 : Math.max(-0.5, Math.min(1.1, me.vy / 700));
      cube(g, me.x, me.y, 15 * unit(), host.player.color, tilt);
      g.save(); g.translate(me.x, me.y); g.rotate(tilt); g.drawImage(sprite, -14 * unit(), -46 * unit(), 28 * unit(), 28 * unit()); g.restore();
    }
    for (const l of leaving) { l.x += l.vx * dt; l.y += l.vy * dt; l.vy -= 300 * dt; cube(g, l.x, l.y, 15 * unit(), l.color, -0.4); }
    leaving = leaving.filter((l) => l.y > -60 && l.x < W + 60);
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vy += 400 * dt; s.life -= dt; g.globalAlpha = Math.max(0, Math.min(1, s.life * 2)); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
    sparks = sparks.filter((s) => s.life > 0);
  };
  const loop = (now: number) => {
    const dt = Math.min(0.04, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    draw(dt);
    if (running && now - hudAt > 100) { hudAt = now; host.onHud({ score, lives: 1 }); }
    if (running || sparks.length) frame = requestAnimationFrame(loop);
  };
  const kick = () => { cancelAnimationFrame(frame); last = performance.now(); frame = requestAnimationFrame(loop); };
  const onKey = (e: KeyboardEvent) => { if (e.type === "keydown" && !e.repeat && [" ", "ArrowUp", "w", "W"].includes(e.key)) { e.preventDefault(); flap(); } };
  const onDown = (e: PointerEvent) => { if (e.button === 0) flap(); };
  if (!demo) { canvas.addEventListener("pointerdown", onDown); window.addEventListener("keydown", onKey); }
  return {
    cast: ({ player, mode }) => {
      if (player.name !== host.player.name || player.color !== host.player.color) {
        leaving.push({ x: me.x, y: me.y, vx: 120, vy: -200, color: host.player.color });
        host.player = player; host.color = player.color; host.figures = player.figures;
        paint();
        me.y = -20; me.vy = 0;
      }
      const w = (["studio", "board", "blocks"].includes(mode) ? mode : world) as World;
      if (w !== world) { prevWorld = world; world = w; fade = 0; }
    },
    start: () => { reset(); running = true; host.onHud({ score: 0, lives: 1 }); kick(); },
    pause: () => { running = false; cancelAnimationFrame(frame); draw(0); },
    resume: () => { if (!over) { running = true; kick(); } },
    stop: () => { running = false; cancelAnimationFrame(frame); ro.disconnect(); canvas.removeEventListener("pointerdown", onDown); window.removeEventListener("keydown", onKey); },
  };
}

export const BIT_HOP: GameDef = {
  id: "bit-hop",
  name: "Bit a bit",
  description: "Haz saltar tu máquina entre las columnas sin tocarlas. Cada hueco suma, los bits valen doble.",
  modes: [
    { id: "studio", name: "Estudio", description: "Pilares de holograma sobre el gris de la app." },
    { id: "board", name: "Placa base", description: "Torres de condensadores y chips sobre las pistas de la placa." },
    { id: "blocks", name: "Bloques", description: "Torres de bloques de colores bajo un cielo con nubes de bloques." },
  ],
  controls: [
    { label: "Saltar", mouse: "left", keys: ["Espacio", "↑"] },
    { label: "Pausa", keys: ["P"] },
  ],
  tips: ["Cada hueco que cruzas suma un punto", "Los bits de los huecos valen doble", "Los huecos se angostan con el puntaje"],
  create,
};
