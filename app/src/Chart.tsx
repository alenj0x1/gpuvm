import type { Sample } from "./types";

const WIDTH = 600;
const HEIGHT = 120;
export const MAX_SAMPLES = 150;

function line(samples: Sample[], key: keyof Sample) {
  const step = WIDTH / (MAX_SAMPLES - 1);
  const offset = MAX_SAMPLES - samples.length;
  return samples.map((s, i) => `${((offset + i) * step).toFixed(1)},${(HEIGHT - (Math.min(100, s[key]) / 100) * (HEIGHT - 6) - 3).toFixed(1)}`).join(" ");
}

/** CPU and GPU usage over the last 5 minutes (one sample every 2 s). */
export function UsageChart({ samples }: { samples: Sample[] }) {
  return (
    <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} preserveAspectRatio="none" style={{ width: "100%", height: 120, display: "block" }} aria-hidden="true">
      {[0.25, 0.5, 0.75].map((f) => (
        <line key={f} x1="0" x2={WIDTH} y1={HEIGHT * f} y2={HEIGHT * f} stroke="var(--chart-grid)" strokeWidth="1" vectorEffect="non-scaling-stroke" />
      ))}
      {samples.length > 1 && (
        <>
          <polyline points={line(samples, "cpu")} fill="none" stroke="var(--chart-cpu)" strokeWidth="2" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
          <polyline points={line(samples, "gpu")} fill="none" stroke="var(--chart-gpu)" strokeWidth="2" vectorEffect="non-scaling-stroke" strokeLinejoin="round" />
        </>
      )}
    </svg>
  );
}
