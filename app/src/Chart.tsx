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

/** A tiny chart of the last minute for the sidebar: processor, memory and GPU as three lines in their resource
 *  colors, so a running machine shows what it is doing at a glance. `memGB` turns memory samples into a share. */
export function TripleSpark({ samples, memGB }: { samples: Sample[]; memGB: number }) {
  const W = 44, H = 18, last = samples.slice(-24);
  const line = (pick: (s: Sample) => number) => {
    const step = W / 23, offset = 24 - last.length;
    return last.map((s, i) => `${((offset + i) * step).toFixed(1)},${(H - 1.5 - (Math.min(100, Math.max(0, pick(s))) / 100) * (H - 3)).toFixed(1)}`).join(" ");
  };
  if (last.length < 2) return null;
  return (
    <svg className="triple-spark" width={W} height={H} viewBox={`0 0 ${W} ${H}`} aria-hidden="true">
      <polyline points={line((s) => s.cpu)} fill="none" stroke="var(--res-cpu)" strokeWidth="1.3" strokeLinejoin="round" />
      <polyline points={line((s) => (s.mem / Math.max(memGB, 0.1)) * 100)} fill="none" stroke="var(--res-mem)" strokeWidth="1.3" strokeLinejoin="round" />
      <polyline points={line((s) => s.gpu)} fill="none" stroke="var(--res-gpu)" strokeWidth="1.3" strokeLinejoin="round" />
    </svg>
  );
}
