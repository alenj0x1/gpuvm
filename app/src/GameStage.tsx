import { useEffect, useRef, useState } from "react";
import { IconDeviceGamepad2, IconHeart, IconPlayerPause, IconPlayerPlay, IconRefresh, IconTrophy, IconX } from "@tabler/icons-react";
import { GAMES, bestScore, saveBest, type GameDef, type GameHud, type GameInstance } from "./games";
import { colorOfDecor, useDecor, type Decor } from "./decor/store";

type Phase = "ready" | "playing" | "paused" | "over";

/** A game running in the space: the canvas, its score and lives, and the start, pause and game-over cards. */
function GameStage({ game, decor, onClose }: { game: GameDef; decor: Decor; onClose: () => void }) {
  const ref = useRef<HTMLCanvasElement>(null);
  const inst = useRef<GameInstance | null>(null);
  const [phase, setPhase] = useState<Phase>("ready");
  const [hud, setHud] = useState<GameHud>({ score: 0, lives: 3 });
  const [best, setBest] = useState(() => bestScore(game.id));
  const [record, setRecord] = useState(false);
  const [final, setFinal] = useState(0);

  useEffect(() => {
    const cv = ref.current;
    if (!cv) return;
    const light = document.documentElement.dataset.theme === "light";
    const color = colorOfDecor(decor, light) ?? (getComputedStyle(cv).getPropertyValue("--accent").trim() || "#7d9cf0");
    inst.current = game.create(cv, {
      color, light, figures: decor.figures.map((f) => f.figure), stickers: decor.stickers.map((s) => s.sticker),
      onHud: setHud,
      onOver: (score) => { setFinal(score); setRecord(saveBest(game.id, score)); setBest(bestScore(game.id)); setPhase("over"); },
    });
    return () => { inst.current?.stop(); inst.current = null; };
  }, [game]);

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

  const play = () => { setRecord(false); inst.current?.start(); setPhase("playing"); ref.current?.focus(); };

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
        <div className="game-card">
          <span className="game-card-icon"><IconDeviceGamepad2 size={22} /></span>
          <strong>{game.name}</strong>
          <span className="game-card-desc">{game.description}</span>
          <ul>{game.controls.map((c) => <li key={c}>{c}</li>)}</ul>
          {best > 0 && <span className="game-best"><IconTrophy size={14} />Récord {best.toLocaleString("es")}</span>}
          <div className="game-card-actions">
            <button type="button" className="btn ghost" onClick={onClose}>Salir</button>
            <button type="button" className="primary compact" onClick={play}><IconPlayerPlay size={16} />Jugar</button>
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
            <button type="button" className="btn ghost" onClick={onClose}>Salir</button>
            <button type="button" className="primary compact" onClick={play}><IconRefresh size={16} />Otra vez</button>
          </div>
        </div>
      )}
    </div>
  );
}

/** The space of machines with its games: a Jugar button over it (on hover), and the game in its place while played.
 *  The cube stops drawing while a game runs. */
export function SpaceWithGames({ decor: shown, decorOf, children }: { decor?: Decor; decorOf?: string; children: React.ReactNode }) {
  const own = useDecor(decorOf ?? "");
  const decor = shown ?? own;
  const [game, setGame] = useState<GameDef | null>(null);
  const [menu, setMenu] = useState(false);
  if (game) return <GameStage game={game} decor={decor} onClose={() => setGame(null)} />;
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
