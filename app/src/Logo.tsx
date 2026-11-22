/** The gpuvm mark drawn inline, so its small square follows the accent color the person chose: a machine inside
 *  another (2026-11-21, chosen by the person over the old chip with pins). Same drawing as assets/logo.svg (the source
 *  for the app and installer icons). The name beside it is written in lowercase, "gpuvm" (`.wordmark`). */
export function Logo({ size, className }: { size: number; className?: string }) {
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 64 64" aria-hidden="true">
      <rect x="4" y="4" width="56" height="56" rx="16" fill="#2a2c31" />
      <rect x="18" y="18" width="28" height="28" rx="8" fill="none" stroke="#ebe8e1" strokeWidth="4" />
      <rect x="33" y="33" width="13" height="13" rx="4" fill="var(--logo-part, var(--accent))" />
    </svg>
  );
}
