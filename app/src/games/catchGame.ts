import type { GameDef, GameHost, GameInstance } from "./types";
import { settledResize } from "./types";
import { drawFigureThumb } from "../decor/figureGL";
import { FIGURES } from "../decor/figures";
import { stickerImage } from "../decor/stickers";
import { background, cube, type World } from "./bitHop";
import { t } from "../i18n";

type Kind = "figure" | "gold" | "bug" | "pick";
type Pick = "clone" | "wide" | "slow" | "magnet" | "shield" | "heart";
interface Drop { kind: Kind; x: number; y: number; vy: number; rot: number; vr: number; img: HTMLCanvasElement | null; pick?: Pick }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }

const PICKS: Record<Pick, { sticker: string; secs: number; label: () => string }> = {
  clone: { sticker: "rocket", secs: 10, label: () => t("Clone") },
  wide: { sticker: "gem", secs: 10, label: () => t("Wider") },
  slow: { sticker: "moon", secs: 6, label: () => t("Slow time") },
  magnet: { sticker: "bolt", secs: 8, label: () => t("Magnet") },
  shield: { sticker: "star", secs: 12, label: () => t("Shield") },
  heart: { sticker: "heart", secs: 0, label: () => t("Life") },
};
const MAX_LIVES = 5;

function create(canvas: HTMLCanvasElement, host: GameHost): GameInstance {
  const g = canvas.getContext("2d")!;
  let world = (["studio", "board", "blocks"].includes(host.mode) ? host.mode : host.world && ["studio", "board", "blocks"].includes(host.world) ? host.world : "studio") as World;
  const demo = !!host.demo;
  let prevWorld: World | null = null, fade = 1;
  let W = 0, H = 0, dpr = 1;
  const resize = () => { dpr = Math.min(2, window.devicePixelRatio || 1); W = canvas.clientWidth; H = canvas.clientHeight; canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); };
  resize();
  const ro = settledResize(() => { resize(); if (!running) draw(0); });
  ro.observe(canvas);
  const unit = () => Math.max(0.75, Math.min(1.3, H / 520));

  const thumb = (id: string, color: string, size = 72) => { const c = document.createElement("canvas"); c.width = c.height = size * dpr; drawFigureThumb(c.getContext("2d")!, id, size, 0.7, color, dpr); return c; };
  const pool = FIGURES.map((f) => f.id).sort(() => Math.random() - 0.5).slice(0, 8);
  const sprites = pool.map((id) => thumb(id, host.player.color));
  const gold = thumb(pool[0], "#e8b23a");
  let rider = thumb(host.player.figures[0] ?? "duck", host.player.color);
  const pickImg = Object.fromEntries(Object.entries(PICKS).map(([k, p]) => [k, stickerImage(p.sticker, host.player.color)])) as Record<Pick, HTMLCanvasElement | null>;
  const bugImg = stickerImage("spider", host.player.color);

  const me = { x: 0, tx: 0 };
  let clone = { x: 0, on: false };
  const power: Record<Pick, number> = { clone: 0, wide: 0, slow: 0, magnet: 0, shield: 0, heart: 0 };
  let drops: Drop[] = [], sparks: Spark[] = [], score = 0, lives = 3, clock = 0, scroll = 0, spawn = 0.6, keys = 0;
  let running = false, over = false, frame = 0, last = 0, hudAt = 0, hurt = 0, combo = 0;
  const halfW = () => (power.wide > 0 ? 84 : 54) * unit();
  const floorY = () => H - 46 * unit();
  const reset = () => {
    me.x = me.tx = W / 2; clone = { x: W / 2, on: false };
    (Object.keys(power) as Pick[]).forEach((k) => (power[k] = 0));
    drops = []; sparks = []; score = 0; lives = 3; clock = 0; scroll = 0; spawn = 0.6; over = false; hurt = 0; combo = 0;
  };
  const burst = (x: number, y: number, color: string, n: number) => {
    for (let i = 0; i < n; i++) { const a = Math.random() * Math.PI * 2, v = 60 + Math.random() * 220; sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v - 60, life: 0.4 + Math.random() * 0.4, color, size: 2 + Math.random() * 3 }); }
  };
  const level = () => Math.min(1, score / 160);
  const spawnOne = () => {
    const r = Math.random(), x = 30 * unit() + Math.random() * (W - 60 * unit());
    const vy = (110 + level() * 190 + Math.random() * 40) * unit();
    let d: Drop;
    if (r < 0.07) { const keys = Object.keys(PICKS) as Pick[]; const pick = keys[Math.floor(Math.random() * keys.length)]; d = { kind: "pick", x, y: -30, vy: vy * 0.8, rot: 0, vr: 1.5, img: pickImg[pick], pick }; }
    else if (r < 0.07 + 0.08 + level() * 0.08) d = { kind: "bug", x, y: -30, vy: vy * 1.1, rot: 0, vr: 0, img: bugImg };
    else if (r < 0.26 + level() * 0.08) d = { kind: "gold", x, y: -30, vy: vy * 1.15, rot: 0, vr: (Math.random() - 0.5) * 3, img: gold };
    else d = { kind: "figure", x, y: -30, vy, rot: 0, vr: (Math.random() - 0.5) * 2.5, img: sprites[Math.floor(Math.random() * sprites.length)] };
    drops.push(d);
  };
  const lose = (x: number) => {
    if (power.shield > 0) { power.shield = 0; burst(x, floorY(), "#ffd34d", 14); return; }
    lives--; hurt = 0.5; combo = 0;
    burst(x, floorY(), "#ff6b6b", 16);
    if (lives <= 0) {
      if (demo) { reset(); return; }
      over = true; running = false; burst(me.x, floorY() - 20, host.player.color, 40);
      host.onHud({ score, lives: 0 }); host.onOver(score);
    }
  };
  const caught = (d: Drop, x: number) => {
    const y = floorY() - 24 * unit();
    if (d.kind === "bug") { if (power.shield > 0) { power.shield = 0; burst(x, y, "#ffd34d", 14); } else { lives--; hurt = 0.5; combo = 0; burst(x, y, "#ff6b6b", 18); if (lives <= 0) lose(x); } return; }
    if (d.kind === "pick" && d.pick) {
      if (d.pick === "heart") lives = Math.min(MAX_LIVES, lives + 1); else power[d.pick] = PICKS[d.pick].secs;
      if (d.pick === "clone") { clone.on = true; clone.x = me.x; }
      burst(x, y, host.player.color, 20); return;
    }
    combo++;
    score += (d.kind === "gold" ? 5 : 1) + (combo >= 10 ? 1 : 0);
    burst(x, y, d.kind === "gold" ? "#e8b23a" : host.player.color, d.kind === "gold" ? 16 : 8);
  };
  const step = (dt: number) => {
    clock += dt;
    const slow = power.slow > 0 ? 0.45 : 1, fdt = dt * slow;
    for (const k of Object.keys(power) as Pick[]) if (k !== "heart") power[k] = Math.max(0, power[k] - dt);
    if (power.clone <= 0) clone.on = false;
    hurt = Math.max(0, hurt - dt);
    if (keys) me.tx = Math.max(0, Math.min(W, me.tx + keys * 620 * unit() * dt));
    if (demo) {
      const target = drops.filter((d) => d.kind !== "bug").sort((a, b) => b.y - a.y)[0];
      if (target) me.tx = target.x;
    }
    me.x += (me.tx - me.x) * Math.min(1, dt * 16);
    if (clone.on) clone.x += ((W - me.x) - clone.x) * Math.min(1, dt * 12);
    spawn -= dt;
    if (spawn <= 0) { spawnOne(); spawn = Math.max(0.28, 0.95 - level() * 0.6) * (0.7 + Math.random() * 0.6); }
    scroll += 40 * dt;
    const fy = floorY(), hw = halfW();
    for (const d of drops) {
      if (power.magnet > 0 && d.kind !== "bug") { const tx = clone.on && Math.abs(d.x - clone.x) < Math.abs(d.x - me.x) ? clone.x : me.x; d.x += (tx - d.x) * Math.min(1, fdt * 2.2); }
      d.y += d.vy * fdt; d.rot += d.vr * fdt;
    }
    for (let i = drops.length - 1; i >= 0; i--) {
      const d = drops[i];
      if (d.y >= fy - 44 * unit() && d.y <= fy) {
        const hitMe = Math.abs(d.x - me.x) < hw, hitClone = clone.on && Math.abs(d.x - clone.x) < hw;
        if (hitMe || hitClone) { caught(d, d.x); drops.splice(i, 1); if (over) return; continue; }
      }
      if (d.y > fy + 10) {
        drops.splice(i, 1);
        if (d.kind === "figure" || d.kind === "gold") { lose(d.x); if (over) return; }
      }
    }
  };
  const draw = (dt: number) => {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    fade = Math.min(1, fade + dt / 0.7);
    if (prevWorld && fade < 1) { background(g, W, H, prevWorld, scroll, host.light, clock); g.globalAlpha = fade * fade * (3 - 2 * fade); }
    background(g, W, H, world, scroll, host.light, clock);
    g.globalAlpha = 1;
    const u = unit(), fy = floorY(), hw = halfW();
    if (power.slow > 0) { g.fillStyle = "rgba(125,156,240,.07)"; g.fillRect(0, 0, W, H); }
    g.fillStyle = host.light ? "rgba(28,27,24,.12)" : "rgba(235,232,225,.1)"; g.fillRect(0, fy + 12 * u, W, 2);
    for (const d of drops) {
      const s = (d.kind === "pick" ? 46 : d.kind === "bug" ? 48 : 66) * u;
      if (d.kind === "gold") { g.fillStyle = "rgba(232,178,58,.18)"; g.beginPath(); g.arc(d.x, d.y, s * 0.62, 0, Math.PI * 2); g.fill(); }
      if (!d.img) continue;
      g.save(); g.translate(d.x, d.y); g.rotate(d.kind === "figure" || d.kind === "gold" ? d.rot * 0.25 : d.rot * 0.15); g.drawImage(d.img, -s / 2, -s / 2, s, s); g.restore();
    }
    const catcher = (x: number, ghost: boolean) => {
      g.globalAlpha = ghost ? 0.6 : 1;
      cube(g, x, fy, 18 * u, host.player.color, 0);
      g.fillStyle = `${host.player.color}`; g.globalAlpha *= 0.85; g.fillRect(x - hw, fy - 26 * u, hw * 2, 5 * u);
      g.globalAlpha = ghost ? 0.6 : 1;
      g.fillRect(x - hw, fy - 40 * u, 5 * u, 19 * u); g.fillRect(x + hw - 5 * u, fy - 40 * u, 5 * u, 19 * u);
      const s = 50 * u; g.drawImage(rider, x - s / 2, fy - 30 * u - s * 0.95, s, s);
      g.globalAlpha = 1;
    };
    if (!over) {
      if (hurt > 0 && Math.floor(hurt * 16) % 2) g.globalAlpha = 0.4;
      catcher(me.x, false);
      if (clone.on) catcher(clone.x, true);
      if (power.shield > 0) { g.strokeStyle = "rgba(255,211,77,.55)"; g.lineWidth = 2; g.beginPath(); g.ellipse(me.x, fy - 18 * u, hw + 10 * u, 34 * u, 0, 0, Math.PI * 2); g.stroke(); }
    }
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vy += 420 * dt; s.life -= dt; g.globalAlpha = Math.max(0, Math.min(1, s.life * 2)); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
    sparks = sparks.filter((s) => s.life > 0);
  };
  const activePower = () => {
    const on = (Object.keys(PICKS) as Pick[]).filter((k) => k !== "heart" && power[k] > 0).sort((a, b) => power[b] - power[a])[0];
    return on ? `${PICKS[on].label()} ${Math.ceil(power[on])} s` : undefined;
  };
  const loop = (now: number) => {
    const dt = Math.min(0.04, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    draw(dt);
    if (running && now - hudAt > 100) { hudAt = now; host.onHud({ score, lives, power: activePower() }); }
    if (running || sparks.length) frame = requestAnimationFrame(loop);
  };
  const kick = () => { cancelAnimationFrame(frame); last = performance.now(); frame = requestAnimationFrame(loop); };
  const held = new Set<string>();
  const onKey = (e: KeyboardEvent) => {
    const k = e.key.toLowerCase(), dir = k === "a" || k === "arrowleft" ? -1 : k === "d" || k === "arrowright" ? 1 : 0;
    if (!dir) return;
    e.preventDefault();
    if (e.type === "keydown") held.add(k); else held.delete(k);
    keys = (held.has("a") || held.has("arrowleft") ? -1 : 0) + (held.has("d") || held.has("arrowright") ? 1 : 0);
  };
  const onMove = (e: PointerEvent) => { const r = canvas.getBoundingClientRect(); me.tx = Math.max(0, Math.min(W, e.clientX - r.left)); };
  if (!demo) { canvas.addEventListener("pointermove", onMove); window.addEventListener("keydown", onKey); window.addEventListener("keyup", onKey); }
  return {
    cast: ({ player, mode }) => {
      if (player.name !== host.player.name || player.color !== host.player.color) {
        host.player = player; host.color = player.color; host.figures = player.figures;
        rider = thumb(player.figures[0] ?? "duck", player.color);
      }
      const w = (["studio", "board", "blocks"].includes(mode) ? mode : world) as World;
      if (w !== world) { prevWorld = world; world = w; fade = 0; }
    },
    start: () => { reset(); running = true; host.onHud({ score: 0, lives: 3 }); kick(); },
    pause: () => { running = false; cancelAnimationFrame(frame); draw(0); },
    resume: () => { if (!over) { running = true; kick(); } },
    stop: () => { running = false; cancelAnimationFrame(frame); ro.disconnect(); canvas.removeEventListener("pointermove", onMove); window.removeEventListener("keydown", onKey); window.removeEventListener("keyup", onKey); },
  };
}

export const CATCH: GameDef = {
  id: "catch",
  // Getters, so texts follow the current language.
  name: "Cache",
  get description() { return t("Catch the falling figures before they hit the floor. Each one that falls costs a heart."); },
  get modes() {
    return [
      { id: "studio", name: t("Studio"), description: t("On the app's gray.") },
      { id: "board", name: t("Motherboard"), description: t("Over the board's traces.") },
      { id: "blocks", name: t("Blocks"), description: t("Under a sky with block clouds.") },
    ];
  },
  get controls() {
    return [
      { label: t("Move"), mouse: "move" as const, keys: ["A", "D"] },
      { label: t("Pause|game"), keys: ["P"] },
    ];
  },
  get tips() {
    return [
      t("Golden ones are worth five; spiders are better left to fall"),
      t("Stickers help: a clone that catches beside you, wider, slow time, a magnet, a shield or a heart"),
      t("Ten in a row without a miss score one extra each"),
    ];
  },
  create,
};
