import { t } from "../i18n";

export type V3 = [number, number, number];

export interface Bricks {
  box: (x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, color: string) => void;
  set: (x: number, y: number, z: number, color: string) => void;
  clear: (x: number, y: number, z: number) => void;
}

export interface FigureDef {
  id: string;
  name: string;
  build: (b: Bricks) => void;
}

export const BRICK = 0.08;

const WHITE = "#f6f2ea", INK = "#2a2522", PINK = "#f29aa8", RED = "#d8443c", GOLD = "#ecbc4c", ORANGE = "#ec9a45";

export const FIGURES: FigureDef[] = [
  {
    id: "lucky-cat", get name() { return t("Lucky cat"); },
    build: (b) => {
      b.box(-4, 4, 0, 0, -3, 3, RED);
      for (const [x, z] of [[-4, -3], [4, -3], [-4, 3], [4, 3]]) b.set(x, 0, z, GOLD);
      b.box(-3, 3, 1, 4, -2, 2, WHITE);
      b.box(-3, -2, 2, 3, -2, -1, INK); b.box(2, 3, 1, 3, -2, 0, ORANGE);
      b.box(-3, 3, 5, 5, -2, 2, RED);
      b.set(0, 5, 3, GOLD);
      b.box(-3, 3, 6, 10, -2, 2, WHITE);
      b.box(1, 3, 9, 10, -2, 0, ORANGE);
      b.box(-3, -2, 11, 11, -1, 0, WHITE); b.set(-3, 12, 0, WHITE); b.set(-2, 11, 1, PINK);
      b.box(2, 3, 11, 11, -1, 0, ORANGE); b.set(3, 12, 0, ORANGE); b.set(2, 11, 1, PINK);
      b.box(-2, -1, 8, 8, 2, 2, INK); b.box(1, 2, 8, 8, 2, 2, INK);
      b.set(0, 7, 2, PINK);
      b.set(-3, 7, 2, "#f6b8c0"); b.set(3, 7, 2, "#f6b8c0");
      b.box(4, 4, 5, 10, 0, 1, WHITE); b.set(4, 9, 2, PINK);
      b.box(-2, 0, 2, 4, 3, 3, GOLD); b.set(-1, 3, 3, "#f8d97a");
      b.box(3, 3, 1, 2, -3, -3, ORANGE);
    },
  },
  {
    id: "succulent", get name() { return t("Plant"); },
    build: (b) => {
      b.box(-3, 3, 0, 3, -3, 3, "#c2714a");
      b.box(-4, 4, 4, 4, -4, 4, "#d27f56");
      b.box(-3, 3, 4, 4, -3, 3, "#5a3d2b");
      for (let x = -4; x <= 4; x++) for (let z = -4; z <= 4; z++) {
        const d = Math.abs(x) + Math.abs(z);
        if (d <= 4) b.set(x, 5, z, d === 4 && (x === 0 || z === 0) ? "#e3909e" : "#5e9e78");
        if (d <= 2) b.set(x, 6, z, "#7cbc92");
        if (d <= 1) b.set(x, 7, z, "#a3d6ae");
      }
      b.set(0, 8, 0, "#c4e8c9");
    },
  },
  {
    id: "duck", get name() { return t("Duckling"); },
    build: (b) => {
      const y = "#ffd23f";
      b.box(-3, 3, 0, 3, -3, 3, y);
      for (const [x, z] of [[-3, -3], [3, -3], [-3, 3], [3, 3]]) b.clear(x, 3, z);
      b.box(-1, 1, 3, 4, -4, -4, y); b.set(0, 5, -4, y);
      b.box(-4, -4, 1, 2, -1, 1, "#f2bd22"); b.box(4, 4, 1, 2, -1, 1, "#f2bd22");
      b.box(-2, 2, 4, 7, 0, 3, y);
      b.box(-1, 1, 5, 5, 4, 5, "#ff8c2b");
      b.set(-1, 6, 3, INK); b.set(1, 6, 3, INK);
      b.set(-2, 5, 3, "#ffb08a"); b.set(2, 5, 3, "#ffb08a");
      b.set(0, 8, 1, y);
    },
  },
  {
    id: "robot", get name() { return t("Robot"); },
    build: (b) => {
      const shell = "#e3e6eb", joint = "#9aa0a8", dark = "#2c3442";
      b.box(-3, -1, 0, 0, -1, 2, "#8c939e"); b.box(1, 3, 0, 0, -1, 2, "#8c939e");
      b.box(-2, -2, 1, 2, 0, 0, joint); b.box(2, 2, 1, 2, 0, 0, joint);
      b.box(-3, 3, 3, 7, -2, 2, shell);
      b.box(-2, 2, 4, 6, 2, 2, dark);
      b.set(-1, 6, 2, "$"); b.set(0, 6, 2, "#ff6b6b"); b.set(1, 6, 2, "#7bd88f");
      b.box(-1, 1, 4, 4, 2, 2, "$");
      b.box(-4, -4, 3, 7, 0, 0, joint); b.box(4, 4, 3, 7, 0, 0, joint);
      b.box(-4, -4, 2, 2, -1, 1, "#b8bec6"); b.box(4, 4, 2, 2, -1, 1, "#b8bec6");
      b.set(0, 8, 0, joint);
      b.box(-3, 3, 9, 12, -2, 2, shell);
      b.box(-2, 2, 10, 11, 2, 2, dark);
      b.set(-1, 11, 2, "$"); b.set(1, 11, 2, "$");
      b.set(-4, 10, 0, joint); b.set(4, 10, 0, joint);
      b.set(0, 13, 0, joint); b.set(0, 14, 0, "#ff6b6b");
    },
  },
  {
    id: "cactus", get name() { return t("Cactus"); },
    build: (b) => {
      const g = "#5f9e6e", dg = "#4b8559";
      b.box(-2, 2, 0, 2, -2, 2, "#ece6da");
      b.box(-2, 2, 2, 2, -2, 2, "$");
      b.box(-2, 2, 3, 3, -2, 2, "#5a3d2b");
      b.box(-1, 1, 3, 10, -1, 1, g);
      for (const [x, z] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) b.box(x, x, 4, 9, z, z, dg);
      b.box(2, 3, 6, 6, 0, 0, g); b.box(3, 3, 7, 8, 0, 0, g);
      b.box(-3, -2, 5, 5, 0, 0, g); b.box(-3, -3, 6, 7, 0, 0, g);
      for (const [x, z] of [[0, 0], [1, 0], [-1, 0], [0, 1], [0, -1]]) b.set(x, 11, z, x || z ? "#f28cb1" : "#ffd34d");
    },
  },
  {
    id: "mushroom", get name() { return t("Mushrooms"); },
    build: (b) => {
      const red = "#d9473f", spot = "#fbf6ec";
      b.box(-4, 4, 0, 0, -3, 3, "#7cb36a");
      b.box(-1, 1, 1, 4, -1, 1, "#efe3cc");
      b.box(-3, 3, 5, 5, -3, 3, red);
      for (const [x, z] of [[-3, -3], [3, -3], [-3, 3], [3, 3]]) b.clear(x, 5, z);
      b.box(-2, 2, 6, 6, -2, 2, red);
      b.box(-1, 1, 7, 7, -1, 1, red);
      for (const [x, y, z] of [[-2, 5, 3], [3, 5, 0], [1, 6, 2], [-2, 6, -1], [0, 7, 0], [2, 5, -3]]) b.set(x, y, z, spot);
      b.box(3, 3, 1, 2, 2, 2, "#efe3cc");
      b.box(2, 4, 3, 3, 1, 3, red); b.set(3, 4, 2, red); b.set(2, 3, 3, spot);
      b.set(-4, 1, 2, "#6faa5e"); b.set(4, 1, -2, "#6faa5e");
    },
  },
  {
    id: "gamepad", get name() { return t("Controller"); },
    build: (b) => {
      const body = "#3a3d44";
      b.box(-4, 4, 0, 1, -1, 1, body);
      b.box(-4, -3, 0, 1, 2, 3, body); b.box(3, 4, 0, 1, 2, 3, body);
      b.box(-4, -2, 2, 2, -1, -1, "#4a4e57"); b.box(2, 4, 2, 2, -1, -1, "#4a4e57");
      b.set(-3, 2, 1, "#25272c"); b.set(-2, 2, 0, "#25272c");
      b.set(-1, 2, 1, "#5a5f69"); b.set(1, 2, 1, "#5a5f69");
      b.set(2, 2, 0, "#6aa8ff"); b.set(3, 2, 1, "#7bd88f"); b.set(4, 2, 0, "#ff6b6b"); b.set(3, 2, -1, "#ffd34d");
      b.set(0, 2, 0, "$");
    },
  },
  {
    id: "mug", get name() { return t("Mug"); },
    build: (b) => {
      b.box(-3, 3, 0, 0, -3, 3, "#ece6da");
      b.box(-2, 2, 1, 5, -2, 2, "$");
      b.box(-1, 1, 5, 5, -1, 1, "#5b3a25");
      b.set(0, 5, 0, "#c99a6b");
      for (const [x, y] of [[-3, 2], [-4, 2], [-4, 3], [-4, 4], [-3, 4]]) b.set(x, y, 0, "$");
      b.set(0, 3, 3, WHITE); b.set(-1, 3, 3, "#ff5a76"); b.set(1, 3, 3, "#ff5a76"); b.set(0, 2, 3, "#ff5a76");
    },
  },
  {
    id: "penguin", get name() { return t("Penguin"); },
    build: (b) => {
      const k = "#2c2f36";
      b.set(-1, 0, 3, ORANGE); b.set(1, 0, 3, ORANGE);
      b.box(-2, 2, 0, 7, -2, 2, k);
      b.box(-1, 1, 1, 5, 2, 2, WHITE);
      b.set(-1, 6, 2, WHITE); b.set(1, 6, 2, WHITE);
      b.set(0, 5, 3, ORANGE);
      b.box(-3, -3, 2, 4, -1, 0, k); b.box(3, 3, 2, 4, -1, 0, k);
      b.set(-2, 5, 2, "#f6b8c0"); b.set(2, 5, 2, "#f6b8c0");
      b.box(-2, 2, 8, 8, -1, 1, "$"); b.set(0, 9, 0, WHITE);
    },
  },
  {
    id: "rocket", get name() { return t("Rocket"); },
    build: (b) => {
      b.set(0, 0, 0, "#ffd34d"); b.set(0, 1, 0, ORANGE);
      b.box(-1, 1, 2, 9, -1, 1, WHITE);
      b.box(-1, 1, 10, 10, -1, 1, RED);
      for (const [x, z] of [[-1, -1], [1, -1], [-1, 1], [1, 1]]) b.clear(x, 10, z);
      b.set(0, 11, 0, RED);
      b.set(0, 7, 1, "$"); b.set(0, 6, 1, "$");
      for (const [x, z] of [[-2, 0], [2, 0], [0, -2], [0, 2]]) b.box(x, x, 2, 4, z, z, RED);
      b.box(-1, 1, 5, 5, -1, 1, "#d6d1c6");
    },
  },
  {
    id: "dog", get name() { return t("Dog"); },
    build: (b) => {
      const brown = "#b07b4b", cream = "#f3d9b1", ear = "#7a5233";
      b.box(-2, 2, 0, 2, -3, 1, brown);
      b.box(-1, 1, 1, 2, 1, 1, cream);
      b.box(-2, -1, 0, 0, 2, 2, cream); b.box(1, 2, 0, 0, 2, 2, cream);
      b.box(-2, 2, 3, 3, -1, 1, "$"); b.box(-2, 2, 3, 3, -3, -2, brown);
      b.set(0, 3, 2, GOLD);
      b.box(-2, 2, 4, 7, -1, 2, brown);
      b.box(-1, 1, 7, 7, 0, 2, cream);
      b.box(-1, 1, 4, 5, 3, 4, cream);
      b.set(0, 5, 4, INK); b.set(0, 4, 5, PINK);
      b.set(-1, 6, 2, INK); b.set(1, 6, 2, INK);
      b.box(-3, -3, 3, 6, -1, 1, ear); b.box(3, 3, 3, 6, -1, 1, ear);
      b.box(0, 0, 2, 4, -4, -4, brown);
    },
  },
  {
    id: "cat", get name() { return t("Cat"); },
    build: (b) => {
      const gray = "#8d9098", dark = "#666971";
      b.box(-2, 2, 0, 4, -2, 1, gray);
      b.box(-1, 1, 1, 3, 1, 1, WHITE);
      b.box(-2, -1, 0, 0, 2, 2, WHITE); b.box(1, 2, 0, 0, 2, 2, WHITE);
      b.box(-2, 2, 2, 2, -2, -2, dark);
      b.box(-2, 2, 5, 8, -1, 2, gray);
      b.box(-1, 1, 8, 8, -1, 0, dark);
      b.set(-2, 9, 0, gray); b.set(2, 9, 0, gray); b.set(-2, 9, 1, PINK); b.set(2, 9, 1, PINK);
      b.box(-1, 1, 5, 5, 2, 2, WHITE);
      b.set(-1, 7, 2, INK); b.set(1, 7, 2, INK); b.set(0, 6, 2, PINK);
      b.set(-2, 6, 2, "#f6b8c0"); b.set(2, 6, 2, "#f6b8c0");
      b.box(3, 3, 0, 0, -2, 1, gray); b.box(3, 3, 1, 4, -2, -2, gray); b.set(3, 4, -1, dark);
    },
  },
  {
    id: "spider", get name() { return t("Spider"); },
    build: (b) => {
      const body = "#3f3752", leg = "#2e2840";
      b.box(-2, 2, 1, 3, -3, -1, body);
      b.set(0, 4, -2, body);
      b.set(0, 3, -2, "#7a6aa6"); b.box(-1, 1, 2, 2, -3, -3, "#7a6aa6");
      b.box(-1, 1, 1, 2, 0, 1, "#4a4160");
      b.set(-1, 2, 2, WHITE); b.set(1, 2, 2, WHITE); b.set(0, 1, 2, "#f29aa8");
      for (const [z, hi] of [[-3, 0], [-2, 1], [0, 1], [1, 0]]) for (const s of [1, -1]) {
        b.set(s * 3, 1 + hi, z, leg); b.set(s * 4, 2 + hi, z, leg); b.set(s * 5, 1 + hi, z, leg);
        for (let y = 0; y < 1 + hi; y++) b.set(s * 5, y, z, leg);
      }
    },
  },
  {
    id: "magic-cube", get name() { return t("Magic cube"); },
    build: (b) => {
      b.box(-5, 4, 0, 9, -5, 4, "#1f2024");
      const C = ["#2fa35b", "#d8443c", "#2f6fd6", "#f08a2b", "#f4f1e8", "#f2cf3b"];
      let n = 7;
      const next = (home: number) => { n = (n * 1103515245 + 12345) & 0x7fffffff; return (n >> 8) % 3 === 0 ? C[(n >> 4) % 6] : C[home]; };
      for (let ti = 0; ti < 3; ti++) for (let tj = 0; tj < 3; tj++) {
        const c = [next(0), next(1), next(2), next(3), next(4)];
        for (let di = 0; di < 2; di++) for (let dj = 0; dj < 2; dj++) {
          const a = 1 + ti * 3 + di, v = 1 + tj * 3 + dj, x = a - 5, z = v - 5;
          b.set(x, v, 4, c[0]); b.set(4, v, -1 - x, c[1]); b.set(-1 - x, v, -5, c[2]); b.set(-5, v, x, c[3]); b.set(x, 9, z, c[4]);
        }
      }
    },
  },
  {
    id: "bunny", get name() { return t("Bunny"); },
    build: (b) => {
      const c = "#ebe5f6", inner = "#f6bfd2", belly = "#fbf8ff";
      b.box(-2, -1, 0, 0, 0, 2, belly); b.box(1, 2, 0, 0, 0, 2, belly);
      b.box(-2, 2, 1, 4, -2, 1, c);
      b.box(-1, 1, 1, 3, 1, 1, belly);
      b.set(0, 2, -3, "#ffffff");
      b.box(-2, 2, 5, 8, -1, 2, c);
      b.set(-1, 7, 2, INK); b.set(1, 7, 2, INK); b.set(0, 6, 2, PINK);
      b.set(-2, 6, 2, "#f8c6d4"); b.set(2, 6, 2, "#f8c6d4");
      b.box(-2, -1, 9, 12, 0, 0, c); b.box(-2, -1, 9, 11, 1, 1, inner);
      b.box(1, 2, 9, 11, 0, 0, c); b.box(1, 2, 9, 10, 1, 1, inner); b.box(2, 3, 12, 12, 0, 0, c);
      b.set(0, 4, 2, "$");
    },
  },
  {
    id: "bear", get name() { return t("Bear"); },
    build: (b) => {
      const c = "#e9b9a3", light = "#f8e4d6";
      b.box(-2, -1, 0, 1, 0, 1, c); b.box(1, 2, 0, 1, 0, 1, c);
      b.box(-3, 3, 1, 5, -2, 1, c);
      b.box(-1, 1, 2, 4, 1, 1, light);
      b.box(-4, -4, 3, 4, -1, 0, c); b.box(4, 4, 3, 4, -1, 0, c);
      b.box(-3, 3, 6, 10, -2, 2, c);
      b.box(-3, -2, 11, 11, -1, 0, c); b.box(2, 3, 11, 11, -1, 0, c);
      b.set(-2, 11, 1, "#f2c3c9"); b.set(2, 11, 1, "#f2c3c9");
      b.box(-1, 1, 6, 7, 3, 3, light); b.set(0, 7, 3, INK);
      b.set(-2, 8, 2, INK); b.set(2, 8, 2, INK);
      b.set(-3, 7, 2, "#f6b8c0"); b.set(3, 7, 2, "#f6b8c0");
      b.box(-1, 1, 5, 5, 2, 2, "$");
    },
  },
  {
    id: "unicorn", get name() { return t("Unicorn"); },
    build: (b) => {
      const c = "#fbf8ff", lilac = "#c9b5f0", pink = "#f6b9d3", mint = "#b5e8d5", hoof = "#c9b5f0";
      for (const [x, z] of [[-2, -3], [2, -3], [-2, 1], [2, 1]]) { b.box(x, x, 1, 2, z, z, c); b.set(x, 0, z, hoof); }
      b.box(-2, 2, 3, 5, -3, 1, c);
      b.box(-1, 1, 6, 7, 0, 2, c);
      b.box(-1, 1, 8, 10, 1, 4, c);
      b.box(-1, 1, 8, 8, 5, 5, "#f4dfe9");
      b.set(-1, 9, 4, INK); b.set(1, 9, 4, INK);
      b.set(-1, 8, 4, "#f8c6d4"); b.set(1, 8, 4, "#f8c6d4");
      b.set(0, 11, 3, "#f2d27a"); b.set(0, 12, 3, "#f2d27a"); b.set(0, 13, 3, "#f8e3a6");
      b.set(-1, 11, 1, c); b.set(1, 11, 1, c);
      [lilac, pink, mint, lilac, pink].forEach((m, i) => b.set(0, 10 - i, 1 - (i > 2 ? 1 : 0), m));
      b.set(0, 11, 2, mint);
      [pink, mint, lilac].forEach((m, i) => b.set(0, 5 - i, -4, m));
    },
  },
  {
    id: "tiger", get name() { return t("Tiger"); },
    build: (b) => {
      const o = "#f4b37a", d = "#c9824a", w = "#fff4e6";
      b.box(-2, 2, 0, 4, -2, 1, o);
      b.box(-1, 1, 1, 3, 1, 1, w);
      b.box(-2, -1, 0, 0, 2, 2, w); b.box(1, 2, 0, 0, 2, 2, w);
      for (const y of [1, 3]) { b.box(-2, -2, y, y, -2, 0, d); b.box(2, 2, y, y, -2, 0, d); }
      b.box(-2, 2, 2, 2, -2, -2, d);
      b.box(-2, 2, 5, 8, -1, 2, o);
      b.set(-1, 8, 2, d); b.set(1, 8, 2, d); b.set(0, 8, 1, d);
      b.box(-1, 1, 5, 5, 2, 2, w); b.set(0, 6, 2, PINK);
      b.set(-1, 7, 2, INK); b.set(1, 7, 2, INK);
      b.set(-2, 6, 2, "#f6b8c0"); b.set(2, 6, 2, "#f6b8c0");
      b.set(-2, 9, 0, o); b.set(2, 9, 0, o); b.set(-2, 9, 1, w); b.set(2, 9, 1, w);
      b.box(3, 3, 0, 0, -2, 1, o); b.set(3, 1, -2, d); b.set(3, 2, -2, o); b.set(3, 3, -2, d);
    },
  },
  {
    id: "fawn", get name() { return t("Fawn"); },
    build: (b) => {
      const c = "#dcab82", spot = "#fbf3e8", hoof = "#7a5233";
      for (const [x, z] of [[-2, -3], [2, -3], [-2, 1], [2, 1]]) { b.box(x, x, 1, 2, z, z, c); b.set(x, 0, z, hoof); }
      b.box(-2, 2, 3, 4, -3, 1, c);
      for (const [x, z] of [[-1, -2], [1, -1], [0, 0], [-1, 1]]) b.set(x, 4, z, spot);
      b.set(0, 4, -4, spot);
      b.box(-1, 1, 5, 6, 0, 1, c);
      b.box(-2, 2, 7, 9, 0, 3, c);
      b.box(-1, 1, 7, 8, 4, 4, "#f6e6d2"); b.set(0, 8, 4, INK);
      b.set(-2, 8, 3, INK); b.set(2, 8, 3, INK);
      b.set(-2, 7, 3, "#f6b8c0"); b.set(2, 7, 3, "#f6b8c0");
      b.box(-3, -3, 9, 10, 1, 1, c); b.box(3, 3, 9, 10, 1, 1, c);
      b.set(-3, 9, 2, "#f6c9b8"); b.set(3, 9, 2, "#f6c9b8");
    },
  },
  {
    id: "bonsai", get name() { return t("Bonsai"); },
    build: (b) => {
      b.box(-4, 4, 0, 1, -2, 2, "#3f4a5c");
      b.box(-3, 3, 2, 2, -1, 1, "#5a3d2b");
      b.box(0, 0, 2, 4, 0, 0, "#7a5233"); b.box(1, 1, 5, 6, 0, 0, "#7a5233"); b.set(-1, 5, 0, "#7a5233");
      b.box(-3, 3, 7, 8, -2, 2, "#4f9461");
      for (const [x, z] of [[-3, -2], [3, -2], [-3, 2], [3, 2]]) { b.clear(x, 7, z); b.clear(x, 8, z); }
      b.box(-2, 2, 9, 9, -1, 1, "#6db37d");
      b.box(-4, -2, 5, 5, -1, 1, "#4f9461");
      b.set(0, 10, 0, "#8fcf9c");
    },
  },
];

export const figureName = (id: string) => FIGURES.find((f) => f.id === id)?.name ?? id;

const cache = new Map<string, Map<string, string>>();
export function figureBricks(id: string): Map<string, string> {
  const hit = cache.get(id);
  if (hit) return hit;
  const grid = new Map<string, string>();
  const key = (x: number, y: number, z: number) => `${x},${y},${z}`;
  FIGURES.find((f) => f.id === id)?.build({
    box: (x0, x1, y0, y1, z0, z1, c) => { for (let x = x0; x <= x1; x++) for (let y = y0; y <= y1; y++) for (let z = z0; z <= z1; z++) grid.set(key(x, y, z), c); },
    set: (x, y, z, c) => grid.set(key(x, y, z), c),
    clear: (x, y, z) => grid.delete(key(x, y, z)),
  });
  cache.set(id, grid);
  return grid;
}

const heights = new Map<string, number>();
export function figureHeight(id: string): number {
  const hit = heights.get(id);
  if (hit !== undefined) return hit;
  let top = 0;
  for (const k of figureBricks(id).keys()) top = Math.max(top, Number(k.split(",")[1]) + 1);
  const h = top * BRICK + BRICK * 0.2;
  heights.set(id, h);
  return h;
}

const extents = new Map<string, number>();
export function figureExtent(id: string): number {
  const hit = extents.get(id);
  if (hit !== undefined) return hit;
  let w = 0;
  for (const k of figureBricks(id).keys()) { const [x, , z] = k.split(",").map(Number); w = Math.max(w, Math.abs(x) * 2 + 1, Math.abs(z) * 2 + 1); }
  const e = Math.max(figureHeight(id), w * BRICK * 0.85);
  extents.set(id, e);
  return e;
}
