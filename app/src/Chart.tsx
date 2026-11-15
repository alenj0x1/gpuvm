import type { Sample } from "./types";

export const MAX_SAMPLES = 150;
const WIDTH = 300;
const HEIGHT = 32;

/** One value's last 5 minutes (one sample every 2 s) as a small line under its number. 0-100. */
export function Sparkline({ values, color }: { values: number[]; color: string }) {
  // The line grows from the right as samples arrive, but the first minute already spans a good part of the width.
  const span = Math.min(MAX_SAMPLES, Math.max(values.length, 30));
  const step = WIDTH / (span - 1);
  const offset = span - values.length;
  const points = values.map((v, i) => `${((offset + i) * step).toFixed(1)},${(HEIGHT - (Math.min(100, Math.max(0, v)) / 100) * (HEIGHT - 4) - 2).toFixed(1)}`).join(" ");
  return (
    <svg className="sparkline" viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" aria-hidden="true">
      <line x1="0" x2={WIDTH} y1={HEIGHT - 1} y2={HEIGHT - 1} stroke="var(--chart-grid)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
      {values.length > 1 && <polyline points={points} fill="none" stroke={color} strokeWidth="1.6" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />}
    </svg>
  );
}

export const series = (samples: Sample[], pick: (s: Sample) => number) => samples.map(pick);
