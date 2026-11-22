import { FACES, LED_COLORS, MACHINE_COLORS, newId, type Decor, type Face, type StickerPlacement } from "./store";
import { STICKERS } from "./stickers";
import { FIGURES } from "./figures";
import type { CubeMachine } from "../MachineCube";
import { t } from "../i18n";

const pick = <T,>(list: T[]) => list[Math.floor(Math.random() * list.length)];
const between = (a: number, b: number) => a + Math.random() * (b - a);
const shuffle = <T,>(list: T[]) => list.map((v) => [Math.random(), v] as const).sort((a, b) => a[0] - b[0]).map(([, v]) => v);

// A function, so texts follow the current language.
const signs = () => ["PLAYER ONE", "NIGHT CITY", t("GAME MODE"), "144 FPS", "READY", t("HELLO WORLD"), "LEVEL UP", "RTX ON", "PRESS START"];
const APPS = ["steam", "discord", "chrome", "spotify", "obs", "epic", "vscode", "vlc"];

export function randomDecor(): Decor {
  const stickers: StickerPlacement[] = [];
  for (const id of shuffle(STICKERS.map((s) => s.id)).slice(0, 2 + Math.floor(Math.random() * 3))) {
    for (let tries = 0; tries < 12; tries++) {
      const face: Face = pick(FACES.filter((f) => f !== "back")), size = between(0.55, 0.8), m = 1 - size / 2;
      const u = between(-m, m), v = face === "top" ? between(-m, m) : between(-0.2, m);
      if (stickers.some((s) => s.face === face && Math.hypot(s.u - u, s.v - v) < (s.size + size) / 2)) continue;
      stickers.push({ id: newId(), sticker: id, face, u, v, rot: between(-18, 18), size });
      break;
    }
  }
  const spots = shuffle([[0.45, -0.35], [-0.45, -0.35], [0.45, 0.4], [-0.45, 0.4]]);
  const figures = shuffle(FIGURES.map((f) => f.id)).slice(0, 1 + Math.floor(Math.random() * 2))
    .map((figure, i) => ({ id: newId(), figure, x: spots[i][0], z: spots[i][1], rot: between(-40, 40), size: between(0.9, 1.15) }));
  return {
    color: Math.random() < 0.15 ? null : pick(MACHINE_COLORS).id,
    led: Math.random() < 0.8 ? { text: pick(signs()), color: pick(LED_COLORS).id, live: false } : null,
    stickers,
    figures,
  };
}

export function randomMachine(): CubeMachine {
  return {
    power: "on",
    cores: pick([4, 6, 8, 12, 16]),
    memoryGB: pick([8, 12, 16, 24, 32]),
    gpuPercent: pick([40, 50, 60, 80, 100]),
    diskGB: pick([128, 256, 512]),
    usage: { cpu: between(15, 70), gpu: between(20, 85), mem: between(30, 75), disk: between(0, 30) },
    apps: shuffle(APPS).slice(0, 2 + Math.floor(Math.random() * 4)),
    removed: pick([0, 4, 8]),
  };
}
