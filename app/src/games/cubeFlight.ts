import type { GameDef, GameHost, GameInstance } from "./types";
import { drawFigureThumb } from "../decor/figureGL";
import { stickerImage } from "../decor/stickers";
import { MACHINE_COLORS } from "../decor/store";

// "Overclock": your machine flies through bricks and rival machines. Move with the keys and aim with the mouse
// anywhere, shooting your own figures. Stickers drift by with new weapons (faster, three at a time, in bursts, all
// around), a shield or a life. Taking things down fills the frenzy: everything speeds up, your figures come out huge
// and go through everything for a few seconds. Shooting and taking things down charge the ability on the right button
// (a pulse at first); cores that drift by swap it for another (laser, slow time, clones, magnet). Every 40 seconds the
// flight crosses into another zone: the galaxy, a motherboard, a world of blocks. It never ends; it only gets fuller.

type Kind = "brick" | "rival";
type Weapon = "normal" | "rapid" | "triple" | "burst" | "ring";
type PickKind = "heart" | "star" | Exclude<Weapon, "normal">;
interface Thing { kind: Kind; x: number; y: number; vx: number; vy: number; r: number; rot: number; vr: number; color: string; hp: number; phase: number; cool: number }
interface Shot { x: number; y: number; vx: number; vy: number; img: HTMLCanvasElement; size: number; hits: Set<Thing> | null }
interface Bolt { x: number; y: number; vx: number; vy: number }
interface Pickup { x: number; y: number; kind: PickKind; t: number }
interface Spark { x: number; y: number; vx: number; vy: number; life: number; color: string; size: number }
interface Star { x: number; y: number; z: number }

const BRICKS = ["#c2714a", "#8c939e", "#5f9e6e", "#d8443c", "#ecbc4c", "#6aa8ff"];
const DEFAULT_FIGURES = ["lucky-cat", "duck", "robot", "rocket"];
/** Each pickup is a sticker: what it gives and for how long. */
const PICKS: Record<PickKind, { sticker: string; label: string; secs: number }> = {
  heart: { sticker: "heart", label: "Vida", secs: 0 },
  star: { sticker: "star", label: "Escudo", secs: 8 },
  rapid: { sticker: "bolt", label: "Disparo rápido", secs: 10 },
  triple: { sticker: "gem", label: "Disparo triple", secs: 10 },
  burst: { sticker: "fire", label: "Ráfaga", secs: 10 },
  ring: { sticker: "rocket", label: "Todas direcciones", secs: 8 },
};
const FRENZY_SECS = 8;

/** The abilities on the right button: what each is called, how long it lasts and its glyph on the cores. */
type AbilityId = "pulse" | "laser" | "slow" | "clones" | "magnet";
const ABILITIES: Record<AbilityId, { name: string; secs: number }> = {
  pulse: { name: "Pulso", secs: 0.6 },
  laser: { name: "Láser", secs: 1.8 },
  slow: { name: "Tiempo lento", secs: 5 },
  clones: { name: "Clones", secs: 8 },
  magnet: { name: "Imán", secs: 8 },
};
const ABILITY_IDS = Object.keys(ABILITIES) as AbilityId[];
/** The zones the flight crosses, one after another. */
const ZONES = ["Galaxia", "Placa base", "Bloques"] as const;
const ZONE_SECS = 40;
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

  // The figures to shoot, drawn once on the GPU into small images (big enough for the frenzy's giant ones).
  const spritesFor = (ids: string[], color: string) => (ids.length ? ids : DEFAULT_FIGURES).map((id) => {
    const c = document.createElement("canvas");
    const s = 96;
    c.width = c.height = s * dpr;
    drawFigureThumb(c.getContext("2d")!, id, s, 0.7, color, dpr);
    return c;
  });
  const figures = spritesFor(host.player.figures, host.player.color);
  const team = host.mode === "team";
  // Your other machines, flying beside you: each aims at the nearest thing and shoots its own figures.
  const SLOTS = [[-46, -58], [-46, 58], [-92, 0]];
  const bots = host.team.slice(0, 3).map((m, i) => ({ ...m, sprites: spritesFor(m.figures, m.color), x: 0, y: 0, slot: SLOTS[i], cool: 0.3 * i, n: 0 }));
  const pickImg = Object.fromEntries(Object.entries(PICKS).map(([k, p]) => [k, stickerImage(p.sticker, host.color)])) as Record<PickKind, HTMLCanvasElement | null>;

  const ink = host.light ? "#1c1b18" : "#ebe8e1";
  // The ability: which one, how charged, and while it runs how long is left; the pulse's ring; the cores that swap it.
  const ab = { id: "pulse" as AbilityId, charge: 0, active: 0 };
  let ring: { x: number; y: number; r: number } | null = null;
  let cores: { x: number; y: number; id: AbilityId; t: number }[] = [], spawnCore = 18;
  let scroll = 0, zoneShown = -1, zoneBanner = 0;
  const me = { x: 0, y: 0, vx: 0, vy: 0, lives: 3, hurt: 0, shield: 0, weapon: "normal" as Weapon, weaponT: 0 };
  const aim = { x: 0, y: 0, set: false };
  let things: Thing[] = [], shots: Shot[] = [], bolts: Bolt[] = [], pickups: Pickup[] = [], sparks: Spark[] = [];
  const stars: Star[] = Array.from({ length: 140 }, () => ({ x: Math.random(), y: Math.random(), z: 0.2 + Math.random() * 0.8 }));
  let t = 0, score = 0, warp = 1, spawnBrick = 0, spawnRival = 2, spawnPick = 8, fireCool = 0, firing = false, shotN = 0, burstLeft = 0, burstCool = 0;
  let meter = 0, frenzy = 0, flash = 0;
  let running = false, over = false, frame = 0, last = 0, hudAt = 0;
  const keys = new Set<string>();

  const reset = () => {
    Object.assign(me, { x: W * 0.25, y: H / 2, vx: 0, vy: 0, lives: 3, hurt: 0, shield: 0, weapon: "normal", weaponT: 0 });
    for (const b of bots) { b.x = me.x + b.slot[0]; b.y = me.y + b.slot[1]; }
    things = []; shots = []; bolts = []; pickups = []; sparks = [];
    t = 0; score = 0; spawnBrick = 0.6; spawnRival = 3; spawnPick = 8; over = false; meter = 0; frenzy = 0; burstLeft = 0;
    Object.assign(ab, { id: "pulse", charge: 0, active: 0 }); ring = null; cores = []; spawnCore = 18; scroll = 0; zoneShown = -1; zoneBanner = 0;
    for (let i = bots.length - 1; i >= 0; i--) if ((bots[i] as { temp?: boolean }).temp) bots.splice(i, 1);
  };

  const burst = (x: number, y: number, color: string, n: number) => {
    for (let i = 0; i < n; i++) {
      const a = Math.random() * Math.PI * 2, v = 60 + Math.random() * 240;
      sparks.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 0.5 + Math.random() * 0.5, color, size: 3 + Math.random() * 5 });
    }
    if (sparks.length > 600) sparks.splice(0, sparks.length - 600);
  };
  const hit = () => {
    if (me.hurt > 0 || frenzy > 0) return;
    if (me.shield > 0) { me.shield = 0; me.hurt = 0.6; burst(me.x, me.y, host.color, 14); return; }
    me.lives--; me.hurt = 1.6; burst(me.x, me.y, "#ff6b6b", 22);
    if (me.lives <= 0) { over = true; running = false; burst(me.x, me.y, host.color, 40); host.onHud({ score: Math.floor(score), lives: 0 }); host.onOver(Math.floor(score)); }
  };
  const takeDown = (o: Thing) => {
    score += (o.kind === "rival" ? 100 : 30) * (frenzy > 0 ? 2 : 1) * (ab.id === "magnet" && ab.active > 0 ? 2 : 1);
    ab.charge = Math.min(1, ab.charge + (o.kind === "rival" ? 0.12 : 0.05));
    burst(o.x, o.y, o.color, o.kind === "rival" ? 26 : 14);
    // Every take-down fills the frenzy; full, it starts.
    if (frenzy <= 0) {
      meter = Math.min(1, meter + (o.kind === "rival" ? 0.14 : 0.07));
      if (meter >= 1) { frenzy = FRENZY_SECS; meter = 0; flash = 1; burst(me.x, me.y, host.color, 50); }
    }
  };

  // One trigger pull: toward the mouse, with the weapon in hand; in the frenzy the figures come out huge.
  // The right button: the ability, when it is charged.
  const useAbility = () => {
    if (ab.charge < 1 || ab.active > 0 || !running) return;
    ab.charge = 0; ab.active = ABILITIES[ab.id].secs;
    burst(me.x, me.y, host.color, 24);
    if (ab.id === "pulse") ring = { x: me.x, y: me.y, r: 0 };
    if (ab.id === "clones") for (const dy of [-70, 70]) bots.push({ name: "", color: host.color, figures: host.player.figures, sprites: figures, x: me.x, y: me.y + dy, slot: [-20, dy], cool: 0.1, n: 0, temp: true } as (typeof bots)[number]);
  };
  const fire = () => {
    ab.charge = Math.min(1, ab.charge + 0.008);
    const base = aim.set ? Math.atan2(aim.y - me.y, aim.x - me.x) : 0;
    const angles = me.weapon === "triple" ? [-0.22, 0, 0.22] : me.weapon === "ring" ? Array.from({ length: 10 }, (_, i) => base + (i * Math.PI * 2) / 10) : [0];
    const big = frenzy > 0, size = big ? 78 : 38, v = big ? 760 : 660;
    for (const da of angles) {
      const a = me.weapon === "ring" ? da : base + da;
      shots.push({ x: me.x + Math.cos(a) * 24, y: me.y + Math.sin(a) * 24, vx: Math.cos(a) * v, vy: Math.sin(a) * v, img: figures[shotN++ % figures.length], size, hits: big ? new Set() : null });
    }
  };

  const step = (dt: number) => {
    t += dt;
    const level = 1 + t / 35;
    frenzy = Math.max(0, frenzy - dt);
    flash = Math.max(0, flash - dt * 2);
    meter = Math.max(0, meter - dt * 0.015);
    // The galaxy runs faster in the frenzy, easing in and out.
    warp += ((frenzy > 0 ? 2.6 : 1) - warp) * (1 - Math.exp(-dt * 3));

    // Moving with the keys, with a little inertia.
    const ax = (keys.has("ArrowRight") || keys.has("d") ? 1 : 0) - (keys.has("ArrowLeft") || keys.has("a") ? 1 : 0);
    const ay = (keys.has("ArrowDown") || keys.has("s") ? 1 : 0) - (keys.has("ArrowUp") || keys.has("w") ? 1 : 0);
    const k = 1 - Math.exp(-dt * 10), top = 380;
    me.vx += (ax * top - me.vx) * k; me.vy += (ay * top - me.vy) * k;
    me.x = Math.max(24, Math.min(W - 24, me.x + me.vx * dt)); me.y = Math.max(24, Math.min(H - 24, me.y + me.vy * dt));
    me.hurt = Math.max(0, me.hurt - dt); me.shield = Math.max(0, me.shield - dt);
    me.weaponT = Math.max(0, me.weaponT - dt);
    if (me.weaponT <= 0) me.weapon = "normal";

    fireCool -= dt; burstCool -= dt;
    if ((firing || keys.has(" ")) && fireCool <= 0) {
      const cool = { normal: 0.24, rapid: 0.1, triple: 0.26, burst: 0.42, ring: 0.36 }[me.weapon];
      fireCool = frenzy > 0 ? Math.min(cool, 0.12) : cool;
      fire();
      if (me.weapon === "burst") { burstLeft = 3; burstCool = 0.06; }
    }
    if (burstLeft > 0 && burstCool <= 0) { fire(); burstLeft--; burstCool = 0.06; }
    for (const b of bots) {
      const kb = 1 - Math.exp(-dt * 6);
      b.x += (me.x + b.slot[0] - b.x) * kb; b.y += (Math.max(20, Math.min(H - 20, me.y + b.slot[1])) - b.y) * kb;
      b.cool -= dt;
      if (b.cool > 0) continue;
      let target: Thing | null = null, dist = 520;
      for (const o of things) { const d = Math.hypot(o.x - b.x, o.y - b.y); if (o.hp > 0 && d < dist) { dist = d; target = o; } }
      if (!target) continue;
      b.cool = frenzy > 0 ? 0.25 : 0.6;
      const a = Math.atan2(target.y - b.y, target.x - b.x), big = frenzy > 0;
      shots.push({ x: b.x, y: b.y, vx: Math.cos(a) * 600, vy: Math.sin(a) * 600, img: b.sprites[b.n++ % b.sprites.length], size: big ? 60 : 30, hits: big ? new Set() : null });
    }

    // Abilities running: the laser burns along its line, the pulse's ring opens, slow time slows everything but you,
    // clones leave when it ends, the magnet pulls what drifts by.
    ab.active = Math.max(0, ab.active - dt);
    const wdt = ab.id === "slow" && ab.active > 0 ? dt * 0.35 : dt;
    if (ab.active <= 0) for (let i = bots.length - 1; i >= 0; i--) if ((bots[i] as { temp?: boolean }).temp) { burst(bots[i].x, bots[i].y, host.color, 10); bots.splice(i, 1); }
    if (ab.id === "laser" && ab.active > 0) {
      const a = aim.set ? Math.atan2(aim.y - me.y, aim.x - me.x) : 0, ex = me.x + Math.cos(a) * 2000, ey = me.y + Math.sin(a) * 2000;
      const near = (x: number, y: number) => { const dx = ex - me.x, dy = ey - me.y, k = Math.max(0, Math.min(1, ((x - me.x) * dx + (y - me.y) * dy) / (dx * dx + dy * dy))); return Math.hypot(x - me.x - dx * k, y - me.y - dy * k); };
      for (const o of things) if (o.hp > 0 && near(o.x, o.y) < o.r + 8) { o.hp -= dt * 9; if (Math.random() < 0.3) burst(o.x, o.y, o.color, 2); if (o.hp <= 0) takeDown(o); }
      for (const b of bolts) if (near(b.x, b.y) < 12) b.x = -999;
    }
    if (ring) {
      ring.r += dt * 760;
      for (const o of things) { const d = Math.hypot(o.x - ring.x, o.y - ring.y); if (o.hp > 0 && d < ring.r && d > ring.r - 60) { o.hp -= 2; burst(o.x, o.y, o.color, 6); if (o.hp <= 0) takeDown(o); } }
      for (const b of bolts) if (Math.hypot(b.x - ring.x, b.y - ring.y) < ring.r) b.x = -999;
      if (ring.r > 340) ring = null;
    }
    if (ab.id === "magnet" && ab.active > 0) for (const p of pickups) { p.x += (me.x - p.x) * dt * 3; p.y += (me.y - p.y) * dt * 3; }
    // Cores drift by now and then: catching one swaps the ability (its charge stays).
    spawnCore -= dt;
    if (spawnCore <= 0) {
      spawnCore = 22 + Math.random() * 10;
      const choices = ABILITY_IDS.filter((x) => x !== ab.id);
      cores.push({ x: W + 24, y: 50 + Math.random() * (H - 100), id: choices[Math.floor(Math.random() * choices.length)], t: 0 });
    }
    const speed = (150 + 40 * level) * warp;
    score += speed * dt * 0.05 * (frenzy > 0 ? 2 : 1);
    // With a team the stream is thicker and the rivals tougher.
    const fill = (frenzy > 0 ? 1.6 : 1) * (team ? 1.45 : 1);

    spawnBrick -= wdt * fill;
    if (spawnBrick <= 0) {
      spawnBrick = Math.max(0.26, 1.1 / level) * (0.6 + Math.random() * 0.8);
      const r = 16 + Math.random() * 18, c = BRICKS[Math.floor(Math.random() * BRICKS.length)];
      // Most come from ahead; from the second level some fall in from above or below.
      const side = level > 1.4 && Math.random() < 0.3 ? (Math.random() < 0.5 ? -1 : 1) : 0;
      if (side) things.push({ kind: "brick", x: W * (0.35 + Math.random() * 0.6), y: side < 0 ? -r : H + r, vx: -speed * 0.5, vy: -side * (90 + Math.random() * 90), r, rot: Math.random() * 6, vr: (Math.random() - 0.5) * 2, color: c, hp: 3, phase: 0, cool: 0 });
      else things.push({ kind: "brick", x: W + r, y: r + Math.random() * (H - r * 2), vx: -(speed + Math.random() * 80), vy: (Math.random() - 0.5) * 30, r, rot: Math.random() * 6, vr: (Math.random() - 0.5) * 2, color: c, hp: 3, phase: 0, cool: 0 });
    }
    spawnRival -= wdt * fill;
    if (spawnRival <= 0) {
      spawnRival = Math.max(0.8, 3.4 / level) * (0.7 + Math.random() * 0.6);
      const c = MACHINE_COLORS[Math.floor(Math.random() * MACHINE_COLORS.length)];
      const behind = level > 1.8 && Math.random() < 0.2;
      things.push({ kind: "rival", x: behind ? -30 : W + 30, y: 40 + Math.random() * (H - 80), vx: behind ? speed * 0.45 : -(speed * 0.7), vy: 0, r: 20, rot: 0, vr: 0, color: host.light ? c.light : c.dark, hp: (level > 2.2 ? 2 : 1) + (team && level > 1.5 ? 1 : 0), phase: Math.random() * 6, cool: 1 + Math.random() * 2 });
    }
    spawnPick -= dt;
    if (spawnPick <= 0) {
      spawnPick = 7 + Math.random() * 7;
      const kinds: PickKind[] = ["star", "rapid", "triple", "burst", "ring", ...(me.lives < 3 ? ["heart" as PickKind] : [])];
      pickups.push({ x: W + 20, y: 40 + Math.random() * (H - 80), kind: kinds[Math.floor(Math.random() * kinds.length)], t: 0 });
    }

    for (const s of shots) { s.x += s.vx * dt; s.y += s.vy * dt; }
    for (const o of things) {
      o.x += o.vx * wdt; o.rot += o.vr * wdt;
      if (o.kind === "rival") {
        o.phase += wdt * 2.2; o.y += Math.sin(o.phase) * 90 * wdt;
        o.cool -= wdt;
        // From the second level on, rival machines shoot back at you.
        if (level > 1.6 && o.cool <= 0 && o.x < W - 20 && o.x > 20) {
          o.cool = Math.max(0.9, 2.6 - level * 0.3);
          const dx = me.x - o.x, dy = me.y - o.y, L = Math.hypot(dx, dy) || 1;
          bolts.push({ x: o.x, y: o.y, vx: (dx / L) * 260, vy: (dy / L) * 260 });
        }
      } else o.y += o.vy * wdt;
    }
    for (const b of bolts) { b.x += b.vx * wdt; b.y += b.vy * wdt; }
    for (const p of pickups) { p.x -= speed * 0.7 * wdt; p.t += dt; }
    for (const c of cores) { c.x -= speed * 0.55 * wdt; c.t += dt; }
    for (const c of cores) if (c.t >= 0 && Math.hypot(me.x - c.x, me.y - c.y) < 34) { c.t = -1; ab.id = c.id; ab.active = 0; ring = null; burst(c.x, c.y, host.color, 20); }
    cores = cores.filter((c) => c.t >= 0 && c.x > -40);
    scroll += speed * wdt;
    for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.vx *= 0.94; s.vy *= 0.94; s.life -= dt; }

    // Your figures against bricks and rivals; giant ones (frenzy) go through everything they hit.
    for (const s of shots) {
      if (s.x < -900) continue;
      for (const o of things) {
        if (o.hp <= 0 || (s.hits && s.hits.has(o))) continue;
        if (Math.hypot(s.x - o.x, s.y - o.y) < o.r + s.size * 0.33) {
          burst(s.x, s.y, o.color, 5);
          if (s.hits) { s.hits.add(o); o.hp = 0; }
          else { o.hp--; s.x = -999; }
          if (o.hp <= 0) takeDown(o);
          if (!s.hits) break;
        }
      }
    }
    for (const o of things) if (o.hp > 0 && Math.hypot(me.x - o.x, me.y - o.y) < o.r + 16) {
      o.hp = 0; burst(o.x, o.y, o.color, 12);
      if (frenzy > 0) takeDown(o); else hit();
    }
    for (const b of bolts) if (b.x > -50 && Math.hypot(me.x - b.x, me.y - b.y) < 18) { b.x = -999; hit(); }
    for (const p of pickups) if (p.t >= 0 && Math.hypot(me.x - p.x, me.y - p.y) < 32) {
      p.t = -1; burst(p.x, p.y, "#ffd34d", 14);
      if (p.kind === "heart") me.lives = Math.min(5, me.lives + 1);
      else if (p.kind === "star") me.shield = PICKS.star.secs;
      else { me.weapon = p.kind; me.weaponT = PICKS[p.kind].secs; }
    }
    const inside = (x: number, y: number, m: number) => x > -m && x < W + m && y > -m && y < H + m;
    shots = shots.filter((s) => inside(s.x, s.y, 80));
    things = things.filter((o) => o.hp > 0 && inside(o.x, o.y, 140));
    bolts = bolts.filter((b) => inside(b.x, b.y, 40));
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

  /** The background of a zone, scrolling with the flight: the galaxy is the stars (drawn after), the motherboard has
   *  traces, vias and chips going by, the world of blocks a baseplate of studs and brick trees. */
  const zoneBg = (z: number, alpha: number) => {
    if (alpha <= 0 || z === 0) return;
    g.globalAlpha = alpha;
    if (z === 1) {
      g.fillStyle = host.light ? "#e4ebe6" : "#121814"; g.fillRect(0, 0, W, H);
      const off = scroll * 0.6;
      g.strokeStyle = host.light ? "#b9c9bf" : "#2c4a3d"; g.lineWidth = 2;
      for (let row = 0; row < H / 22 + 1; row++) {
        const y = 11 + row * 22, seed = Math.floor((off + row * 997) / 400);
        g.beginPath();
        for (let x = -((off + row * 137) % 400); x < W; x += 400) { const len = 180 + ((seed * 37 + row * 11) % 160); g.moveTo(x, y); g.lineTo(x + len, y); g.lineTo(x + len + 16, y + (row % 2 ? 16 : -16)); }
        g.stroke();
      }
      g.fillStyle = host.light ? "#26292b" : "#1c2123";
      for (let k = 0; k < 6; k++) {
        const x = ((k * 330 - scroll * 0.35) % (W + 330) + W + 330) % (W + 330) - 160, y = 40 + ((k * 151) % Math.max(60, H - 140)), s = 70 + (k % 3) * 30;
        g.fillRect(x, y, s, s);
        g.fillStyle = host.light ? "#9aa1a3" : "#5c666a";
        for (let q = 0; q < 8; q++) { g.fillRect(x + 6 + q * (s - 12) / 8, y - 5, 3, 5); g.fillRect(x + 6 + q * (s - 12) / 8, y + s, 3, 5); }
        g.fillStyle = host.light ? "#26292b" : "#1c2123";
      }
    } else {
      g.fillStyle = host.light ? "#8fc282" : "#264a24"; g.fillRect(0, 0, W, H);
      const off = (scroll * 0.6) % 24;
      g.fillStyle = host.light ? "#7fb373" : "#2f5a2c";
      for (let y = 12; y < H; y += 24) for (let x = -off; x < W + 24; x += 24) { g.beginPath(); g.arc(x, y, 7, 0, Math.PI * 2); g.fill(); }
      for (let k = 0; k < 5; k++) {
        const x = ((k * 420 - scroll * 0.45) % (W + 420) + W + 420) % (W + 420) - 200, base = H - 10 - (k % 2) * 30;
        g.fillStyle = "#7a4e2c"; g.fillRect(x - 8, base - 40, 16, 40);
        g.fillStyle = host.light ? "#4f9c45" : "#3d7a36"; g.fillRect(x - 40, base - 90, 80, 54); g.fillRect(x - 26, base - 116, 52, 28);
      }
    }
    g.globalAlpha = 1;
  };
  const glyph = (x: number, y: number, id: AbilityId, s: number) => {
    g.strokeStyle = host.light ? "#ffffff" : "#161616"; g.lineWidth = 2; g.beginPath();
    if (id === "pulse") { g.arc(x, y, s * 0.25, 0, 7); g.moveTo(x + s * 0.5, y); g.arc(x, y, s * 0.5, 0, 7); }
    else if (id === "laser") { g.moveTo(x - s * 0.55, y + s * 0.3); g.lineTo(x + s * 0.55, y - s * 0.3); }
    else if (id === "slow") { g.arc(x, y, s * 0.5, 0, 7); g.moveTo(x, y); g.lineTo(x, y - s * 0.35); g.moveTo(x, y); g.lineTo(x + s * 0.25, y); }
    else if (id === "clones") { g.rect(x - s * 0.55, y - s * 0.2, s * 0.45, s * 0.45); g.rect(x + s * 0.1, y - s * 0.2, s * 0.45, s * 0.45); }
    else { g.moveTo(x - s * 0.4, y - s * 0.4); g.lineTo(x - s * 0.4, y + s * 0.05); g.arc(x, y + s * 0.05, s * 0.4, Math.PI, 0, true); g.lineTo(x + s * 0.4, y - s * 0.4); }
    g.stroke();
  };
  const draw = (dt: number) => {
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, W, H);
    // The zone: crossing into the next one fades it in over a second and a half.
    const zt = t / ZONE_SECS, zi = Math.floor(zt) % ZONES.length, into = (zt % 1) * ZONE_SECS, prev = (zi + ZONES.length - 1) % ZONES.length;
    if (t >= ZONE_SECS && into < 1.5) { zoneBg(prev, 1); zoneBg(zi, into / 1.5); } else zoneBg(zi, 1);
    if (zoneShown !== zi && running) { zoneShown = zi; zoneBanner = t < 1 ? 0 : 2.5; }
    zoneBanner = Math.max(0, zoneBanner - dt);
    // The galaxy: stars drifting by, nearer ones faster; in the frenzy they stretch into streaks in your color.
    const drift = (150 + 40 * (1 + t / 35)) * warp * (running ? 1 : 0);
    const streak = Math.max(0, warp - 1.1) * 0.05;
    g.lineCap = "round";
    const starsAlpha = zi === 0 ? 1 : t >= ZONE_SECS && into < 1.5 && prev === 0 ? 1 - into / 1.5 : 0.35;
    g.globalAlpha = starsAlpha;
    for (const s of stars) {
      s.x -= (drift * s.z * dt) / Math.max(1, W);
      if (s.x < 0) { s.x += 1; s.y = Math.random(); }
      const x = s.x * W, y = s.y * H, a = 0.06 + s.z * 0.16;
      if (streak > 0) {
        g.strokeStyle = rgba(frenzy > 0 ? host.color : ink, a + 0.1); g.lineWidth = 1 + s.z;
        g.beginPath(); g.moveTo(x, y); g.lineTo(x + drift * s.z * streak, y); g.stroke();
      } else { g.fillStyle = rgba(ink, a); g.fillRect(x, y, 1 + s.z * 1.5, 1 + s.z * 1.5); }
    }
    g.globalAlpha = 1;
    // Cores: a hexagon in the machine's color with the glyph of the ability it brings.
    for (const c of cores) {
      const y = c.y + Math.sin(c.t * 3) * 4, r = 20;
      g.beginPath(); for (let k = 0; k < 6; k++) { const a = (k / 6) * Math.PI * 2 + c.t; g.lineTo(c.x + Math.cos(a) * r, y + Math.sin(a) * r); } g.closePath();
      g.fillStyle = host.color; g.fill(); g.strokeStyle = rgba(host.color, 0.4); g.lineWidth = 6; g.stroke();
      glyph(c.x, y, c.id, 18);
    }
    for (const p of pickups) {
      const img = pickImg[p.kind];
      if (img) g.drawImage(img, p.x - 22, p.y - 22 + Math.sin(p.t * 4) * 4, 44, 44);
    }
    for (const o of things) {
      if (o.kind === "brick") brick(o);
      else {
        cube(o.x, o.y, o.r * 0.8, o.color, 1, -t * 1.2 + o.phase);
        g.fillStyle = "#ff6b6b"; g.beginPath(); g.arc(o.x + (o.vx > 0 ? 1 : -1) * o.r * 0.55, o.y - 2, 3, 0, Math.PI * 2); g.fill();
      }
    }
    for (const b of bolts) { g.fillStyle = "#ff6b6b"; g.beginPath(); g.arc(b.x, b.y, 4.5, 0, Math.PI * 2); g.fill(); }
    for (const s of shots) {
      g.save(); g.translate(s.x, s.y); g.rotate(Math.atan2(s.vy, s.vx) * 0.25);
      g.drawImage(s.img, -s.size / 2, -s.size / 2, s.size, s.size);
      g.restore();
    }
    for (const b of bots) {
      cube(b.x, b.y, 12, b.color, 0.9, 0.6 + Math.sin(t * 2 + b.slot[1]) * 0.15);
      g.drawImage(b.sprites[0], b.x - 11, b.y - 30, 22, 22);
    }
    if (!over) {
      const flicker = me.hurt > 0 && Math.floor(t * 14) % 2 === 0;
      if (!flicker) {
        cube(me.x, me.y, frenzy > 0 ? 20 : 17, host.color, 1, 0.6 + Math.sin(t * 2) * 0.15);
        // The machine's first figure rides on top of it.
        g.drawImage(figures[0], me.x - 15, me.y - 42, 30, 30);
      }
      if (me.shield > 0 || frenzy > 0) { g.strokeStyle = rgba(frenzy > 0 ? host.color : "#ffd34d", 0.45 + 0.3 * Math.sin(t * 8)); g.lineWidth = 2; g.beginPath(); g.arc(me.x, me.y, 32, 0, Math.PI * 2); g.stroke(); }
      // Where you aim: a small sight at the pointer.
      if (aim.set && running) {
        g.strokeStyle = rgba(host.color, 0.8); g.lineWidth = 1.5;
        g.beginPath(); g.arc(aim.x, aim.y, 9, 0, Math.PI * 2);
        g.moveTo(aim.x - 14, aim.y); g.lineTo(aim.x - 5, aim.y); g.moveTo(aim.x + 5, aim.y); g.lineTo(aim.x + 14, aim.y);
        g.moveTo(aim.x, aim.y - 14); g.lineTo(aim.x, aim.y - 5); g.moveTo(aim.x, aim.y + 5); g.lineTo(aim.x, aim.y + 14);
        g.stroke();
      }
    }
    // The abilities while they run.
    if (ab.id === "laser" && ab.active > 0 && !over) {
      const a = aim.set ? Math.atan2(aim.y - me.y, aim.x - me.x) : 0, ex = me.x + Math.cos(a) * 2000, ey = me.y + Math.sin(a) * 2000;
      for (const [lw, al] of [[14, 0.18], [6, 0.5], [2, 1]] as const) { g.strokeStyle = rgba(host.color, al); g.lineWidth = lw * (0.85 + Math.random() * 0.3); g.beginPath(); g.moveTo(me.x, me.y); g.lineTo(ex, ey); g.stroke(); }
    }
    if (ring) { g.strokeStyle = rgba(host.color, Math.max(0, 1 - ring.r / 340)); g.lineWidth = 6; g.beginPath(); g.arc(ring.x, ring.y, ring.r, 0, Math.PI * 2); g.stroke(); }
    if (ab.id === "slow" && ab.active > 0) { g.fillStyle = rgba(host.color, 0.06); g.fillRect(0, 0, W, H); }
    if (ab.id === "magnet" && ab.active > 0 && !over) { g.strokeStyle = rgba(host.color, 0.35); g.lineWidth = 1.5; g.setLineDash([4, 6]); g.beginPath(); g.arc(me.x, me.y, 46 + Math.sin(t * 6) * 4, 0, Math.PI * 2); g.stroke(); g.setLineDash([]); }
    for (const s of sparks) { g.globalAlpha = Math.min(1, s.life * 2); g.fillStyle = s.color; g.fillRect(s.x - s.size / 2, s.y - s.size / 2, s.size, s.size); }
    g.globalAlpha = 1;
    if (flash > 0) { g.fillStyle = rgba(host.color, flash * 0.25); g.fillRect(0, 0, W, H); }
    // Crossing into a zone: its name on a small plate at the top, for a moment.
    if (zoneBanner > 0) {
      const a = Math.min(1, zoneBanner * 2, (2.5 - zoneBanner) * 4), label = `Zona ${ZONES[zi]}`;
      g.font = "600 14px 'Plus Jakarta Sans', sans-serif";
      const w = g.measureText(label).width + 28, x = W / 2 - w / 2, y = 56;
      g.globalAlpha = a; g.fillStyle = host.light ? "#ffffff" : "#1c1c1c"; g.beginPath(); g.roundRect(x, y, w, 30, 15); g.fill();
      g.fillStyle = ink; g.textBaseline = "middle"; g.textAlign = "center"; g.fillText(label, W / 2, y + 15); g.textAlign = "start"; g.globalAlpha = 1;
    }
  };

  const loop = (now: number) => {
    const dt = Math.min(0.05, (now - last) / 1000);
    last = now;
    if (running) step(dt);
    else for (const s of sparks) { s.x += s.vx * dt; s.y += s.vy * dt; s.life -= dt; }
    draw(dt);
    if (running && now - hudAt > 120) {
      hudAt = now;
      const abHud = { name: ABILITIES[ab.id].name, charge: ab.charge, active: ab.active > 0 ? ab.active / ABILITIES[ab.id].secs : undefined };
      const power = frenzy > 0 ? `Frenesí ${Math.ceil(frenzy)} s` : me.weapon !== "normal" ? `${PICKS[me.weapon].label} ${Math.ceil(me.weaponT)} s` : me.shield > 0 ? `Escudo ${Math.ceil(me.shield)} s` : undefined;
      host.onHud({ score: Math.floor(score), lives: me.lives, power, meter: frenzy > 0 ? frenzy / FRENZY_SECS : meter, frenzy: frenzy > 0, ability: abHud, zone: ZONES[Math.floor(t / ZONE_SECS) % ZONES.length] });
    }
    if (running || sparks.length) frame = requestAnimationFrame(loop);
  };
  const kick = () => { cancelAnimationFrame(frame); last = performance.now(); frame = requestAnimationFrame(loop); };

  const local = (e: PointerEvent) => { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
  const onMove = (e: PointerEvent) => { const [x, y] = local(e); aim.x = x; aim.y = y; aim.set = true; };
  const onDown = (e: PointerEvent) => { if (e.button === 2 && running) { e.preventDefault(); useAbility(); return; } if (e.button === 0 && running) { onMove(e); firing = true; try { canvas.setPointerCapture(e.pointerId); } catch { /* not a real pointer */ } } };
  const onUp = () => { firing = false; };
  const onKey = (e: KeyboardEvent) => {
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    if (k === "e" && e.type === "keydown") { e.preventDefault(); useAbility(); return; }
    if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " ", "w", "a", "s", "d"].includes(k)) { e.preventDefault(); if (e.type === "keydown") keys.add(k); else keys.delete(k); }
  };
  const onHidden = () => { if (document.hidden && running) { running = false; cancelAnimationFrame(frame); } };
  const noMenu = (e: MouseEvent) => e.preventDefault();
  canvas.addEventListener("contextmenu", noMenu);
  canvas.addEventListener("pointermove", onMove);
  canvas.addEventListener("pointerdown", onDown);
  window.addEventListener("pointerup", onUp);
  window.addEventListener("keydown", onKey);
  window.addEventListener("keyup", onKey);
  document.addEventListener("visibilitychange", onHidden);

  return {
    start: () => { reset(); running = true; host.onHud({ score: 0, lives: 3, meter: 0, ability: { name: ABILITIES.pulse.name, charge: 0 }, zone: ZONES[0] }); kick(); },
    pause: () => { running = false; keys.clear(); firing = false; cancelAnimationFrame(frame); draw(0); },
    resume: () => { if (!over) { running = true; kick(); } },
    stop: () => {
      running = false; cancelAnimationFrame(frame); ro.disconnect();
      canvas.removeEventListener("pointermove", onMove); canvas.removeEventListener("pointerdown", onDown); canvas.removeEventListener("contextmenu", noMenu);
      window.removeEventListener("pointerup", onUp); window.removeEventListener("keydown", onKey); window.removeEventListener("keyup", onKey);
      document.removeEventListener("visibilitychange", onHidden);
    },
  };
}

export const CUBE_FLIGHT: GameDef = {
  id: "cube-flight",
  name: "Overclock",
  description: "Vuela entre bloques y máquinas rivales, junta habilidades y cruza de zona en zona.",
  modes: [
    { id: "solo", name: "Solo", description: "Tu máquina contra todo." },
    { id: "team", name: "En equipo", description: "Tus otras máquinas vuelan contigo y disparan solas. Llegan más rivales y más duros.", team: true },
  ],
  controls: [
    "Muévete con W A S D o las flechas",
    "Apunta con el mouse y dispara con clic (o la barra espaciadora)",
    "Los stickers traen armas, escudo o una vida",
    "Derribar llena el frenesí: figuras gigantes por unos segundos",
    "Disparar carga tu habilidad: úsala con clic derecho (o E)",
    "Los núcleos de colores cambian tu habilidad",
  ],
  create,
  cover: (g, w, h, t, light, accent) => {
    // The machine flying among bricks over a galaxy, shooting, with a streak of the frenzy.
    g.fillStyle = light ? "#eef0f3" : "#14161a"; g.fillRect(0, 0, w, h);
    for (let i = 0; i < 70; i++) {
      const z = ((i * 0.618) % 1), x = ((i * 97.3 - t * (40 + z * 160)) % w + w) % w, y = (i * 53.7) % h;
      g.fillStyle = light ? `rgba(40,40,50,${0.15 + z * 0.3})` : `rgba(235,232,225,${0.15 + z * 0.5})`;
      g.fillRect(x, y, 2 + z * 10, 1.5);
    }
    for (let k = 0; k < 5; k++) {
      const x = ((w * 1.2 - (t * 70 + k * 90)) % (w * 1.2) + w * 1.2) % (w * 1.2), y = h * (0.2 + ((k * 0.37) % 0.65)), s = 14 + (k % 3) * 5;
      g.save(); g.translate(x, y); g.rotate(t * (k % 2 ? 1 : -1) * 0.8 + k);
      g.fillStyle = BRICKS[k % BRICKS.length]; g.beginPath(); g.roundRect(-s, -s * 0.7, s * 2, s * 1.4, 3); g.fill();
      g.fillStyle = "rgba(255,255,255,.25)"; for (const sx of [-0.5, 0.5]) { g.beginPath(); g.ellipse(sx * s, -s * 0.7, s * 0.3, s * 0.14, 0, 0, 7); g.fill(); }
      g.restore();
    }
    const px = w * 0.24, py = h * 0.5 + Math.sin(t * 2) * h * 0.08, s = h * 0.1;
    for (let k = 0; k < 4; k++) { const x = px + 30 + ((t * 260 + k * 70) % (w * 0.8)); g.fillStyle = accent; g.globalAlpha = 0.85; g.fillRect(x, py - 3, 10, 6); }
    g.globalAlpha = 1;
    g.strokeStyle = accent; g.lineWidth = 2;
    g.strokeRect(px - s, py - s, s * 2, s * 2);
    g.globalAlpha = 0.2; g.fillStyle = accent; g.fillRect(px - s, py - s, s * 2, s * 2); g.globalAlpha = 1;
    g.beginPath(); g.moveTo(px - s, py - s); g.lineTo(px - s * 0.4, py - s * 1.5); g.lineTo(px + s * 1.6, py - s * 1.5); g.lineTo(px + s, py - s); g.moveTo(px + s * 1.6, py - s * 1.5); g.lineTo(px + s * 1.6, py + s * 0.5); g.lineTo(px + s, py + s); g.stroke();
    g.strokeStyle = accent; g.globalAlpha = 0.5 + 0.5 * Math.sin(t * 3); g.lineWidth = 3;
    g.beginPath(); g.arc(px, py, s * (2 + (t * 1.5) % 2), 0, 7); g.stroke(); g.globalAlpha = 1;
  },
};
