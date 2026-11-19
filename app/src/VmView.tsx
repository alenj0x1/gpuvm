import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  IconAdjustments, IconBrandWindows, IconAlertTriangle, IconAppWindow, IconApps, IconArrowsMaximize, IconBolt, IconCheck, IconChevronRight, IconClipboardText, IconClock, IconCpu, IconDeviceDesktop, IconDeviceFloppy, IconDeviceGamepad2, IconDots, IconDownload, IconExternalLink, IconFileExport, IconFolders, IconGauge, IconKey, IconLayoutBoard, IconLayoutGrid, IconLink, IconList, IconLoader2, IconNetwork, IconPalette, IconPencil, IconPlayerPause, IconPlayerPlay, IconPlayerTrackNext, IconPlugConnected, IconPlugOff, IconPlus, IconPointer, IconPower, IconRectangle, IconRefresh, IconRotate360, IconRefreshAlert, IconScreenShare, IconSearch, IconShieldCheck, IconSparkles, IconTemplate, IconTopologyStar3, IconTrash, IconWaveSine, IconWorld, IconUser, IconUserShield,
} from "@tabler/icons-react";
import type { AppInfo, CleanupLevelId, DiskBudget, SharedDiskInfo, DisplayMode, HostInfo, MouseMode, Sample, StreamSettings, VmOverview } from "./types";
import { usePrefs } from "./prefs";
import { AGENT_USE, AppLogo, FpsPicker, MonitorPicker, resolveMonitor, useMonitors, CODECS, RESOLUTIONS, USES, streamUseOf, useCleanupLevels, profileLabel } from "./pickers";
import { MachineIcon, patternClick, patternVariant, setPatternVariant } from "./machineIcon";
import { CLEANUP_REMOVED, MachineCube, cubeOf, type CubeView } from "./MachineCube";
import { Customize, useDecorEdit } from "./Customize";
import { machineSource } from "./decor/store";
import { moveToSpace, showSpace, spaceOf, useSpaceOf, useSpaces } from "./spaces";
import { ambientInfo } from "./ambient";
import { SpaceDialog } from "./SpaceDialog";
import { RestorePoints } from "./RestorePoints";
import { Scene, nextSceneStyle, sceneStyle } from "./Scene";
import { CleanupFlow, CleanupItems, LEVEL_LOOK } from "./CleanupFlow";
import { Sparkline, series } from "./Chart";
import { CheckMark, Dropdown, Segmented, Slider, formatUptime, portalRoot, scrollToSection, stateText, useScrollFade } from "./ui";
import { MachineAgent } from "./Agents";
import { useAgents } from "./agentStore";
import { agents, api, openConsole, pickExportFile, vmNameError } from "./api";
import { locale, t, tn, translateModule } from "./i18n";

export interface JobInfo {
  cmd: string;
  message: string;
  log: string[];
}

interface Props {
  vm: VmOverview;
  /** Every machine, for the space around this one's cube. */
  vms?: VmOverview[];
  host: HostInfo | null;
  samples: Sample[];
  /** Long job or power action in progress for this VM. */
  busy: JobInfo | null;
  startJob: (vm: string, cmd: string, args: Record<string, unknown>, after?: () => void, failed?: () => void) => void;
  run: (vm: string, label: string, task: () => Promise<unknown>) => Promise<boolean>;
  onRemoved: () => void;
  /** The rename finished: the page, the sidebar and the route follow the new name. */
  onRenamed?: (from: string, to: string) => void;
}

const transitionText = (state: string): string | undefined => ({ Starting: t("Starting"), Stopping: t("Shutting down"), Saving: t("Saving"), Pausing: t("Pausing"), Resuming: t("Resuming") } as Record<string, string>)[state];

type VmTab = "machine" | "agent" | "display" | "windows" | "custom";
// The cube's column: dragged anywhere between the two edges. Near the right edge the cube folds into a thin rail
// (0 is stored); near the left one it takes the whole width and the options fold (FULL is stored). In between, both
// keep a usable width.
const CUBE_KEY = "gpuvm.cubeWidth", CUBE_DEFAULT = 380, CUBE_MIN = 220, OPTIONS_MIN = 300, FOLD = 140, FULL = 99999, RAIL = 14;
const readCubeW = () => { try { return Number(localStorage.getItem(CUBE_KEY)) || CUBE_DEFAULT; } catch { return CUBE_DEFAULT; } };
/** Where the last machine page was left, to open the next one at the same place. */
let lastPlace: { section: VmTab; offset: number; at: number } | null = null;
const NEW_SPACE = "__new__";
const tabLabel = (tab: VmTab) => ({ machine: t("Machine"), agent: t("Agent"), display: t("Picture and control"), windows: t("Windows"), custom: t("Customize") })[tab];

export function VmView({ vm, vms = [], host, samples, busy, startJob, run, onRemoved, onRenamed }: Props) {
  const [variant, setVariant] = useState(() => patternVariant(vm.name));
  // What is being changed and not saved yet (resources, cleanup level, apps picked to install), for the cube.
  const [preview, setPreview] = useState<{ cpu?: number; memoryGB?: number; gpuPercent?: number; diskGB?: number; cleanup?: CleanupLevelId }>({});
  const [previewApps, setPreviewApps] = useState<string[]>([]);
  // The name being typed in "Rename" (and then being applied), so the cube's plate engraves it as it is typed.
  const [draftName, setDraftName] = useState<string | null>(null);
  const [renameOpen, setRenameOpen] = useState(false);
  useEffect(() => { setPreview({}); setPreviewApps([]); setDraftName(null); }, [vm.name]);
  const running = vm.state === "Running";
  const off = vm.state === "Off";
  const tabs: VmTab[] = [];
  if (vm.managed && vm.options) tabs.push("machine");
  // A machine made for agents, or one an agent works on now, shows its Agent section right after Machine.
  const agentHere = useAgents().clients.some((c) => c.machine === vm.name);
  if (vm.forAgents || agentHere) tabs.push("agent");
  if (vm.managed && vm.options && vm.streaming) tabs.push("display");
  if (vm.managed && vm.guestCredential) tabs.push("windows");
  if (vm.managed && vm.options) tabs.push("custom");
  const decorSource = useMemo(() => machineSource(vm.name), [vm.name]);
  const space = useSpaceOf(vm.name);
  const bodyRef = useRef<HTMLDivElement>(null);
  const [cubeW, setCubeW] = useState(readCubeW);
  const [resizing, setResizing] = useState(false);
  const span = () => bodyRef.current?.clientWidth ?? 1200;
  /** A width as the person left it, fitted to the page now: folded, full or in between. */
  const fitCube = (w: number) => (w <= 0 ? 0 : w >= FULL || span() - w - 16 < OPTIONS_MIN ? FULL : Math.max(CUBE_MIN, w));
  const resizeCube = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = e.currentTarget, startX = e.clientX, startW = cubeW;
    el.setPointerCapture(e.pointerId);
    setResizing(true);
    let w = startW;
    const from = startW >= FULL ? span() : startW <= 0 ? RAIL : startW;
    const move = (ev: PointerEvent) => {
      const raw = from - (ev.clientX - startX);
      // Past the folding points it snaps to the edge; in between it follows the pointer.
      w = raw < FOLD ? 0 : span() - raw - 16 < OPTIONS_MIN * 0.6 ? FULL : Math.round(Math.min(span() - OPTIONS_MIN - 16, Math.max(CUBE_MIN, raw)));
      setCubeW(w);
    };
    const up = () => {
      el.removeEventListener("pointermove", move); el.removeEventListener("pointerup", up); el.removeEventListener("pointercancel", up);
      setResizing(false);
      try { localStorage.setItem(CUBE_KEY, String(w)); } catch { /* no storage */ }
    };
    el.addEventListener("pointermove", move); el.addEventListener("pointerup", up); el.addEventListener("pointercancel", up);
  };
  const decorEdit = useDecorEdit(decorSource);
  // While decorating, a fixed view of the cube (front, a side, the top) that stays still.
  const [cubeView, setCubeView] = useState<CubeView | null>(null);
  // Every section is on the same page; the bar above them marks the one in view and takes you to the others.
  const mainRef = useRef<HTMLDivElement>(null);
  const sectionRefs = useRef<Partial<Record<VmTab, HTMLElement | null>>>({});
  const [active, setActive] = useState<VmTab | undefined>(tabs[0]);
  const tabKey = tabs.join(",");
  useEffect(() => {
    const main = mainRef.current;
    if (!main) return;
    const spy = () => {
      const list = tabKey.split(",").filter(Boolean) as VmTab[];
      const nav = main.querySelector<HTMLElement>(".section-nav");
      const line = main.getBoundingClientRect().top + (nav?.offsetHeight ?? 0) + 48;
      let current = list[0];
      for (const t of list) {
        const el = sectionRefs.current[t];
        if (el && el.getBoundingClientRect().top <= line) current = t;
      }
      // At the very bottom the last section is the one in view, however short it is.
      if (main.scrollHeight > main.clientHeight + 4 && main.scrollTop + main.clientHeight >= main.scrollHeight - 4) current = list[list.length - 1];
      setActive(current);
    };
    spy();
    main.addEventListener("scroll", spy, { passive: true });
    return () => main.removeEventListener("scroll", spy);
  }, [tabKey, vm.name]);
  // Switching to another machine keeps the place on the page: the same section, as far into it as before, so a
  // section (Personalizar, Windows) can be compared machine after machine. Coming from elsewhere starts at the top.
  useLayoutEffect(() => {
    const main = mainRef.current;
    if (!main) return;
    const from = lastPlace;
    let mine = true;
    if (from && performance.now() - from.at < 1500) {
      const place = () => {
        const el = sectionRefs.current[from.section];
        if (!el || !mine) return;
        main.scrollTop += el.getBoundingClientRect().top - main.getBoundingClientRect().top + from.offset;
      };
      place();
      // What loads after opening (apps, disks) changes heights: follow it until the person scrolls.
      const ro = new ResizeObserver(place);
      const body = main.querySelector(".vm-sections");
      if (body) ro.observe(body);
      const stop = () => { mine = false; ro.disconnect(); };
      main.addEventListener("wheel", stop, { once: true, passive: true });
      main.addEventListener("pointerdown", stop, { once: true });
      const t = setTimeout(stop, 1500);
      return () => { clearTimeout(t); stop(); keep(); };
    }
    return keep;
    function keep() {
      const list = tabKey.split(",").filter(Boolean) as VmTab[];
      let section = list[0], offset = main!.scrollTop;
      for (const t of list) {
        const el = sectionRefs.current[t];
        const top = el ? el.getBoundingClientRect().top - main!.getBoundingClientRect().top : Infinity;
        if (top <= 1) { section = t; offset = -top; }
      }
      lastPlace = section ? { section, offset, at: performance.now() } : null;
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const goTo = (t: VmTab) => {
    const main = mainRef.current, el = sectionRefs.current[t];
    if (main && el) scrollToSection(main, el);
  };

  return (
    <div className={`main${renameOpen ? " renaming" : ""}`} ref={mainRef}>
      <Header vm={vm} vms={vms} busy={busy} variant={variant} startJob={startJob} run={run} onRemoved={onRemoved}
        onRenameDraft={setDraftName} onRenameOpen={setRenameOpen} onRenamed={onRenamed}
        onPattern={() => {
          // The third quick click switches every pattern's palette; the two before it are undone.
          const v = patternClick() ? Math.max(0, variant - 2) : variant + 1;
          setPatternVariant(vm.name, v);
          setVariant(v);
          window.dispatchEvent(new Event("gpuvm-pattern"));
        }} />

      <div className="card stats joined">
        <Stat icon={<IconCpu size={15} />} label={t("Processor")} value={t("{n} threads", { n: vm.processorCount })}
          sub={running ? t("{n} % in use", { n: vm.cpuPercent }) : t("Idle")} spark={running ? series(samples, (s) => s.cpu) : []} color="var(--chart-cpu)" />
        <Stat icon={<IconTopologyStar3 size={15} />} label={t("Memory")} value={`${vm.memoryStartupGB} GB`}
          sub={running ? t("{n} GB in use", { n: vm.memoryDemandGB }) : t("Fixed at start")}
          spark={running ? series(samples, (s) => (s.mem / Math.max(vm.memoryAssignedGB, 0.1)) * 100) : []} color="var(--chart-mem)" />
        <Stat icon={<IconBolt size={15} />} label="GPU"
          value={vm.hasGpu ? (running ? `${vm.gpuPercent} %` : t("{n} % assigned", { n: vm.options?.gpuPercent ?? 100 })) : t("No GPU")}
          sub={vm.gpuName ?? t("Basic graphics only")} spark={running && vm.hasGpu ? series(samples, (s) => s.gpu) : []} color="var(--chart-gpu)" />
        <Stat icon={<IconClock size={15} />} label={t("Uptime")} value={running ? formatUptime(vm.uptimeSeconds) : "—"}
          sub={running ? (vm.address ?? t("Waiting for network")) : t("No network")}
          // Its line, in the text color: how busy the machine has been overall (processor and GPU together).
          spark={running ? series(samples, (s) => (s.cpu + (vm.hasGpu ? s.gpu : s.cpu)) / 2) : []} color="var(--text)" />
      </div>

      {vm.managed && !vm.guestCredential && <GuestPassword vm={vm} run={run} />}
      {vm.managed && vm.driverInSync === false && (
        <div className="notice">
          <IconRefreshAlert size={20} />
          <div className="grow">{t("The VM's NVIDIA driver differs from your PC's. It updates itself the next time you start it from here.")}</div>
          {!busy && (
            <button className="btn" onClick={() => startJob(vm.name, "Sync-GpuVMDriver", { Name: vm.name, Confirm: false, ShutdownIfRunning: true })}>
              <IconDownload size={16} />{off ? t("Update now") : t("Shut down and update")}
            </button>
          )}
        </div>
      )}


      {tabs.length > 1 && (
        <nav className="section-nav" role="tablist">
          {tabs.map((tab) => (
            <button key={tab} type="button" role="tab" aria-selected={tab === active} className={tab === active ? "on" : ""} onClick={() => goTo(tab)}>{tabLabel(tab)}</button>
          ))}
        </nav>
      )}
      <div className={`vm-body${resizing ? " resizing" : ""}${fitCube(cubeW) === 0 ? " cube-folded" : fitCube(cubeW) === FULL ? " options-folded" : ""}`} ref={bodyRef}
        style={{ "--cube-w": `${fitCube(cubeW) === 0 ? RAIL : fitCube(cubeW) === FULL ? 0 : fitCube(cubeW)}px` } as React.CSSProperties}>
      <div className="vm-sections">
      {tabs.includes("machine") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.machine = el; }}>
          <Options part="machine" vm={vm} host={host} busy={busy} startJob={startJob} run={run} onPreview={(r) => setPreview((p) => ({ ...p, ...r }))} />
          <SharedDisks vm={vm} busy={busy} startJob={startJob} />
          <RestorePoints vm={vm} busy={busy} startJob={startJob} run={run} />
        </section>
      )}
      {tabs.includes("agent") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.agent = el; }}>
          <MachineAgent machine={vm.name} />
        </section>
      )}
      {tabs.includes("display") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.display = el; }}>
          <Options part="display" vm={vm} host={host} busy={busy} startJob={startJob} run={run} />
        </section>
      )}
      {tabs.includes("windows") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.windows = el; }}>
          {vm.options && <Cleanup vm={vm} busy={busy} startJob={startJob} onPreview={(cleanup) => setPreview((p) => ({ ...p, cleanup }))} />}
          <Apps vm={vm} busy={busy} startJob={startJob} onPreview={setPreviewApps} />
        </section>
      )}
      {tabs.includes("custom") && (
        <section className="vm-section" ref={(el) => { sectionRefs.current.custom = el; }}>
          <Customize source={decorEdit.source} ops={decorEdit.ops} selected={decorEdit.selected} setSelected={decorEdit.setSelected} openMenu={decorEdit.openMenu}
            first={<SpaceRow name={vm.name} vms={vms} />} />
        </section>
      )}
      </div>
      {decorEdit.menu}
      {/* The machine itself, always in view beside its options, following what is being changed before it is saved. */}
      {vm.managed && vm.options && (
        <aside className={`vm-cube${renameOpen ? " lifted" : ""}`}>
          <div className="vm-cube-split" role="separator" aria-orientation="vertical" aria-label={t("Cube width")} title={t("Drag to change the width")}
            onPointerDown={resizeCube} onDoubleClick={() => { setCubeW(CUBE_DEFAULT); try { localStorage.setItem(CUBE_KEY, String(CUBE_DEFAULT)); } catch { /* no storage */ } }}><span /></div>
          {active === "custom" && (
            <div className="cube-views" role="radiogroup" aria-label={t("Cube view")}>
              {([[null, t("Free"), <IconRotate360 size={15} key="i" />, t("Rotate freely")], ["front", t("Front"), null, t("View from the front")], ["right", t("Right"), null, t("View from the right")], ["back", t("Back"), null, t("View from the back")], ["left", t("Left"), null, t("View from the left")], ["top", t("Top"), null, t("View from the top")]] as const).map(([v, label, icon, hint]) => (
                <button key={label} type="button" role="radio" aria-checked={cubeView === v} className={cubeView === v ? "on" : ""} title={hint} onClick={() => setCubeView(v)}>
                  {icon ?? <FaceGlyph face={v!} />}<span>{label}</span>
                </button>
              ))}
            </div>
          )}
          <MachineCube key={vm.name} travel machine={{
            power: running ? "on" : vm.state === "Starting" || vm.state === "Stopping" ? "starting" : "off",
            cores: preview.cpu ?? vm.options.cpu,
            memoryGB: preview.memoryGB ?? vm.options.memoryGB,
            gpuPercent: vm.hasGpu ? preview.gpuPercent ?? vm.options.gpuPercent : 0,
            diskGB: preview.diskGB ?? vm.options.diskGB,
            usage: { cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100, disk: 0 },
            apps: previewApps,
            removed: CLEANUP_REMOVED[preview.cleanup ?? vm.options.cleanup] ?? 0,
          }} ambient={space.ambient} spaceName={space.name} time={space.time} name={draftName || vm.name} decorOf={vm.name} spin={decorEdit.spins} edit={{ ...decorEdit.edit, holdStill: active === "custom", view: active === "custom" ? cubeView : null }} others={vms.filter((v) => v.name !== vm.name && spaceOf(v.name).id === space.id).map((v) => ({ name: v.name, machine: cubeOf(v) }))} />
        </aside>
      )}
      </div>
    </div>
  );
}

/** Shared disks: attach one to this machine or take it away, also while it runs. Hidden until a disk exists. */
// The shared disks are asked for once GpuVM opens and kept: the card is there when the page shows, instead of
// appearing a moment later and pushing what is under it.
let sharedCache: SharedDiskInfo[] = [];
const sharedReady = api.sharedDisks().then((d) => { sharedCache = d; }).catch(() => {});

export function SharedDisks({ vm, busy, startJob }: Pick<Props, "vm" | "busy" | "startJob">) {
  const [disks, setDisks] = useState<SharedDiskInfo[]>(sharedCache);
  const load = () => sharedReady.then(() => api.sharedDisks()).then((d) => { sharedCache = d; setDisks(d); }).catch(() => {});
  useEffect(() => { load(); }, [vm.name, vm.state, busy?.cmd]);
  if (!disks.length) return null;
  const working = busy?.cmd === "Connect-GpuVMSharedDisk" || busy?.cmd === "Disconnect-GpuVMSharedDisk";
  const gb = (n: number) => `${n.toLocaleString(locale(), { maximumFractionDigits: 1 })} GB`;
  return (
    <div className="card">
      <div className="opt-rows">
        {disks.map((d) => {
          const here = d.vm === vm.name;
          // Another running machine has it: it has to be taken away there first.
          const elsewhere = !!d.vm && !here;
          const state = here ? t("Connected") : elsewhere ? t("In {vm}", { vm: d.vm! }) : t("Free");
          return (
            <div className="opt-row disk-row" key={d.name}>
              <span className="opt-icon">{d.purpose === "games" ? <IconDeviceGamepad2 size={17} /> : <IconFolders size={17} />}</span>
              <div className="opt-text">
                <span className="opt-title">{d.name}
                  <span className={`disk-state${here ? " here" : elsewhere ? " away" : ""}`}><i />{state}</span>
                </span>
                {/* What a shared disk is, said plainly: its name alone ("juegos") doesn't tell. */}
                <span className="opt-desc">{d.purpose === "games"
                  ? t("Shared {size} disk for games. Install them once and connect it to whichever machine needs them.", { size: gb(d.sizeGB) })
                  : t("Shared {size} disk. Your files, on whichever machine connects it.", { size: gb(d.sizeGB) })}</span>
                <div className="disk-use" title={t("Takes {size} on your PC", { size: gb(d.fileGB) })}>
                  <div className="disk-use-bar"><span style={{ width: `${Math.min(100, (d.fileGB / Math.max(d.sizeGB, 1)) * 100)}%` }} /></div>
                  <span>{t("{used} of {size}", { used: gb(d.fileGB), size: gb(d.sizeGB) })}</span>
                </div>
              </div>
              <div className="opt-ctl">
                {here ? (
                  <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Disconnect-GpuVMSharedDisk", { Name: d.name }, load)}>
                    {working ? <IconLoader2 size={16} className="spin" /> : <IconPlugOff size={16} />}{working ? translateModule(busy!.message) : t("Disconnect")}
                  </button>
                ) : (
                  <button className="btn" disabled={!!busy || (elsewhere && d.vmRunning)} onClick={() => startJob(vm.name, "Connect-GpuVMSharedDisk", { Name: d.name, VMName: vm.name }, load)}
                    title={elsewhere && d.vmRunning ? t("Disconnect it in {vm} or shut that machine down to bring it here", { vm: d.vm! }) : undefined}>
                    <IconPlugConnected size={16} />{elsewhere ? t("Bring from {vm}", { vm: d.vm! }) : t("Connect")}
                  </button>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

// What each cleanup level is about, in a few words; what it does comes from the module, item by item.

/** Windows cleanup: the levels as cards (each includes the ones before it), what the chosen one does, and Aplicar
 *  only when a different level is chosen. */
export function Cleanup({ vm, busy, startJob, onPreview }: Pick<Props, "vm" | "busy" | "startJob"> & { onPreview?: (level: CleanupLevelId) => void }) {
  const levels = useCleanupLevels();
  const current = vm.options?.cleanup ?? "none";
  const [chosen, setChosen] = useState<CleanupLevelId>(current);
  useEffect(() => setChosen(current), [vm.name, current]);
  useEffect(() => onPreview?.(chosen), [chosen]);
  if (!levels.length) return null;
  const applying = busy?.cmd === "Set-GpuVMCleanup";
  const rank = Math.max(0, levels.findIndex((l) => l.id === chosen));
  const items = levels.slice(0, rank + 1).flatMap((l) => l.items);
  const all = levels.flatMap((l) => l.items);
  const removedIds = new Set(items.map((i) => i.id));
  return (
    <div className="card">
      <div className="opt-rows">
        <OptionRow icon={<IconSparkles size={17} />} title={t("Windows cleanup")} desc={t("Each level includes the ones before it.")}>
          {(chosen !== current || applying) && (
            <button className="btn" disabled={!!busy} onClick={() => startJob(vm.name, "Set-GpuVMCleanup", { Name: vm.name, Level: chosen })}>
              {applying ? <IconLoader2 size={16} className="spin" /> : <IconSparkles size={16} />}
              {applying ? translateModule(busy!.message) : vm.state === "Off" ? t("Start and apply") : t("Apply")}
            </button>
          )}
        </OptionRow>
      </div>
      <div className="cleanup-body">
        <div className="level-list" role="radiogroup" aria-label={t("Cleanup level")}>
          {levels.map((l) => (
            <button key={l.id} type="button" role="radio" aria-checked={l.id === chosen} className={`level-row${l.id === chosen ? " on" : ""}`}
              onClick={() => setChosen(l.id)}>
              <span className="level-icon">{LEVEL_LOOK[l.id]?.icon ?? <IconSparkles size={18} />}</span>
              <span className="level-text"><span className="level-name">{translateModule(l.name)}</span><span className="level-tagline">{LEVEL_LOOK[l.id]?.tagline ?? ""}</span></span>
              {l.id === current && <span className="level-applied"><IconCheck size={12} />{t("Applied")}</span>}
            </button>
          ))}
        </div>
        <CleanupFlow items={all.map((i) => i.id)} removed={removedIds} />
        <CleanupItems items={all} removed={removedIds} />
      </div>
      <p className="levels-safe"><IconShieldCheck size={14} />{t("Microsoft Defender, Windows Update, SmartScreen and the firewall are never touched.")}</p>
    </div>
  );
}

const APP_JOBS = ["Install-GpuVMApp", "Uninstall-GpuVMApp"];
type AppsView = "tiles" | "list";
const APPS_VIEW_KEY = "gpuvm.appsView";
const fold = (s: string) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();

/** Apps of a machine: the installed ones on top (each with its menu), then the catalog as tiles to pick several
 *  and install them together, or as a list with each app's own action. The chosen view is remembered. */
export function Apps({ vm, busy, startJob, onPreview }: Pick<Props, "vm" | "busy" | "startJob"> & { onPreview?: (apps: string[]) => void }) {
  const [catalog, setCatalog] = useState<AppInfo[]>([]);
  const [chosen, setChosen] = useState<string[]>([]);
  const [installed, setInstalled] = useState<string[]>([]);
  // The cube shows what is installed and what is picked to install.
  useEffect(() => onPreview?.([...installed, ...chosen.filter((id) => !installed.includes(id))]), [installed, chosen]);
  const [uninstalling, setUninstalling] = useState<AppInfo | null>(null);
  const [query, setQuery] = useState("");
  const [category, setCategory] = useState("all");
  const [view, setView] = useState<AppsView>(() => { try { return (localStorage.getItem(APPS_VIEW_KEY) as AppsView) || "tiles"; } catch { return "tiles"; } });
  const [menu, setMenu] = useState<{ app: AppInfo; x: number; y: number } | null>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  // The catalog keeps a set height and scrolls inside, fading where it continues, so the page doesn't grow with it.
  const [listRef, listFade] = useScrollFade<HTMLDivElement>();
  useEffect(() => { try { localStorage.setItem(APPS_VIEW_KEY, view); } catch { /* no storage */ } }, [view]);
  useEffect(() => { api.apps().then(setCatalog).catch(() => {}); }, []);
  // Checked again when the machine turns on and after every job (an install, a template, a cleanup) ends.
  const idle = !busy;
  useEffect(() => {
    if (!idle) return;
    let live = true;
    api.installedApps(vm.name).then((list) => {
      if (!live) return;
      const ids = list.map((a) => a.id);
      setInstalled(ids);
      setChosen((c) => c.filter((id) => !ids.includes(id)));
    }).catch(() => {});
    return () => { live = false; };
  }, [vm.name, vm.state, idle]);
  useEffect(() => {
    if (!menu) return;
    const close = (e: PointerEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(null); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(null); };
    const away = () => setMenu(null);
    window.addEventListener("pointerdown", close, true);
    window.addEventListener("keydown", key);
    window.addEventListener("scroll", away, true);
    return () => { window.removeEventListener("pointerdown", close, true); window.removeEventListener("keydown", key); window.removeEventListener("scroll", away, true); };
  }, [menu]);
  if (!catalog.length) return null;

  const working = !!busy && APP_JOBS.includes(busy.cmd);
  const install = (ids: string[], after?: () => void) => startJob(vm.name, "Install-GpuVMApp", { Name: vm.name, App: ids }, after);
  const reinstall = (app: AppInfo) => startJob(vm.name, "Install-GpuVMApp", { Name: vm.name, App: [app.id], Reinstall: true });
  const openMenu = (app: AppInfo, target: HTMLElement) => {
    const box = target.getBoundingClientRect();
    const y = box.bottom + 6 + 96 > window.innerHeight ? box.top - 96 - 6 : box.bottom + 6;
    setMenu({ app, x: Math.min(box.right - 200, window.innerWidth - 208), y });
  };
  const categories = [...new Map(catalog.map((a) => [a.category, a.categoryName ? translateModule(a.categoryName) : a.category])).entries()];
  const q = fold(query.trim());
  // The catalog shows every app of the category, the installed ones too (marked, not installable again).
  const available = catalog
    .filter((a) => (q ? fold(`${a.name} ${a.categoryName ?? ""} ${translateModule(a.categoryName ?? "")}`).includes(q) : category === "all" || a.category === category));
  const mine = catalog.filter((a) => installed.includes(a.id));
  const mineShown = q ? mine.filter((a) => fold(`${a.name} ${a.categoryName ?? ""} ${translateModule(a.categoryName ?? "")}`).includes(q)) : mine;
  const toggle = (id: string) => setChosen((c) => (c.includes(id) ? c.filter((x) => x !== id) : [...c, id]));

  return (
    <div className="card apps-card">
      <div className="opt-rows">
        <OptionRow icon={<IconApps size={17} />} title={t("Apps")} desc={t("From their official source, verified before installing.")}>
          <Segmented<AppsView> value={view} onChange={setView} options={[
            { value: "tiles", label: <><IconLayoutGrid size={15} />{t("Tiles")}</> },
            { value: "list", label: <><IconList size={15} />{t("List")}</> },
          ]} />
        </OptionRow>
      </div>

      <div className="apps-layout">
        {/* Left: the catalog, by category; it renews with a short animation whenever the category or view changes. */}
        <div className="apps-catalog">
          <Segmented value={category} onChange={setCategory} options={[{ value: "all", label: t("All") }, ...categories.map(([id, name]) => ({ value: id, label: name }))]} />
          {available.length === 0 ? (
            <p className="app-none">{t("No app is called “{query}”", { query: query.trim() })}</p>
          ) : view === "tiles" ? (
            <div key={`${category}-${q}`} ref={listRef} className={`app-tiles app-scroll appear ${listFade}`} role="group" aria-label={t("Apps to install")}>
              {available.map((a, n) => {
                const on = chosen.includes(a.id);
                const has = installed.includes(a.id);
                return (
                  <button key={a.id} type="button" role="checkbox" aria-checked={on} className={`app-tile${on ? " on" : ""}${has ? " has" : ""}`} disabled={!!busy || has}
                    onClick={() => toggle(a.id)} style={{ "--n": n } as React.CSSProperties}>
                    {on && <span className="app-tile-check"><IconCheck size={12} stroke={2.4} /></span>}
                    <span className="app-tile-logo"><AppLogo id={a.id} /></span>
                    <span className="app-tile-name">{a.name}</span>
                    {has ? <span className="app-installed"><IconCheck size={12} />{t("Installed")}</span> : <span className="app-tile-cat">{translateModule(a.categoryName ?? "")}</span>}
                  </button>
                );
              })}
            </div>
          ) : (
            <div key={`${category}-${q}`} ref={listRef} className={`app-rows app-scroll appear ${listFade}`}>
              {available.map((a, n) => (
                <div key={a.id} className="app-row" style={{ "--n": n } as React.CSSProperties}>
                  <span className="app-row-logo"><AppLogo id={a.id} /></span>
                  <span className="app-row-text"><strong>{a.name}</strong><span>{translateModule(a.categoryName ?? "")}</span></span>
                  {installed.includes(a.id) ? <span className="app-installed"><IconCheck size={14} />{t("Installed")}</span> : (
                    <button type="button" className="btn" disabled={!!busy} onClick={() => install([a.id])}>
                      <IconDownload size={15} />{vm.state === "Off" ? t("Start and install") : t("Install")}
                    </button>
                  )}
                </div>
              ))}
            </div>
          )}
          {/* The tiles' selection: what is chosen and the one button that installs it. */}
          {view === "tiles" && (chosen.length > 0 || working) && (
            <div className="apps-selection">
              <span>{working ? translateModule(busy!.message) : tn(chosen.length, "{n} app picked", "{n} apps picked")}</span>
              {!working && <button type="button" className="btn ghost" onClick={() => setChosen([])}>{t("Remove")}</button>}
              <button type="button" className="primary compact" disabled={!!busy} onClick={() => install(chosen, () => setChosen([]))}>
                {working ? <IconLoader2 size={16} className="spin" /> : <IconDownload size={16} />}
                {vm.state === "Off" ? t("Start and install") : t("Install")}
              </button>
            </div>
          )}
        </div>

        {/* Right: the search (it looks through both sides) and what this machine already has. */}
        <div className="apps-mine">
          <label className="search-box">
            <IconSearch size={16} />
            <input className="text-input" placeholder={t("Search")} value={query} onChange={(e) => setQuery(e.target.value)} />
          </label>
          <span className="apps-mine-title">{t("On this machine")}</span>
          {mineShown.length ? (
            <div className="apps-mine-list">
              {mineShown.map((a) => (
                <div key={a.id} className="app-row mine" onContextMenu={(e) => { e.preventDefault(); if (!busy) openMenu(a, e.currentTarget); }}>
                  <span className="app-row-logo"><AppLogo id={a.id} /></span>
                  <span className="app-row-text"><strong>{a.name}</strong><span>{translateModule(a.categoryName ?? "")}</span></span>
                  <button type="button" className="icon-btn" aria-label={t("Options for {name}", { name: a.name })} disabled={!!busy}
                    onClick={(e) => (menu?.app.id === a.id ? setMenu(null) : openMenu(a, e.currentTarget))}><IconDots size={15} /></button>
                </div>
              ))}
            </div>
          ) : (
            <div className="empty-small">
              <span className="empty-small-icon">{q ? <IconSearch size={18} /> : <IconApps size={18} />}</span>
              <strong>{q ? t("None with that name") : t("No apps installed")}</strong>
            </div>
          )}
        </div>
      </div>

      {menu && createPortal(
        <div ref={menuRef} className="menu floating" role="menu" style={{ left: Math.max(8, menu.x), top: menu.y }}>
          <button role="menuitem" onClick={() => { setMenu(null); reinstall(menu.app); }}><IconRefresh size={16} />{t("Reinstall")}</button>
          <button role="menuitem" className="danger" onClick={() => { setMenu(null); setUninstalling(menu.app); }}><IconTrash size={16} />{t("Uninstall")}</button>
        </div>,
        document.body,
      )}
      {uninstalling && (
        <ConfirmUninstall vm={vm} app={uninstalling} onClose={() => setUninstalling(null)}
          onConfirm={() => { setUninstalling(null); startJob(vm.name, "Uninstall-GpuVMApp", { Name: vm.name, App: [uninstalling.id], Confirm: false }); }} />
      )}
    </div>
  );
}

function ConfirmUninstall({ vm, app, onClose, onConfirm }: { vm: VmOverview; app: AppInfo; onClose: () => void; onConfirm: () => void }) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  // In a portal: inside the card, the overlay would be laid out within it.
  return createPortal(
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={t("Uninstall {name}", { name: app.name })}>
        <div className="dialog-head"><span className="choice-icon dialog-logo"><AppLogo id={app.id} /></span><h2>{t("Uninstall {name}", { name: app.name })}</h2></div>
        <p className="dialog-text">
          {app.interactiveUninstall
            ? t("Its uninstaller opens in {name}'s window. Finish it there.", { name: vm.name })
            : t("It's removed from {name} with its own uninstaller, along with what it keeps in its folder.", { name: vm.name })}
          {vm.state === "Off" && ` ${t("The machine starts to do it.")}`}
        </p>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
          <button className="btn danger-fill" onClick={onConfirm}><IconTrash size={16} />{t("Uninstall")}</button>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function Stat({ icon, label, value, sub, spark, color }: { icon: React.ReactNode; label: string; value: string; sub: string; spark?: number[]; color?: string }) {
  return (
    <div className="stat">
      <span className="label">{icon}{label}</span>
      <span className="value">{value}</span>
      <span className="sub" title={sub}>{sub}</span>
      {/* The line's room is kept even without data, so the strip never changes height. */}
      <div className="spark-room">{spark && color && <Sparkline values={spark} color={color} />}</div>
    </div>
  );
}

interface HeaderProps extends Omit<Props, "samples" | "host"> {
  variant: number;
  onPattern: () => void;
  onRenameDraft: (name: string | null) => void;
  onRenameOpen: (open: boolean) => void;
}

function Header({ vm, vms = [], busy, variant, startJob, run, onRemoved, onRenamed, onPattern, onRenameDraft, onRenameOpen }: HeaderProps) {
  const [menu, setMenu] = useState(false);
  const [confirmOff, setConfirmOff] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [templating, setTemplating] = useState(false);
  const [renaming, setRenaming] = useState(false);
  useEffect(() => onRenameOpen(renaming), [renaming]);
  const [pasting, setPasting] = useState<"busy" | "done" | null>(null);
  const [banner, setBanner] = useState(() => sceneStyle(vm.name));
  useEffect(() => setBanner(sceneStyle(vm.name)), [vm.name]);
  const menuRef = useRef<HTMLDivElement>(null);
  const running = vm.state === "Running";
  const paused = vm.state === "Paused";
  const off = vm.state === "Off";
  const transition = transitionText(vm.state);
  const working = busy?.message ? translateModule(busy.message) : transition ? `${transition}…` : null;

  useEffect(() => {
    if (!menu) { setConfirmOff(false); return; }
    const close = (e: MouseEvent) => { if (!menuRef.current?.contains(e.target as Node)) setMenu(false); };
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") setMenu(false); };
    window.addEventListener("mousedown", close);
    window.addEventListener("keydown", key);
    return () => { window.removeEventListener("mousedown", close); window.removeEventListener("keydown", key); };
  }, [menu]);

  const power = (action: string, label: string) => {
    setMenu(false);
    run(vm.name, label, () => api.power(vm.name, action));
  };
  const job = (cmd: string, args: Record<string, unknown>) => { setMenu(false); startJob(vm.name, cmd, args); };

  let primary: { label: string; icon: React.ReactNode; onClick: () => void; disabled?: boolean; title?: string };
  // Off and doesn't fit in the free memory as configured: said before the click, with a way out.
  const short = off && !vm.fits;
  if (paused) primary = { label: t("Resume"), icon: <IconPlayerPlay size={17} />, onClick: () => power("Resume", t("Resuming")) };
  else if (short && vm.managed && vm.streaming && vm.fitGB >= 4 && vm.fitGB < vm.memoryStartupGB) {
    // Opens with what does fit; it is saved, like changing it in Options.
    primary = { label: t("Open with {gb} GB", { gb: vm.fitGB }), icon: <IconPlayerPlay size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name, MemoryGB: vm.fitGB }),
      title: t("Uses {gb} GB of memory instead of {total} GB; you can raise it again in Options", { gb: vm.fitGB, total: vm.memoryStartupGB }) };
  } else if (short) {
    primary = { label: t("Not enough memory"), icon: <IconAlertTriangle size={17} />, onClick: () => {}, disabled: true, title: t("Close programs on this PC to start it") };
  } else if (vm.managed && vm.streaming) {
    primary = running
      ? { label: t("Open"), icon: <IconExternalLink size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name }) }
      : { label: t("Start and open"), icon: <IconPlayerPlay size={17} />, onClick: () => job("Connect-GpuVM", { Name: vm.name }) };
  } else {
    primary = running
      ? { label: t("View console"), icon: <IconDeviceDesktop size={17} />, onClick: () => openConsole(vm.name) }
      : { label: t("Start"), icon: <IconPlayerPlay size={17} />, onClick: () => power("Start", t("Starting")) };
  }
  const consoleIsPrimary = !vm.streaming && running;
  const locked = !!working;

  return (
    <div className="card head scene-head">
      <div className="scene-wrap"><Scene name={vm.name} variant={variant} style={banner} state={vm.state}
        activity={{ cpu: vm.cpuPercent, gpu: vm.gpuPercent, mem: (vm.memoryDemandGB / Math.max(vm.memoryAssignedGB, 0.1)) * 100 }} /></div>
      <div className="head-info">
      <button type="button" className="pattern-btn" title={t("Another icon")} aria-label={t("Another icon")} onClick={onPattern}>
        <MachineIcon name={vm.name} variant={variant} size={48} radius={12} />
      </button>
      <div className="head-text">
        <h1>{vm.name}</h1>
        <div className="meta">
          <span className="state-pill"><span className={`dot ${vm.state}`} />{stateText(vm.state)}</span>
          {/* What the machine is, as small labeled pieces: its Windows, its GPU and the profile it was made from. In a
              narrow header they move to a row of their own under the icon and the name. */}
          <span className="specs">
            {vm.edition && <span className="spec-chip" title="Windows"><IconBrandWindows size={13} />{vm.edition}</span>}
            {vm.hasGpu && vm.gpuName && <span className="spec-chip" title="GPU"><IconBolt size={13} />{vm.gpuName.replace("NVIDIA GeForce ", "")}</span>}
            {vm.profile && <span className="spec-chip" title={t("Profile")}><IconLayoutGrid size={13} />{profileLabel(vm.profile)}</span>}
          </span>
          {short && <span className="warn-text">{t("It needs {gb} GB more free memory", { gb: vm.missingGB.toLocaleString(locale()) })}</span>}
        </div>
      </div>
      </div>
      <div className="actions" ref={menuRef}>
        {running && vm.managed && vm.guestCredential && (
          <button className="icon-btn" aria-label={t("Paste in the VM")} title={t("Paste in the VM what you copied on this PC")} disabled={pasting === "busy"}
            onClick={async () => {
              setPasting("busy");
              const ok = await run(vm.name, t("Pasting"), () => api.pasteToVm(vm.name));
              setPasting(ok ? "done" : null);
              if (ok) setTimeout(() => setPasting(null), 2000);
            }}>
            {pasting === "busy" ? <IconLoader2 size={18} className="spin" /> : pasting === "done" ? <IconCheck size={18} /> : <IconClipboardText size={18} />}
          </button>
        )}
        <button className="icon-btn" aria-label={t("More options")} aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu((m) => !m)}><IconDots size={18} /></button>
        {working ? (
          <span className="primary busy" role="status" title={working}><IconLoader2 size={17} className="spin" /><span className="ellipsis">{working}</span></span>
        ) : (
          <button className="primary" onClick={primary.onClick} disabled={primary.disabled} title={primary.title}>{primary.icon}<span className="ellipsis">{primary.label}</span></button>
        )}
        {menu && (
          <div className="menu" role="menu">
            {!locked && off && vm.streaming && (
              <button role="menuitem" onClick={() => power("Start", t("Starting"))}><IconPower size={16} />{t("Start without opening")}</button>
            )}
            {!locked && !off && (
              <>
                <button role="menuitem" onClick={() => job("Invoke-GpuVMPower", { Name: vm.name, Action: "Shutdown" })}><IconPower size={16} />{t("Shut down")}</button>
                <button role="menuitem" className={confirmOff ? "danger" : ""}
                  onClick={() => confirmOff ? power("TurnOff", t("Forcing shutdown")) : setConfirmOff(true)}>
                  <IconPlugOff size={16} />{confirmOff ? t("Force: unsaved work is lost") : t("Force shutdown")}
                </button>
                <button role="menuitem" onClick={() => power("Restart", t("Restarting"))}><IconRefresh size={16} />{t("Restart")}</button>
                {paused
                  ? <button role="menuitem" onClick={() => power("Resume", t("Resuming"))}><IconPlayerPlay size={16} />{t("Resume")}</button>
                  : <button role="menuitem" onClick={() => power("Pause", t("Pausing"))}><IconPlayerPause size={16} />{t("Pause")}</button>}
              </>
            )}
            {locked && vm.state !== "Off" && (
              <button role="menuitem" className={confirmOff ? "danger" : ""}
                onClick={() => confirmOff ? power("TurnOff", t("Forcing shutdown")) : setConfirmOff(true)}>
                <IconPlugOff size={16} />{confirmOff ? t("Force: unsaved work is lost") : t("Force shutdown")}
              </button>
            )}
            {!consoleIsPrimary && (
              <button role="menuitem" onClick={() => { setMenu(false); openConsole(vm.name); }}><IconDeviceDesktop size={16} />{t("View Hyper-V console")}</button>
            )}
            {!locked && vm.managed && vm.streaming && (
              <button role="menuitem" onClick={() => job("Connect-GpuVM", { Name: vm.name, Pair: true })}><IconLink size={16} />{t("Pair the viewer again")}</button>
            )}
            <hr />
            {!locked && vm.managed && (
              <button role="menuitem" onClick={() => job("Sync-GpuVMDriver", { Name: vm.name, Confirm: false, ShutdownIfRunning: true })}>
                <IconDownload size={16} />{off ? t("Update GPU driver") : t("Shut down and update driver")}
              </button>
            )}
            {!locked && vm.managed && !vm.disposable && (
              <button role="menuitem" onClick={() => { setMenu(false); setTemplating(true); }}>
                <IconTemplate size={16} />{off ? t("Create template") : t("Shut down and create template")}
              </button>
            )}
            {!locked && vm.managed && !vm.disposable && (
              <button role="menuitem" onClick={async () => {
                setMenu(false);
                const path = await pickExportFile(vm.name);
                if (path) startJob(vm.name, "Export-GpuVM", { Name: vm.name, Path: path, ShutdownIfRunning: true, Confirm: false });
              }}>
                <IconFileExport size={16} />{off ? t("Export to a file") : t("Shut down and export")}
              </button>
            )}
            {!locked && vm.managed && off && (
              <button role="menuitem" onClick={() => { setMenu(false); setRenaming(true); onRenameDraft(vm.name); }}><IconPencil size={16} />{t("Rename")}</button>
            )}
            <button role="menuitem" onClick={() => { setMenu(false); onPattern(); }}><IconPalette size={16} />{t("Another icon")}</button>
            <button role="menuitem" onClick={() => { setMenu(false); setBanner(nextSceneStyle(vm.name)); }}><IconLayoutBoard size={16} />{t("Another banner")}</button>
            {!locked && vm.managed && (
              <>
                <hr />
                <button role="menuitem" className="danger" onClick={() => { setMenu(false); setConfirm(true); }}><IconTrash size={16} />{t("Delete machine")}</button>
              </>
            )}
          </div>
        )}
      </div>
      {confirm && <ConfirmRemove vm={vm} run={run} onClose={() => setConfirm(false)} onRemoved={onRemoved} />}
      {renaming && (
        <RenameMachine vm={vm} vms={vms} onDraft={onRenameDraft}
          onClose={() => { setRenaming(false); onRenameDraft(null); }}
          onRename={(to) => {
            const from = vm.name;
            setRenaming(false);
            // The plate keeps the new name while the job runs; a failure engraves the old one back.
            onRenameDraft(to);
            startJob(from, "Rename-GpuVM", { Name: from, NewName: to, Confirm: false }, () => onRenamed?.(from, to), () => onRenameDraft(null));
          }} />
      )}
      {templating && (
        <NewTemplate vm={vm} onClose={() => setTemplating(false)}
          onCreate={(name, from) => { setTemplating(false); startJob(from, "New-GpuVMTemplate", { Name: name, VMName: from, ShutdownIfRunning: true, Confirm: false }); }} />
      )}
    </div>
  );
}

/** Names the template; the copy itself runs as a job on the machine (its button shows the progress). */
/** Save a machine's Windows as a template. From a machine's menu it is that machine; from the Library, `vms` lists the
 *  machines to pick from. */
export function NewTemplate({ vm: fixed, vms, onClose, onCreate }: {
  vm?: VmOverview; vms?: VmOverview[]; onClose: () => void; onCreate: (name: string, vm: string) => void;
}) {
  const [picked, setPicked] = useState<string>(fixed?.name ?? vms?.[0]?.name ?? "");
  const vm = fixed ?? vms?.find((v) => v.name === picked) ?? null;
  const [name, setName] = useState(`${fixed?.name ?? vms?.[0]?.name ?? "maquina"}-base`);
  const [named, setNamed] = useState(false);
  useEffect(() => { if (!named && vm) setName(`${vm.name}-base`); }, [vm?.name]);
  const [existing, setExisting] = useState<string[]>([]);
  useEffect(() => { api.templates().then((t) => setExisting(t.map((x) => x.name))).catch(() => {}); }, []);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  const trimmed = name.trim();
  const nameError = !trimmed ? "" : !/^[\w-]{1,40}$/.test(trimmed) ? t("Use letters, numbers or hyphens, no spaces")
    : existing.some((x) => x.toLowerCase() === trimmed.toLowerCase()) ? t("There's already a template with that name") : "";
  const complete = !!trimmed && !nameError && !!vm;
  const running = !!vm && vm.state !== "Off";
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={t("Create template")}>
        <div className="dialog-head"><MachineIcon name={`plantilla-${trimmed || vm?.name || "nueva"}`} size={40} radius={10} /><h2>{t("Create template")}</h2></div>
        <form className="dialog-form" onSubmit={(e) => { e.preventDefault(); if (complete && vm) onCreate(trimmed, vm.name); }}>
          <div className="dialog-body">
            {!fixed && (
              <div className="field">
                <div className="field-top"><span>{t("Machine")}</span></div>
                {vms && vms.length ? (
                  <Dropdown label={t("Machine")} value={picked} onChange={setPicked}
                    options={vms.map((v) => ({ value: v.name, label: v.name, detail: [v.edition, stateText(v.state)].filter(Boolean).join(" · "), icon: <MachineIcon name={v.name} size={22} radius={6} /> }))} />
                ) : <span className="hint">{t("Create a machine first: the template saves its Windows.")}</span>}
              </div>
            )}
            {vm && <p className="dialog-text">{t("Saves {name}'s Windows, with its apps and settings, to create other machines in seconds. {name} stays as it is.", { name: vm.name })}</p>}
            <div className="field">
              <label className="field-top" htmlFor="tpl-name"><span>{t("Name")}</span></label>
              <input id="tpl-name" className="text-input" value={name} autoFocus onChange={(e) => { setName(e.target.value); setNamed(true); }} />
              {nameError && <span className="error-text">{nameError}</span>}
            </div>
          </div>
          <div className="dialog-foot">
            <button type="button" className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
            <button type="submit" className="primary compact" disabled={!complete}><IconTemplate size={16} />{running ? t("Shut down and create") : t("Create template")}</button>
          </div>
        </form>
      </div>
    </div>
  );
}

/** Renames a machine that is off. The name is checked as it is typed, and the cube beside engraves it on its plate. */
function RenameMachine({ vm, vms, onClose, onDraft, onRename }: {
  vm: VmOverview; vms: VmOverview[]; onClose: () => void; onDraft: (name: string | null) => void; onRename: (name: string) => void;
}) {
  const [name, setName] = useState(vm.name);
  useEffect(() => {
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  const trimmed = name.trim();
  const nameError = vmNameError(trimmed, vms, vm.name);
  const complete = !nameError && trimmed !== vm.name;
  // The cube stays above the scrim to show the plate taking the name: the dialog is centered in the room left of it,
  // never over it.
  const [besideCube, setBesideCube] = useState<number | null>(null);
  useLayoutEffect(() => {
    const place = () => {
      const cube = document.querySelector(".vm-cube.lifted")?.getBoundingClientRect();
      setBesideCube(cube && cube.width ? window.innerWidth - cube.left + 16 : null);
    };
    place();
    window.addEventListener("resize", place);
    return () => window.removeEventListener("resize", place);
  }, []);
  // In a portal: inside the page, its fade would clip the scrim and the dialog.
  return createPortal(
    <div className="overlay" style={besideCube ? { paddingRight: besideCube } : undefined} onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={t("Rename {name}", { name: vm.name })}>
        <div className="dialog-head"><MachineIcon name={vm.name} size={40} radius={10} /><h2>{t("Rename")}</h2></div>
        <form className="dialog-form" onSubmit={(e) => { e.preventDefault(); if (complete) onRename(trimmed); }}>
          <div className="dialog-body">
            <p className="dialog-text">{t("Its folder and disk are renamed too. The viewer stays paired and shared disks stay connected.")}</p>
            <div className="field">
              <label className="field-top" htmlFor="vm-rename"><span>{t("Name")}</span></label>
              <input id="vm-rename" className="text-input" value={name} autoFocus spellCheck={false} maxLength={60}
                onFocus={(e) => e.currentTarget.select()}
                onChange={(e) => { setName(e.target.value); onDraft(e.target.value.trim() || vm.name); }} />
              {nameError && <span className="error-text">{nameError}</span>}
            </div>
          </div>
          <div className="dialog-foot">
            <button type="button" className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
            <button type="submit" className="primary compact" disabled={!complete}><IconPencil size={16} />{t("Rename")}</button>
          </div>
        </form>
      </div>
    </div>,
    portalRoot());
}

function ConfirmRemove({ vm, run, onClose, onRemoved }: { vm: VmOverview; run: Props["run"]; onClose: () => void; onRemoved: () => void }) {
  const [deleteDisk, setDeleteDisk] = useState(false);
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
    const key = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [onClose]);
  return (
    <div className="overlay" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="dialog narrow" role="dialog" aria-modal="true" aria-label={t("Delete {name}", { name: vm.name })}>
        <div className="dialog-head"><MachineIcon name={vm.name} size={40} radius={10} /><h2>{t("Delete {name}", { name: vm.name })}</h2></div>
        <p className="dialog-text">{t("The machine is removed from Hyper-V. This can't be undone.")}</p>
        <div className="choice-list" role="radiogroup">
          <button role="radio" aria-checked={!deleteDisk} className={`choice ${!deleteDisk ? "on" : ""}`} onClick={() => setDeleteDisk(false)}>
            <span className="check">{!deleteDisk && <CheckMark />}</span>
            <span className="grow"><span className="title">{t("Keep the disk")}</span><span className="desc">{t("You can use the .vhdx file again later.")}</span></span>
          </button>
          <button role="radio" aria-checked={deleteDisk} className={`choice ${deleteDisk ? "on" : ""}`} onClick={() => setDeleteDisk(true)}>
            <span className="check">{deleteDisk && <CheckMark />}</span>
            <span className="grow"><span className="title">{t("Delete the disk too")}</span><span className="desc">{t("Frees the space in the VM's folder.")}</span></span>
          </button>
        </div>
        <div className="dialog-foot">
          <button ref={cancelRef} className="btn ghost" onClick={onClose}>{t("Cancel")}</button>
          <button className="btn danger-fill" onClick={async () => {
            onClose();
            if (await run(vm.name, t("Deleting"), () => api.remove(vm.name, deleteDisk))) onRemoved();
          }}><IconTrash size={16} />{t("Delete")}</button>
        </div>
      </div>
    </div>
  );
}

function GuestPassword({ vm, run }: { vm: VmOverview; run: Props["run"] }) {
  const [password, setPassword] = useState("");
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  return (
    <div className="notice info">
      <IconKey size={20} />
      <div className="grow">
        {t("Save this machine's Windows password so GpuVM can fix problems inside it without asking you.")}
        <span className="notice-sub">{t("User: {user}", { user: "gpuvm" })}</span>
      </div>
      <form className="notice-form" onSubmit={async (e) => {
        e.preventDefault();
        if (!password) { setError(t("Type the password")); return; }
        setError("");
        setSaving(true);
        await run(vm.name, t("Saving"), () => api.saveGuestPassword(vm.name, "gpuvm", password));
        setSaving(false);
      }}>
        <div className="field-stack">
          <input type="password" aria-label={t("Windows password")} placeholder={t("Windows password")} value={password}
            onChange={(e) => { setPassword(e.target.value); setError(""); }} />
          {error && <span className="error-text">{error}</span>}
        </div>
        <button className="btn" type="submit" disabled={saving}>
          {saving ? <IconLoader2 size={16} className="spin" /> : <IconDeviceFloppy size={16} />}{saving ? t("Saving") : t("Save")}
        </button>
      </form>
    </div>
  );
}

/** The drive as it would be with this disk at sizeGB and every VM disk full: this machine, what the other machines'
 * disks can still take, and what would be left. Changes as the slider moves. */
export function DiskRoom({ budget, sizeGB }: { budget: DiskBudget; sizeGB: number }) {
  const used = budget.usedGB ?? 0;
  const ownPromised = Math.max(0, sizeGB - used);
  // What the drive has now, split: this VM's file, its unwritten part, the others' unwritten parts, what is left.
  const total = used + budget.freeGB;
  const left = Math.max(0, budget.freeGB - budget.promisedGB - ownPromised);
  const pct = (gb: number) => `${Math.max(0, Math.min(100, (gb / Math.max(1, total)) * 100))}%`;
  const others = budget.others.map((o) => o.vm).join(", ");
  const gb = (n: number) => `${Math.round(n).toLocaleString(locale())} GB`;
  return (
    <div className="disk-room">
      <div className="disk-bar" role="img" aria-label={t("{drive} would have {free} free with every disk full", { drive: budget.drive, free: gb(left) })}>
        <span className="seg own" style={{ width: pct(used) }} />
        <span className="seg own-room" style={{ width: pct(ownPromised) }} />
        <span className="seg others" style={{ width: pct(budget.promisedGB) }} />
      </div>
      <ul className="disk-legend">
        <li><i className="own" />{t("This machine, {used} used of {size}", { used: gb(used), size: gb(sizeGB) })}</li>
        {budget.promisedGB > 0 && <li><i className="others" />{t("Reserved for {who}, {size}", { who: others || t("other machines"), size: gb(budget.promisedGB) })}</li>}
        <li><i className="free" />{t("Free on {drive} with everything full, {free}", { drive: budget.drive, free: gb(left) })}</li>
      </ul>
    </div>
  );
}

/** One option: icon, name and a short line that explains it, with its control at the right (or below, `wide`). */
function OptionRow({ icon, title, value, desc, wide, section, sub, below, children }: {
  icon: React.ReactNode; title: string; value?: string; desc: string; wide?: boolean; below?: React.ReactNode; children?: React.ReactNode;
  /** Heads a group whose rows it changes (Tipo de uso); `sub` rows belong to the group above. */
  section?: boolean; sub?: boolean;
}) {
  return (
    <div className={`opt-row${wide ? " wide" : ""}${section ? " section" : ""}${sub ? " sub" : ""}`}>
      <span className="opt-icon">{icon}</span>
      <div className="opt-text">
        <span className="opt-title">{title}{value && <strong>{value}</strong>}</span>
        <span className="opt-desc">{desc}</span>
      </div>
      {children && <div className="opt-ctl">{children}</div>}
      {below && <div className="opt-below">{below}</div>}
    </div>
  );
}

/** The machine's settings, in two parts: "machine" (resources and network) and "display" (use, picture, connection). */
function Options({ part, vm, host, busy, startJob, run, onPreview }: Pick<Props, "vm" | "host" | "busy" | "startJob" | "run"> & {
  part: "machine" | "display";
  onPreview?: (r: { cpu: number; memoryGB: number; gpuPercent: number; diskGB: number }) => void;
}) {
  const initial = {
    cpu: vm.options!.cpu, memoryGB: vm.options!.memoryGB, gpuPercent: vm.options!.gpuPercent, diskGB: vm.options!.diskGB,
    resolution: vm.client?.resolution ?? "1920x1080", fps: vm.client?.fps ?? 60,
    displayMode: (vm.client?.displayMode === "windowed" ? "windowed" : "fullscreen") as DisplayMode,
    // Unset = Moonlight's own defaults.
    vsync: vm.client?.vsync ?? true,
    framePacing: vm.client?.framePacing ?? false,
    mouse: (vm.client?.mouse ?? "capture") as MouseMode,
    codec: vm.client?.codec ?? "auto",
    bitrateKbps: vm.client?.bitrateKbps ?? 0,
    captureMode: vm.options!.captureMode ?? "wgc",
    networkIsolation: vm.options!.networkIsolation ?? true,
    // "default": the monitor chosen in Preferences.
    monitor: vm.client?.monitor ?? "default",
    forAgents: vm.forAgents ?? false,
    agentUser: vm.agent?.user ?? "agent",
  };
  const [draft, setDraft] = useState(initial);
  const [saved, setSaved] = useState(false);
  const key = JSON.stringify(initial);
  useEffect(() => setDraft(JSON.parse(key)), [key]);
  useEffect(() => onPreview?.({ cpu: draft.cpu, memoryGB: draft.memoryGB, gpuPercent: draft.gpuPercent, diskGB: draft.diskGB }), [draft.cpu, draft.memoryGB, draft.gpuPercent, draft.diskGB]);
  useEffect(() => { if (!saved) return; const t = setTimeout(() => setSaved(false), 2500); return () => clearTimeout(t); }, [saved]);

  const hostCpu = host?.logicalProcessors ?? 12;
  const hostMem = Math.round(host?.memoryGB ?? 16);
  const maxCpu = Math.max(2, hostCpu - 1);
  const maxMem = Math.max(4, hostMem - 4);
  // A disk only grows, and never past what the drive can hold once every VM disk on it is full (the module checks
  // the same limit). Without the budget (older module), the old rule.
  const budget = vm.options!.diskBudget ?? null;
  const maxDisk = budget ? Math.max(initial.diskGB, Math.floor(budget.maxGB / 8) * 8)
    : Math.max(initial.diskGB, Math.min(1024, initial.diskGB + (vm.options!.diskType === "Fixed" ? vm.options!.diskFreeGB - 10 : 1024)));
  const vmDirty = draft.cpu !== initial.cpu || draft.memoryGB !== initial.memoryGB || draft.gpuPercent !== initial.gpuPercent || draft.diskGB !== initial.diskGB;
  const streamKeys = ["vsync", "framePacing", "mouse", "codec", "bitrateKbps"] as const;
  const streamChanges: StreamSettings = Object.fromEntries(streamKeys.filter((k) => draft[k] !== initial[k]).map((k) => [k, draft[k]]));
  const clientDirty = draft.resolution !== initial.resolution || draft.fps !== initial.fps || draft.displayMode !== initial.displayMode
    || Object.keys(streamChanges).length > 0;
  const use = streamUseOf(draft);
  // "Custom" picked by hand stays chosen until a use is picked; a change by hand also lands there.
  const [customUse, setCustomUse] = useState(false);
  const shownUse = customUse ? null : use;
  const [advanced, setAdvanced] = useState(false);
  const captureDirty = draft.captureMode !== initial.captureMode;
  const networkDirty = draft.networkIsolation !== initial.networkIsolation;
  const monitorDirty = draft.monitor !== initial.monitor;
  const agentDirty = draft.forAgents !== initial.forAgents || draft.agentUser !== initial.agentUser;
  const monitors = useMonitors();
  const prefs = usePrefs();
  const off = vm.state === "Off";

  const save = async () => {
    if (clientDirty && !(await run(vm.name, t("Saving"), () => api.setClient(vm.name, draft.resolution, draft.fps, draft.displayMode !== initial.displayMode ? draft.displayMode : undefined, streamChanges)))) return;
    if (captureDirty && !(await run(vm.name, t("Changing capture"), () => api.setCapture(vm.name, draft.captureMode)))) return;
    if (networkDirty && !(await run(vm.name, t("Changing network"), () => api.setNetworkIsolation(vm.name, draft.networkIsolation)))) return;
    if (monitorDirty && !(await run(vm.name, t("Saving"), () => api.setMonitor(vm.name, draft.monitor)))) return;
    if (draft.forAgents !== initial.forAgents && !(await run(vm.name, t("Saving"), () => agents.setUse(vm.name, draft.forAgents ? "agent" : null)))) return;
    if (draft.agentUser !== initial.agentUser && !(await run(vm.name, t("Saving"), () => agents.setUser(vm.name, draft.agentUser)))) return;
    // A machine made for agents without the guest agent gets it now (its own job, with its steps on the button).
    if (draft.forAgents && !initial.forAgents && !vm.agent?.installed) { startJob(vm.name, "Install-GpuVMAgent", { Name: vm.name, User: draft.agentUser }); return; }
    if (!vmDirty) { setSaved(true); return; }
    const override = {
      vm: { cpu: { count: draft.cpu }, memoryGB: draft.memoryGB, disk: { sizeGB: draft.diskGB } },
      gpu: { allocationPercent: draft.gpuPercent },
    };
    if (off) { if (await run(vm.name, t("Applying"), () => api.applyOptions(vm.name, override))) setSaved(true); }
    else startJob(vm.name, "Update-GpuVMSettings", { Name: vm.name, Override: override });
  };

  return (
    <div className="card">
      <div className="opt-rows">
        {part === "machine" && (
          <>
        <OptionRow icon={<IconCpu size={17} />} title={t("Processor")} value={t("{n} threads", { n: draft.cpu })} desc={t("{n} threads left for your PC", { n: hostCpu - draft.cpu })}>
          <Slider label={t("Threads")} value={Math.min(draft.cpu, maxCpu)} min={2} max={maxCpu} onChange={(cpu) => setDraft({ ...draft, cpu })} />
        </OptionRow>
        <OptionRow icon={<IconTopologyStar3 size={17} />} title={t("Memory")} value={`${draft.memoryGB} GB`} desc={t("{n} GB left for your PC, all reserved at start", { n: hostMem - draft.memoryGB })}>
          <Slider label={t("Memory")} value={Math.min(draft.memoryGB, maxMem)} min={4} max={maxMem} onChange={(memoryGB) => setDraft({ ...draft, memoryGB })} />
        </OptionRow>
        <OptionRow icon={<IconBolt size={17} />} title={t("GPU for the VM")} value={`${draft.gpuPercent} %`} desc={draft.gpuPercent === 100 ? t("Can use the whole GPU, shared with your PC") : t("Up to {n} % of the GPU", { n: draft.gpuPercent })}>
          <Slider label="GPU" value={draft.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => setDraft({ ...draft, gpuPercent })} />
        </OptionRow>
        <OptionRow icon={<IconDeviceFloppy size={17} />} title={t("Disk")} value={`${draft.diskGB} GB`}
          desc={vm.options!.diskType === "Differencing" ? t("Built on a template, same size as it")
            : maxDisk > initial.diskGB ? t("Can grow, not shrink") : t("No free space on this PC to grow it")}
          below={budget && vm.options!.diskType !== "Differencing" ? <DiskRoom budget={budget} sizeGB={draft.diskGB} /> : undefined}>
          {vm.options!.diskType !== "Differencing" && maxDisk > initial.diskGB
            && <Slider label={t("Disk")} value={draft.diskGB} min={initial.diskGB} max={maxDisk} step={8} onChange={(diskGB) => setDraft({ ...draft, diskGB })} />}
        </OptionRow>
        <OptionRow icon={<IconWorld size={17} />} title={t("Network")} desc={draft.networkIsolation
          ? t("The VM can't reach this PC or your local network. If it gets infected, it can't get out.")
          : t("The VM can reach this PC and the others on your network. Use it only if you need, say, a NAS.")}>
          <Segmented value={draft.networkIsolation} onChange={(networkIsolation) => setDraft({ ...draft, networkIsolation })} options={[
            { value: true, label: <><IconWorld size={15} />{t("Internet only")}</> },
            { value: false, label: <><IconNetwork size={15} />{t("Internet and local network")}</> },
          ]} />
        </OptionRow>
          </>
        )}
        {part === "display" && (
          <>
        {vm.streaming && (
          // Five uses: a list with each one's icon and what it's for (a row of five doesn't fit).
          <OptionRow icon={<IconDeviceGamepad2 size={17} />} title={t("Use|machine")} section
            desc={draft.forAgents ? AGENT_USE.description : shownUse ? USES.find((u) => u.id === shownUse)!.description : t("Set by hand. Pick a use to go back to its values.")}>
            <Dropdown<string> short label={t("Use|machine")} value={draft.forAgents ? AGENT_USE.id : shownUse ?? "custom"} onChange={(id) => {
              if (id === "custom") { setCustomUse(true); setDraft({ ...draft, forAgents: false }); return; }
              setCustomUse(false);
              if (id === AGENT_USE.id) setDraft({ ...draft, ...AGENT_USE.client, resolution: AGENT_USE.resolution, networkIsolation: true, forAgents: true });
              else setDraft({ ...draft, ...USES.find((u) => u.id === id)!.client, forAgents: false });
            }} options={[...USES.map((u) => ({ value: u.id as string, label: u.label, detail: u.description, icon: <u.icon size={16} /> })),
              { value: AGENT_USE.id, label: AGENT_USE.label, detail: AGENT_USE.description, icon: <AGENT_USE.icon size={16} /> },
              { value: "custom", label: t("Custom"), detail: t("Set by hand. Pick a use to go back to its values."), icon: <IconAdjustments size={16} /> }]} />
          </OptionRow>
        )}
        {vm.streaming && draft.forAgents && (
          <OptionRow sub icon={<IconUser size={17} />} title={t("Agents' Windows user")} desc={draft.agentUser === "agent"
            ? t("Agents work as a standard user of their own. Your files and sessions stay out of their reach.")
            : t("Agents work as you, with your files, saved passwords and open sessions. Use it only on a machine with nothing of yours.")}>
            <Segmented value={draft.agentUser} onChange={(agentUser) => setDraft({ ...draft, agentUser })} options={[
              { value: "agent", label: <><IconUserShield size={15} />{t("A user of their own")}</> },
              { value: "own", label: <><IconUser size={15} />{t("My user")}</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconGauge size={17} />} title={t("Frames per second")}
            desc={draft.fps === 0 ? t("Always at the pace of the monitor it opens on") : t("Fixed {n} FPS", { n: draft.fps })}>
            <FpsPicker value={draft.fps} monitor={resolveMonitor(monitors, draft.monitor, prefs.monitor)} onChange={(fps) => setDraft({ ...draft, fps })} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconRectangle size={17} />} title={t("Vertical sync")} desc={draft.vsync
            ? t("Every frame reaches the monitor whole. At the monitor's pace it adds no wait.")
            : t("Each frame goes out as soon as it arrives, even if the monitor is halfway through drawing the last one.")}>
            <Segmented value={draft.vsync} onChange={(vsync) => setDraft({ ...draft, vsync, framePacing: vsync && draft.framePacing })} options={[
              { value: true, label: <><IconRectangle size={15} />{t("Whole picture")}</> },
              { value: false, label: <><IconBolt size={15} />{t("Faster")}</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconWaveSine size={17} />} title={t("Frame pacing")} desc={!draft.vsync
            ? t("Only with the whole picture.")
            : draft.framePacing ? t("Spaces frames at a steady pace, ideal at 60 FPS.") : t("Shows each frame as soon as it's ready.")}>
            <div className={`segment-row${draft.vsync ? "" : " disabled"}`}>
              <Segmented value={draft.framePacing} onChange={(framePacing) => draft.vsync && setDraft({ ...draft, framePacing })} options={[
                { value: true, label: <><IconWaveSine size={15} />{t("Even")}</> },
                { value: false, label: <><IconPlayerTrackNext size={15} />{t("Instant")}</> },
              ]} />
            </div>
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow sub icon={<IconPointer size={17} />} title={t("Mouse")} desc={draft.mouse === "capture"
            ? t("The VM takes the mouse, as games need to turn the camera. Ctrl+Alt+Shift+Z releases it without closing.")
            : t("The pointer moves in and out of the window as in remote desktop. Doesn't work in most games.")}>
            <Segmented value={draft.mouse} onChange={(mouse) => setDraft({ ...draft, mouse })} options={[
              { value: "capture", label: <><IconDeviceGamepad2 size={15} />{t("For games")}</> },
              { value: "absolute", label: <><IconPointer size={15} />{t("Free")}</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconDeviceDesktop size={17} />} title={t("Resolution")} desc={t("Size of the machine's picture")}>
            <Segmented value={draft.resolution} onChange={(resolution) => setDraft({ ...draft, resolution })}
              options={(RESOLUTIONS.includes(draft.resolution) ? RESOLUTIONS : [draft.resolution, ...RESOLUTIONS]).map((r) => ({ value: r, label: r.split("x")[1] + "p" }))} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconArrowsMaximize size={17} />} title={t("Window")}
            desc={draft.displayMode === "fullscreen" ? t("Fills the whole monitor") : t("Opens in a window you can move")}>
            <Segmented value={draft.displayMode} onChange={(displayMode) => setDraft({ ...draft, displayMode })} options={[
              { value: "fullscreen", label: <><IconArrowsMaximize size={15} />{t("Full screen")}</> },
              { value: "windowed", label: <><IconAppWindow size={15} />{t("Window")}</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && monitors.length > 1 && (
          <OptionRow icon={<IconScreenShare size={17} />} title={t("Open on")} desc={t("Monitor the machine opens on")}>
            <MonitorPicker monitors={monitors} value={draft.monitor} inherited={prefs.monitor} onChange={(monitor) => setDraft({ ...draft, monitor })} />
          </OptionRow>
        )}
        {vm.streaming && (
          <OptionRow icon={<IconScreenShare size={17} />} title={t("Capture")} desc={draft.captureMode === "wgc"
            ? t("The picture shows up as soon as you connect and exclusive full-screen games are visible. Windows admin prompts are answered from GpuVM.")
            : t("Admin prompts show in the viewer, but the picture can take a while to appear when connecting and exclusive full-screen games show black.")}>
            <Segmented value={draft.captureMode} onChange={(captureMode) => setDraft({ ...draft, captureMode })} options={[
              { value: "wgc", label: <><IconBolt size={15} />{t("Fast")}</> },
              { value: "ddx", label: <><IconScreenShare size={15} />{t("Classic")}</> },
            ]} />
          </OptionRow>
        )}
        {vm.streaming && (
          <button type="button" className="disclosure opt-disclosure" aria-expanded={advanced} onClick={() => setAdvanced(!advanced)}>
            <IconChevronRight size={15} />{t("Advanced")}
          </button>
        )}
        {vm.streaming && advanced && (
          <>
            <OptionRow icon={<IconAppWindow size={17} />} title={t("Codec")}
              desc={draft.codec === "auto" ? t("The viewer picks the best one your PC can show.") : t("If the picture doesn't appear, go back to Automatic.")}>
              <Segmented value={draft.codec} onChange={(codec) => setDraft({ ...draft, codec })} options={CODECS} />
            </OptionRow>
            <OptionRow icon={<IconSparkles size={17} />} title={t("Picture quality")} value={draft.bitrateKbps ? `${draft.bitrateKbps / 1000} Mbps` : t("Automatic")}
              desc={t("More quality uses more network. At the minimum, the viewer sets it from the resolution and FPS.")}>
              <Slider label={t("Picture quality")} value={draft.bitrateKbps / 1000} min={0} max={150} step={5} format={(v) => (v ? String(v) : "Auto")}
                onChange={(mbps) => setDraft({ ...draft, bitrateKbps: mbps * 1000 })} />
            </OptionRow>
          </>
        )}
          </>
        )}
      </div>
      {(vmDirty || clientDirty || captureDirty || networkDirty || monitorDirty || agentDirty || saved) && (
        <div className="options-foot">
          {saved && !vmDirty && !clientDirty && !captureDirty && !networkDirty && !monitorDirty && !agentDirty ? (
            <span className="saved"><IconCheck size={16} />{t("Saved|settings")}</span>
          ) : (
            <>
              <button className="btn ghost" onClick={() => setDraft(initial)}>{t("Discard")}</button>
              <button className="primary compact" disabled={!!busy} onClick={save}>
                <IconDeviceFloppy size={16} />{vmDirty && !off ? t("Shut down and apply") : t("Save")}
              </button>
            </>
          )}
        </div>
      )}
    </div>
  );
}

/** The space the machine is in: changing it moves the machine there, and the cube takes that space's ambient. */
function SpaceRow({ name, vms }: { name: string; vms: VmOverview[] }) {
  const spaces = useSpaces();
  const space = useSpaceOf(name);
  const Icon = ambientInfo(space.ambient).icon;
  const [creating, setCreating] = useState(false);
  return (
    <div className="opt-row">
      <span className="opt-icon"><Icon size={17} /></span>
      <div className="opt-text">
        <span className="opt-title">{t("Space")}</span>
        <span className="opt-desc">{t("Where it sits with other machines, and its ambience. On Home they show together.")}</span>
      </div>
      <div className="opt-ctl space-row-ctl">
        <Dropdown label={t("Space")} value={space.id} onChange={(id) => (id === NEW_SPACE ? setCreating(true) : moveToSpace(name, id))}
          options={[...spaces.map((x) => { const I = ambientInfo(x.ambient).icon; return { value: x.id, label: x.name, detail: ambientInfo(x.ambient).name, icon: <I size={16} /> }; }),
            { value: NEW_SPACE, label: t("New space"), detail: t("With {name} and its own ambience", { name }), icon: <IconPlus size={16} /> }]} />
        <button type="button" className="btn ghost" onClick={() => { showSpace(space.id); location.hash = encodeURIComponent(":home"); }}>{t("View space")}</button>
      </div>
      {creating && createPortal(<SpaceDialog vms={vms} initialMachines={[name]} onClose={() => setCreating(false)} />, portalRoot())}
    </div>
  );
}

/** A tiny cube with the face it shows filled, so each fixed view says which side it is. */
function FaceGlyph({ face }: { face: CubeView }) {
  const faces: Record<CubeView, string> = {
    front: "M3 6h7v7H3z", right: "M10 6l3-3v7l-3 3z", top: "M3 6l3-3h7l-3 3z", back: "M6 3h7v7H6z", left: "M3 6l3-3v7l-3 3z",
  };
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M3 6h7v7H3zM3 6l3-3h7l-3 3M10 6l3-3v7l-3 3" fill="none" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round" opacity=".55" />
      <path d={faces[face]} fill="currentColor" opacity=".9" stroke="currentColor" strokeWidth="1.1" strokeLinejoin="round" />
    </svg>
  );
}
