/** Home while its data loads: a constellation. The cube in the center and the machines around it draw themselves in
 *  fine lines and float, until Home arrives and takes their place. Drawn with CSS on SVG (no canvas, no per-frame
 *  work in JS). */
export function HomeLoading({ names = [] }: { names?: string[] }) {
  const shown = names.slice(0, 8);
  const count = shown.length || 5;
  const ring = Array.from({ length: count }, (_, i) => {
    const a = -Math.PI / 2 + (i / count) * Math.PI * 2 + 0.35;
    return { x: 400 + Math.cos(a) * 300, y: 250 + Math.sin(a) * 175, name: shown[i] ?? "" };
  });
  return (
    <div className="main home home-loading" aria-busy="true">
      <svg viewBox="0 0 800 500" preserveAspectRatio="xMidYMid meet" role="presentation">
        <defs>
          <g id="home-loading-cube">
            <path d="M0 -14 L14 -7 L0 0 L-14 -7 Z M-14 -7 L-14 9 L0 16 L0 0 M14 -7 L14 9 L0 16" />
          </g>
        </defs>
        <ellipse className="home-loading-orbit" cx={400} cy={250} rx={300} ry={175} />
        {ring.map((p, i) => (
          <line key={`l${i}`} className="home-loading-link" x1={400} y1={250} x2={p.x} y2={p.y} style={{ animationDelay: `${0.25 + i * 0.12}s` }} />
        ))}
        <g className="home-loading-core" transform="translate(400 250) scale(5)">
          <use href="#home-loading-cube" />
          <rect x={-2.2} y={-1.6} width={4.4} height={4.4} rx={1} transform="matrix(1 .5 -1 .5 0 -7)" />
        </g>
        {ring.map((p, i) => (
          <g key={i} className="home-loading-machine" style={{ animationDelay: `${i * 0.5}s` }}>
            <g transform={`translate(${p.x} ${p.y}) scale(2)`}>
              <use href="#home-loading-cube" style={{ animationDelay: `${0.3 + i * 0.12}s` }} />
            </g>
            {p.name && <text x={p.x} y={p.y + 52} textAnchor="middle">{p.name}</text>}
          </g>
        ))}
      </svg>
    </div>
  );
}
