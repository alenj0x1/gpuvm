import { CUBE_FLIGHT } from "./cubeFlight";
import { BIT_HOP } from "./bitHop";
import type { GameDef } from "./types";

/** The games in the space of machines. A new one is a GameDef added here. */
export const GAMES: GameDef[] = [CUBE_FLIGHT, BIT_HOP];
export * from "./types";
