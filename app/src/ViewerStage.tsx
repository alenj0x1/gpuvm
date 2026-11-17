import { MachineCube, cubeOf } from "./MachineCube";
import type { VmOverview } from "./types";
import { t, translateModule } from "./i18n";

/** What the app shows while a machine opens inside it: the machine's cube moves from its place on the right to the
 *  center, with the steps under it. Once the first picture arrives the viewer covers this area (live). */
export function ViewerStage({ vm, phase, step }: { vm: VmOverview | null; phase: "opening" | "live"; step?: string }) {
  return (
    <main className={`viewer-stage ${phase}`}>
      {phase === "opening" && vm && (
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
