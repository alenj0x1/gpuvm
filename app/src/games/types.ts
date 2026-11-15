// Mini games played in the space of machines (Home). Each game is a definition in games/index.ts with a create()
// that runs on a canvas; the stage around it (start, pause, game over, record) is shared, so a new game only
// brings its own play.

export interface GameHud { score: number; lives: number; /** A power-up in effect, in words ("Escudo"). */ power?: string }

export interface GameHost {
  /** The machine's color and its decoration: the player's machine looks like the one on Home. */
  color: string;
  light: boolean;
  figures: string[];
  stickers: string[];
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
