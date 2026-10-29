import { useEffect, useState } from "react";

// Seeded Bauhaus patterns: each machine always gets the same one (its background is the machine's color).

const COLORS = ["#2f5bd3", "#e5483f", "#f2b632", "#1f8f6a"];
const NEUTRALS = ["#f6f5f2", "#23252a"];

function hash(text: string) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function random(seed: number) {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const VARIANT_KEY = "gpuvm.pattern.";

export function patternVariant(name: string): number {
  try { return Number(localStorage.getItem(VARIANT_KEY + name) ?? 0); } catch { return 0; }
}

export function setPatternVariant(name: string, variant: number) {
  try { localStorage.setItem(VARIANT_KEY + name, String(variant)); } catch { /* no storage */ }
}

export function machineColor(name: string, variant = patternVariant(name)) {
  return COLORS[hash(`${name}#${variant}`) % COLORS.length];
}

// Figures for the machines' icons: animals and objects built from circles, triangles and rectangles, drawn on a
// 100 x 100 square and kept between 14 and 86 so the square's rounded corners never cut them. `l` and `d` are the
// light and dark inks; `a` and `b` two accents that differ from the background.
type Inks = { l: string; d: string; a: string; b: string };
type Figure = (c: Inks) => JSX.Element;

const figures: Figure[] = [
  // Fox.
  ({ l, d }) => (
    <g>
      <path d="M26 36 L34 18 L44 34 Z M56 34 L66 18 L74 36 Z" fill={l} />
      <path d="M24 36 L76 36 L50 82 Z" fill={l} />
      <path d="M39 56 L61 56 L50 82 Z" fill={d} />
      <circle cx="39" cy="46" r="3.5" fill={d} />
      <circle cx="61" cy="46" r="3.5" fill={d} />
    </g>
  ),
  // Bird.
  ({ l, d, a }) => (
    <g>
      <path d="M18 64 A30 30 0 0 1 66 40 L66 64 Z" fill={l} />
      <circle cx="64" cy="40" r="13" fill={l} />
      <path d="M76 36 L86 41 L76 46 Z" fill={a} />
      <circle cx="67" cy="38" r="3" fill={d} />
      <path d="M38 64 V78 M50 64 V78" stroke={a} strokeWidth="4" strokeLinecap="round" />
    </g>
  ),
  // Fish.
  ({ d, a }) => (
    <g>
      <ellipse cx="44" cy="50" rx="27" ry="17" fill={a} />
      <path d="M68 50 L86 34 L86 66 Z" fill={a} />
      <path d="M36 37 C44 44 44 56 36 63" fill="none" stroke={d} strokeWidth="3" />
      <circle cx="27" cy="47" r="3.5" fill={d} />
    </g>
  ),
  // Cat.
  ({ d, a }) => (
    <g>
      <path d="M26 46 L28 20 L46 34 Z M74 46 L72 20 L54 34 Z" fill={d} />
      <circle cx="50" cy="56" r="26" fill={d} />
      <circle cx="40" cy="53" r="5" fill={a} />
      <circle cx="60" cy="53" r="5" fill={a} />
      <path d="M46 64 L54 64 L50 69 Z" fill={a} />
    </g>
  ),
  // Owl.
  ({ l, d, a }) => (
    <g>
      <path d="M24 30 L36 22 L64 22 L76 30 L76 66 A26 18 0 0 1 24 66 Z" fill={d} />
      <circle cx="38" cy="42" r="11" fill={l} />
      <circle cx="62" cy="42" r="11" fill={l} />
      <circle cx="38" cy="42" r="4.5" fill={d} />
      <circle cx="62" cy="42" r="4.5" fill={d} />
      <path d="M45 54 L55 54 L50 63 Z" fill={a} />
    </g>
  ),
  // Whale.
  ({ l, d }) => (
    <g>
      <path d="M14 58 C14 42 32 34 50 36 C64 38 72 46 72 54 L84 42 L86 66 L74 62 C68 70 54 74 40 72 C24 70 14 66 14 58 Z" fill={l} />
      <path d="M20 62 C32 66 50 66 64 60" fill="none" stroke={d} strokeWidth="3" strokeLinecap="round" />
      <circle cx="30" cy="50" r="3.5" fill={d} />
      <path d="M40 30 V20 M40 24 L32 16 M40 24 L48 16" stroke={l} strokeWidth="4" strokeLinecap="round" />
    </g>
  ),
  // Turtle.
  ({ l, d, a }) => (
    <g>
      <path d="M22 62 A24 24 0 0 1 70 62 Z" fill={a} />
      <path d="M34 62 A12 12 0 0 1 58 62 Z" fill={d} />
      <circle cx="76" cy="58" r="8" fill={l} />
      <circle cx="78" cy="56" r="2" fill={d} />
      <rect x="28" y="62" width="8" height="12" rx="3" fill={l} />
      <rect x="56" y="62" width="8" height="12" rx="3" fill={l} />
    </g>
  ),
  // Bear.
  ({ l, d }) => (
    <g>
      <circle cx="30" cy="30" r="10" fill={d} />
      <circle cx="70" cy="30" r="10" fill={d} />
      <circle cx="50" cy="54" r="28" fill={d} />
      <ellipse cx="50" cy="64" rx="12" ry="9" fill={l} />
      <circle cx="50" cy="60" r="3.5" fill={d} />
      <circle cx="40" cy="48" r="3.5" fill={l} />
      <circle cx="60" cy="48" r="3.5" fill={l} />
    </g>
  ),
  // Rabbit.
  ({ l, d, a }) => (
    <g>
      <rect x="34" y="14" width="11" height="34" rx="5.5" fill={l} />
      <rect x="55" y="14" width="11" height="34" rx="5.5" fill={l} />
      <rect x="37.5" y="20" width="4" height="22" rx="2" fill={a} />
      <rect x="58.5" y="20" width="4" height="22" rx="2" fill={a} />
      <circle cx="50" cy="62" r="22" fill={l} />
      <circle cx="42" cy="58" r="3" fill={d} />
      <circle cx="58" cy="58" r="3" fill={d} />
      <path d="M46 67 L54 67 L50 71 Z" fill={a} />
    </g>
  ),
  // Penguin.
  ({ l, d, a }) => (
    <g>
      <ellipse cx="50" cy="52" rx="24" ry="30" fill={d} />
      <ellipse cx="50" cy="58" rx="15" ry="21" fill={l} />
      <circle cx="43" cy="40" r="4" fill={l} />
      <circle cx="57" cy="40" r="4" fill={l} />
      <circle cx="43" cy="40" r="2" fill={d} />
      <circle cx="57" cy="40" r="2" fill={d} />
      <path d="M45 46 L55 46 L50 53 Z" fill={a} />
      <path d="M36 80 H46 M54 80 H64" stroke={a} strokeWidth="5" strokeLinecap="round" />
    </g>
  ),
  // Planet.
  ({ l, a }) => (
    <g>
      <circle cx="50" cy="50" r="20" fill={a} />
      <ellipse cx="50" cy="50" rx="34" ry="9" fill="none" stroke={l} strokeWidth="4" transform="rotate(-20 50 50)" />
      <circle cx="76" cy="24" r="4" fill={l} />
      <circle cx="24" cy="76" r="2.5" fill={l} />
    </g>
  ),
  // Mountain and sun.
  ({ l, d, a }) => (
    <g>
      <circle cx="70" cy="30" r="10" fill={a} />
      <path d="M14 78 L40 32 L56 58 L64 46 L86 78 Z" fill={l} />
      <path d="M40 32 L48 46 L32 46 Z" fill={d} />
    </g>
  ),
  // Rocket.
  ({ l, d, a, b }) => (
    <g>
      <path d="M50 14 C63 25 65 48 59 66 L41 66 C35 48 37 25 50 14 Z" fill={l} />
      <circle cx="50" cy="38" r="6.5" fill={b} />
      <path d="M41 54 L30 70 L41 66 Z M59 54 L70 70 L59 66 Z" fill={a} />
      <path d="M45 66 L50 84 L55 66 Z" fill={d} />
    </g>
  ),
  // Cactus.
  ({ l, d, a }) => (
    <g>
      <rect x="43" y="18" width="14" height="52" rx="7" fill={l} />
      <path d="M43 52 H33 A6 6 0 0 1 27 46 V34" fill="none" stroke={l} strokeWidth="10" strokeLinecap="round" />
      <path d="M57 44 H67 A6 6 0 0 0 73 38 V30" fill="none" stroke={l} strokeWidth="10" strokeLinecap="round" />
      <path d="M32 70 H68 L64 84 H36 Z" fill={a} />
      <circle cx="50" cy="16" r="4" fill={d} />
    </g>
  ),
  // Moon and stars.
  ({ l }) => (
    <g>
      <path d="M58 18 A32 32 0 1 0 82 66 A26 26 0 1 1 58 18 Z" fill={l} />
      <path d="M70 22 L72 28 L78 30 L72 32 L70 38 L68 32 L62 30 L68 28 Z" fill={l} />
      <circle cx="78" cy="48" r="2.5" fill={l} />
    </g>
  ),
  // Sailboat.
  ({ l, d, a }) => (
    <g>
      <path d="M48 16 L48 62 L22 62 Z" fill={l} />
      <path d="M53 26 L53 62 L76 62 Z" fill={a} />
      <path d="M16 66 H84 L74 80 H26 Z" fill={d} />
    </g>
  ),
  // Tree.
  ({ l, d }) => (
    <g>
      <path d="M50 14 L74 46 L26 46 Z" fill={l} />
      <path d="M50 30 L80 68 L20 68 Z" fill={l} />
      <rect x="44" y="68" width="12" height="16" fill={d} />
    </g>
  ),
  // Mushroom.
  ({ l, d, a }) => (
    <g>
      <path d="M16 52 A34 30 0 0 1 84 52 Z" fill={a} />
      <circle cx="36" cy="38" r="5" fill={l} />
      <circle cx="58" cy="32" r="6" fill={l} />
      <circle cx="70" cy="46" r="4" fill={l} />
      <path d="M40 52 H60 L64 82 H36 Z" fill={l} />
      <path d="M42 64 H58" stroke={d} strokeWidth="3" strokeLinecap="round" />
    </g>
  ),
];

interface Props {
  name: string;
  size: number;
  radius?: number;
  variant?: number;
  muted?: boolean;
}

/** A machine's icon: a square in its color with an animal or object, the same one every time for that name.
 *  "Otro patrón" (another pattern) moves to the next variant. `muted` dims it for powered-off machines without a GPU. */
export function Bauhaus({ name, size, radius = 10, variant, muted }: Props) {
  const v = variant ?? patternVariant(name);
  const r = random(hash(`${name}#${v}#figure`));
  const bg = machineColor(name, v);
  const accents = COLORS.filter((c) => c !== bg);
  const a = accents[Math.floor(r() * accents.length)];
  const b = accents.filter((c) => c !== a)[Math.floor(r() * (accents.length - 1))];
  // On yellow, the light ink would hardly show: light and dark swap.
  const [l, d] = bg === "#f2b632" ? [NEUTRALS[1], NEUTRALS[0]] : NEUTRALS;
  const figure = figures[hash(`${name}#${v}`) % figures.length];
  return (
    <svg width={size} height={size} viewBox="0 0 100 100"
      style={{ borderRadius: radius, display: "block", flex: "none", filter: muted ? "saturate(0.35)" : undefined }} aria-hidden="true">
      <rect width="100" height="100" fill={bg} />
      {figure({ l, d, a, b })}
    </svg>
  );
}

import type { JSX } from "react";

/** A pattern that changes to the next one when clicked; the choice is remembered and shown everywhere at once. */
export function PatternButton({ name, onChange, ...props }: Omit<Props, "variant"> & { onChange?: (variant: number) => void }) {
  const [variant, setVariant] = useState(() => patternVariant(name));
  useEffect(() => {
    setVariant(patternVariant(name));
    const sync = () => setVariant(patternVariant(name));
    window.addEventListener("gpuvm-pattern", sync);
    return () => window.removeEventListener("gpuvm-pattern", sync);
  }, [name]);
  const next = () => {
    const v = variant + 1;
    setPatternVariant(name, v);
    setVariant(v);
    onChange?.(v);
    window.dispatchEvent(new Event("gpuvm-pattern"));
  };
  return (
    <button type="button" className="pattern-btn" title="Otro patrón" aria-label="Otro patrón" onClick={next}>
      <Bauhaus name={name} variant={variant} {...props} />
    </button>
  );
}
