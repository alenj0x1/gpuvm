import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconActivity, IconArrowsVertical, IconCat, IconCopy, IconDice5, IconX, IconLetterCase, IconPalette, IconPhotoPlus, IconRotate2, IconRotateClockwise2, IconSticker, IconTrash, IconTypography, IconZoomIn, IconZoomOut,
} from "@tabler/icons-react";
import { DND, type CubeEdit } from "./MachineCube";
import { FIGURES, figureName } from "./decor/figures";
import { drawFigureThumb } from "./decor/figureGL";
import { STICKERS, addCustomSticker, customStickers, removeCustomSticker, stickerImage, stickerName } from "./decor/stickers";
import { LED_COLORS, MACHINE_COLORS, newId, onDecorChange, useSource, type Decor, type DecorSource, type Face, type LedColor } from "./decor/store";
import { randomDecor } from "./decor/random";
import { ACCENTS, usePrefs } from "./prefs";
import { Segmented, Slider } from "./ui";

/** The color the decoration is drawn with right now: the machine's own or the accent. */
function useDecorColor(decor: Decor) {
  const prefs = usePrefs();
  const light = document.documentElement.dataset.theme === "light";
  const own = MACHINE_COLORS.find((c) => c.id === decor.color);
  const accent = ACCENTS.find((a) => a.id === prefs.accent) ?? ACCENTS[0];
  return own ? (light ? own.light : own.dark) : light ? accent.light : accent.dark;
}

// Where a sticker or figure added with a click goes: the first free spot, so they don't pile up.
const STICKER_SPOTS: [number, number][] = [[-0.45, 0.45], [0.45, 0.45], [-0.45, -0.1], [0.45, -0.1], [0, 0.72], [0, 0.18]];
const FIGURE_SPOTS: [number, number][] = [[0.42, -0.3], [-0.42, -0.3], [0.42, 0.42], [-0.42, 0.42], [0, 0.05]];
const free = <T,>(spots: [number, number][], taken: T[], at: (t: T) => [number, number]) =>
  spots.find(([a, b]) => taken.every((t) => { const [x, y] = at(t); return Math.hypot(x - a, y - b) > 0.35; })) ?? spots[Math.floor(Math.random() * spots.length)];

/** The selection and right-click menu shared by the cube and the panel. */
export function useDecorEdit(source: DecorSource) {
  const [selected, setSelected] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ id: string; x: number; y: number } | null>(null);
  // Each "Decorar al azar" turns the cube once, as Home's showcase does.
  const [spins, setSpins] = useState(0);
  useEffect(() => { setSelected(null); setMenu(null); }, [source]);
  const edit: CubeEdit = { selected, onSelect: setSelected, onMenu: (id, x, y) => setMenu({ id, x, y }), write: source.set };
  const ops = useMemo(() => {
    const change = (f: (d: Decor) => Decor) => source.set(f(source.get()));
    return { ...decorOps(change, setSelected), randomize: () => { source.set(randomDecor()); setSelected(null); setSpins((n) => n + 1); } };
  }, [source]);

  // Delete removes what is picked, Escape lets it go (not while typing).
  useEffect(() => {
    if (!selected) return;
    const key = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.closest("input, textarea, [contenteditable]")) return;
      if (e.key === "Delete" || e.key === "Backspace") { ops.remove(selected); e.preventDefault(); }
      else if (e.key === "Escape") setSelected(null);
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [selected, ops]);

  const menuRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!menu) return;
    const close = (e: PointerEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(null); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(null); };
    window.addEventListener("pointerdown", close, true);
    window.addEventListener("keydown", key);
    return () => { window.removeEventListener("pointerdown", close, true); window.removeEventListener("keydown", key); };
  }, [menu]);
  const act = (f: () => void) => () => { f(); setMenu(null); };
  const menuNode = menu && createPortal(
    <div ref={menuRef} className="menu floating decor-menu" role="menu"
      style={{ left: Math.min(menu.x, window.innerWidth - 228), top: Math.min(menu.y, window.innerHeight - 260) }}>
      <button role="menuitem" onClick={act(() => ops.turn(menu.id, -15))}><IconRotate2 size={16} />Girar a la izquierda</button>
      <button role="menuitem" onClick={act(() => ops.turn(menu.id, 15))}><IconRotateClockwise2 size={16} />Girar a la derecha</button>
      <button role="menuitem" onClick={act(() => ops.grow(menu.id, 1.15))}><IconZoomIn size={16} />Más grande</button>
      <button role="menuitem" onClick={act(() => ops.grow(menu.id, 1 / 1.15))}><IconZoomOut size={16} />Más pequeño</button>
      <button role="menuitem" onClick={act(() => ops.duplicate(menu.id))}><IconCopy size={16} />Duplicar</button>
      <hr />
      <button role="menuitem" className="danger" onClick={act(() => ops.remove(menu.id))}><IconTrash size={16} />Quitar</button>
    </div>,
    document.body,
  );
  return { source, edit, ops, selected, setSelected, spins, menu: menuNode, openMenu: (id: string, x: number, y: number) => setMenu({ id, x, y }) };
}

const STICKER_MIN = 0.28, STICKER_MAX = 1.4, FIGURE_MIN = 0.5, FIGURE_MAX = 1.8;
/** How big a sticker is placed (cube units; a face is 2): its 100 %. */
export const STICKER_SIZE = 0.7;

function decorOps(change: (f: (d: Decor) => Decor) => void, select: (id: string | null) => void) {
  const both = (id: string, st: (s: Decor["stickers"][number]) => Decor["stickers"][number], fg: (f: Decor["figures"][number]) => Decor["figures"][number]) =>
    change((d) => ({ ...d, stickers: d.stickers.map((s) => (s.id === id ? st(s) : s)), figures: d.figures.map((f) => (f.id === id ? fg(f) : f)) }));
  const clampSize = (v: number, a: number, b: number) => Math.round(Math.min(b, Math.max(a, v)) * 100) / 100;
  return {
    addSticker(sticker: string) {
      const id = newId();
      change((d) => {
        const face: Face = "front";
        const [u, v] = free(STICKER_SPOTS, d.stickers.filter((s) => s.face === face), (s) => [s.u, s.v]);
        return { ...d, stickers: [...d.stickers, { id, sticker, face, u, v, rot: 0, size: STICKER_SIZE }] };
      });
      select(id);
    },
    addFigure(figure: string) {
      const id = newId();
      change((d) => {
        const [x, z] = free(FIGURE_SPOTS, d.figures, (f) => [f.x, f.z]);
        return { ...d, figures: [...d.figures, { id, figure, x, z, rot: 0, size: 1 }] };
      });
      select(id);
    },
    turn: (id: string, deg: number) => both(id, (s) => ({ ...s, rot: (s.rot + deg + 360) % 360 }), (f) => ({ ...f, rot: (f.rot + deg + 360) % 360 })),
    grow: (id: string, k: number) => both(id,
      (s) => { const size = clampSize(s.size * k, STICKER_MIN, STICKER_MAX), m = 1 - size / 2; return { ...s, size, u: Math.max(-m, Math.min(m, s.u)), v: Math.max(-m, Math.min(m, s.v)) }; },
      (f) => ({ ...f, size: clampSize(f.size * k, FIGURE_MIN, FIGURE_MAX) })),
    set: (id: string, rot: number, size: number) => both(id,
      (s) => { const m = 1 - size / 2; return { ...s, rot, size, u: Math.max(-m, Math.min(m, s.u)), v: Math.max(-m, Math.min(m, s.v)) }; },
      (f) => ({ ...f, rot, size })),
    duplicate(id: string) {
      const nid = newId();
      change((d) => {
        const s = d.stickers.find((t) => t.id === id), f = d.figures.find((t) => t.id === id);
        if (s) { const m = 1 - s.size / 2; return { ...d, stickers: [...d.stickers, { ...s, id: nid, u: Math.min(m, s.u + 0.2), v: Math.max(-m, s.v - 0.2) }] }; }
        if (f) return { ...d, figures: [...d.figures, { ...f, id: nid, x: Math.min(0.85, f.x + 0.3) }] };
        return d;
      });
      select(nid);
    },
    remove(id: string) {
      change((d) => ({ ...d, stickers: d.stickers.filter((s) => s.id !== id), figures: d.figures.filter((f) => f.id !== id) }));
      select(null);
    },
  };
}

/** Half as it looks in light, half in dark, split by a wavy diagonal, like the accent swatches in Ajustes. */
function Swatch({ light, dark, on, title, onClick }: { light: string; dark: string; on: boolean; title: string; onClick: () => void }) {
  return (
    <button type="button" role="radio" aria-checked={on} title={title} aria-label={title} className={`swatch${on ? " on" : ""}`} onClick={onClick}>
      <svg viewBox="0 0 32 32" aria-hidden="true">
        <rect width="32" height="32" fill={dark} />
        <path d="M0 0H32C28 4 25 3 22 7S16 12 12 15 6 21 3 25 0 30 0 32Z" fill={light} />
      </svg>
    </button>
  );
}

function StickerThumb({ id, color, small }: { id: string; color: string; small?: boolean }) {
  const [, tick] = useState(0);
  useEffect(() => onDecorChange(() => tick((n) => n + 1)), []);
  const img = stickerImage(id, color);
  const src = useMemo(() => img?.toDataURL() ?? "", [img]);
  const size = small ? { width: 24, height: 24 } : undefined;
  return src ? <img className="decor-thumb" style={size} src={src} alt="" draggable={false} /> : <span className="decor-thumb" style={size} />;
}

/** The figure turning slowly while the pointer is over its tile. */
function FigureThumb({ id, color, spin, size = 64 }: { id: string; color: string; spin: boolean; size?: number }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const yaw = useRef(0.6);
  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const dpr = window.devicePixelRatio || 1;
    cv.width = size * dpr; cv.height = size * dpr;
    const g = cv.getContext("2d")!;
    let frame = 0, last = performance.now();
    const draw = (now: number) => {
      yaw.current += spin ? ((now - last) / 1000) * 1.4 : 0;
      last = now;
      g.setTransform(1, 0, 0, 1, 0, 0);
      g.clearRect(0, 0, cv.width, cv.height);
      drawFigureThumb(g, id, size, yaw.current, color, dpr);
      if (spin) frame = requestAnimationFrame(draw);
    };
    draw(last);
    return () => cancelAnimationFrame(frame);
  }, [id, color, spin, size]);
  return <canvas ref={ref} className="decor-thumb" style={{ width: size, height: size }} />;
}

function Tile({ kind, id, label, onAdd, onContext, children }: {
  kind: "sticker" | "figure"; id: string; label: string; onAdd: () => void; onContext?: (e: React.MouseEvent) => void; children: React.ReactNode;
}) {
  return (
    <button type="button" className="app-tile decor-tile" title={`${label}. Arrástralo al cubo o haz clic para ponerlo`} draggable
      onDragStart={(e) => { e.dataTransfer.setData(DND, `${kind}|${id}`); e.dataTransfer.effectAllowed = "copy"; }}
      onClick={onAdd} onContextMenu={onContext}>
      {children}
      <span className="app-tile-name">{label}</span>
    </button>
  );
}

/** The Personalizar section: the machine's color, its LED sign, stickers for the glass and figures for its top.
 *  The cube beside it is where they are placed: dragged in, moved, turned and taken off. */
/** What is already on the machine, as chips: a click picks it on the cube, the cross takes it off, a right click
 *  opens the same menu as on the cube. */
function Placed({ items, selected, onPick, onRemove, onMenu }: {
  items: { id: string; label: string; thumb: React.ReactNode }[]; selected: string | null;
  onPick: (id: string) => void; onRemove: (id: string) => void; onMenu: (id: string, x: number, y: number) => void;
}) {
  if (!items.length) return null;
  return (
    <div className="decor-placed">
      {items.map((it) => (
        <div key={it.id} className={`decor-chip${selected === it.id ? " on" : ""}`} onContextMenu={(e) => { e.preventDefault(); onPick(it.id); onMenu(it.id, e.clientX, e.clientY); }}>
          <button type="button" className="decor-chip-main" onClick={() => onPick(it.id)}>{it.thumb}<span>{it.label}</span></button>
          <button type="button" className="decor-chip-x" title="Quitar" aria-label={`Quitar ${it.label}`} onClick={() => onRemove(it.id)}><IconX size={13} /></button>
        </div>
      ))}
    </div>
  );
}

export function Customize({ source, ops, selected, setSelected, openMenu, bare }: Pick<ReturnType<typeof useDecorEdit>, "source" | "ops" | "selected" | "setSelected" | "openMenu"> & {
  /** Without its own card (inside Crear máquina, which already frames each section). */
  bare?: boolean;
}) {
  const decor = useSource(source);
  const name = source.name;
  const prefs = usePrefs();
  const color = useDecorColor(decor);
  const [hover, setHover] = useState<string | null>(null);
  const [error, setError] = useState("");
  const [customs, setCustoms] = useState(customStickers);
  useEffect(() => onDecorChange(() => setCustoms(customStickers())), []);
  const fileRef = useRef<HTMLInputElement>(null);
  const save = (d: Partial<Decor>) => source.set({ ...source.get(), ...d });
  const accent = ACCENTS.find((a) => a.id === prefs.accent) ?? ACCENTS[0];
  const led = decor.led;
  const picked = decor.stickers.find((s) => s.id === selected) ?? decor.figures.find((f) => f.id === selected);
  const pickedSticker = decor.stickers.find((s) => s.id === selected);
  const pickedName = pickedSticker ? stickerName(pickedSticker.sticker) : picked && "figure" in picked ? figureName(picked.figure) : "";

  const upload = async (file: File | undefined) => {
    if (!file) return;
    setError("");
    try { ops.addSticker(await addCustomSticker(file)); } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  };

  return (
    <div className={bare ? "customize" : "card customize"}>
      <div className="opt-rows">
        <div className="opt-row">
          <span className="opt-icon"><IconDice5 size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">Al azar</span>
            <span className="opt-desc">Color, letrero, stickers y figuras elegidos al azar. Puedes seguir cambiando lo que quieras.</span>
          </div>
          <div className="opt-ctl">
            <button type="button" className="btn" onClick={ops.randomize}><IconDice5 size={16} />Decorar al azar</button>
          </div>
        </div>
        <div className="opt-row">
          <span className="opt-icon"><IconPalette size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">Color</span>
            <span className="opt-desc">El holograma, los rayos y el ícono de la máquina. Sin elegir, usa el color de énfasis.</span>
          </div>
          <div className="opt-ctl">
            <div className="swatches" role="radiogroup" aria-label="Color de la máquina">
              <Swatch light={accent.light} dark={accent.dark} on={!decor.color} title="Color de énfasis" onClick={() => save({ color: null })} />
              {MACHINE_COLORS.map((c) => <Swatch key={c.id} light={c.light} dark={c.dark} on={decor.color === c.id} title={c.name} onClick={() => save({ color: c.id })} />)}
            </div>
          </div>
        </div>

        <div className="opt-row section">
          <span className="opt-icon"><IconTypography size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">Letrero LED</span>
            <span className="opt-desc">Un texto que corre alrededor del vidrio.</span>
          </div>
          <div className="opt-ctl">
            <Segmented value={!!led} options={[{ value: false, label: "Apagado" }, { value: true, label: "Encendido" }]}
              onChange={(on) => save({ led: on ? { text: "", color: "amber", live: false } : null })} />
          </div>
        </div>
        {led && (
          <>
            <div className="opt-row sub">
              <span className="opt-icon"><IconLetterCase size={17} /></span>
              <div className="opt-text"><span className="opt-title">Texto</span><span className="opt-desc">Sin texto, muestra el nombre de la máquina.</span></div>
              <div className="opt-ctl">
                <input className="text-input" value={led.text} maxLength={60} placeholder={(name || "GpuVM").toUpperCase()} aria-label="Texto del letrero"
                  onChange={(e) => save({ led: { ...led, text: e.target.value } })} />
              </div>
            </div>
            <div className="opt-row sub">
              <span className="opt-icon"><IconPalette size={17} /></span>
              <div className="opt-text"><span className="opt-title">Color del letrero</span><span className="opt-desc">Como las luces de un letrero de la calle, o el color de la máquina.</span></div>
              <div className="opt-ctl">
                <div className="swatches" role="radiogroup" aria-label="Color del letrero">
                  {LED_COLORS.map((c) => {
                    const hex = c.id === "machine" ? color : c.hex;
                    return (
                      <button type="button" key={c.id} role="radio" aria-checked={led.color === c.id} title={c.name} aria-label={c.name}
                        className={`swatch led-swatch${led.color === c.id ? " on" : ""}`} onClick={() => save({ led: { ...led, color: c.id as LedColor } })}>
                        <svg viewBox="0 0 32 32" aria-hidden="true">
                          <rect width="32" height="32" fill="#2c2c2c" />
                          {[9, 16, 23].flatMap((x) => [9, 16, 23].map((y) => <circle key={`${x}-${y}`} cx={x} cy={y} r="2.6" fill={hex} opacity={(x + y) % 14 === 4 ? 0.3 : 1} />))}
                        </svg>
                      </button>
                    );
                  })}
                </div>
              </div>
            </div>
            <div className="opt-row sub">
              <span className="opt-icon"><IconArrowsVertical size={17} /></span>
              <div className="opt-text"><span className="opt-title">Altura</span><span className="opt-desc">También se sube o se baja arrastrándolo en el cubo.</span></div>
              <div className="opt-ctl">
                <Slider label="Altura" value={Math.round((led.y ?? 0) * 100)} min={0} max={100} step={5} marks={[0, 50, 100]}
                  format={(v) => (v === 0 ? "Abajo" : v === 100 ? "Arriba" : `${v} %`)} onChange={(v) => save({ led: { ...led, y: v / 100 } })} />
              </div>
            </div>
            <div className="opt-row sub">
              <span className="opt-icon"><IconActivity size={17} /></span>
              <div className="opt-text"><span className="opt-title">Uso en vivo</span><span className="opt-desc">Agrega el uso de la GPU y del procesador mientras está encendida.</span></div>
              <div className="opt-ctl">
                <Segmented value={led.live} options={[{ value: false, label: "Solo el texto" }, { value: true, label: "Con el uso" }]}
                  onChange={(live) => save({ led: { ...led, live } })} />
              </div>
            </div>
          </>
        )}

        <div className="opt-row wide">
          <span className="opt-icon"><IconSticker size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">Stickers</span>
            <span className="opt-desc">Arrástralos a cualquier cara del vidrio. Clic derecho en el cubo para girarlos o quitarlos.</span>
          </div>
          <div className="opt-below">
            <Placed selected={selected} onPick={setSelected} onRemove={ops.remove} onMenu={openMenu}
              items={decor.stickers.map((st) => ({ id: st.id, label: stickerName(st.sticker), thumb: <StickerThumb id={st.sticker} color={color} small /> }))} />
            <div className="app-tiles decor-tiles">
              {STICKERS.map((s) => (
                <Tile key={s.id} kind="sticker" id={s.id} label={s.name} onAdd={() => ops.addSticker(s.id)}><StickerThumb id={s.id} color={color} /></Tile>
              ))}
              {customs.map((c) => (
                <span key={c} className="decor-tile-custom">
                  <Tile kind="sticker" id={`custom:${c}`} label="Tu imagen" onAdd={() => ops.addSticker(`custom:${c}`)}>
                    <StickerThumb id={`custom:${c}`} color={color} />
                  </Tile>
                  <button type="button" className="decor-tile-x" title="Quitar de tus stickers" aria-label="Quitar de tus stickers" onClick={() => removeCustomSticker(c)}><IconX size={13} /></button>
                </span>
              ))}
              <button type="button" className="app-tile decor-tile decor-add" onClick={() => fileRef.current?.click()}>
                <span className="decor-thumb decor-add-icon"><IconPhotoPlus size={22} /></span>
                <span className="app-tile-name">Subir imagen</span>
              </button>
              <input ref={fileRef} type="file" accept="image/png,image/webp,image/jpeg,image/gif" hidden
                onChange={(e) => { upload(e.target.files?.[0]); e.target.value = ""; }} />
            </div>
            {error && <span className="error-text">{error}</span>}
          </div>
        </div>

        <div className="opt-row wide">
          <span className="opt-icon"><IconCat size={17} /></span>
          <div className="opt-text">
            <span className="opt-title">Figuras</span>
            <span className="opt-desc">Se paran sobre el cubo. Arrástralas para moverlas.</span>
          </div>
          <div className="opt-below">
            <Placed selected={selected} onPick={setSelected} onRemove={ops.remove} onMenu={openMenu}
              items={decor.figures.map((f) => ({ id: f.id, label: figureName(f.figure), thumb: <FigureThumb id={f.figure} color={color} spin={false} size={24} /> }))} />
            <div className="app-tiles decor-tiles">
              {FIGURES.map((f) => (
                <span key={f.id} onPointerEnter={() => setHover(f.id)} onPointerLeave={() => setHover(null)} className="decor-tile-wrap">
                  <Tile kind="figure" id={f.id} label={f.name} onAdd={() => ops.addFigure(f.id)}><FigureThumb id={f.id} color={color} spin={hover === f.id} /></Tile>
                </span>
              ))}
            </div>
          </div>
        </div>

        {picked && (
          <div className="opt-row decor-picked">
            <span className="opt-icon">{pickedSticker ? <IconSticker size={17} /> : <IconCat size={17} />}</span>
            <div className="opt-text">
              <span className="opt-title">{pickedName}</span>
              <span className="opt-desc">{pickedSticker ? "En el vidrio." : "Sobre el cubo."} Suprimir lo quita.</span>
            </div>
            <div className="opt-ctl decor-picked-ctl">
              {/* Size in percent of how it is first placed (a sticker starts at half a face). */}
              <div className="field">
                <div className="field-top"><span>Tamaño</span><strong>{Math.round(picked.size * (pickedSticker ? 100 / STICKER_SIZE : 100))} %</strong></div>
                <Slider label="Tamaño" value={Math.round(picked.size * (pickedSticker ? 100 / STICKER_SIZE : 100))} step={5}
                  min={Math.round((pickedSticker ? STICKER_MIN / STICKER_SIZE : FIGURE_MIN) * 100)} max={Math.round((pickedSticker ? STICKER_MAX / STICKER_SIZE : FIGURE_MAX) * 100)}
                  marks={pickedSticker ? [40, 100, 150, 200] : [50, 100, 150, 180]}
                  format={(v) => `${v} %`} onChange={(v) => ops.set(picked.id, picked.rot, v / 100 * (pickedSticker ? STICKER_SIZE : 1))} />
              </div>
              <div className="field">
                <div className="field-top"><span>Giro</span><strong>{Math.round(picked.rot > 180 ? picked.rot - 360 : picked.rot)}°</strong></div>
                <Slider label="Giro" value={Math.round(picked.rot > 180 ? picked.rot - 360 : picked.rot)} min={-180} max={180} step={5} marks={[-180, -90, 0, 90, 180]}
                  format={(v) => `${v}°`} onChange={(v) => ops.set(picked.id, (v + 360) % 360, picked.size)} />
              </div>
              <div className="decor-picked-actions">
                <button className="btn" onClick={() => ops.duplicate(picked.id)}><IconCopy size={16} />Duplicar</button>
                <button className="btn" onClick={() => ops.remove(picked.id)}><IconTrash size={16} />Quitar</button>
                <button className="btn ghost" onClick={() => setSelected(null)}>Listo</button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
