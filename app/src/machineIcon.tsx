import { useEffect, useState, useSyncExternalStore } from "react";
import { decorColor, useDecor } from "./decor/store";

// A machine's icon (a tile tinted with its color): the app logo's chip with one of its four parts in the machine's color — the part of the GPU it gets.
// Each name always gets the same part and color; "Otro ícono" moves to the next variant.

// Muted, dark-friendly colors. Blue stays out: it is the accent for actions.
const NORMAL = ["#4f9a86", "#c4775e", "#8a7fd0", "#c9a24f", "#c46f8e"];
// A hidden palette: three quick clicks on any icon turn every color purple; three more undo it.
const PURPLE = ["#8a6fe0", "#6d5bc4", "#a98cf0", "#7a63d6", "#9b7ee8"];
const PALETTE_KEY = "gpuvm.palette";
let purple = (() => { try { return localStorage.getItem(PALETTE_KEY) === "purple"; } catch { return false; } })();
const palette = () => (purple ? PURPLE : NORMAL);

function subscribePalette(onChange: () => void) {
  window.addEventListener("gpuvm-palette", onChange);
  return () => window.removeEventListener("gpuvm-palette", onChange);
}
function usePalette() { return useSyncExternalStore(subscribePalette, () => purple); }

// A triple click, not three changes at a normal pace: each click must come less than 300 ms after the previous one.
const QUICK_MS = 300;
let streak = 0;
let lastClick = -Infinity;
/** Call on every click of an icon. True on the third quick click in a row: the palette has just switched. */
export function patternClick(): boolean {
  const now = performance.now();
  streak = now - lastClick < QUICK_MS ? streak + 1 : 1;
  lastClick = now;
  if (streak < 3) return false;
  streak = 0;
  purple = !purple;
  try { localStorage.setItem(PALETTE_KEY, purple ? "purple" : "normal"); } catch { /* no storage */ }
  window.dispatchEvent(new Event("gpuvm-palette"));
  return true;
}

export function hash(text: string) {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** Seeded random numbers in [0, 1): the same seed always gives the same sequence. */
export function random(seed: number) {
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

/** A renamed machine keeps the pattern picked for it. */
export function renamePatternVariant(from: string, to: string) {
  try {
    const saved = localStorage.getItem(VARIANT_KEY + from);
    if (saved !== null) { localStorage.setItem(VARIANT_KEY + to, saved); localStorage.removeItem(VARIANT_KEY + from); }
  } catch { /* no storage */ }
}

export function machineColor(name: string, variant = patternVariant(name)) {
  // A color picked in Personalizar wins over the one from the name.
  const own = decorColor(name);
  if (own) return own;
  const colors = palette();
  return colors[hash(`${name}#${variant}`) % colors.length];
}

/** Which of the chip's four parts (0 top-left … 3 bottom-right) belongs to this name. */
export function machinePart(name: string, variant = patternVariant(name)) {
  return hash(`${name}#${variant}#part`) % 4;
}

interface Props {
  name: string;
  size: number;
  radius?: number;
  variant?: number;
  muted?: boolean;
}

const CELL = [[10, 10], [20.5, 10], [10, 20.5], [20.5, 20.5]];

/** The machine's icon. `muted` dims it for powered-off machines without a GPU. */
export function MachineIcon({ name, size, radius, variant, muted }: Props) {
  usePalette();
  useDecor(name);
  const v = variant ?? patternVariant(name);
  const color = machineColor(name, v);
  const part = machinePart(name, v);
  return (
    <svg className="machine-icon" width={size} height={size} viewBox="0 0 40 40" aria-hidden="true"
      style={{ borderRadius: radius ?? Math.round(size / 4), filter: muted ? "saturate(0.35)" : undefined }}>
      <rect width="40" height="40" fill={color} fillOpacity={0.14} />
      {CELL.map(([x, y], i) => (
        <rect key={i} x={x} y={y} width="9.5" height="9.5" rx="2.4"
          fill={i === part ? color : "var(--text)"} fillOpacity={i === part ? 1 : 0.08} />
      ))}
    </svg>
  );
}

/** An icon that changes to the next variant when clicked; the choice is remembered and shown everywhere at once. */
export function PatternButton({ name, onChange, ...props }: Omit<Props, "variant"> & { onChange?: (variant: number) => void }) {
  const [variant, setVariant] = useState(() => patternVariant(name));
  useEffect(() => {
    setVariant(patternVariant(name));
    const sync = () => setVariant(patternVariant(name));
    window.addEventListener("gpuvm-pattern", sync);
    return () => window.removeEventListener("gpuvm-pattern", sync);
  }, [name]);
  const next = () => {
    // The third quick click switched the palette: the two clicks before it go back, so only the colors change.
    const v = patternClick() ? Math.max(0, variant - 2) : variant + 1;
    setPatternVariant(name, v);
    setVariant(v);
    onChange?.(v);
    window.dispatchEvent(new Event("gpuvm-pattern"));
  };
  return (
    <button type="button" className="pattern-btn" title="Otro ícono" aria-label="Otro ícono" onClick={next}>
      <MachineIcon name={name} variant={variant} {...props} />
    </button>
  );
}
