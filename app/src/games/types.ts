export interface GameHud {
  score: number; lives: number;
  power?: string;
  meter?: number; frenzy?: boolean;
  ability?: { name: string; charge: number; active?: number };
  zone?: string;
}

export interface GameMachine { name: string; color: string; figures: string[] }

export interface GameHost {
  player: GameMachine;
  team: GameMachine[];
  mode: string;
  color: string;
  figures: string[];
  light: boolean;
  world?: string;
  demo?: boolean;
  onHud: (h: GameHud) => void;
  onOver: (score: number) => void;
}

export interface GameInstance {
  start: () => void;
  pause: () => void;
  resume: () => void;
  stop: () => void;
  cast?: (c: { player: GameMachine; team: GameMachine[]; mode: string }) => void;
}

export interface Control { label: string; keys?: string[]; mouse?: "left" | "right" | "move" }

export interface GameDef {
  id: string;
  name: string;
  description: string;
  controls: Control[];
  tips?: string[];
  modes?: { id: string; name: string; description: string; team?: boolean }[];
  create: (canvas: HTMLCanvasElement, host: GameHost) => GameInstance;
}

const BEST = "gpuvm.games.best.";
export function bestScore(id: string): number {
  try { return Number(localStorage.getItem(BEST + id)) || 0; } catch { return 0; }
}
export function saveBest(id: string, score: number): boolean {
  if (score <= bestScore(id)) return false;
  try { localStorage.setItem(BEST + id, String(score)); } catch {}
  return true;
}

/** Resizing the bitmap clears the canvas, so `fit` waits until the size settles; meanwhile the picture stretches. */
export function settledResize(fit: () => void, ms = 140) {
  let timer = 0;
  return new ResizeObserver(() => { clearTimeout(timer); timer = window.setTimeout(fit, ms); });
}
