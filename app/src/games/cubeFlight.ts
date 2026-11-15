import type { GameDef, GameHost, GameInstance } from "./types";
import { drawFigureThumb } from "../decor/figureGL";
import { stickerImage } from "../decor/stickers";
import { MACHINE_COLORS } from "../decor/store";

// "Vuelo del cubo": your machine flies through an endless stream of bricks and rival machines. Dodge the bricks,
// shoot your figures at the machines, pick up stickers for a life, a shield or faster shots. It speeds up and
// fills up the longer you last; the score is the distance plus what you take down.

type Kind = "brick" | "rival";
interface Thing { kind: Kind; x: number; y: number; vx: number; vy: number; r: number; rot: number; vr: number; color: string; hp: number; phase: number; cool: number }
interface Shot { x: number; y: number; vx: number; rot: number; img: number }
interface Bolt { x: number; y: number; vx: number; vy: number }
interface Pickup { x: number; y: number; kind: "heart" | "bolt" | "star"; t: number }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }

const BRICKS = ["#c2714a", "#8c939e", "#5f9e6e", "#d8443c", "#ecbc4c", "#6aa8ff"];
const DEFAULT_FIGURES = ["lucky-cat", "duck", "robot", "rocket"];
const rgba = (hex: string, a: number) => { const h = hex.replace("#", ""); return `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`; };

function create(canvas: HTMLCanvasElement, host: GameHost): GameInstance {
  const g = canvas.getContext("2d")!;
  let W = 0, H = 0, dpr = 1;
  const resize = () => {
    dpr = Math.min(2, window.devicePixelRatio || 1);
    W = canvas.clientWidth; H = canvas.clientHeight;
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr);
  };
  resize();
  const ro = new ResizeObserver(resize);
  ro.observe(canvas);

  // The figures to shoot, drawn once on the GPU into small images.
  const figures = (host.figures.length ? host.figures : DEFAULT_FIGURES).map((id) => {
    const c = document.createElement("canvas");
    const s = 56;
    c.width = c.height = s * dpr;
    drawFigureThumb(c.getContext("2d")!, id, s, 0.7, host.color, dpr);
    return c;
  });
  const pickImg = { heart: stickerImage("heart", host.color), bolt: stickerImage("bolt", host.color), star: stickerImage("star", host.color) };

  const ink = host.light ? "#1c1b18" : "#ebe8e1";
  const me = { x: 0, y: 0, tx: 0, ty: 0, lives: 3, hurt: 0, shield: 0, rapid: 0 };
  let things: Thing[] = [], shots: Shot[] = [], bolts: Bolt[] = [], pickups: Pickup[] = [], sparks: Spark[] = [];
  let t = 0, score = 0, distance = 0, spawnBrick = 0, spawnRival = 2, spawnPick = 12, fireCool = 0, firing = false, shotN = 0;
  let running = false, over = false, frame = 0, last = 0, hudAt = 0;
  const keys = new Set<string>();

  const reset = () => {
    Object.assign(me, { x: W * 0.18, y: H / 2, tx: W * 0.18, ty: H / 2, lives: 3, hurt: 0, shield: 0, rapid: 0 });
    things = []; shots = []; bolts = []; pickups = []; sparks = [];
    t = 0; score = 0; distance = 0; spawnBrick = 0.6; spawnRival = 3; spawnPick = 12; over = false;
  };

  const burst = (x: number, y: number, color: string, n: number) => {
    for (let i = 0; i < n; i++) {
      const a = Math.random() * Math.PI * 2, v = 60 + Math.random() * 220;
      sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 0.5 + Math.random() * 0.5, color, size: 3 + Math.random() * 5 });
    }
  };
  const hit = () => {
    if (me.hurt > 0) return;
    if (me.shield > 0) { me.shield = 0; me.hurt = 0.6; burst(me.x, me.y, host.color, 14); return; }
    me.lives--; me.hurt = 1.6; burst(me.x, me.y, "#ff6b6b", 22);
    if (me.lives <= 0) { over = true; running = false; burst(me.x, me.y, host.color, 40); host.onHud({ score: Math.floor(score), lives: 0 }); host.onOver(Math.floor(score)); }
  };

  const step = (dt: number) => {
    t += dt;
    const level = 1 + t / 35;
    // Moving: toward the pointer, or with the keys.
    const sp = 420;
    if (keys.has("ArrowUp") || keys.has("w")) me.ty -= sp * dt;
    if (keys.has("ArrowDown") || keys.has("s")) me.ty += sp * dt;
    if (keys.has("ArrowLeft") || keys.has("a")) me.tx -= sp * dt;
    if (keys.has("ArrowRight") || keys.has("d")) me.tx += sp * dt;
    me.tx = Math.max(30, Math.min(W * 0.55, me.tx)); me.ty = Math.max(28, Math.min(H - 28, me.ty));
    const k = 1 - Math.exp(-dt * 12);
    me.x += (me.tx - me.x) * k; me.y += (me.ty - me.y) * k;
    me.hurt = Math.max(0, me.hurt - dt); me.shield = Math.max(0, me.shield - dt); me.rapid = Math.max(0, me.rapid - dt);

    fireCool -= dt;
    if ((firing || keys.has(" ")) && fireCool <= 0) {
      fireCool = me.rapid > 0 ? 0.11 : 0.24;
      shots.push({ x: me.x + 26, y: me.y, vx: 640, rot: 0, img: shotN++ % figures.length });
    }

    const speed = 150 + 40 * level;
    distance += speed * dt;
    score += speed * dt * 0.05;

    spawnBrick -= dt;
    if (spawnBrick <= 0) {
      spawnBrick = Math.max(0.28, 1.1 / level) * (0.6 + Math.random() * 0.8);
      const r = 16 + Math.random() * 18;
      things.push({ kind: "brick", x: W + r, y: r + Math.random() * (H - r * 2), vx: -(speed + Math.random() * 80), vy: (Math.random() - 0.5) * 30, r, rot: Math.random() * 6, vr: (Math.random() - 0.5) * 2, color: BRICKS[Math.floor(Math.random() * BRICKS.length)], hp: 3, phase: 0, cool: 0 });
    }
    spawnRival -= dt;
    if (spawnRival <= 0) {
      spawnRival = Math.max(0.9, 3.4 / level) * (0.7 + Math.random() * 0.6);
      const c = MACHINE_COLORS[Math.floor(Math.random() * MACHINE_COLORS.length)];
      things.push({ kind: "rival", x: W + 30, y: 40 + Math.random() * (H - 80), vx: -(speed * 0.7), vy: 0, r: 20, rot: 0, vr: 0, color: host.light ? c.light : c.dark, hp: level > 2.2 ? 2 : 1, phase: Math.random() * 6, cool: 1 + Math.random() * 2 });
    }
    spawnPick -= dt;
    if (spawnPick <= 0) {
      spawnPick = 9 + Math.random() * 8;
      const kinds: Pickup["kind"][] = me.lives < 3 ? ["heart", "bolt", "star"] : ["bolt", "star"];
      pickups.push({ x: W + 20, y: 40 + Math.random() * (H - 80), kind: kinds[Math.floor(Math.random() * kinds.length)], t: 0 });
    }

    for (const s of shots) { s.x += s.vx * dt; s.rot += dt * 8; }
    for (const o of things) {
      o.x += o.vx * dt; o.rot += o.vr * dt;
      if (o.kind === "rival") {
        o.phase += dt * 2.2; o.y += Math.sin(o.phase) * 90 * dt;
        o.cool -= dt;
        // From the third level on, rival machines shoot back at you.
        if (level > 1.6 && o.cool <= 0 && o.x < W - 20) {
          o.cool = Math.max(0.9, 2.6 - level * 0.3);
          const dx = me.x - o.x, dy = me.y - o.y, L = Math.hypot(dx, dy) || 1;
          bolts.push({ x: o.x - 18, y: o.y, vx: (dx / L) * 260, vy: (dy / L) * 260 });
        }
      } else o.y += o.vy * dt;
    }
    for (const b of bolts) { b.x += b.vx * dt; b.y += b.vy * dt; }
    for (const p of pickups) { p.x -= speed * 0.8 * dt; p.t += dt; }
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vx *= 0.94; s.vy *= 0.94; s.life -= dt; }

    // Hits: your figures against bricks and rivals, everything against you.
    for (const s of shots) for (const o of things) {
      if (o.hp <= 0 || s.x < 0) continue;
      if (Math.hypot(s.x - o.x, s.y - o.y) < o.r + 12) {
        s.x = -999; o.hp--;
        burst(s.x < 0 ? o.x : s.x, o.y, o.color, 5);
        if (o.hp <= 0) { score += o.kind === "rival" ? 100 : 30; burst(o.x, o.y, o.color, o.kind === "rival" ? 26 : 14); }
      }
    }
    for (const o of things) if (o.hp > 0 && Math.hypot(me.x - o.x, me.y - o.y) < o.r + 16) { o.hp = 0; burst(o.x, o.y, o.color, 12); hit(); }
    for (const b of bolts) if (b.x > -50 && Math.hypot(me.x - b.x, me.y - b.y) < 18) { b.x = -999; hit(); }
    for (const p of pickups) if (p.t >= 0 && Math.hypot(me.x - p.x, me.y - p.y) < 30) {
      p.t = -1; burst(p.x, p.y, "#ffd34d", 12);
      if (p.kind === "heart") me.lives = Math.min(5, me.lives + 1);
      if (p.kind === "bolt") me.rapid = 7;
      if (p.kind === "star") me.shield = 7;
    }
    shots = shots.filter((s) => s.x > -50 && s.x < W + 60);
    things = things.filter((o) => o.hp > 0 && o.x > -80);
    bolts = bolts.filter((b) => b.x > -40 && b.x < W + 40 && b.y > -40 && b.y < H + 40);
    pickups = pickups.filter((p) => p.t >= 0 && p.x > -40);
    sparks = sparks.filter((s) => s.life > 0);
  };

  const cube = (x: number, y: number, s: number, color: string, alpha: number, spin: number) => {
    // A small glass cube seen from a corner, like the machine on Home.
    const c = Math.cos(spin), sn = Math.sin(spin);
    const pts = [[-1, -1, -1], [1, -1, -1], [1, 1, -1], [-1, 1, -1], [-1, -1, 1], [1, -1, 1], [1, 1, 1], [-1, 1, 1]].map(([px, py, pz]) => {
      const rx = px * c - pz * sn, rz = px * sn + pz * c;
      return [x + rx * s, y + py * s * 0.92 + rz * s * 0.35];
    });
    g.fillStyle = rgba(color, 0.14 * alpha);
    g.beginPath(); [0, 1, 2, 3].forEach((i, n) => (n ? g.lineTo(pts[i][0], pts[i][1]) : g.moveTo(pts[i][0], pts[i][1]))); g.closePath(); g.fill();
    g.strokeStyle = rgba(color, 0.9 * alpha); g.lineWidth = 1.6;
    g.beginPath();
    for (const [a, b] of [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]) { g.moveTo(pts[a][0], pts[a][1]); g.lineTo(pts[b][0], pts[b][1]); }
    g.stroke();
    // The board inside.
    g.fillStyle = rgba(color, 0.55 * alpha);
    g.fillRect(x - s * 0.6, y + s * 0.45, s * 1.2, s * 0.18);
    g.fillRect(x - s * 0.35, y - s * 0.1, s * 0.5, s * 0.5);
  };
  const brick = (o: Thing) => {
    g.save(); g.translate(o.x, o.y); g.rotate(o.rot);
    const s = o.r;
    g.fillStyle = o.color; g.beginPath(); g.roundRect(-s, -s * 0.7, s * 2, s * 1.4, 4); g.fill();
    g.fillStyle = "rgba(0,0,0,.18)"; g.fillRect(-s, s * 0.35, s * 2, s * 0.35);
    g.fillStyle = "rgba(255,255,255,.22)";
    for (const sx of [-0.5, 0.5]) { g.beginPath(); g.ellipse(sx * s, -s * 0.7, s * 0.3, s * 0.14, 0, 0, Math.PI * 2); g.fill(); }
    if (o.hp < 3) { g.strokeStyle = "rgba(0,0,0,.35)"; g.lineWidth = 2; g.beginPath(); g.moveTo(-s * 0.3, -s * 0.5); g.lineTo(0, 0); g.lineTo(-s * 0.1, s * 0.4); g.stroke(); }
    g.restore();
  };

  const draw = () => {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    // Two layers of dots drifting past, for speed.
    for (const [gap, k, a] of [[48, 0.35, 0.08], [96, 0.8, 0.14]] as const) {
      const off = (distance * k) % gap;
      g.fillStyle = rgba(ink, a);
      for (let x = -off; x < W; x += gap) for (let y = (gap / 2) % gap; y < H; y += gap) g.fillRect(x, y, 2, 2);
    }
    for (const p of pickups) {
      const img = pickImg[p.kind];
      if (img) g.drawImage(img, p.x - 20, p.y - 20 + Math.sin(p.t * 4) * 4, 40, 40);
    }
    for (const o of things) {
      if (o.kind === "brick") brick(o);
      else {
        cube(o.x, o.y, o.r * 0.8, o.color, 1, -t * 1.2 + o.phase);
        g.fillStyle = "#ff6b6b"; g.beginPath(); g.arc(o.x - o.r * 0.55, o.y - 2, 3, 0, Math.PI * 2); g.fill();
      }
    }
    for (const b of bolts) { g.fillStyle = "#ff6b6b"; g.beginPath(); g.arc(b.x, b.y, 4.5, 0, Math.PI * 2); g.fill(); }
    for (const s of shots) {
      g.save(); g.translate(s.x, s.y); g.rotate(Math.sin(s.rot) * 0.3);
      g.drawImage(figures[s.img], -18, -18, 36, 36);
      g.restore();
    }
    if (!over || me.lives > 0) {
      const flicker = me.hurt > 0 && Math.floor(t * 14) % 2 === 0;
      if (!flicker) cube(me.x, me.y, 17, host.color, 1, 0.6 + Math.sin(t * 2) * 0.15);
      if (me.shield > 0) { g.strokeStyle = rgba("#ffd34d", 0.4 + 0.3 * Math.sin(t * 8)); g.lineWidth = 2; g.beginPath(); g.arc(me.x, me.y, 30, 0, Math.PI * 2); g.stroke(); }
    }
    for (const s of sparks) { g.globalAlpha = Math.min(1, s.life * 2); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
  };

  const loop = (now: number) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    else for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.life -= dt; }
    draw();
    if (running && now - hudAt > 120) {
      hudAt = now;
      host.onHud({ score: Math.floor(score), lives: me.lives, power: me.shield > 0 ? "Escudo" : me.rapid > 0 ? "Disparo rápido" : undefined });
    }
    if (running || sparks.length) frame = requestAnimationFrame(loop);
  };
  const kick = () => { cancelAnimationFrame(frame); last = performance.now(); frame = requestAnimationFrame(loop); };

  const local = (e: PointerEvent) => { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  const onMove = (e: PointerEvent) => { if (!running) return; const [x, y] = local(e); me.tx = x; me.ty = y; };
  const onDown = (e: PointerEvent) => { if (e.button === 0 && running) { firing = true; canvas.setPointerCapture(e.pointerId); } };
  const onUp = () => { firing = false; };
  const onKey = (e: KeyboardEvent) => {
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " ", "w", "a", "s", "d"].includes(k)) { e.preventDefault(); if (e.type === "keydown") keys.add(k); else keys.delete(k); }
  };
  // Hidden window: the game waits (no frames drawn, nothing moves).
  const onHidden = () => { if (document.hidden && running) { running = false; cancelAnimationFrame(frame); } };
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerdown", onDown);
  window.addEventListener("pointerup", onUp);
  window.addEventListener("keydown", onKey);
  window.addEventListener("keyup", onKey);
  document.addEventListener("visibilitychange", onHidden);

  return {
    start: () => { reset(); running = true; host.onHud({ score: 0, lives: 3 }); kick(); },
    pause: () => { running = false; keys.clear(); firing = false; cancelAnimationFrame(frame); draw(); },
    resume: () => { if (!over) { running = true; kick(); } },
    stop: () => {
      running = false; cancelAnimationFrame(frame); ro.disconnect();
      canvas.removeEventListener("pointermove", onMove); canvas.removeEventListener("pointerdown", onDown);
      window.removeEventListener("pointerup", onUp); window.removeEventListener("keydown", onKey); window.removeEventListener("keyup", onKey);
      document.removeEventListener("visibilitychange", onHidden);
    },
  };
}

export const CUBE_FLIGHT: GameDef = {
  id: "cube-flight",
  name: "Vuelo del cubo",
  description: "Esquiva los bloques y derriba a las otras máquinas con tus figuras.",
  controls: ["Mueve la máquina con el mouse o con W A S D", "Dispara con clic o con la barra espaciadora", "Los stickers dan una vida, escudo o disparo rápido"],
  create,
};
