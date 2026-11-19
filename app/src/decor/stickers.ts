import { t } from "../i18n";
// The stickers that go on the cube's glass. Each one is drawn once into an image with a die-cut white border
// (like a real vinyl sticker) and then mapped onto the glass. Adding a sticker is adding an entry to STICKERS:
// its art is drawn in a 200 × 200 box and the border is made from its shape.

export interface StickerDef {
  id: string;
  name: string;
  /** Draws the art in a 200 × 200 box. `color` is the machine's color, for stickers that follow it. */
  draw: (g: CanvasRenderingContext2D, color: string) => void;
}

type G = CanvasRenderingContext2D;
const ell = (g: G, x: number, y: number, rx: number, ry: number, fill: string, rot = 0) => {
  g.beginPath(); g.ellipse(x, y, rx, ry, rot, 0, Math.PI * 2); g.fillStyle = fill; g.fill();
};
const poly = (g: G, pts: number[][], fill: string, round = 0) => {
  g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y))); g.closePath();
  g.fillStyle = fill; g.fill();
  if (round) { g.lineJoin = "round"; g.lineWidth = round; g.strokeStyle = fill; g.stroke(); }
};
const stroke = (g: G, pts: number[][], color: string, w: number, alpha = 1) => {
  g.beginPath(); pts.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
  g.globalAlpha = alpha; g.lineCap = "round"; g.lineJoin = "round"; g.lineWidth = w; g.strokeStyle = color; g.stroke(); g.globalAlpha = 1;
};
/** An eye: a dark oval with a glint, the way cute stickers draw them. */
const eye = (g: G, x: number, y: number, rx: number, ry: number, ink = "#2a2220") => {
  ell(g, x, y, rx, ry, ink);
  ell(g, x - rx * 0.32, y - ry * 0.38, rx * 0.36, ry * 0.3, "#ffffff");
  ell(g, x + rx * 0.3, y + ry * 0.35, rx * 0.16, ry * 0.13, "rgba(255,255,255,.7)");
};
const starPts = (cx: number, cy: number, R: number, r: number) =>
  Array.from({ length: 10 }, (_, i) => { const a = -Math.PI / 2 + (i * Math.PI) / 5, k = i % 2 ? r : R; return [cx + Math.cos(a) * k, cy + Math.sin(a) * k]; });
const heartPath = (g: G, dx = 0, dy = 0, k = 1) => {
  const p = (x: number, y: number) => [100 + (x - 100) * k + dx, 110 + (y - 110) * k + dy] as const;
  g.beginPath();
  g.moveTo(...p(100, 172));
  g.bezierCurveTo(...p(28, 122), ...p(20, 70), ...p(58, 50));
  g.bezierCurveTo(...p(82, 38), ...p(97, 54), ...p(100, 68));
  g.bezierCurveTo(...p(103, 54), ...p(118, 38), ...p(142, 50));
  g.bezierCurveTo(...p(180, 70), ...p(172, 122), ...p(100, 172));
  g.closePath();
};

export const STICKERS: StickerDef[] = [
  {
    id: "logo", name: "GpuVM",
    draw: (g, color) => {
      g.save(); g.translate(7, 7); g.scale(2.9, 2.9);
      g.beginPath(); g.roundRect(2, 2, 60, 60, 15); g.fillStyle = "#2a2c31"; g.fill();
      g.strokeStyle = "#ebe8e1"; g.lineCap = "round"; g.lineWidth = 3;
      for (const v of [22, 32, 42]) for (const [a, b] of [[12, 16], [48, 52]]) {
        g.beginPath(); g.moveTo(v, a); g.lineTo(v, b); g.stroke();
        g.beginPath(); g.moveTo(a, v); g.lineTo(b, v); g.stroke();
      }
      g.beginPath(); g.roundRect(17, 17, 30, 30, 6); g.stroke();
      g.globalAlpha = 0.45; g.lineWidth = 2;
      g.beginPath(); g.moveTo(32, 20); g.lineTo(32, 44); g.moveTo(20, 32); g.lineTo(44, 32); g.stroke();
      g.globalAlpha = 1;
      g.beginPath(); g.roundRect(34, 34, 10, 10, 2.5); g.fillStyle = color; g.fill();
      g.restore();
    },
  },
  {
    id: "star", get name() { return t("Star"); },
    draw: (g) => {
      poly(g, starPts(103, 112, 80, 40), "#eda21e", 26);
      poly(g, starPts(99, 107, 76, 38), "#ffc83a", 24);
      poly(g, starPts(97, 104, 62, 31), "#ffd75e", 18);
      stroke(g, [[64, 74], [80, 74]], "#ffffff", 7, 0.75);
      stroke(g, [[96, 34], [92, 50]], "#ffffff", 7, 0.75);
      eye(g, 84, 106, 7, 10, "#3b2a14");
      eye(g, 114, 106, 7, 10, "#3b2a14");
      ell(g, 72, 124, 9, 6, "rgba(255,120,120,.5)");
      ell(g, 126, 124, 9, 6, "rgba(255,120,120,.5)");
      g.beginPath(); g.arc(99, 116, 10, 0.18 * Math.PI, 0.82 * Math.PI);
      g.lineWidth = 4; g.lineCap = "round"; g.strokeStyle = "#3b2a14"; g.stroke();
    },
  },
  {
    id: "bolt", get name() { return t("Bolt"); },
    draw: (g) => {
      const pts = [[112, 14], [56, 110], [96, 110], [78, 188], [150, 80], [110, 80], [148, 14]];
      poly(g, pts.map(([x, y]) => [x + 6, y + 6]), "#e8901c", 12);
      poly(g, pts, "#ffd23f", 12);
      poly(g, [[118, 26], [76, 98], [96, 98], [116, 46]], "#ffe17a");
      stroke(g, [[122, 24], [90, 80]], "#ffffff", 6, 0.7);
    },
  },
  {
    id: "heart", get name() { return t("Heart"); },
    draw: (g) => {
      heartPath(g, 5, 6); g.fillStyle = "#d8344f"; g.fill();
      heartPath(g); g.fillStyle = "#ff5a76"; g.fill();
      heartPath(g, -4, -5, 0.8); g.fillStyle = "#ff7590"; g.fill();
      ell(g, 64, 80, 15, 8, "rgba(255,255,255,.8)", -0.75);
      ell(g, 84, 62, 5, 4, "rgba(255,255,255,.8)");
    },
  },
  {
    id: "cat", get name() { return t("Cat"); },
    draw: (g) => {
      const fur = "#f6a65a", dark = "#d9803a";
      poly(g, [[42, 96], [50, 26], [96, 66]], fur, 14);
      poly(g, [[158, 96], [150, 26], [104, 66]], fur, 14);
      poly(g, [[58, 80], [58, 46], [82, 66]], "#ffb7be", 6);
      poly(g, [[142, 80], [142, 46], [118, 66]], "#ffb7be", 6);
      ell(g, 100, 118, 68, 56, fur);
      for (const [x1, y1, x2, y2] of [[100, 66, 100, 84], [84, 70, 87, 86], [116, 70, 113, 86]]) stroke(g, [[x1, y1], [x2, y2]], dark, 7);
      for (const s of [1, -1]) stroke(g, [[100 + s * 66, 112], [100 + s * 50, 116]], dark, 6);
      ell(g, 86, 138, 18, 13, "#fff3e6");
      ell(g, 114, 138, 18, 13, "#fff3e6");
      eye(g, 76, 112, 9, 12);
      eye(g, 124, 112, 9, 12);
      ell(g, 60, 136, 10, 6, "rgba(255,120,130,.45)");
      ell(g, 140, 136, 10, 6, "rgba(255,120,130,.45)");
      poly(g, [[92, 124], [108, 124], [100, 133]], "#ff7f8f", 5);
      g.beginPath(); g.moveTo(100, 133); g.lineTo(100, 138);
      g.moveTo(87, 138); g.quadraticCurveTo(93, 147, 100, 138); g.quadraticCurveTo(107, 147, 113, 138);
      g.lineWidth = 3; g.lineCap = "round"; g.strokeStyle = "#6b3f2a"; g.stroke();
      for (const s of [1, -1]) {
        stroke(g, [[100 + s * 36, 132], [100 + s * 74, 124]], "#6b3f2a", 2.5, 0.7);
        stroke(g, [[100 + s * 36, 140], [100 + s * 74, 144]], "#6b3f2a", 2.5, 0.7);
      }
    },
  },
  {
    id: "dog", get name() { return t("Dog"); },
    draw: (g) => {
      const cream = "#f3d9b1", brown = "#9a6a3f", patch = "#c28a55";
      ell(g, 100, 108, 56, 54, cream);
      ell(g, 100, 60, 20, 11, patch);
      ell(g, 124, 100, 21, 19, patch);
      eye(g, 78, 102, 8, 11);
      eye(g, 122, 102, 8, 11);
      ell(g, 100, 136, 32, 23, "#fff1dc");
      g.beginPath(); g.ellipse(100, 152, 9, 12, 0, 0, Math.PI); g.fillStyle = "#ff7d8e"; g.fill();
      stroke(g, [[100, 146], [100, 158]], "#e05a6e", 2.5);
      ell(g, 100, 124, 14, 10, "#2a1f18");
      ell(g, 95, 120, 5, 3, "rgba(255,255,255,.8)");
      g.beginPath(); g.moveTo(100, 133); g.lineTo(100, 140);
      g.moveTo(86, 142); g.quadraticCurveTo(93, 150, 100, 140); g.quadraticCurveTo(107, 150, 114, 142);
      g.lineWidth = 3; g.lineCap = "round"; g.strokeStyle = "#5a3a24"; g.stroke();
      ell(g, 64, 128, 9, 6, "rgba(255,120,130,.4)");
      ell(g, 136, 128, 9, 6, "rgba(255,120,130,.4)");
      // Floppy ears hanging over the sides of the head.
      ell(g, 52, 112, 20, 44, brown, 0.32);
      ell(g, 148, 112, 20, 44, brown, -0.32);
      ell(g, 56, 116, 11, 30, "#b07b4b", 0.32);
      ell(g, 144, 116, 11, 30, "#b07b4b", -0.32);
    },
  },
  {
    id: "spider", get name() { return t("Spider"); },
    draw: (g) => {
      const leg = "#3a3347";
      stroke(g, [[100, 6], [100, 66]], "#cfc9da", 3);
      const legs = [[[84, 98], [46, 62], [28, 84]], [[80, 108], [36, 98], [18, 126]], [[80, 120], [38, 134], [26, 164]], [[86, 130], [56, 160], [50, 188]]];
      for (const l of legs) for (const s of [1, -1]) {
        const p = l.map(([x, y]) => [s === 1 ? x : 200 - x, y]);
        stroke(g, p, leg, 10);
        ell(g, p[1][0], p[1][1], 5, 5, "#4d4560");
      }
      ell(g, 100, 142, 40, 38, "#3f3752");
      ell(g, 92, 132, 16, 12, "#4f4666", -0.4);
      for (const [x, y, r] of [[100, 154, 7], [86, 166, 4], [114, 166, 4]]) ell(g, x, y, r, r, "#7a6aa6");
      ell(g, 100, 96, 36, 32, "#4a4160");
      ell(g, 88, 84, 12, 7, "rgba(255,255,255,.12)", -0.5);
      for (const x of [86, 114]) { ell(g, x, 96, 11, 13, "#ffffff"); eye(g, x + 1, 99, 6.5, 7.5, "#1d1826"); }
      for (const x of [80, 120]) { ell(g, x, 76, 4.5, 4.5, "#ffffff"); ell(g, x, 77, 2.4, 2.4, "#1d1826"); }
      ell(g, 74, 112, 8, 5, "rgba(255,130,170,.45)");
      ell(g, 126, 112, 8, 5, "rgba(255,130,170,.45)");
      poly(g, [[93, 116], [99, 116], [96, 123]], "#ffffff", 2);
      poly(g, [[101, 116], [107, 116], [104, 123]], "#ffffff", 2);
    },
  },
  {
    id: "ghost", get name() { return t("Ghost"); },
    draw: (g) => {
      const body = (dx: number, dy: number) => {
        g.beginPath();
        g.moveTo(42 + dx, 168 + dy);
        g.lineTo(42 + dx, 92 + dy);
        g.arc(100 + dx, 92 + dy, 58, Math.PI, 0);
        g.lineTo(158 + dx, 168 + dy);
        for (let i = 0; i < 4; i++) { const x = 158 - i * 29; g.quadraticCurveTo(x - 7 + dx, 186 + dy, x - 14.5 + dx, 170 + dy); g.quadraticCurveTo(x - 22 + dx, 154 + dy, x - 29 + dx, 168 + dy); }
        g.closePath();
      };
      body(5, 5); g.fillStyle = "#cfc8e6"; g.fill();
      body(0, 0); g.fillStyle = "#f6f4fc"; g.fill();
      ell(g, 70, 66, 12, 7, "rgba(255,255,255,.9)", -0.6);
      eye(g, 80, 104, 9, 13, "#2b2540");
      eye(g, 120, 104, 9, 13, "#2b2540");
      ell(g, 64, 124, 10, 6, "rgba(255,140,170,.45)");
      ell(g, 136, 124, 10, 6, "rgba(255,140,170,.45)");
      ell(g, 100, 128, 7, 9, "#2b2540");
      ell(g, 100, 132, 4, 4, "#ff8fa8");
    },
  },
  {
    id: "rocket", get name() { return t("Rocket"); },
    draw: (g) => {
      g.save(); g.translate(100, 100); g.rotate(Math.PI / 4);
      // Flame, fins, body, nose and window.
      g.beginPath(); g.moveTo(-16, 58); g.quadraticCurveTo(0, 104, 16, 58); g.closePath(); g.fillStyle = "#ff8a2e"; g.fill();
      g.beginPath(); g.moveTo(-8, 58); g.quadraticCurveTo(0, 86, 8, 58); g.closePath(); g.fillStyle = "#ffd23f"; g.fill();
      for (const s of [1, -1]) poly(g, [[s * 22, 14], [s * 46, 52], [s * 22, 52]], "#e04848", 8);
      g.beginPath(); g.moveTo(-24, 58); g.lineTo(-24, -30); g.quadraticCurveTo(-24, -76, 0, -96); g.quadraticCurveTo(24, -76, 24, -30); g.lineTo(24, 58); g.closePath();
      g.fillStyle = "#eef0f4"; g.fill();
      g.beginPath(); g.moveTo(8, 58); g.lineTo(8, -30); g.quadraticCurveTo(10, -70, 0, -96); g.quadraticCurveTo(24, -76, 24, -30); g.lineTo(24, 58); g.closePath(); g.fillStyle = "#d3d7df"; g.fill();
      g.beginPath(); g.moveTo(-17, -56); g.quadraticCurveTo(0, -66, 17, -56); g.quadraticCurveTo(10, -82, 0, -96); g.quadraticCurveTo(-10, -82, -17, -56); g.closePath(); g.fillStyle = "#e04848"; g.fill();
      ell(g, 0, -14, 16, 16, "#9aa3b2");
      ell(g, 0, -14, 11, 11, "#5bb6f0");
      ell(g, -4, -18, 4, 3, "rgba(255,255,255,.85)");
      stroke(g, [[-24, 34], [24, 34]], "#c7ccd5", 4);
      g.restore();
    },
  },
  {
    id: "fire", get name() { return t("Fire"); },
    draw: (g) => {
      const flame = (k: number, dy: number, color: string) => {
        g.save(); g.translate(100, 180 + dy); g.scale(k, k);
        g.beginPath();
        g.moveTo(0, 0);
        g.bezierCurveTo(-62, 0, -70, -60, -40, -100);
        g.bezierCurveTo(-34, -78, -22, -70, -14, -72);
        g.bezierCurveTo(-26, -112, 0, -146, 14, -166);
        g.bezierCurveTo(16, -128, 66, -108, 62, -56);
        g.bezierCurveTo(60, -20, 40, 0, 0, 0);
        g.closePath(); g.fillStyle = color; g.fill(); g.restore();
      };
      flame(1, 0, "#ff6a2e");
      flame(0.72, -4, "#ff9a2e");
      flame(0.46, -6, "#ffd23f");
      eye(g, 88, 130, 6, 8, "#3b1d0e");
      eye(g, 112, 130, 6, 8, "#3b1d0e");
      g.beginPath(); g.arc(100, 140, 8, 0.15 * Math.PI, 0.85 * Math.PI); g.lineWidth = 3.5; g.lineCap = "round"; g.strokeStyle = "#3b1d0e"; g.stroke();
    },
  },
  {
    id: "gem", get name() { return t("Diamond"); },
    draw: (g) => {
      const top = [[52, 70], [76, 40], [124, 40], [148, 70]], tip = [100, 170];
      poly(g, [top[0], top[1], top[2], top[3], tip], "#3fb8d6", 6);
      poly(g, [[76, 40], [100, 70], [52, 70]], "#9ee9f5");
      poly(g, [[76, 40], [124, 40], [100, 70]], "#c9f6fb");
      poly(g, [[124, 40], [148, 70], [100, 70]], "#7fdcee");
      poly(g, [[52, 70], [100, 70], tip], "#5fcde4");
      poly(g, [[100, 70], [148, 70], tip], "#2ea3c4");
      poly(g, [[78, 70], [100, 70], [100, 160]], "#8de3f2");
      stroke(g, [[84, 48], [70, 64]], "#ffffff", 5, 0.8);
    },
  },
  {
    id: "moon", get name() { return t("Moon"); },
    draw: (g) => {
      g.beginPath(); g.arc(100, 104, 74, 0, Math.PI * 2); g.fillStyle = "#ffe08a"; g.fill();
      g.globalCompositeOperation = "destination-out";
      g.beginPath(); g.arc(138, 78, 62, 0, Math.PI * 2); g.fill();
      g.globalCompositeOperation = "source-over";
      for (const [x, y, r] of [[56, 112, 9], [80, 150, 6], [44, 80, 5]]) ell(g, x, y, r, r, "#f2c95e");
      g.beginPath(); g.arc(70, 122, 7, 0.1 * Math.PI, 0.9 * Math.PI); g.lineWidth = 3.5; g.lineCap = "round"; g.strokeStyle = "#5a4320"; g.stroke();
      ell(g, 58, 134, 8, 5, "rgba(255,140,140,.5)");
      for (const [x, y, k] of [[150, 140, 1], [172, 106, 0.6], [128, 170, 0.5]]) poly(g, starPts(x, y, 14 * k, 6 * k), "#fff3c4", 3);
    },
  },
  {
    id: "gamepad", get name() { return t("Controller"); },
    draw: (g, color) => {
      const body = (dy: number, color: string) => {
        g.beginPath();
        g.moveTo(52, 70 + dy); g.lineTo(148, 70 + dy);
        g.bezierCurveTo(176, 70 + dy, 192, 132 + dy, 182, 150 + dy);
        g.bezierCurveTo(172, 168 + dy, 150, 160 + dy, 138, 138 + dy);
        g.lineTo(62, 138 + dy);
        g.bezierCurveTo(50, 160 + dy, 28, 168 + dy, 18, 150 + dy);
        g.bezierCurveTo(8, 132 + dy, 24, 70 + dy, 52, 70 + dy);
        g.closePath(); g.fillStyle = color; g.fill();
      };
      body(5, "#24262b");
      body(0, "#3b3e46");
      stroke(g, [[44, 82], [70, 80]], "rgba(255,255,255,.18)", 5);
      poly(g, [[50, 96], [62, 96], [62, 84], [74, 84], [74, 96], [86, 96], [86, 108], [74, 108], [74, 120], [62, 120], [62, 108], [50, 108]], "#25272c", 3);
      for (const [x, y, c] of [[140, 86, "#ffd34d"], [154, 100, "#ff6b6b"], [126, 100, "#6aa8ff"], [140, 114, "#7bd88f"]] as [number, number, string][]) ell(g, x, y, 8, 8, c);
      ell(g, 84, 128, 11, 11, "#25272c"); ell(g, 116, 128, 11, 11, "#25272c");
      ell(g, 84, 126, 7, 7, "#555a64"); ell(g, 116, 126, 7, 7, "#555a64");
      ell(g, 100, 92, 6, 6, color);
    },
  },
];

/** Images the person added as stickers, shared by every machine. */
const CUSTOM_KEY = "gpuvm.decor.custom";
const IMG_KEY = "gpuvm.decor.img.";
export function customStickers(): string[] {
  try { return JSON.parse(localStorage.getItem(CUSTOM_KEY) ?? "[]"); } catch { return []; }
}
export function customImage(id: string): string | null {
  try { return localStorage.getItem(IMG_KEY + id); } catch { return null; }
}

/** Reads an image file, makes it at most 256 px on its longer side (keeping its transparency) and keeps it as a
 *  sticker. Returns its sticker id, or throws with a message to show. */
export async function addCustomSticker(file: File): Promise<string> {
  if (!/^image\/(png|webp|jpeg|gif)$/.test(file.type)) throw new Error(t("Use a PNG, WEBP, JPG or GIF image."));
  if (file.size > 8 * 1024 * 1024) throw new Error(t("The image is larger than 8 MB."));
  const url = URL.createObjectURL(file);
  try {
    const img = await new Promise<HTMLImageElement>((ok, fail) => { const i = new Image(); i.onload = () => ok(i); i.onerror = () => fail(new Error(t("The image couldn't be read."))); i.src = url; });
    const k = Math.min(1, 256 / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(img.width * k)); c.height = Math.max(1, Math.round(img.height * k));
    c.getContext("2d")!.drawImage(img, 0, 0, c.width, c.height);
    const id = Math.random().toString(36).slice(2, 10);
    localStorage.setItem(IMG_KEY + id, c.toDataURL("image/png"));
    localStorage.setItem(CUSTOM_KEY, JSON.stringify([...customStickers(), id]));
    window.dispatchEvent(new Event("gpuvm-decor"));
    return `custom:${id}`;
  } finally { URL.revokeObjectURL(url); }
}
export function removeCustomSticker(id: string) {
  try {
    localStorage.removeItem(IMG_KEY + id);
    localStorage.setItem(CUSTOM_KEY, JSON.stringify(customStickers().filter((c) => c !== id)));
  } catch { /* no storage */ }
  images.forEach((_, k) => { if (k.startsWith(`custom:${id}`)) images.delete(k); });
  window.dispatchEvent(new Event("gpuvm-decor"));
}

const SIZE = 256, PAD = 28, BORDER = 9;
/** The art with its die-cut border: a white margin following its shape. Drawn stickers
 *  also get an ink line around the art, like printed illustrations, and every sticker a soft vinyl sheen. */
function dieCut(art: HTMLCanvasElement, ink = false): HTMLCanvasElement {
  const out = document.createElement("canvas");
  out.width = out.height = SIZE;
  const g = out.getContext("2d")!;
  const ring = (r: number, color: string) => {
    const layer = document.createElement("canvas");
    layer.width = layer.height = SIZE;
    const l = layer.getContext("2d")!;
    for (let i = 0; i < 32; i++) { const a = (i / 32) * Math.PI * 2; l.drawImage(art, Math.cos(a) * r, Math.sin(a) * r); }
    l.globalCompositeOperation = "source-in";
    l.fillStyle = color; l.fillRect(0, 0, SIZE, SIZE);
    g.drawImage(layer, 0, 0);
  };
  // Just the white margin: no gray edge around it, which read as a shadow.
  ring(BORDER, "#f8f6f1");
  if (ink) ring(2.6, "#2b2420");
  g.drawImage(art, 0, 0);
  // The vinyl's sheen: a wide light band across the upper left, only on the sticker itself.
  g.globalCompositeOperation = "source-atop";
  const sheen = g.createLinearGradient(0, 0, SIZE, SIZE);
  sheen.addColorStop(0, "rgba(255,255,255,0.22)");
  sheen.addColorStop(0.38, "rgba(255,255,255,0.06)");
  sheen.addColorStop(0.42, "rgba(255,255,255,0)");
  sheen.addColorStop(1, "rgba(0,0,0,0.05)");
  g.fillStyle = sheen; g.fillRect(0, 0, SIZE, SIZE);
  g.globalCompositeOperation = "source-over";
  return out;
}

const images = new Map<string, HTMLCanvasElement | null>();
/** The sticker as an image ready to draw (256 px square, the art centered), or null while a custom one loads. */
export function stickerImage(id: string, color: string): HTMLCanvasElement | null {
  const key = `${id}|${id === "logo" || id === "gamepad" ? color : ""}`;
  if (images.has(key)) return images.get(key)!;
  const art = document.createElement("canvas");
  art.width = art.height = SIZE;
  const g = art.getContext("2d")!;
  if (id.startsWith("custom:")) {
    const src = customImage(id.slice(7));
    if (!src) { images.set(key, null); return null; }
    images.set(key, null);
    const img = new Image();
    img.onload = () => {
      const k = Math.min((SIZE - PAD * 2) / img.width, (SIZE - PAD * 2) / img.height);
      g.drawImage(img, (SIZE - img.width * k) / 2, (SIZE - img.height * k) / 2, img.width * k, img.height * k);
      images.set(key, dieCut(art));
      window.dispatchEvent(new Event("gpuvm-decor"));
    };
    img.src = src;
    return null;
  }
  const def = STICKERS.find((s) => s.id === id);
  if (!def) return null;
  g.translate(PAD, PAD);
  g.scale((SIZE - PAD * 2) / 200, (SIZE - PAD * 2) / 200);
  def.draw(g, color);
  const done = dieCut(art, id !== "logo");
  images.set(key, done);
  return done;
}

export const stickerName = (id: string) => (id.startsWith("custom:") ? t("Your image") : STICKERS.find((s) => s.id === id)?.name ?? id);
