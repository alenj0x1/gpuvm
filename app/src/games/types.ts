// Mini games played in the space of machines (Home). Each game is a definition in games/index.ts with a create()
// that runs on a canvas; the stage around it (start, pause, game over, record) is shared, so a new game only
// brings its own play.

export interface GameHud {
  score: number; lives: number;
  /** A power-up in effect, in words ("Escudo 6 s"). */
  power?: string;
  /** A meter that fills (0 to 1) and what happens when it is full, if the game has one. */
  meter?: number; frenzy?: boolean;
  /** The ability on the right button: its name, how charged it is (0 to 1) and, while it runs, how much is left. */
  ability?: { name: string; charge: number; active?: number };
  /** The zone the game is in, when it has several (shown when it changes). */
  zone?: string;
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
  /** The world of the space it is played in ("studio", "board" or "blocks"): where the game starts. */
  world?: string;
  /** Plays by itself, never ends and leaves the keyboard alone (the gallery's cards). */
  demo?: boolean;
  /** Called a few times per second, not every frame. */
  onHud: (h: GameHud) => void;
  onOver: (score: number) => void;
}

export interface GameInstance {
  start: () => void;
  pause: () => void;
  resume: () => void;
  stop: () => void;
  /** Changes who plays (and the mode) without starting over: the ones leaving fly off and the new ones fly in. */
  cast?: (c: { player: GameMachine; team: GameMachine[]; mode: string }) => void;
}

/** One action of a game and what does it: keys (as written on them) and/or a mouse button. */
export interface Control { label: string; keys?: string[]; mouse?: "left" | "right" | "move" }

export interface GameDef {
  id: string;
  name: string;
  /** One line under its name. */
  description: string;
  /** How it is played: each action with the keys and mouse button that do it, drawn on the start screen. */
  controls: Control[];
  /** A few short lines about what happens in the game (pickups, scoring). */
  tips?: string[];
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

/** Watches a game's canvas size and calls `fit` once it has settled. Resizing the canvas's bitmap clears it, so doing
 *  it on every step of a drag (Home's panels) left the games gray and stuttering; meanwhile the last picture just
 *  stretches with the box. */
export function settledResize(fit: () => void, ms = 140) {
  let timer = 0;
  return new ResizeObserver(() => { clearTimeout(timer); timer = window.setTimeout(fit, ms); });
}
