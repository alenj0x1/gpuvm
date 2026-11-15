import { useEffect, useRef, useState } from "react";
import { IconDeviceGamepad2, IconHeart, IconPlayerPause, IconPlayerPlay, IconRefresh, IconTrophy, IconX } from "@tabler/icons-react";
import { GAMES, bestScore, saveBest, type GameDef, type GameHud, type GameInstance, type GameMachine } from "./games";
import { colorOfDecor, readDecor, useDecor, type Decor } from "./decor/store";
import { MachineIcon } from "./machineIcon";
import { Segmented } from "./ui";

type Phase = "ready" | "playing" | "paused" | "over";

/** A machine as the games draw it: its color and the figures it carries. */
function asPlayer(name: string, decor: Decor, light: boolean, accent: string): GameMachine {
  return { name, color: colorOfDecor(decor, light) ?? accent, figures: decor.figures.map((f) => f.figure) };
}

/** A game running in the space: the canvas, its score and lives, and the start, pause and game-over cards. On the
 *  start card the player picks the machine to play with and, if the game has them, a mode. */
function GameStage({ game, machines, first, fallback, onClose }: {
  game: GameDef; machines: string[]; first?: string; fallback: Decor; onClose: () => void;
}) {
  const ref = useRef<HTMLCanvasElement>(null);
  const inst = useRef<GameInstance | null>(null);
  const [phase, setPhase] = useState<Phase>("ready");
  const [hud, setHud] = useState<GameHud>({ score: 0, lives: 3 });
  const [player, setPlayer] = useState(() => first ?? machines[0] ?? "");
  const [mode, setMode] = useState(game.modes?.[0]?.id ?? "");
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
      player: me, team, mode, light, color: me.color, figures: me.figures,
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
          <span className="grow" />
          {phase === "playing" && <button type="button" className="icon-btn" title="Pausa" aria-label="Pausa" onClick={() => { inst.current?.pause(); setPhase("paused"); }}><IconPlayerPause size={16} /></button>}
          <button type="button" className="icon-btn" title="Salir" aria-label="Salir del juego" onClick={onClose}><IconX size={16} /></button>
        </div>
      )}
      {phase === "ready" && (
        <div className="game-card wide">
          <span className="game-card-icon"><IconDeviceGamepad2 size={22} /></span>
          <strong>{game.name}</strong>
          <span className="game-card-desc">{game.description}</span>
          {machines.length > 0 && (
            <div className="game-pick" role="radiogroup" aria-label="Máquina con la que juegas">
              {machines.map((n) => (
                <button key={n} type="button" role="radio" aria-checked={n === player} className={`game-pick-item${n === player ? " on" : ""}`} onClick={() => setPlayer(n)}>
                  <MachineIcon name={n} size={22} radius={6} /><span>{n}</span>
                </button>
              ))}
            </div>
          )}
          {game.modes && game.modes.length > 1 && (
            <>
              <Segmented value={mode} options={game.modes.map((m) => ({ value: m.id, label: m.name }))}
                onChange={(m) => setMode(m)} />
              <span className="game-card-desc">
                {modeInfo?.team && !teamReady ? "Necesitas al menos dos máquinas para jugar en equipo." : modeInfo?.description}
              </span>
            </>
          )}
          <ul>{game.controls.map((c) => <li key={c}>{c}</li>)}</ul>
          {best > 0 && <span className="game-best"><IconTrophy size={14} />Récord {best.toLocaleString("es")}</span>}
          <div className="game-card-actions">
            <button type="button" className="btn ghost" onClick={onClose}>Salir</button>
            <button type="button" className="primary compact" disabled={!!modeInfo?.team && !teamReady} onClick={play}><IconPlayerPlay size={16} />Jugar</button>
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
export function SpaceWithGames({ decor: shown, decorOf, machines = [], children }: {
  /** The decoration to play with when there are no machines (Home's showcase). */
  decor?: Decor;
  /** The machine in front, picked first on the start card. */
  decorOf?: string;
  machines?: string[];
  children: React.ReactNode;
}) {
  const own = useDecor(decorOf ?? "");
  const fallback = shown ?? own;
  const [game, setGame] = useState<GameDef | null>(null);
  const [menu, setMenu] = useState(false);
  if (game) return <GameStage game={game} machines={machines} first={decorOf} fallback={fallback} onClose={() => setGame(null)} />;
  return (
    <>
      {children}
      <div className="space-games">
        <button type="button" className="btn space-play" onClick={() => (GAMES.length > 1 ? setMenu((m) => !m) : setGame(GAMES[0]))}>
          <IconDeviceGamepad2 size={16} />Jugar
        </button>
        {menu && (
          <div className="menu space-games-menu" role="menu">
            {GAMES.map((gd) => (
              <button key={gd.id} role="menuitem" onClick={() => { setMenu(false); setGame(gd); }}><IconDeviceGamepad2 size={16} />{gd.name}</button>
            ))}
          </div>
        )}
      </div>
    </>
  );
}
