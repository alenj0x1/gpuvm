import { MachineCube, cubeOf } from "./MachineCube";
import type { VmOverview } from "./types";
import { t, translateModule } from "./i18n";

export type ViewerPhase = "opening" | "entering" | "live" | "leaving";
/** How long the zoom into (and out of) the machine lasts; the same as .viewer-stage.entering / .leaving. */
export const ZOOM_MS = 560;

/** What the app shows while a machine opens inside it: the machine's cube moves from its place on the right to the
 *  center, with the steps under it; with the first picture it zooms in, into the machine, and the picture takes the
 *  area (live). Leaving, the cube zooms back out on the way to Home. */
export function ViewerStage({ vm, phase, step }: { vm: VmOverview | null; phase: ViewerPhase; step?: string }) {
  return (
    <main className={`viewer-stage ${phase}`}>
      {phase !== "live" && vm && (
        <div className="viewer-stage-center">
          <div className="viewer-stage-cube">
            <MachineCube machine={cubeOf(vm)} name={vm.name} />
          </div>
          <div className="viewer-stage-steps" aria-live="polite">
            <span>{step ? translateModule(step) : t("Preparando")}</span>
            <div className="viewer-stage-bar"><i /></div>
          </div>
        </div>
      )}
    </main>
  );
}
