import { useRef } from "react";
import { MachineCube, cubeOf, type CubeMachine } from "./MachineCube";
import { Tips } from "./Tips";
import type { VmOverview } from "./types";
import { t, translateModule } from "./i18n";

export type ViewerPhase = "opening" | "entering" | "live" | "leaving";
/** How long the zoom into (and out of) the machine lasts; the same as .viewer-stage.entering / .leaving. */
export const ZOOM_MS = 560;

/** What the app shows while a machine opens inside it: the machine's cube moves from its place on the right to the
 *  center, with the steps under it and a tip; with the first picture it zooms in, into the machine, and the picture
 *  takes the area (live). Leaving, the cube zooms back out on the way to Home. */
export function ViewerStage({ vm, phase, step }: { vm: VmOverview | null; phase: ViewerPhase; step?: string }) {
  // The cube is frozen as it was when the machine started opening: the hologram zooms to any piece that changes, and
  // the machine changing state (on, its usage) right before the zoom made it move twice.
  const frozen = useRef<{ name: string; machine: CubeMachine } | null>(null);
  if (vm && frozen.current?.name !== vm.name) frozen.current = { name: vm.name, machine: cubeOf(vm) };
  // The last step stays when the job ends (it went back to "Preparando" for a moment, right before the zoom).
  const lastStep = useRef<string>("");
  if (step) lastStep.current = step;
  const shown = step ?? lastStep.current;
  return (
    <main className={`viewer-stage ${phase}`}>
      {phase !== "live" && vm && frozen.current && (
        <div className="viewer-stage-center">
          <div className="viewer-stage-cube">
            <MachineCube machine={frozen.current.machine} name={vm.name} />
          </div>
          <div className="viewer-stage-steps" aria-live="polite">
            <span>{shown ? translateModule(shown) : t("Preparando")}</span>
            <div className="viewer-stage-bar"><i /></div>
          </div>
        </div>
      )}
      {phase === "opening" && <Tips className="viewer-stage-tips" />}
    </main>
  );
}
