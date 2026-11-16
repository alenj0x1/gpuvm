import type { GameDef, GameHost, GameInstance } from "./types";
import { drawFigureThumb } from "../decor/figureGL";
import { t } from "../i18n";

// "Torre de bloques": your machine is the base, and a block slides from side to side above the top of the tower.
// One click drops it: what hangs past the block below falls off and what is left is the new top, so a miss makes the
// tower narrower. Landing it right on top is a Perfect: it keeps its width, and three in a row make the block grow
// back a little. The machine's first figure rides on the top block. The tower climbs and the camera follows. Every
// eight floors it climbs into another world (blocks, a motherboard, the studio, then space), each with its own kind of
// block, and it gets harder as it goes: faster, then a speed that swells and eases, then blocks from either side.
// Missing the tower completely ends the game. In a demo it plays by itself.

type World = "studio" | "board" | "blocks" | "space";
interface Floor { x: number; w: number; color: string; world: World }
const ORDER: World[] = ["blocks", "board", "studio", "space"];
const FLOORS_PER_ZONE = 8;
const zoneName = (w: World) => (w === "blocks" ? t("Bloques") : w === "board" ? t("Placa base") : w === "studio" ? t("Estudio") : t("Espacio"));
interface Piece { x: number; y: number; w: number; vx: number; vy: number; rot: number; vr: number; color: string }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }

const rgba = (hex: string, a: number) => { const h = hex.replace("#", ""); return `rgba(${parseInt(h.slice(0, 2), 16)},${parseInt(h.slice(2, 4), 16)},${parseInt(h.slice(4, 6), 16)},${a})`; };
const BRICKS = ["#cc4f43", "#d9a03a", "#3f6fb5", "#4f9c45", "#e9e3d6", "#8a5cc2"];

/** The world behind, scrolled by how high the camera has climbed. */
function background(g: CanvasRenderingContext2D, w: number, h: number, world: World, cam: number, light: boolean) {
  if (world === "space") {
    // Up past the sky: deep graphite with stars drifting by as the tower climbs.
    g.fillStyle = light ? "#20232b" : "#0f1013"; g.fillRect(0, 0, w, h);
    for (let n = 0; n < 70; n++) {
      const x = (n * 97.3) % w, y = (((n * 53.7 + cam * (0.15 + (n % 3) * 0.1)) % (h + 20)) + h + 20) % (h + 20) - 10, s = n % 7 === 0 ? 2 : 1;
      g.fillStyle = n % 5 === 0 ? "rgba(255,236,190,.8)" : "rgba(235,232,225,.55)"; g.fillRect(x, y, s, s);
    }
  } else if (world === "board") {
    // Kept close to its own tone: it is only a backdrop, the chips of the tower must stand out from it.
    g.fillStyle = light ? "#e4ebe6" : "#121814"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "#d2ddd5" : "#1b2a23"; g.lineWidth = 1.5;
    const off = (cam * 0.4) % 22;
    for (let row = -1; row < h / 22 + 1; row++) {
      const y = row * 22 + off, i = Math.floor((cam * 0.4) / 22) - row;
      g.beginPath();
      for (let x = -((i * 137) % 380 + 380) % 380; x < w; x += 380) { const len = 160 + (((i * 53) % 140) + 140) % 140; g.moveTo(x, y); g.lineTo(x + len, y); g.lineTo(x + len + 14, y + (i % 2 ? 14 : -14)); }
      g.stroke();
    }
  } else if (world === "blocks") {
    // A sky that gets deeper as the tower climbs, with clouds of blocks going by.
    const k = Math.min(1, cam / 2400);
    const sky = g.createLinearGradient(0, 0, 0, h);
    sky.addColorStop(0, light ? mix("#8fbfe2", "#3e6f9e", k) : mix("#4d7899", "#1d3047", k));
    sky.addColorStop(1, light ? mix("#e6f0ea", "#9cc2df", k) : mix("#a7c0bb", "#4d7899", k));
    g.fillStyle = sky; g.fillRect(0, 0, w, h);
    g.fillStyle = light ? "#ffffff" : "#e3e9ec";
    for (let n = 0; n < 6; n++) {
      const y = ((n * 170 + cam * 0.5) % (h + 170)) - 80, x = (n * 233) % Math.max(1, w - 80), u = 12;
      g.globalAlpha = 0.9; g.fillRect(x, y, u * 6, u); g.fillRect(x + u, y - u, u * 3, u);
    }
    g.globalAlpha = 1;
  } else {
    g.fillStyle = light ? "#f2f1ee" : "#161616"; g.fillRect(0, 0, w, h);
    g.strokeStyle = light ? "rgba(28,27,24,.06)" : "rgba(235,232,225,.05)"; g.lineWidth = 1;
    const off = (cam * 0.3) % 48;
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

/** One block of the tower, drawn as the world's kind of piece: a hologram slab, a chip, or a toy brick. */
function block(g: CanvasRenderingContext2D, x: number, y: number, w: number, h: number, color: string, world: World, light: boolean, ink: string) {
  if (w <= 0) return;
  if (world === "blocks") {
    g.fillStyle = color; g.fillRect(x, y, w, h);
    g.fillStyle = "rgba(0,0,0,.16)"; g.fillRect(x, y + h - 4, w, 4);
    g.fillStyle = "rgba(255,255,255,.2)"; g.fillRect(x + 3, y + 3, Math.min(w - 6, w * 0.3), 3);
    // Studs on top, one every stud's width, as many as fit.
    const s = h * 0.62, n = Math.max(1, Math.floor(w / (s * 1.6)));
    for (let k = 0; k < n; k++) {
      const sx = x + (w / n) * (k + 0.5) - s / 2;
      g.fillStyle = color; g.fillRect(sx, y - 5, s, 5);
      g.fillStyle = "rgba(255,255,255,.22)"; g.fillRect(sx + 2, y - 5, s * 0.35, 2);
    }
  } else if (world === "board") {
    g.fillStyle = light ? "#2b3034" : "#3a4449"; g.fillRect(x, y, w, h);
    g.fillStyle = light ? "#9aa1a3" : "#a7aeb0";
    for (let px = x + 5; px < x + w - 4; px += 9) { g.fillRect(px, y - 3, 3, 3); g.fillRect(px, y + h, 3, 3); }
    g.fillStyle = color; g.fillRect(x + 6, y + h / 2 - 2, Math.max(0, Math.min(18, w - 12)), 4);
  } else {
    g.fillStyle = rgba(color, light ? 0.16 : 0.2); g.fillRect(x, y, w, h);
    g.strokeStyle = rgba(color, 0.95); g.lineWidth = 1.6; g.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    g.strokeStyle = rgba(ink, 0.12); g.lineWidth = 1; g.beginPath();
    for (let sy = y + 4; sy < y + h - 2; sy += 4) { g.moveTo(x + 2, sy); g.lineTo(x + w - 2, sy); }
    g.stroke();
  }
}

function create(canvas: HTMLCanvasElement, host: GameHost): GameInstance {
  const g = canvas.getContext("2d")!;
  // The world it starts in (the mode picked), then the others in order as the tower climbs.
  let startWorld = (["studio", "board", "blocks"].includes(host.mode) ? host.mode : host.world && ["studio", "board", "blocks"].includes(host.world) ? host.world : "blocks") as World;
  const zoneOf = (floor: number) => { const k = ORDER.indexOf(startWorld); return ORDER[(k + Math.floor(floor / FLOORS_PER_ZONE)) % ORDER.length]; };
  let world: World = startWorld, bannerAt = -9;
  const demo = !!host.demo;
  let prevWorld: World | null = null, fade = 1;
  let W = 0, H = 0, dpr = 1;
  const resize = () => { dpr = Math.min(2, window.devicePixelRatio || 1); W = canvas.clientWidth; H = canvas.clientHeight; canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); };
  resize();
  const ro = new ResizeObserver(resize);
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
  const bh = () => 36 * unit();
  const baseW = () => Math.min(W * 0.5, 300 * unit());
  // Where a floor sits on screen: the base near the bottom, each floor one block higher, scrolled by the camera.
  const yOf = (i: number) => H - 64 * unit() - (i + 1) * bh() + cam;
  const colorFor = (i: number) => zoneOf(i) === "blocks" ? BRICKS[i % BRICKS.length] : i % 3 === 0 ? host.player.color : mix(host.player.color, host.light ? "#ffffff" : "#000000", 0.25 + (i % 3) * 0.12);
  // Faster with every floor; from the second world the speed swells and eases as the block crosses.
  const speed = () => (260 + Math.min(560, floors.length * 13)) * unit() * (floors.length > FLOORS_PER_ZONE ? 1 + 0.4 * Math.sin(clock * 3.2) : 1);
  const nextBlock = () => {
    const top = floors[floors.length - 1];
    // From the third world on, the next block may come from either side.
    const fromLeft = floors.length > FLOORS_PER_ZONE * 2 ? Math.random() < 0.5 : floors.length % 2 === 1;
    moving = { x: fromLeft ? -top.w : W, w: top.w, dir: fromLeft ? 1 : -1, color: colorFor(floors.length) };
    // In a demo it aims for the top with a small, random error now and then.
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
      // Missed the tower: the block falls and the game is over.
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
      // Three in a row: the block grows back a little (never past the base).
      if (streak % 3 === 0) { const grow = Math.min(baseW() - w, 18 * unit()); x -= grow / 2; w += grow; label = t("¡Crece!"); }
      else label = t("¡Perfecto!");
      perfectAt = clock;
      burst(x + w / 2, y, moving.color, 14);
      score += 2;
    } else {
      streak = 0; score += 1;
      // What hangs past the block below falls off.
      const cutLeft = moving.x < left, cx = cutLeft ? moving.x : right, cw = moving.w - w;
      falling.push({ x: cx, y, w: cw, vx: (cutLeft ? -1 : 1) * 80, vy: -40, rot: 0, vr: (cutLeft ? -1 : 1) * 3, color: moving.color });
    }
    floors.push({ x, w, color: moving.color, world: zoneOf(floors.length) });
    // Into the next world: the backdrop fades over and its name shows for a moment.
    const next = zoneOf(floors.length);
    if (next !== world) { prevWorld = world; world = next; fade = 0; bannerAt = clock; }
    // The camera climbs to keep the top in the upper third.
    camTo = Math.max(0, (floors.length + 1) * bh() - H * 0.55);
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
    cam += (camTo - cam) * Math.min(1, dt * 5);
    fade = Math.min(1, fade + dt / 0.7);
    if (prevWorld && fade < 1) { background(g, W, H, prevWorld, cam, host.light); g.globalAlpha = fade * fade * (3 - 2 * fade); }
    background(g, W, H, world, cam, host.light);
    g.globalAlpha = 1;
    const h = bh(), u = unit();
    // The machine: a glass slab with its color, the base of everything.
    const base = floors[0];
    if (base) {
      const by = yOf(0);
      g.fillStyle = rgba(host.player.color, 0.16); g.fillRect(base.x - 10 * u, by, base.w + 20 * u, H - by + 40);
      g.strokeStyle = host.player.color; g.lineWidth = 2; g.strokeRect(base.x - 10 * u, by, base.w + 20 * u, H - by + 40);
      g.fillStyle = rgba(host.player.color, 0.55);
      g.fillRect(base.x + base.w * 0.1, by + 14 * u, base.w * 0.35, 8 * u); g.fillRect(base.x + base.w * 0.55, by + 12 * u, base.w * 0.3, 12 * u);
    }
    for (let i = 1; i < floors.length; i++) { const f = floors[i], y = yOf(i); if (y > H + h || y < -h * 2) continue; block(g, f.x, y, f.w, h, f.color, f.world, host.light, ink); }
    // The figure rides on the top block.
    const top = floors[floors.length - 1];
    if (top && !over) { const s = 54 * u, y = yOf(floors.length - 1); g.drawImage(sprite, top.x + top.w / 2 - s / 2, y - s + (world === "blocks" ? -3 : 2), s, s); }
    if (moving.w > 0 && !over) block(g, moving.x, yOf(floors.length), moving.w, h, moving.color, zoneOf(floors.length), host.light, ink);
    for (const p of falling) {
      p.vy += 900 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.rot += p.vr * dt;
      g.save(); g.translate(p.x + p.w / 2, p.y + h / 2); g.rotate(p.rot); block(g, -p.w / 2, -h / 2, p.w, h, p.color, world, host.light, ink); g.restore();
    }
    falling = falling.filter((p) => p.y < H + 80);
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vy += 420 * dt; s.life -= dt; g.globalAlpha = Math.max(0, Math.min(1, s.life * 2)); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
    sparks = sparks.filter((s) => s.life > 0);
    // A new world: its name on a small plate at the top, for a moment.
    const sinceZone = clock - bannerAt;
    if (sinceZone < 2.2 && !demo) {
      const a = Math.min(1, sinceZone * 4, (2.2 - sinceZone) * 3), text = t("Zona {name}", { name: zoneName(world) });
      g.globalAlpha = a; g.font = `600 ${14 * u}px 'Plus Jakarta Sans', sans-serif`;
      const tw = g.measureText(text).width + 28, x = W / 2 - tw / 2, y = 20 * u;
      g.fillStyle = host.light ? "rgba(255,255,255,.9)" : "rgba(28,28,28,.9)"; g.beginPath(); g.roundRect(x, y, tw, 30 * u, 8); g.fill();
      g.fillStyle = ink; g.textAlign = "center"; g.fillText(text, W / 2, y + 20 * u); g.textAlign = "left"; g.globalAlpha = 1;
    }
    // "Perfect" over the top for a moment.
    const since = clock - perfectAt;
    if (label && since < 0.9 && top) {
      g.globalAlpha = Math.max(0, 1 - since / 0.9);
      g.font = `700 ${15 * u}px 'Plus Jakarta Sans', sans-serif`; g.textAlign = "center"; g.fillStyle = host.player.color;
      g.fillText(label, top.x + top.w / 2, yOf(floors.length - 1) - 50 * u - since * 30);
      g.textAlign = "left"; g.globalAlpha = 1;
    }
  };
  const loop = (now: number) => {
    const dt = Math.min(0.04, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    draw(dt);
    if (running && now - hudAt > 100) { hudAt = now; host.onHud({ score, lives: 1, power: streak >= 2 ? t("{n} perfectos seguidos", { n: streak }) : undefined }); }
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
  // Getters: the texts come out in the language in use.
  get name() { return t("Torre de bloques"); },
  get description() { return t("Suelta cada bloque justo sobre el anterior. Lo que sobresale se cae y la torre se angosta."); },
  get modes() {
    return [
      { id: "blocks", name: t("Bloques"), description: t("Empieza entre bloques de juguete de colores.") },
      { id: "studio", name: t("Estudio"), description: t("Empieza con placas de holograma sobre el gris de la app.") },
      { id: "board", name: t("Placa base"), description: t("Empieza con chips sobre las pistas de la placa.") },
    ];
  },
  get controls() {
    return [
      { label: t("Soltar"), mouse: "left" as const, keys: [t("Espacio"), "↓"] },
      { label: t("Pausa"), keys: ["P"] },
    ];
  },
  get tips() { return [t("Encima justo es Perfecto y vale doble"), t("Tres perfectos seguidos hacen crecer el bloque"), t("Cada 8 pisos subes a otro mundo y se pone más difícil")]; },
  create,
};
