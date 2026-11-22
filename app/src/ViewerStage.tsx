import { useRef } from "react";
import { MachineCube, cubeOf, type CubeMachine } from "./MachineCube";
import { Tips } from "./Tips";
import type { VmOverview } from "./types";
import { t, translateModule } from "./i18n";

export type ViewerPhase = "opening" | "entering" | "live" | "leaving";
/** Must match .viewer-stage.entering / .leaving in styles.css. */
export const ZOOM_MS = 560;

export function ViewerStage({ vm, phase, step }: { vm: VmOverview | null; phase: ViewerPhase; step?: string }) {
  // Frozen at the start of opening: a state change right before the zoom made the hologram move twice.
  const frozen = useRef<{ name: string; machine: CubeMachine } | null>(null);
  if (vm && frozen.current?.name !== vm.name) frozen.current = { name: vm.name, machine: cubeOf(vm) };
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
            <span>{shown ? translateModule(shown) : t("Preparing")}</span>
            <div className="viewer-stage-bar"><i /></div>
          </div>
        </div>
      )}
      {phase === "opening" && <Tips className="viewer-stage-tips" />}
    </main>
  );
}
