// Mini games played in the space of machines (Home). Each game is a definition in games/index.ts with a create()
// that runs on a canvas; the stage around it (start, pause, game over, record) is shared, so a new game only
// brings its own play.

export interface GameHud {
  score: number; lives: number;
  /** A power-up in effect, in words ("Escudo 6 s"). */
  power?: string;
  /** A meter that fills (0 to 1) and what happens when it is full, if the game has one. */
  meter?: number; frenzy?: boolean;
}

/** A machine as a game draws it: its color and the figures it carries. */
export interface GameMachine { name: string; color: string; figures: string[] }

export interface GameHost {
  /** The machine you play with, and in a team mode the others flying with you. */
  player: GameMachine;
  team: GameMachine[];
  /** The chosen mode's id ("" when the game has none). */
  mode: string;
  /** Same as the player's, kept for games that only need these. */
  color: string;
  figures: string[];
  light: boolean;
  /** Called a few times per second, not every frame. */
  onHud: (h: GameHud) => void;
  onOver: (score: number) => void;
}

export interface GameInstance {
  start: () => void;
  pause: () => void;
  resume: () => void;
  stop: () => void;
}

export interface GameDef {
  id: string;
  name: string;
  /** One line under its name. */
  description: string;
  /** How it is played, in words, for the start screen. */
  controls: string[];
  /** Ways to play it, picked on the start card; `team` modes bring your other machines along. */
  modes?: { id: string; name: string; description: string; team?: boolean }[];
  create: (canvas: HTMLCanvasElement, host: GameHost) => GameInstance;
}

const BEST = "gpuvm.games.best.";
export function bestScore(id: string): number {
  try { return Number(localStorage.getItem(BEST + id)) || 0; } catch { return 0; }
}
export function saveBest(id: string, score: number): boolean {
  if (score <= bestScore(id)) return false;
  try { localStorage.setItem(BEST + id, String(score)); } catch { /* no storage */ }
  return true;
}
