import { useEffect, useRef, useState } from "react";
import { IconDeviceGamepad2, IconHeart, IconPlayerPause, IconPlayerPlay, IconRefresh, IconTrophy, IconX } from "@tabler/icons-react";
import { GAMES, bestScore, saveBest, type GameDef, type GameHud, type GameInstance, type GameMachine } from "./games";
import { IconArrowLeft, IconBolt, IconUser, IconUsersGroup } from "@tabler/icons-react";
import { ambientInfo } from "./ambient";
import type { Control } from "./games/types";
import { colorOfDecor, readDecor, useDecor, type Decor } from "./decor/store";
import { MachineIcon } from "./machineIcon";

type Phase = "ready" | "playing" | "paused" | "over";

/** A machine as the games draw it: its color and the figures it carries. */
function asPlayer(name: string, decor: Decor, light: boolean, accent: string): GameMachine {
  return { name, color: colorOfDecor(decor, light) ?? accent, figures: decor.figures.map((f) => f.figure) };
}

/** A game running in the space: the canvas, its score and lives, and the start, pause and game-over cards. On the
 *  start card the player picks the machine to play with and, if the game has them, a mode. */
function GameStage({ game, machines, first, fallback, world, onClose }: {
  game: GameDef; machines: string[]; first?: string; fallback: Decor; world?: string; onClose: () => void;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const inst = useRef<GameInstance | null>(null);
  const [phase, setPhase] = useState<Phase>("ready");
  const [hud, setHud] = useState<GameHud>({ score: 0, lives: 3 });
  const [player, setPlayer] = useState(() => first ?? machines[0] ?? "");
  // A game whose modes are worlds starts in the space's own world.
  const [mode, setMode] = useState(game.modes?.find((m) => m.id === world)?.id ?? game.modes?.[0]?.id ?? "");
  const modeInfo = game.modes?.find((m) => m.id === mode);
  const recordKey = mode ? `${game.id}.${mode}` : game.id;
  const [best, setBest] = useState(() => bestScore(recordKey));
  useEffect(() => setBest(bestScore(recordKey)), [recordKey]);
  const [record, setRecord] = useState(false);
  const [final, setFinal] = useState(0);
  const teamReady = machines.length > 1;

  useEffect(() => () => { inst.current?.stop(); inst.current = null; }, []);

  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if (e.key !== "Escape" && e.key.toLowerCase() !== "p") return;
      if (phase === "playing") { inst.current?.pause(); setPhase("paused"); }
      else if (phase === "paused" && e.key.toLowerCase() === "p") { inst.current?.resume(); setPhase("playing"); }
      else if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [phase, onClose]);
  // Leaving the window pauses the game; coming back waits for the player.
  useEffect(() => {
    const hide = () => { if (document.hidden && phase === "playing") { inst.current?.pause(); setPhase("paused"); } };
    document.addEventListener("visibilitychange", hide);
    return () => document.removeEventListener("visibilitychange", hide);
  }, [phase]);

  // Each round starts a fresh game with the chosen machine (and, in a team mode, the others beside it).
  const play = () => {
    const cv = ref.current;
    if (!cv) return;
    inst.current?.stop();
    const light = document.documentElement.dataset.theme === "light";
    const accent = getComputedStyle(cv).getPropertyValue("--accent").trim() || "#7d9cf0";
    const me = player ? asPlayer(player, readDecor(player), light, accent) : asPlayer("", fallback, light, accent);
    const team = modeInfo?.team ? machines.filter((n) => n !== player).slice(0, 3).map((n) => asPlayer(n, readDecor(n), light, accent)) : [];
    inst.current = game.create(cv, {
      player: me, team, mode, light, color: me.color, figures: me.figures, world,
      onHud: setHud,
      onOver: (score) => { setFinal(score); setRecord(saveBest(recordKey, score)); setBest(bestScore(recordKey)); setPhase("over"); },
    });
    setRecord(false);
    inst.current.start();
    setPhase("playing");
    cv.focus();
  };

  return (
    <div className="game-stage">
      <canvas ref={ref} className={`game-canvas${phase === "playing" ? " live" : ""}`} tabIndex={-1} />
      {phase !== "ready" && (
        <div className="game-hud">
          <span className="game-score">{hud.score.toLocaleString("es")}</span>
          <span className="game-lives" aria-label={`${hud.lives} vidas`}>
            {Array.from({ length: Math.max(0, hud.lives) }, (_, i) => <IconHeart key={i} size={15} />)}
          </span>
          {hud.meter !== undefined && (
            <span className={`game-meter${hud.frenzy ? " on" : ""}`} title="Frenesí"><span style={{ width: `${Math.round(hud.meter * 100)}%` }} /></span>
          )}
          {hud.power && <span className="game-power">{hud.power}</span>}
          {hud.ability && (
            <span className={`game-ability${hud.ability.charge >= 1 && hud.ability.active === undefined ? " ready" : ""}${hud.ability.active !== undefined ? " on" : ""}`}
              title={hud.ability.charge >= 1 ? "Clic derecho o E para usarla" : "Se carga al disparar y derribar"}>
              <IconBolt size={13} />{hud.ability.name}
              <span className="game-ability-bar"><span style={{ width: `${Math.round((hud.ability.active ?? hud.ability.charge) * 100)}%` }} /></span>
            </span>
          )}
          <span className="grow" />
          {phase === "playing" && <button type="button" className="icon-btn" title="Pausa" aria-label="Pausa" onClick={() => { inst.current?.pause(); setPhase("paused"); }}><IconPlayerPause size={16} /></button>}
          <button type="button" className="icon-btn" title="Salir" aria-label="Salir del juego" onClick={onClose}><IconX size={16} /></button>
        </div>
      )}
      {phase === "ready" && (
        <div className="game-start">
          {/* The game itself, playing on its own with the machine and the mode picked beside it. */}
          <div className="game-start-preview">
            <GameDemo game={game} player={player} fallback={fallback} world={world} mode={mode}
              team={modeInfo?.team ? machines.filter((n) => n !== player).slice(0, 3) : []} />
            {best > 0 && <span className="game-start-record"><IconTrophy size={14} />Récord {best.toLocaleString("es")}</span>}
          </div>
          <div className="game-start-side">
            <div className="game-start-head">
              <strong>{game.name}</strong>
              <span>{game.description}</span>
            </div>
            {machines.length > 1 && (
              <div className="game-start-group">
                <span className="game-start-label">Máquina</span>
                <div className="game-start-list" role="radiogroup" aria-label="Máquina con la que juegas">
                  {machines.map((n) => (
                    <button key={n} type="button" role="radio" aria-checked={n === player} className={`game-start-option${n === player ? " on" : ""}`} onClick={() => setPlayer(n)}>
                      <MachineIcon name={n} size={28} radius={8} />
                      <span className="grow"><span className="title">{n}</span></span>
                    </button>
                  ))}
                </div>
              </div>
            )}
            {game.modes && game.modes.length > 1 && (
              <div className="game-start-group">
                <span className="game-start-label">{game.modes.some((m) => m.team) ? "Modo" : "Mundo"}</span>
                <div className="game-start-list" role="radiogroup" aria-label="Modo">
                  {game.modes.map((m) => {
                    const off = !!m.team && !teamReady;
                    const Icon = m.id === "solo" ? IconUser : m.team ? IconUsersGroup : ambientInfo(m.id).icon;
                    return (
                      <button key={m.id} type="button" role="radio" aria-checked={m.id === mode} disabled={off} className={`game-start-option${m.id === mode ? " on" : ""}`} onClick={() => setMode(m.id)}>
                        <span className="game-start-option-icon"><Icon size={16} /></span>
                        <span className="grow"><span className="title">{m.name}</span><span className="desc">{off ? "Necesitas al menos dos máquinas." : m.description}</span></span>
                      </button>
                    );
                  })}
                </div>
              </div>
            )}
            <div className="game-start-group">
              <span className="game-start-label">Controles</span>
              <div className="game-controls">
                {game.controls.map((c) => <ControlRow key={c.label} c={c} />)}
              </div>
            </div>
            {game.tips && <ul className="game-tips">{game.tips.map((t) => <li key={t}>{t}</li>)}</ul>}
            <div className="game-start-actions">
              <button type="button" className="btn ghost" onClick={onClose}><IconArrowLeft size={16} />Atrás</button>
              <button type="button" className="primary" disabled={!!modeInfo?.team && !teamReady} onClick={play}><IconPlayerPlay size={16} />Jugar</button>
            </div>
          </div>
        </div>
      )}
      {phase === "paused" && (
        <div className="game-card">
          <strong>En pausa</strong>
          <span className="game-card-desc">{hud.score.toLocaleString("es")} puntos</span>
          <div className="game-card-actions">
            <button type="button" className="btn ghost" onClick={onClose}>Salir</button>
            <button type="button" className="primary compact" onClick={() => { inst.current?.resume(); setPhase("playing"); }}><IconPlayerPlay size={16} />Seguir</button>
          </div>
        </div>
      )}
      {phase === "over" && (
        <div className="game-card">
          <span className="game-card-icon"><IconTrophy size={22} /></span>
          <strong>{record ? "Nuevo récord" : "Fin del juego"}</strong>
          <span className="game-final">{final.toLocaleString("es")}</span>
          <span className="game-card-desc">{record ? "Superaste tu mejor marca." : `Récord ${best.toLocaleString("es")}`}</span>
          <div className="game-card-actions">
            <button type="button" className="btn ghost" onClick={() => setPhase("ready")}>Cambiar máquina</button>
            <button type="button" className="primary compact" onClick={play}><IconRefresh size={16} />Otra vez</button>
          </div>
        </div>
      )}
    </div>
  );
}

/** The space of machines with its games: a Jugar button over it (on hover), and the game in its place while played.
 *  The cube stops drawing while a game runs. */
export function SpaceWithGames({ decor: shown, decorOf, machines = [], world, children }: {
  /** The decoration to play with when there are no machines (Home's showcase). */
  decor?: Decor;
  /** The machine in front, picked first on the start card. */
  decorOf?: string;
  machines?: string[];
  /** The space's world: games start in it. */
  world?: string;
  children: React.ReactNode;
}) {
  const own = useDecor(decorOf ?? "");
  const fallback = shown ?? own;
  const [game, setGame] = useState<GameDef | null>(null);
  const [gallery, setGallery] = useState(false);
  if (game) return <GameStage game={game} machines={machines} first={decorOf} fallback={fallback} world={world} onClose={() => { setGame(null); setGallery(true); }} />;
  // The gallery takes the place of the space while it is open: the cube stops drawing, so the games on the cards run
  // smoothly.
  if (gallery) return <GameGallery player={decorOf} fallback={fallback} world={world} onPick={(gd) => { setGallery(false); setGame(gd); }} onClose={() => setGallery(false)} />;
  return (
    <>
      {children}
      <div className="space-games">
        <button type="button" className="btn space-play" onClick={() => setGallery(true)}><IconDeviceGamepad2 size={16} />Jugar</button>
      </div>
    </>
  );
}

/** One game playing by itself on its card: the real game, in a demo, with the machine in front. */
function GameDemo({ game, player, fallback, world, mode: pickedMode, team = [] }: { game: GameDef; player?: string; fallback: Decor; world?: string; mode?: string; team?: string[] }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const inst = useRef<GameInstance | null>(null);
  const cast = () => {
    const cv = ref.current;
    if (!cv) return null;
    const light = document.documentElement.dataset.theme === "light";
    const accent = getComputedStyle(cv).getPropertyValue("--accent").trim() || "#7d9cf0";
    const me = player ? asPlayer(player, readDecor(player), light, accent) : asPlayer("", fallback, light, accent);
    const mode = pickedMode ?? game.modes?.find((m) => m.id === world)?.id ?? (game.modes?.some((m) => m.team) ? "solo" : game.modes?.[0]?.id ?? "");
    return { me, mates: team.map((n) => asPlayer(n, readDecor(n), light, accent)), mode, light };
  };
  // Another machine or mode: the running demo changes who plays, with the ones leaving flying off (no restart).
  const castKey = `${player}|${pickedMode}|${team.join("|")}`;
  useEffect(() => {
    const c = cast();
    if (c && inst.current?.cast) inst.current.cast({ player: c.me, team: c.mates, mode: c.mode });
  }, [castKey]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const light = document.documentElement.dataset.theme === "light";
    const accent = getComputedStyle(cv).getPropertyValue("--accent").trim() || "#7d9cf0";
    const me = player ? asPlayer(player, readDecor(player), light, accent) : asPlayer("", fallback, light, accent);
    const mode = pickedMode ?? game.modes?.find((m) => m.id === world)?.id ?? (game.modes?.some((m) => m.team) ? "solo" : game.modes?.[0]?.id ?? "");
    const mates = team.map((n) => asPlayer(n, readDecor(n), light, accent));
    const run = game.create(cv, { player: me, team: mates, mode, light, color: me.color, figures: me.figures, world, demo: true, onHud: () => {}, onOver: () => {} });
    inst.current = run;
    run.start();
    return () => { run.stop(); inst.current = null; };
  }, [game, world]); // eslint-disable-line react-hooks/exhaustive-deps
  return <canvas ref={ref} />;
}

/** The games, each on a card showing the game itself playing, with its best score. */
function GameGallery({ player, fallback, world, onPick, onClose }: { player?: string; fallback: Decor; world?: string; onPick: (g: GameDef) => void; onClose: () => void }) {
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  return (
    <div className="game-gallery">
      <div className="game-gallery-head">
        <IconDeviceGamepad2 size={18} /><strong>Juegos</strong>
        <button type="button" className="icon-btn" aria-label="Cerrar" title="Cerrar" onClick={onClose}><IconX size={16} /></button>
      </div>
      <div className="game-gallery-grid">
        {GAMES.map((gd) => {
          const best = Math.max(bestScore(gd.id), ...(gd.modes ?? []).map((m) => bestScore(`${gd.id}.${m.id}`)));
          return (
            <div key={gd.id} className="game-tile">
              <button type="button" className="game-tile-art" aria-label={`Jugar ${gd.name}`} onClick={() => onPick(gd)}>
                <GameDemo game={gd} player={player} fallback={fallback} world={world} />
              </button>
              <div className="game-tile-row">
                <div className="game-tile-text">
                  <strong>{gd.name}</strong>
                  <span>{best > 0 ? <><IconTrophy size={13} />Récord {best.toLocaleString("es")}</> : "Sin récord todavía"}</span>
                </div>
                <button type="button" className="primary compact" onClick={() => onPick(gd)}><IconPlayerPlay size={15} />Jugar</button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

/** A key as it looks on the keyboard. */
const Key = ({ k }: { k: string }) => <kbd className={`keycap${k.length > 2 ? " wide" : ""}`}>{k}</kbd>;
/** The mouse with the button that does the action in the accent (or its middle marked, to aim). */
function Mouse({ part }: { part: "left" | "right" | "move" }) {
  return (
    <svg className="mouse-glyph" width="22" height="28" viewBox="0 0 22 28" aria-hidden="true">
      <rect x="3" y="2" width="16" height="24" rx="8" fill="none" stroke="currentColor" strokeWidth="1.4" opacity=".7" />
      <path d="M11 2v9M3 11h16" stroke="currentColor" strokeWidth="1.2" opacity=".5" />
      {part === "left" && <path d="M11 2.7a7.3 7.3 0 0 0-7.3 7.3v.3H11z" fill="var(--accent)" />}
      {part === "right" && <path d="M11 2.7a7.3 7.3 0 0 1 7.3 7.3v.3H11z" fill="var(--accent)" />}
      {part === "move" && <circle cx="11" cy="18" r="2.4" fill="var(--accent)" />}
    </svg>
  );
}
/** One control: what does it (keys, a mouse button, or both) and what it is for. */
function ControlRow({ c }: { c: Control }) {
  const wasd = c.keys?.join("") === "WASD";
  return (
    <div className="game-control">
      <span className="game-control-input">
        {c.mouse && <Mouse part={c.mouse} />}
        {c.mouse && c.keys && <span className="game-control-or">o</span>}
        {wasd ? (
          <span className="keys-wasd"><span><Key k="W" /></span><span><Key k="A" /><Key k="S" /><Key k="D" /></span></span>
        ) : c.keys?.map((k, i) => <span key={k} className="keys-row">{i > 0 && <span className="game-control-or">o</span>}<Key k={k} /></span>)}
      </span>
      <span className="game-control-label">{c.label}</span>
    </div>
  );
}
