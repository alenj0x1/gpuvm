import { CUBE_FLIGHT } from "./cubeFlight";
import { BIT_HOP } from "./bitHop";
import { BRICK_TOWER } from "./brickTower";
import { CATCH } from "./catchGame";
import type { GameDef } from "./types";

export const GAMES: GameDef[] = [CUBE_FLIGHT, BIT_HOP, BRICK_TOWER, CATCH];
export * from "./types";
