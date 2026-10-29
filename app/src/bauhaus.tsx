import { useEffect, useState } from "react";

// Seeded Bauhaus patterns: each machine always gets the same one, and its main color
// tints its primary button.

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

type Shape = (x: number, y: number, s: number, fill: string, r: () => number, key: string) => JSX.Element | null;

const shapes: Shape[] = [
  (x, y, s, f, _r, k) => <circle key={k} cx={x + s / 2} cy={y + s / 2} r={s * 0.38} fill={f} />,
  (x, y, s, f, r, k) => {
    const corner = Math.floor(r() * 4);
    const cx = corner % 2 ? x + s : x;
    const cy = corner > 1 ? y + s : y;
    return <path key={k} d={`M${cx} ${cy} L${cx === x ? x + s : x} ${cy} A${s} ${s} 0 0 ${corner === 0 || corner === 3 ? 1 : 0} ${cx} ${cy === y ? y + s : y} Z`} fill={f} />;
  },
  (x, y, s, f, r, k) => {
    const up = r() > 0.5;
    return <path key={k} d={up ? `M${x} ${y + s} L${x + s / 2} ${y} L${x + s} ${y + s} Z` : `M${x} ${y} L${x + s} ${y} L${x} ${y + s} Z`} fill={f} />;
  },
  (x, y, s, f, _r, k) => <rect key={k} x={x + s * 0.18} y={y + s * 0.18} width={s * 0.64} height={s * 0.64} fill={f} />,
  (x, y, s, f, r, k) => {
    const top = r() > 0.5;
    return <path key={k} d={top ? `M${x} ${y + s / 2} A${s / 2} ${s / 2} 0 0 1 ${x + s} ${y + s / 2} Z` : `M${x} ${y + s / 2} A${s / 2} ${s / 2} 0 0 0 ${x + s} ${y + s / 2} Z`} fill={f} />;
  },
  () => null,
];

interface Props {
  name: string;
  size: number;
  radius?: number;
  cols?: number;
  rows?: number;
  variant?: number;
  muted?: boolean;
}

/** Bauhaus icon or banner for a machine. `muted` dims it for powered-off machines without a GPU. */
export function Bauhaus({ name, size, radius = 10, cols = 2, rows = 2, variant, muted }: Props) {
  const v = variant ?? patternVariant(name);
  const r = random(hash(`${name}#${v}#shapes`));
  const bg = machineColor(name, v);
  const cell = 100 / cols;
  const height = cell * rows;
  const palette = [...COLORS, ...NEUTRALS].filter((c) => c !== bg);
  const cells: JSX.Element[] = [];
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const shape = shapes[Math.floor(r() * shapes.length)];
      const fill = palette[Math.floor(r() * palette.length)];
      const el = shape(col * cell, row * cell, cell, fill, r, `${row}-${col}`);
      if (el) cells.push(el);
    }
  }
  const width = cols === rows ? size : (size * cols) / rows;
  return (
    <svg width={width} height={size} viewBox={`0 0 100 ${height}`} preserveAspectRatio="xMidYMid slice"
      style={{ borderRadius: radius, display: "block", flex: "none", filter: muted ? "saturate(0.35)" : undefined }} aria-hidden="true">
      <rect width="100" height={height} fill={bg} />
      {cells}
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
