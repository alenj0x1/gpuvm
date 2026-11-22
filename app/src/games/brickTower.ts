import type { GameDef, GameHost, GameInstance } from "./types";
import { settledResize } from "./types";
import { drawFigureThumb } from "../decor/figureGL";
import { t } from "../i18n";

type World = "studio" | "board" | "blocks" | "space";
interface Floor { x: number; w: number; color: string; world: World }
const ORDER: World[] = ["blocks", "board", "studio", "space"];
const FLOORS_PER_ZONE = 8;
const zoneName = (w: World) => (w === "blocks" ? t("Blocks") : w === "board" ? t("Motherboard") : w === "studio" ? t("Studio") : t("Space"));
interface Piece { x: number; y: number; w: number; vx: number; vy: number; rot: number; vr: number; color: string }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }

const rgba = (hex: string, a: number) => { const h = hex.replace("#", ""); return `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`; };
const BRICKS = ["#cc4f43", "#d9a03a", "#3f6fb5", "#4f9c45", "#e9e3d6", "#8a5cc2"];

function background(g: CanvasRenderingContext2D, w: number, h: number, world: World, cam: number, light: boolean) {
  if (world === "space") {
    g.fillStyle = light ? "#20232b" : "#0f1013"; g.fillRect(0, 0, w, h);
    for (let n = 0; n < 70; n++) {
      const x = (n * 97.3) % w, y = (((n * 53.7 + cam * (0.15 + (n % 3) * 0.1)) % (h + 20)) + h + 20) % (h + 20) - 10, s = n % 7 === 0 ? 2 : 1;
      g.fillStyle = n % 5 === 0 ? "rgba(255,236,190,.8)" : "rgba(235,232,225,.55)"; g.fillRect(x, y, s, s);
    }
  } else if (world === "board") {
    g.fillStyle = light ? "#e4ebe6" : "#121814"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "#d2ddd5" : "#1b2a23"; g.lineWidth = 1.5;
    const off = (cam * 0.7) % 22;
    for (let row = -1; row < h / 22 + 1; row++) {
      const y = row * 22 + off, i = Math.floor((cam * 0.7) / 22) - row;
      g.beginPath();
      for (let x = -((i * 137) % 380 + 380) % 380; x < w; x += 380) { const len = 160 + (((i * 53) % 140) + 140) % 140; g.moveTo(x, y); g.lineTo(x + len, y); g.lineTo(x + len + 14, y + (i % 2 ? 14 : -14)); }
      g.stroke();
    }
  } else if (world === "blocks") {
    const k = Math.min(1, cam / 2400);
    const sky = g.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, light ? mix("#8fbfe2", "#3e6f9e", k) : mix("#4d7899", "#1d3047", k));
    sky.addColorStop(1, light ? mix("#e6f0ea", "#9cc2df", k) : mix("#a7c0bb", "#4d7899", k));
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.fillStyle = light ? "#ffffff" : "#e3e9ec";
    for (let n = 0; n < 6; n++) {
      const y = ((n * 170 + cam * 0.85) % (h + 170)) - 80, x = (n * 233) % Math.max(1, w - 80), u = 12;
      g.globalAlpha = 0.9; g.fillRect(x, y, u * 6, u); g.fillRect(x + u, y - u, u * 3, u);
    }
    g.globalAlpha = 1;
  } else {
    g.fillStyle = light ? "#f2f1ee" : "#161616"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "rgba(28,27,24,.06)" : "rgba(235,232,225,.05)"; g.lineWidth = 1;
    const off = (cam * 0.6) % 48;
    g.beginPath();
    for (let x = 0; x < w; x += 48) { g.moveTo(x, 0); g.lineTo(x, h); }
    for (let y = off - 48; y < h; y += 48) { g.moveTo(0, y); g.lineTo(w, y); }
    g.stroke();
  }
}
function mix(a: string, b: string, k: number) {
  const p = (c: string) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
  const [x, y] = [p(a), p(b)];
  return "#" + x.map((v, i) => Math.round(v + (y[i] - v) * k).toString(16).padStart(2, "0")).join("");
}

function tone(hex: string, k: number) { return k >= 0 ? mix(hex, "#ffffff", k) : mix(hex, "#000000", -k); }

function block(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, color: string, world: World, light: boolean, ink: string, d = h * 0.32) {
  if (w <= 0) return;
  const dx = d, dy = d * 0.62;
  const face = (c: string) => { g.fillStyle = c; g.fillRect(x, y, w, h); };
  const top = (c: string) => { g.fillStyle = c; g.beginPath(); g.moveTo(x, y); g.lineTo(x + dx, y - dy); g.lineTo(x + w + dx, y - dy); g.lineTo(x + w, y); g.closePath(); g.fill(); };
  const side = (c: string) => { g.fillStyle = c; g.beginPath(); g.moveTo(x + w, y); g.lineTo(x + w + dx, y - dy); g.lineTo(x + w + dx, y + h - dy); g.lineTo(x + w, y + h); g.closePath(); g.fill(); };
  if (world === "blocks") {
    side(tone(color, -0.28)); face(color); top(tone(color, 0.18));
    g.fillStyle = tone(color, -0.18); g.fillRect(x, y + h - h * 0.12, w, h * 0.12);
    g.fillStyle = "rgba(255,255,255,.16)"; g.fillRect(x + 4, y + 4, Math.max(0, Math.min(w * 0.35, w - 8)), 3);
    if (d > 0) {
      const sw = Math.min(h * 0.42, 22), n = Math.max(1, Math.floor(w / (sw * 1.7)));
      for (let row = 0; row < 2; row++) for (let k = 0; k < n; k++) {
        const t0 = (row + 0.5) / 2, cx = x + (w / n) * (k + 0.5) + dx * t0, cy = y - dy * t0, rx = sw / 2, ry = rx * 0.45, sh = sw * 0.32;
        g.fillStyle = tone(color, -0.22); g.fillRect(cx - rx, cy - sh, rx * 2, sh);
        g.beginPath(); g.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2); g.fill();
        g.fillStyle = tone(color, 0.22); g.beginPath(); g.ellipse(cx, cy - sh, rx, ry, 0, 0, Math.PI * 2); g.fill();
        g.fillStyle = "rgba(255,255,255,.35)"; g.beginPath(); g.ellipse(cx - rx * 0.35, cy - sh - ry * 0.2, rx * 0.3, ry * 0.35, 0, 0, Math.PI * 2); g.fill();
      }
    }
  } else if (world === "board") {
    const body = light ? "#2b3034" : "#3a4449";
    side(tone(body, -0.25)); face(body); top(tone(body, 0.12));
    g.fillStyle = light ? "#b9bfc1" : "#c4cacc";
    for (let px = x + 6; px < x + w - 5; px += 10) { g.fillRect(px, y + h, 3, 5); }
    g.fillStyle = "#c9a24a";
    for (let px = x + 8; px < x + w - 4; px += 14) { g.fillRect(px + dx * 0.5, y - dy * 0.5 - 1, 5, 2); }
    g.fillStyle = tone(body, 0.2); g.beginPath(); g.arc(x + 10, y + 10, 3, 0, Math.PI * 2); g.fill();
    g.fillStyle = color; g.fillRect(x + w / 2 - 8, y + h / 2 - 2, 16, 4);
  } else if (world === "space") {
    side(tone("#1b2140", -0.3)); top(tone(color, 0.1));
    face(light ? "#26304f" : "#1b2140");
    const cols = Math.max(1, Math.floor(w / 18)), cw = (w - 6) / cols;
    g.fillStyle = rgba(color, 0.55);
    for (let c = 0; c < cols; c++) for (let rI = 0; rI < 2; rI++) g.fillRect(x + 3 + c * cw + 1, y + 3 + rI * ((h - 6) / 2) + 1, cw - 2, (h - 6) / 2 - 2);
    g.strokeStyle = color; g.lineWidth = 1.5; g.strokeRect(x + 0.75, y + 0.75, w - 1.5, h - 1.5);
  } else {
    side(rgba(color, light ? 0.1 : 0.14)); top(rgba(color, light ? 0.22 : 0.28));
    g.fillStyle = rgba(color, light ? 0.14 : 0.18); g.fillRect(x, y, w, h);
    g.strokeStyle = rgba(ink, 0.1); g.lineWidth = 1; g.beginPath();
    for (let sy = y + 4; sy < y + h - 2; sy += 4) { g.moveTo(x + 2, sy); g.lineTo(x + w - 2, sy); }
    g.stroke();
    g.strokeStyle = rgba(color, 0.95); g.lineWidth = 1.6; g.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    if (d > 0) { g.beginPath(); g.moveTo(x, y); g.lineTo(x + dx, y - dy); g.lineTo(x + w + dx, y - dy); g.lineTo(x + w + dx, y + h - dy); g.lineTo(x + w, y + h); g.moveTo(x + w + dx, y - dy); g.lineTo(x + w, y); g.stroke(); }
    const m = Math.min(10, w / 4); g.lineWidth = 2.4;
    g.beginPath(); g.moveTo(x - 3, y + m); g.lineTo(x - 3, y - 3 + 0); g.lineTo(x + m, y - 3); g.moveTo(x + w - m, y + h + 3); g.lineTo(x + w + 3, y + h + 3); g.lineTo(x + w + 3, y + h - m); g.stroke();
  }
}

function create(canvas: HTMLCanvasElement, host: GameHost): GameInstance {
  const g = canvas.getContext("2d")!;
  let startWorld = (["studio", "board", "blocks"].includes(host.mode) ? host.mode : host.world && ["studio", "board", "blocks"].includes(host.world) ? host.world : "blocks") as World;
  const zoneOf = (floor: number) => { const k = ORDER.indexOf(startWorld); return ORDER[(k + Math.floor(floor / FLOORS_PER_ZONE)) % ORDER.length]; };
  let world: World = startWorld, bannerAt = -9;
  const demo = !!host.demo;
  let prevWorld: World | null = null, fade = 1;
  let W = 0, H = 0, dpr = 1;
  const resize = () => { dpr = Math.min(2, window.devicePixelRatio || 1); W = canvas.clientWidth; H = canvas.clientHeight; canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); };
  resize();
  const ro = settledResize(() => { resize(); if (!running) draw(0); });
  ro.observe(canvas);
  const sprite = document.createElement("canvas");
  const paint = () => { sprite.width = sprite.height = 72 * dpr; drawFigureThumb(sprite.getContext("2d")!, host.player.figures[0] ?? "duck", 72, 0.7, host.player.color, dpr); };
  paint();
  const ink = host.light ? "#1c1b18" : "#ebe8e1";

  let floors: Floor[] = [], falling: Piece[] = [], sparks: Spark[] = [];
  let moving = { x: 0, w: 0, dir: 1, color: "" };
  let score = 0, streak = 0, cam = 0, camTo = 0, perfectAt = -9, label = "", clock = 0;
  let running = false, over = false, frame = 0, last = 0, hudAt = 0, demoAim = 0;
  const unit = () => Math.max(0.75, Math.min(1.3, H / 520));
  const bh = () => 58 * unit();
  const baseW = () => Math.min(W * 0.46, 280 * unit());
  const yOf = (i: number) => H - 64 * unit() - (i + 1) * bh() + cam;
  const colorFor = (i: number) => zoneOf(i) === "blocks" ? BRICKS[i % BRICKS.length] : i % 3 === 0 ? host.player.color : mix(host.player.color, host.light ? "#ffffff" : "#000000", 0.25 + (i % 3) * 0.12);
  const speed = () => (260 + Math.min(560, floors.length * 13)) * unit() * (floors.length > FLOORS_PER_ZONE ? 1 + 0.4 * Math.sin(clock * 3.2) : 1);
  const nextBlock = () => {
    const top = floors[floors.length - 1];
    const fromLeft = floors.length > FLOORS_PER_ZONE * 2 ? Math.random() < 0.5 : floors.length % 2 === 1;
    moving = { x: fromLeft ? -top.w : W, w: top.w, dir: fromLeft ? 1 : -1, color: colorFor(floors.length) };
    demoAim = top.x + (Math.random() < 0.8 ? (Math.random() - 0.5) * 6 : (Math.random() - 0.5) * top.w * 0.5);
  };
  const reset = () => {
    const w = baseW();
    world = startWorld; prevWorld = null; fade = 1; bannerAt = -9;
    floors = [{ x: W / 2 - w / 2, w, color: host.player.color, world }];
    falling = []; sparks = []; score = 0; streak = 0; cam = 0; camTo = 0; over = false; label = ""; clock = 0;
    nextBlock();
  };
  const burst = (x: number, y: number, color: string, n: number) => {
    for (let i = 0; i < n; i++) { const a = Math.random() * Math.PI * 2, v = 60 + Math.random() * 200; sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 80, life: 0.5 + Math.random() * 0.4, color, size: 2 + Math.random() * 3 }); }
  };
  const drop = () => {
    if (!running || over) return;
    const top = floors[floors.length - 1], y = yOf(floors.length);
    const left = Math.max(top.x, moving.x), right = Math.min(top.x + top.w, moving.x + moving.w);
    if (right - left <= 0) {
      falling.push({ x: moving.x, y, w: moving.w, vx: moving.dir * 60, vy: 0, rot: 0, vr: moving.dir * 2, color: moving.color });
      if (demo) { setTimeout(() => { if (!over) reset(); }, 600); moving.w = 0; return; }
      over = true; running = false; burst(top.x + top.w / 2, yOf(floors.length - 1), host.player.color, 30);
      host.onHud({ score, lives: 0 }); host.onOver(score);
      return;
    }
    const perfect = Math.abs(moving.x - top.x) <= 4 * unit();
    let x = left, w = right - left;
    if (perfect) {
      x = top.x; w = top.w; streak++;
      if (streak % 3 === 0) { const grow = Math.min(baseW() - w, 22 * unit()); x -= grow / 2; w += grow; label = "grow"; }
      else label = "perfect";
      perfectAt = clock;
      burst(x + w / 2, y, moving.color, 14);
      score += 2;
    } else {
      streak = 0; score += 1;
      const cutLeft = moving.x < left, cx = cutLeft ? moving.x : right, cw = moving.w - w;
      falling.push({ x: cx, y, w: cw, vx: (cutLeft ? -1 : 1) * 80, vy: -40, rot: 0, vr: (cutLeft ? -1 : 1) * 3, color: moving.color });
    }
    floors.push({ x, w, color: moving.color, world: zoneOf(floors.length) });
    const next = zoneOf(floors.length);
    if (next !== world) { prevWorld = world; world = next; fade = 0; bannerAt = clock; }
    camTo = Math.max(0, (floors.length + 1) * bh() - H * 0.5);
    nextBlock();
  };
  const step = (dt: number) => {
    clock += dt;
    if (moving.w > 0) {
      moving.x += moving.dir * speed() * dt;
      if (moving.x > W - moving.w * 0.15 && moving.dir > 0) moving.dir = -1;
      if (moving.x < -moving.w * 0.85 && moving.dir < 0) moving.dir = 1;
      if (demo && Math.abs(moving.x - demoAim) < speed() * dt * 0.6 + 1) drop();
    }
  };
  const draw = (dt: number) => {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    cam += (camTo - cam) * Math.min(1, dt * 3.2);
    fade = Math.min(1, fade + dt / 0.7);
    if (prevWorld && fade < 1) { background(g, W, H, prevWorld, cam, host.light); g.globalAlpha = fade * fade * (3 - 2 * fade); }
    background(g, W, H, world, cam, host.light);
    g.globalAlpha = 1;
    const h = bh(), u = unit();
    const base = floors[0];
    if (base) {
      const by = yOf(0);
      g.fillStyle = rgba(host.player.color, 0.16); g.fillRect(base.x - 10 * u, by, base.w + 20 * u, H - by + 40);
      g.strokeStyle = host.player.color; g.lineWidth = 2; g.strokeRect(base.x - 10 * u, by, base.w + 20 * u, H - by + 40);
      g.fillStyle = rgba(host.player.color, 0.55);
      g.fillRect(base.x + base.w * 0.1, by + 14 * u, base.w * 0.35, 8 * u); g.fillRect(base.x + base.w * 0.55, by + 12 * u, base.w * 0.3, 12 * u);
    }
    for (let i = 1; i < floors.length; i++) { const f = floors[i], y = yOf(i); if (y > H + h || y < -h * 2) continue; block(g, f.x, y, f.w, h, f.color, f.world, host.light, ink); }
    const top = floors[floors.length - 1];
    if (top && !over) { const s = 64 * u, y = yOf(floors.length - 1); const d = h * 0.32; g.drawImage(sprite, top.x + top.w / 2 + d * 0.5 - s / 2, y - d * 0.31 - s * 0.92 - (zoneOf(floors.length - 1) === "blocks" ? h * 0.14 : 0), s, s); }
    if (moving.w > 0 && !over) block(g, moving.x, yOf(floors.length), moving.w, h, moving.color, zoneOf(floors.length), host.light, ink);
    for (const p of falling) {
      p.vy += 900 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.vr * dt;
      g.save(); g.translate(p.x + p.w / 2, p.y + h / 2); g.rotate(p.rot); block(g, -p.w / 2, -h / 2, p.w, h, p.color, world, host.light, ink, 0); g.restore();
    }
    falling = falling.filter((p) => p.y < H + 80);
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vy += 420 * dt; s.life -= dt; g.globalAlpha = Math.max(0, Math.min(1, s.life * 2)); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
    sparks = sparks.filter((s) => s.life > 0);
    const sinceZone = clock - bannerAt;
    if (sinceZone < 2.2 && !demo) {
      const a = Math.min(1, sinceZone * 4, (2.2 - sinceZone) * 3), text = t("{name} zone", { name: zoneName(world) });
      g.globalAlpha = a; g.font = `600 ${14 * u}px 'Plus Jakarta Sans', sans-serif`;
      const tw = g.measureText(text).width + 28, x = W / 2 - tw / 2, y = 20 * u;
      g.fillStyle = host.light ? "rgba(255,255,255,.9)" : "rgba(28,28,28,.9)"; g.beginPath(); g.roundRect(x, y, tw, 30 * u, 8); g.fill();
      g.fillStyle = ink; g.textAlign = "center"; g.fillText(text, W / 2, y + 20 * u); g.textAlign = "left"; g.globalAlpha = 1;
    }
    const since = clock - perfectAt;
    if (label && since < 0.6 && top) {
      const k = since / 0.6, y = yOf(floors.length - 1), pad = 6 + k * 18;
      g.globalAlpha = (1 - k) * 0.9; g.strokeStyle = host.player.color; g.lineWidth = 3 * (1 - k) + 1;
      g.beginPath(); g.roundRect(top.x - pad, y - pad - h * 0.2, top.w + pad * 2, h + pad * 2 + h * 0.2, 8); g.stroke();
      if (label === "grow") { g.fillStyle = "#ffffff"; g.globalAlpha = (1 - k) * 0.6; g.fillRect(top.x + top.w * k - 6, y, 12, h); }
      g.globalAlpha = 1;
    }
  };
  const loop = (now: number) => {
    const dt = Math.min(0.04, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    draw(dt);
    if (running && now - hudAt > 100) { hudAt = now; host.onHud({ score, lives: 1, power: streak >= 2 ? t("{n} Perfects in a row", { n: streak }) : undefined }); }
    if (running || falling.length || sparks.length) frame = requestAnimationFrame(loop);
  };
  const kick = () => { cancelAnimationFrame(frame); last = performance.now(); frame = requestAnimationFrame(loop); };
  const onKey = (e: KeyboardEvent) => { if (e.type === "keydown" && !e.repeat && [" ", "ArrowDown", "s", "S"].includes(e.key)) { e.preventDefault(); drop(); } };
  const onDown = (e: PointerEvent) => { if (e.button === 0) drop(); };
  if (!demo) { canvas.addEventListener("pointerdown", onDown); window.addEventListener("keydown", onKey); }
  return {
    cast: ({ player, mode }) => {
      if (player.name !== host.player.name || player.color !== host.player.color) {
        host.player = player; host.color = player.color; host.figures = player.figures;
        paint();
        if (floors[0]) floors[0].color = player.color;
      }
      const w = (["studio", "board", "blocks"].includes(mode) ? mode : startWorld) as World;
      if (w !== startWorld) { startWorld = w; if (floors.length <= 1 || demo) { prevWorld = world; world = w; fade = 0; if (floors[0]) floors[0].world = w; } }
    },
    start: () => { reset(); running = true; host.onHud({ score: 0, lives: 1 }); kick(); },
    pause: () => { running = false; cancelAnimationFrame(frame); draw(0); },
    resume: () => { if (!over) { running = true; kick(); } },
    stop: () => { running = false; cancelAnimationFrame(frame); ro.disconnect(); canvas.removeEventListener("pointerdown", onDown); window.removeEventListener("keydown", onKey); },
  };
}

export const BRICK_TOWER: GameDef = {
  id: "brick-tower",
  // Getters, so texts follow the current language.
  name: "Stack",
  get description() { return t("Drop each block right on the one below. What hangs over falls off and the tower narrows."); },
  get modes() {
    return [
      { id: "blocks", name: t("Blocks"), description: t("Starts among colorful toy bricks.") },
      { id: "studio", name: t("Studio"), description: t("Starts with hologram slabs on the app's gray.") },
      { id: "board", name: t("Motherboard"), description: t("Starts with chips over the board's traces.") },
    ];
  },
  get controls() {
    return [
      { label: t("Drop"), mouse: "left" as const, keys: [t("Space"), "↓"] },
      { label: t("Pause|game"), keys: ["P"] },
    ];
  },
  get tips() { return [t("Right on top is a Perfect, worth double"), t("Three Perfects in a row grow the block back"), t("Every 8 floors you climb into another world, and it gets harder")]; },
  create,
};
