// The app's real components for the website, running on the same sample data used to design the app (mock.ts): the
// machine's cube (the hero, the machine's options, Customize), the games, Home, the Windows cleanup, the stream
// options, the administrator card and the whole app in a window. Each one mounts in a Shadow DOM with the app's own
// styles, so neither the site's CSS nor the app's leak into each other. They all follow the page's language, light or
// dark mode, accent and world (configure()), and the app's own Settings change the page back ("gpuvm-embed-prefs").
// Built by vite.embed.config.ts into site/assets/embed.js.
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { api, onJob, startJob as runJob } from "./api";
import { App } from "./App";
import { Home } from "./Home";
import { readPrefs, resolvedTheme, savePrefs, type AccentPref } from "./prefs";
import { setPortalRoot, Segmented, Slider } from "./ui";
import { Cleanup, SharedDisks, Apps, type JobInfo } from "./VmView";
import { PromptCard } from "./PromptCard";
import { FpsPicker, MONITOR_FPS, USES, streamUseOf } from "./pickers";
import { setLang as setI18nLang, getLang, t, type Lang } from "./i18n";
import { showSamplePrompt } from "./mock";
import { MachineCube, cubeOf, type CubeMachine } from "./MachineCube";
import { Customize, useDecorEdit } from "./Customize";
import { SpaceWithGames } from "./GameStage";
import { randomDecor } from "./decor/random";
import { draftSource, useSource, type Decor } from "./decor/store";
import type { AmbientId, AmbientTime } from "./ambient";
import {
  IconAdjustments, IconBolt, IconCpu, IconDeviceGamepad2, IconGauge, IconPlayerTrackNext, IconPointer, IconRectangle, IconTopologyStar3, IconWaveSine,
} from "@tabler/icons-react";
import type { HostMonitor, MouseMode, VmOverview } from "./types";
import appCss from "./styles.css?inline";
import { BAR, GLYPHS, MachineDesktop, PAINT_COLORS, SITE, browserLayout, paintLayout, stageBox, termBar,
  type BrowserStage, type Frac, type Kind, type PaintStage, type PaintTool, type Stage, type StageWindow, type TermStage } from "./MachineDesktop";
import { LiveOverlay, type LiveEvent } from "./LiveOverlay";
import { StatusRow, type StatusItem } from "./StatusNotch";
import { ViewerPanel } from "./ViewerPanel";

type View = "app" | "home" | "cleanup" | "apps" | "shared" | "stream" | "prompt" | "cube" | "machine" | "customize" | "games" | "viewer" | "agents";
type Theme = "light" | "dark";
interface Site { lang: Lang; theme: Theme; accent: AccentPref; world: AmbientId; time: AmbientTime; dice: number }
interface RunningJob extends JobInfo { vm: string; after?: () => void }

/* ---------- What the page decides: language, mode, accent and world ---------- */

let site: Site = { lang: "es", theme: "light", accent: "blue", world: "blocks", time: "day", dice: 0 };
const siteSubs = new Set<() => void>();
const useSite = () => useSyncExternalStore((l) => { siteSubs.add(l); return () => { siteSubs.delete(l); }; }, () => site);
const hosts = new Set<HTMLElement>();
const paintHosts = () => hosts.forEach((el) => { el.dataset.theme = site.theme; el.dataset.accent = site.accent; });

// Sample decorations and spaces, the same the screenshots use, so Home and the app show decorated machines in worlds.
const SEED = "gpuvm.site.seed";
const DECOR: Record<string, Decor> = {
  win10: { color: "violet", led: { text: "PLAYER ONE", color: "amber", live: false, y: 0.35 },
    stickers: [{ id: "s1", sticker: "logo", face: "front", u: -0.45, v: 0.35, rot: -8, size: 0.62 }, { id: "s2", sticker: "bolt", face: "right", u: 0.3, v: 0.1, rot: 12, size: 0.6 }],
    figures: [{ id: "f1", figure: "cat", x: 0.45, z: -0.35, rot: -20, size: 1.05 }, { id: "f2", figure: "succulent", x: -0.45, z: 0.4, rot: 10, size: 0.95 }] },
  "win11-pruebas": { color: "teal", led: { text: "RTX ON", color: "green", live: false, y: 0.2 },
    stickers: [{ id: "s3", sticker: "rocket", face: "front", u: 0.4, v: 0.3, rot: 10, size: 0.65 }], figures: [{ id: "f3", figure: "robot", x: -0.4, z: -0.3, rot: 25, size: 1 }] },
  estudio: { color: "amber", led: null, stickers: [{ id: "s4", sticker: "heart", face: "left", u: 0, v: 0.2, rot: -6, size: 0.6 }], figures: [{ id: "f4", figure: "bunny", x: 0.4, z: 0.35, rot: -15, size: 1 }] },
} as Record<string, Decor>;
const LAB_NAME = { es: "Laboratorio", en: "Lab" };
function seed() {
  try {
    if (localStorage.getItem(SEED)) return;
    localStorage.setItem(SEED, "1");
    for (const [name, d] of Object.entries(DECOR)) localStorage.setItem(`gpuvm.decor.${name}`, JSON.stringify(d));
    localStorage.setItem("gpuvm.spaces", JSON.stringify([
      { id: "main", name: "My machines", ambient: "blocks", time: "day", machines: ["win10", "win11-pruebas"] },
      { id: "lab", name: LAB_NAME[site.lang], ambient: "board", machines: ["estudio"] },
    ]));
    localStorage.setItem("gpuvm.space.shown", "main");
  } catch { /* no storage: the demos still run, undecorated */ }
}
// The sample space keeps a name in the page's language (until someone renames it in the app).
function renameLab(lang: Lang) {
  try {
    const list = JSON.parse(localStorage.getItem("gpuvm.spaces") ?? "[]");
    const lab = Array.isArray(list) && list.find((s: { id: string; name: string }) => s.id === "lab" && Object.values(LAB_NAME).includes(s.name));
    if (lab) { lab.name = LAB_NAME[lang]; localStorage.setItem("gpuvm.spaces", JSON.stringify(list)); window.dispatchEvent(new Event("gpuvm-spaces")); }
  } catch { /* no storage */ }
}

/** The page changed something: every demo follows (the app's preferences too, so its own Settings show it). */
function configure(change: Partial<Omit<Site, "dice">>) {
  const next = { ...site, ...change };
  const langChanged = next.lang !== site.lang;
  if (langChanged) { setI18nLang(next.lang); renameLab(next.lang); }
  site = next;
  paintHosts();
  const prefs = readPrefs();
  if (prefs.theme !== site.theme || prefs.accent !== site.accent || prefs.lang !== site.lang) savePrefs({ theme: site.theme, accent: site.accent, lang: site.lang });
  document.documentElement.dataset.theme = site.theme;
  siteSubs.forEach((l) => l());
}
/** "Decorate at random" on the hero's cube. */
function randomize() { site = { ...site, dice: site.dice + 1 }; siteSubs.forEach((l) => l()); }

// The app's own Settings (in the window demo) changed the theme, accent or language: the page follows.
window.addEventListener("gpuvm-prefs", () => {
  const p = readPrefs();
  const theme = resolvedTheme(p.theme), lang = p.lang === "system" ? site.lang : p.lang;
  if (theme === site.theme && p.accent === site.accent && lang === site.lang) return;
  configure({ theme, accent: p.accent, lang });
  window.dispatchEvent(new CustomEvent("gpuvm-embed-prefs", { detail: { theme, accent: p.accent, lang } }));
});

/* ---------- Jobs shared by every demo, like the app's ---------- */

let jobs: Record<string, RunningJob> = {};
const listeners = new Set<() => void>();
const changed = () => listeners.forEach((l) => l());
onJob((e) => {
  const job = jobs[e.jobId];
  if (!job) return;
  if (e.type === "result") {
    const { [e.jobId]: done, ...rest } = jobs;
    jobs = rest;
    done.after?.();
  } else if (e.message) {
    jobs = { ...jobs, [e.jobId]: { ...job, message: e.message, log: [...job.log, e.message] } };
  }
  changed();
});
function start(vm: string, cmd: string, args: Record<string, unknown>, after?: () => void) {
  const id = `${cmd}-${Date.now()}`;
  jobs = { ...jobs, [id]: { vm, cmd, message: t("Working"), log: [], after } };
  changed();
  runJob(id, cmd, args);
}

/* ---------- Pieces of the machine's page, as the app draws them ---------- */

function OptionRow({ icon, title, value, desc, section, sub, children }: {
  icon: ReactNode; title: string; value?: string; desc: string; section?: boolean; sub?: boolean; children?: ReactNode;
}) {
  return (
    <div className={`opt-row${section ? " section" : ""}${sub ? " sub" : ""}`}>
      <span className="opt-icon">{icon}</span>
      <div className="opt-text">
        <span className="opt-title">{title}{value && <strong>{value}</strong>}</span>
        <span className="opt-desc">{desc}</span>
      </div>
      {children && <div className="opt-ctl">{children}</div>}
    </div>
  );
}

const MONITOR: HostMonitor = { id: "demo", name: "KG241Y S", primary: true, x: 0, y: 0, width: 1920, height: 1080, hz: 180 } as HostMonitor;

// How the machine streams: its use heads the group and sets the rows under it, as in the machine's options.
function Stream({ vm }: { vm: VmOverview }) {
  const [draft, setDraft] = useState({ fps: vm.client?.fps ?? MONITOR_FPS, vsync: vm.client?.vsync ?? true, framePacing: vm.client?.framePacing ?? false,
    mouse: (vm.client?.mouse ?? "capture") as MouseMode });
  const [custom, setCustom] = useState(false);
  const use = custom ? null : streamUseOf(draft);
  return (
    <div className="card opt-rows">
      <OptionRow icon={<IconDeviceGamepad2 size={17} />} title={t("Use|machine")} section
        desc={use ? USES.find((u) => u.id === use)!.description : t("Set by hand. Pick a use to go back to its values.")}>
        <Segmented value={use ?? "custom"} onChange={(id) => {
          if (id === "custom") { setCustom(true); return; }
          setCustom(false);
          setDraft({ ...draft, ...USES.find((u) => u.id === id)!.client });
        }} options={[...USES.map((u) => ({ value: u.id as string, label: <><u.icon size={15} />{u.label}</> })),
          { value: "custom", label: <><IconAdjustments size={15} />{t("Custom")}</> }]} />
      </OptionRow>
      <OptionRow sub icon={<IconGauge size={17} />} title={t("Frames per second")}
        desc={draft.fps === 0 ? t("Always at the pace of the monitor it opens on") : t("Fixed {n} FPS", { n: draft.fps })}>
        <FpsPicker value={draft.fps} monitor={MONITOR} onChange={(fps) => setDraft({ ...draft, fps })} />
      </OptionRow>
      <OptionRow sub icon={<IconRectangle size={17} />} title={t("Vertical sync")} desc={draft.vsync
        ? t("Every frame reaches the monitor whole. At the monitor's pace it adds no wait.")
        : t("Each frame goes out as soon as it arrives, even if the monitor is halfway through drawing the last one.")}>
        <Segmented value={draft.vsync} onChange={(vsync) => setDraft({ ...draft, vsync, framePacing: vsync && draft.framePacing })} options={[
          { value: true, label: <><IconRectangle size={15} />{t("Whole picture")}</> },
          { value: false, label: <><IconBolt size={15} />{t("Faster")}</> },
        ]} />
      </OptionRow>
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
      <OptionRow sub icon={<IconPointer size={17} />} title={t("Mouse")} desc={draft.mouse === "capture"
        ? t("The VM takes the mouse, as games need to turn the camera. Ctrl+Alt+Shift+Z releases it without closing.")
        : t("The pointer moves in and out of the window as in remote desktop. Doesn't work in most games.")}>
        <Segmented value={draft.mouse} onChange={(mouse) => setDraft({ ...draft, mouse })} options={[
          { value: "capture", label: <><IconDeviceGamepad2 size={15} />{t("For games")}</> },
          { value: "absolute", label: <><IconPointer size={15} />{t("Free")}</> },
        ]} />
      </OptionRow>
    </div>
  );
}

// The card over Moonlight with a sample prompt. Answering it shows the next one, as another program would ask.
function Prompt() {
  const [round, setRound] = useState(0);
  return (
    <div className="prompt-demo" onClickCapture={(e) => {
      if ((e.target as HTMLElement).closest("button")) setTimeout(() => setRound((r) => r + 1), 1400);
    }}>
      <PromptCard key={round} />
    </div>
  );
}

/** The sample machines, refreshed whenever a job ends. */
function useVms() {
  const [vms, setVms] = useState<VmOverview[]>([]);
  const [, tick] = useState(0);
  const refresh = useCallback(() => api.overview().then((v) => setVms([...v])), []);
  useEffect(() => {
    refresh();
    const update = () => { tick((n) => n + 1); refresh(); };
    listeners.add(update);
    return () => { listeners.delete(update); };
  }, [refresh]);
  return vms;
}
const busyFor = (vm: string) => Object.values(jobs).find((j) => j.vm === vm) ?? null;

function Demo({ view, vmName }: { view: View; vmName: string }) {
  const vms = useVms();
  const vm = vms.find((v) => v.name === vmName);
  if (!vms.length || (view !== "home" && !vm)) return null;
  if (view === "home") return <Home vms={vms} busyFor={busyFor} startJob={start} onOpenVm={() => {}} onRoute={() => {}} onCreate={() => {}} />;
  const props = { vm: vm!, busy: busyFor(vm!.name), startJob: start };
  if (view === "stream") return <Stream vm={vm!} />;
  if (view === "cleanup") return <Cleanup {...props} />;
  if (view === "apps") return <Apps {...props} />;
  return <SharedDisks {...props} />;
}

/* ---------- The cube ---------- */

const NEIGHBORS = ["win11-pruebas", "estudio"];
/** Usage that wanders like a machine at work, so the lightning comes and goes. */
function useLiveUsage(base: CubeMachine["usage"], still: boolean) {
  const [usage, setUsage] = useState(base);
  useEffect(() => {
    if (still) return;
    const id = setInterval(() => {
      if (document.hidden) return;
      setUsage((u) => ({
        cpu: Math.max(8, Math.min(95, u.cpu + (Math.random() - 0.5) * 30)),
        gpu: Math.max(10, Math.min(98, u.gpu + (Math.random() - 0.5) * 34)),
        mem: Math.max(25, Math.min(90, u.mem + (Math.random() - 0.5) * 14)),
        disk: Math.max(0, Math.min(60, u.disk + (Math.random() - 0.5) * 24)),
      }));
    }, 2400);
    return () => clearInterval(id);
  }, [still]);
  return usage;
}
const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches;

function useNeighbors(vms: VmOverview[]) {
  return useMemo(() => vms.filter((v) => NEIGHBORS.includes(v.name)).map((v) => ({ name: v.name, machine: cubeOf(v) })), [vms]);
}

/** The hero: a machine decorated at random, in the world the page picked; "Decorate at random" redecorates it. */
function HeroCube() {
  const s = useSite();
  const vms = useVms();
  const others = useNeighbors(vms);
  const [decor, setDecor] = useState(randomDecor);
  const first = useRef(s.dice);
  useEffect(() => { if (s.dice !== first.current) setDecor(randomDecor()); }, [s.dice]);
  const usage = useLiveUsage({ cpu: 42, gpu: 66, mem: 58, disk: 12 }, reducedMotion());
  const machine: CubeMachine = useMemo(() => ({ power: "on", cores: 12, memoryGB: 16, gpuPercent: 80, diskGB: 256, usage, apps: ["steam", "discord", "spotify", "obs", "chrome"], removed: 8 }), [usage]);
  return <MachineCube machine={machine} name="win10" decorShown={decor} spin={s.dice} ambient={s.world} time={s.time} spaceName={t("My machines")} others={others} />;
}

/** The machine's options beside its cube: the camera closes in on the piece that changes. */
function MachineDemo() {
  const s = useSite();
  const vms = useVms();
  const others = useNeighbors(vms);
  const [draft, setDraft] = useState({ cpu: 8, memoryGB: 8, gpuPercent: 80 });
  const usage = useLiveUsage({ cpu: 34, gpu: 61, mem: 64, disk: 8 }, reducedMotion());
  const machine: CubeMachine = useMemo(() => ({ power: "on", cores: draft.cpu, memoryGB: draft.memoryGB, gpuPercent: draft.gpuPercent, diskGB: 200, usage, apps: ["steam", "discord", "chrome"], removed: 0 }), [draft, usage]);
  const hostCpu = 16, hostMem = 32;
  return (
    <div className="site-machine">
      <div className="card site-cube"><MachineCube machine={machine} name="win10" ambient={s.world} time={s.time} spaceName={t("My machines")} others={others} /></div>
      <div className="card opt-rows">
        <OptionRow icon={<IconCpu size={17} />} title={t("Processor")} value={t("{n} threads", { n: draft.cpu })} desc={t("{n} threads left for your PC", { n: hostCpu - draft.cpu })}>
          <Slider label={t("Threads")} value={draft.cpu} min={2} max={12} onChange={(cpu) => setDraft({ ...draft, cpu })} />
        </OptionRow>
        <OptionRow icon={<IconTopologyStar3 size={17} />} title={t("Memory")} value={`${draft.memoryGB} GB`} desc={t("{n} GB left for your PC, all reserved at start", { n: hostMem - draft.memoryGB })}>
          <Slider label={t("Memory")} value={draft.memoryGB} min={4} max={24} onChange={(memoryGB) => setDraft({ ...draft, memoryGB })} />
        </OptionRow>
        <OptionRow icon={<IconBolt size={17} />} title={t("GPU for the VM")} value={`${draft.gpuPercent} %`} desc={draft.gpuPercent === 100 ? t("Can use the whole GPU, shared with your PC") : t("Up to {n} % of the GPU", { n: draft.gpuPercent })}>
          <Slider label="GPU" value={draft.gpuPercent} min={10} max={100} step={10} onChange={(gpuPercent) => setDraft({ ...draft, gpuPercent })} />
        </OptionRow>
      </div>
    </div>
  );
}

/** Customize, as on a machine's page: the panel beside the cube, decorated by dragging on it. */
function CustomizeDemo() {
  const s = useSite();
  const [source] = useState(() => draftSource("win10", randomDecor()));
  const d = useDecorEdit(source);
  const decor = useSource(source);
  const noMenu = () => {};
  return (
    <div className="site-customize">
      <div className="card site-cube">
        <MachineCube machine={{ power: "on", cores: 8, memoryGB: 16, gpuPercent: 80, diskGB: 256, usage: { cpu: 30, gpu: 50, mem: 50, disk: 5 }, apps: ["steam", "discord"], removed: 0 }}
          name="win10" decorOf="win10" decorShown={decor} spin={d.spins} ambient={s.world} time={s.time} spaceName={t("My machines")}
          edit={{ ...d.edit, onMenu: noMenu, holdStill: true }} />
      </div>
      <div className="site-customize-panel">
        <Customize source={d.source} ops={d.ops} selected={d.selected} setSelected={d.setSelected} openMenu={noMenu} />
      </div>
    </div>
  );
}
/** The games over a machine's space: Jugar opens the gallery, where each game plays by itself and can be played. */
function GamesDemo() {
  const s = useSite();
  const vms = useVms();
  const others = useNeighbors(vms);
  return (
    <div className="home-space site-games">
      <SpaceWithGames decorOf="win10" world={s.world} machines={["win10", ...NEIGHBORS]}>
        <MachineCube machine={vms.length ? cubeOf(vms[0], ["steam", "discord"]) : { power: "on", cores: 8, memoryGB: 8, gpuPercent: 100, diskGB: 200, usage: { cpu: 30, gpu: 60, mem: 60, disk: 5 }, apps: [], removed: 0 }}
          name="win10" ambient={s.world} time={s.time} spaceName={t("My machines")} others={others} />
      </SpaceWithGames>
    </div>
  );
}

/** GpuVM's viewer with its side panel: the machine's picture and, beside it, the same board of widgets as in the
 *  app (Edit moves, resizes, adds and removes them; switching machines and the games work). */
// Each sample machine shows its own landscape, so switching machines in the panel changes the picture.
const VIEWER_SCENES = new Set(["win10", "win11-pruebas", "estudio"]);
// In the demo every sample machine is on and streaming, so the panel can switch between them.
const allOn = (vms: VmOverview[]) => vms.map((v) => (VIEWER_SCENES.has(v.name) ? { ...v, state: "Running", streaming: true } : v));

function ViewerDemo() {
  const [vm, setVm] = useState("win10");
  // Dragged from the panel's edge as in the app (300-560 px), within what the demo leaves for the picture.
  const [width, setWidth] = useState(340);
  return (
    <div className="site-viewer" style={{ gridTemplateColumns: `minmax(0, 1fr) ${width}px` }}>
      <div className="site-viewer-picture"><MachineDesktop vm={vm} /></div>
      <div className="site-viewer-panel"><ViewerPanel machine="win10" onSwitched={setVm} onResize={setWidth} sample={allOn} /></div>
    </div>
  );
}

/* ---------- The agents chapter ---------- */

// An agent working on its machine with the app's own overlay (cursor, rings, strokes, keys) and its line in the status
// notch, in three scenes that take turns: a drawing in Paint, an app installed with winget, a video found and played in
// the browser. Each scene is a script of steps laid out with MachineDesktop's own layout helpers, so the cursor lands
// where the windows are; each step also tells the desktop what changes and when (a window opens, a letter is typed,
// the bucket fills), so the windows do what the agent does.

type Shape = NonNullable<LiveEvent["shapes"]>[number];
type Fn = (s: Stage) => Stage;
type Pt = [number, number];
interface Beat extends LiveEvent { then?: [number, Fn][] }
interface Act { s: Shape; then?: Fn; during?: [number, Fn][] }
interface SceneCtx { W: number; H: number; es: boolean; pin(id: string): Pt }
interface Plan { beats: Beat[]; key?: string }
/** The overlay's glide to each click (LiveOverlay's GLIDE_MS), to time what the desktop does after it. */
const GLIDE = 240;
const EMPTY: Stage = { windows: [] };
/** A window's place, made shorter when needed so the status notch floating over the taskbar never covers it. */
const clear = (at: Frac, H: number): Frac => [at[0], at[1], at[2], Math.min(at[3], (H - 62) / H - at[1])];

function beat(step: number, intent: string, screen: { w: number; h: number }, acts: Act[], method = "input.act"): Beat {
  let at = 0;
  const then: [number, Fn][] = [];
  for (const a of acts) {
    const s = a.s, from = at;
    if (s.type === "click" || s.type === "move" || s.type === "scroll") at += GLIDE;
    else if (s.type === "drag") at += GLIDE + Math.min(3000, Math.max(250, s.ms ?? 1000));
    else if (s.type === "wait") at += s.ms;
    a.during?.forEach(([dt, f]) => then.push([from + dt, f]));
    if (a.then) then.push([at, a.then]);
  }
  return { phase: "start", step, clientName: "Claude Code", screen, intent, method, shapes: acts.map((a) => a.s), then };
}
const click = (p: Pt, then?: Fn): Act => ({ s: { type: "click", x: Math.round(p[0]), y: Math.round(p[1]) }, then });
const move = (p: Pt): Act => ({ s: { type: "move", x: Math.round(p[0]), y: Math.round(p[1]) } });
const wait = (ms: number, during?: [number, Fn][], then?: Fn): Act => ({ s: { type: "wait", ms }, during, then });
const key = (keys: string, then?: Fn): Act => ({ s: { type: "key", keys }, then });
const typing = (chars: number): Act => ({ s: { type: "type", chars } });
const withWin = (kind: Kind, f: (w: StageWindow) => StageWindow): Fn => (s) => ({ ...s, windows: s.windows.map((w) => (w.kind === kind ? f(w) : w)) });
const openWin = (w: StageWindow): Fn => (s) => ({ ...s, windows: [...s.windows.filter((x) => x.kind !== w.kind), w] });
/** One letter at a time, `ms` apart: what `text(i)` shows after the i-th letter. */
const letters = (n: number, ms: number, f: (i: number) => Fn): [number, Fn][] => Array.from({ length: n }, (_, i) => [(i + 1) * ms, f(i + 1)] as [number, Fn]);

/** a) A night landscape in Paint: the sky filled, a crescent moon, stars, two mountain ridges with snow, the lake and a
 *  house with its window lit, each outlined with the pencil and filled with the bucket, as one paints in Paint. */
function paintScene({ W, H, es, pin }: SceneCtx): Plan {
  const screen = { w: W, h: H };
  const at = clear([0.07, 0.03, 0.86, 0.77], H);
  const L = paintLayout(stageBox(at, W, H)), cv = L.canvas, A = cv.w / cv.h;
  /** Canvas fractions → desktop pixels. Round shapes are measured in canvas heights (`ring`) so they stay round. */
  const C = (p: Pt): Pt => [cv.x + p[0] * cv.w, cv.y + p[1] * cv.h];
  const ring = (cx: number, cy: number, r: number, a: number): Pt => [cx + (r * Math.cos(a)) / A, cy + r * Math.sin(a)];
  const pen = Math.max(1.6, cv.h / 100);
  const paint = (p: Partial<PaintStage>) => withWin("paint", (w) => ({ ...w, paint: { ...w.paint, ...p } }));
  const fill = (pts: Pt[], color: number) => withWin("paint", (w) => ({ ...w, paint: { ...w.paint, fills: [...(w.paint?.fills ?? []), { pts, color: PAINT_COLORS[color] }] } }));
  const tool = (t: PaintTool) => click(L.tool(t), paint({ tool: t }));
  const color = (i: number) => click(L.swatch(i), paint({ color: i }));
  const draw = (strokes: Pt[][], ms: number, c: number, width = pen): Act => ({ s: { type: "drag", strokes: strokes.map((st) => st.map(C)), ms, color: PAINT_COLORS[c], width } });
  const bucket = (p: Pt, pts: Pt[], c: number) => click(C(p), fill(pts, c));

  // The moon: a circle with another, slightly smaller and shifted to the upper right, taken out of it.
  const mo = { x: 0.15, y: 0.27, r: 0.15 }, d = 0.42, r2 = 0.92, tilt = -0.6;
  const x0 = (d * d + 1 - r2 * r2) / (2 * d), y0 = Math.sqrt(1 - x0 * x0);
  const th = Math.atan2(y0, x0), be = Math.atan2(y0, x0 - d);
  const turn = (p: Pt): Pt => { const c = Math.cos(tilt), s = Math.sin(tilt); return [mo.x + ((p[0] * c - p[1] * s) * mo.r) / A, mo.y + (p[0] * s + p[1] * c) * mo.r]; };
  const moon = [
    ...Array.from({ length: 25 }, (_, i): Pt => { const a = th + (i / 24) * (2 * Math.PI - 2 * th); return [Math.cos(a), Math.sin(a)]; }),
    ...Array.from({ length: 20 }, (_, i): Pt => { const a = 2 * Math.PI - be - (i / 19) * (2 * Math.PI - 2 * be); return [d + r2 * Math.cos(a), r2 * Math.sin(a)]; }),
  ].map(turn);
  const moonIn = turn([-(1 + r2 - d) / 2, 0]);
  // Five-point stars and a few small ones.
  const star = (cx: number, cy: number, r: number): Pt[] => Array.from({ length: 11 }, (_, i) => ring(cx, cy, i % 2 ? r * 0.42 : r, -Math.PI / 2 + (i * Math.PI) / 5));
  const STARS: [number, number, number][] = [[0.34, 0.14, 0.05], [0.47, 0.3, 0.034], [0.58, 0.1, 0.043], [0.72, 0.24, 0.054], [0.86, 0.11, 0.04], [0.95, 0.31, 0.032]];
  const DOTS: Pt[] = [[0.05, 0.08], [0.27, 0.06], [0.41, 0.05], [0.53, 0.21], [0.8, 0.05], [0.91, 0.21], [0.39, 0.34], [0.64, 0.3]];
  // The ridges, the lake and the house.
  const LAKE = 0.8;
  const BACK: Pt[] = [[0.003, 0.56], [0.07, 0.49], [0.15, 0.55], [0.27, 0.4], [0.36, 0.5], [0.45, 0.44], [0.55, 0.57], [0.66, 0.37], [0.76, 0.5], [0.86, 0.42], [0.94, 0.51], [0.997, 0.47]];
  const FRONT: Pt[] = [[0.003, 0.66], [0.1, 0.6], [0.2, 0.68], [0.31, 0.62], [0.42, 0.72], [0.53, 0.65], [0.62, 0.71], [0.69, 0.69], [0.83, 0.69], [0.9, 0.62], [0.997, 0.7]];
  const down = (r: Pt[]): Pt[] => [[0, r[0][1]], ...r, [1, r[r.length - 1][1]], [1, LAKE], [0, LAKE]];
  const cap = (r: Pt[], i: number, drop: number): Pt[] => {
    const P = r[i], v = P[1] + drop;
    const cross = (a: Pt, b: Pt) => a[0] + ((b[0] - a[0]) * (v - a[1])) / (b[1] - a[1]);
    const lu = cross(r[i - 1], P), ru = cross(P, r[i + 1]), m = (f: number) => lu + (ru - lu) * f;
    return [[lu, v], P, [ru, v], [m(0.8), v + drop * 0.35], [m(0.6), v - drop * 0.05], [m(0.4), v + drop * 0.38], [m(0.2), v + drop * 0.05], [lu, v]];
  };
  const caps = [cap(BACK, 3, 0.065), cap(BACK, 7, 0.07), cap(BACK, 9, 0.045)];
  const hw = 0.21 / A, hx = 0.72, base = 0.69, wallH = 0.12, roofH = 0.1, eave = 0.035 / A;
  const walls: Pt[] = [[hx, base], [hx, base - wallH], [hx + hw, base - wallH], [hx + hw, base], [hx, base]];
  const roof: Pt[] = [[hx - eave, base - wallH], [hx + hw / 2, base - wallH - roofH], [hx + hw + eave, base - wallH], [hx - eave, base - wallH]];
  const wx = hx + hw * 0.3, wy = base - wallH * 0.55, side = wallH * 0.4, door = hx + hw * 0.72;
  const lake: Pt[] = [[0, LAKE], [1, LAKE], [1, 1], [0, 1]];
  const dash = (u: number, v: number, half: number): Pt[] => [[u - half, v], [u + half, v]];

  const b = (n: number, intent: [string, string], acts: Act[]) => beat(n, es ? intent[0] : intent[1], screen, acts);
  return { beats: [
    b(1, ["Abriendo Paint", "Opening Paint"], [click(pin(GLYPHS.paint), openWin({ kind: "paint", at, paint: { tool: "pencil", color: 0 } }))]),
    b(2, ["Pintando el cielo de noche", "Painting the night sky"], [tool("bucket"), color(2), click(C([0.5, 0.4]), paint({ background: PAINT_COLORS[2] }))]),
    b(3, ["Dibujando la luna", "Drawing the moon"], [tool("pencil"), color(6), draw([moon], 1100, 6), tool("bucket"), bucket(moonIn, moon, 6)]),
    b(4, ["Dibujando las estrellas", "Drawing the stars"], [tool("pencil"), color(7),
      draw([...STARS.map(([x, y, r]) => star(x, y, r)), ...DOTS.map(([x, y]): Pt[] => [[x, y], [x + 0.0005, y]])], 2200, 7),
      tool("bucket"), ...STARS.map(([x, y, r]) => bucket([x, y], star(x, y, r), 7))]),
    b(5, ["Dibujando las montañas", "Drawing the mountains"], [tool("pencil"), color(3), draw([BACK], 1000, 3), tool("bucket"), bucket([0.66, 0.62], down(BACK), 3)]),
    b(6, ["Poniendo nieve en las cumbres", "Adding snow to the peaks"], [tool("pencil"), color(1), draw(caps, 700, 1), tool("bucket"),
      ...caps.map((c) => bucket([c[1][0], c[1][1] + 0.035], c, 1))]),
    b(7, ["Dibujando las colinas", "Drawing the hills"], [tool("pencil"), color(4), draw([FRONT], 1000, 4), tool("bucket"), bucket([0.5, 0.75], down(FRONT), 4)]),
    b(8, ["Pintando el lago", "Painting the lake"], [color(11), bucket([0.5, 0.9], lake, 11), tool("pencil"), color(5),
      draw([[[0.003, LAKE], [0.997, LAKE]], dash(0.36, 0.875, 0.03), dash(0.57, 0.93, 0.025), dash(0.9, 0.9, 0.02), dash(0.47, 0.845, 0.015)], 900, 5)]),
    b(9, ["Dibujando la casa", "Drawing the house"], [color(9), draw([walls], 600, 9), tool("bucket"), bucket([hx + hw * 0.7, base - wallH * 0.3], walls, 9),
      tool("pencil"), color(8), draw([roof], 500, 8), tool("bucket"), bucket([hx + hw / 2, base - wallH - roofH * 0.35], roof, 8)]),
    b(10, ["Encendiendo la ventana", "Lighting the window"], [tool("brush"), color(10),
      draw([[[wx - (side * 0.18) / A, wy], [wx + (side * 0.18) / A, wy]]], 300, 10, side * cv.h * 0.72),
      draw([dash(wx, 0.85, 0.008), dash(wx, 0.885, 0.005)], 300, 10, pen * 1.3),
      color(0), draw([[[door, base - pen / cv.h], [door, base - wallH * 0.45]]], 300, 0, side * cv.h * 0.55),
      color(6), draw([dash(mo.x, 0.85, 0.035), dash(mo.x, 0.885, 0.026), dash(mo.x, 0.92, 0.018), dash(mo.x, 0.955, 0.01)], 600, 6, pen * 1.3)]),
    b(11, ["Guardando el dibujo", "Saving the drawing"], [key("ctrl+s", paint({ title: es ? "noche-en-el-lago.png: Paint" : "night-at-the-lake.png: Paint" })), wait(2200)]),
  ] };
}

/** b) An app installed with winget in PowerShell: the command typed, the download filling its bar, VLC on the desktop. */
function installScene({ W, H, es, pin }: SceneCtx): Plan {
  const screen = { w: W, h: H };
  const at = clear([0.1, 0.04, 0.8, 0.74], H);
  const box = stageBox(at, W, H);
  const prompt = "PS C:\\Users\\agent> ";
  const cmd = "winget install --id VideoLAN.VLC";
  const term = (f: (t: TermStage) => TermStage): Fn => withWin("terminal", (w) => ({ ...w, term: f(w.term ?? { lines: [], input: prompt }) }));
  const add = (...lines: string[]) => term((t) => ({ ...t, lines: [...t.lines, ...lines] }));
  const cells = box.w < 420 ? 12 : 24, total = 43.6;
  const bar = (p: number) => termBar(Math.round(p * cells) / cells, cells, `${(total * p).toFixed(1)} MB / ${total} MB`);
  const setBar = (p: number) => term((t) => ({ ...t, lines: [...t.lines.slice(0, -1), bar(p)] }));
  const steps = 24, perStep = 115;
  const tx = es
    ? { found: "Encontrado VLC media player [VideoLAN.VLC] Versión 3.0.21", lic: "El propietario le concede la licencia de esta aplicación.", ms: "Microsoft no es responsable ni concede licencias a paquetes de terceros.",
      dl: "Descargando", hash: "Se verificó correctamente el hash del instalador", start: "Iniciando instalación de paquete...", ok: "Instalado correctamente" }
    : { found: "Found VLC media player [VideoLAN.VLC] Version 3.0.21", lic: "This application is licensed to you by its owner.", ms: "Microsoft is not responsible for, nor does it grant any licenses to, third-party packages.",
      dl: "Downloading", hash: "Successfully verified installer hash", start: "Starting package install...", ok: "Successfully installed" };
  const terminal = pin(GLYPHS.terminal);
  const b = (n: number, intent: [string, string], acts: Act[]) => beat(n, es ? intent[0] : intent[1], screen, acts, n > 2 ? "exec.run" : "input.act");
  return { beats: [
    b(1, ["Abriendo PowerShell", "Opening PowerShell"], [click(terminal, openWin({ kind: "terminal", at,
      term: { lines: ["Windows PowerShell", es ? "Copyright (C) Microsoft Corporation. Todos los derechos reservados." : "Copyright (C) Microsoft Corporation. All rights reserved.", ""], input: prompt } }))]),
    b(2, ["Instalando VLC con winget", "Installing VLC with winget"], [click([box.x + box.w * 0.5, box.y + box.h * 0.45]), typing(cmd.length),
      wait(cmd.length * 36 + 250, letters(cmd.length, 36, (i) => term((t) => ({ ...t, input: prompt + cmd.slice(0, i) })))),
      key("enter", term((t) => ({ lines: [...t.lines, prompt + cmd], input: "" })))]),
    b(3, ["Descargando VLC", "Downloading VLC"], [wait(steps * perStep + 500, [
      [150, add(tx.found)], [350, add(tx.lic, tx.ms)], [600, add(`${tx.dl} https://get.videolan.org/vlc/3.0.21/win64/vlc-3.0.21-win64.exe`, bar(0))],
      ...Array.from({ length: steps }, (_, i): [number, Fn] => [700 + i * perStep, setBar((i + 1) / steps)]),
    ])]),
    b(4, ["Instalando VLC", "Installing VLC"], [wait(2000, [[100, add(tx.hash)], [450, add(tx.start)]],
      (s) => ({ ...term((t) => ({ lines: [...t.lines, tx.ok, ""], input: prompt }))(s), icons: [[GLYPHS.vlc, "vlc"]], pinned: [GLYPHS.vlc] }))]),
    // A new app on a centered taskbar: everything moves half a button left and VLC comes after the terminal.
    b(5, ["VLC quedó instalado", "VLC is installed"], [move([terminal[0] + 17, terminal[1]]), wait(2400)]),
  ] };
}

/** c) The browser: the address typed, a video picked on the site and played. */
function browseScene({ W, H, es, pin }: SceneCtx): Plan {
  const screen = { w: W, h: H };
  const at = clear([0.07, 0.03, 0.86, 0.77], H);
  const L = browserLayout(stageBox(at, W, H));
  const br = (p: Partial<BrowserStage>) => withWin("browser", (w) => ({ ...w, browser: { ...(w.browser ?? { address: "", page: "new" }), ...p } }));
  const thumb = L.thumbs[0];
  const b = (n: number, intent: [string, string], acts: Act[]) => beat(n, es ? intent[0] : intent[1], screen, acts);
  return { beats: [
    b(1, ["Abriendo el navegador", "Opening the browser"], [click(pin(GLYPHS.chrome), openWin({ kind: "browser", at, browser: { address: "", page: "new" } }))]),
    b(2, ["Escribiendo la dirección", "Typing the address"], [click([L.address.x + Math.min(70, L.address.w / 3), L.address.y + L.address.h / 2], br({ editing: true })), typing(SITE.length),
      wait(SITE.length * 55 + 250, letters(SITE.length, 55, (i) => br({ address: SITE.slice(0, i) }))), key("enter", br({ editing: false, page: "site" }))]),
    b(3, ["Eligiendo un video", "Choosing a video"], [click([thumb.x + thumb.w / 2, thumb.y + thumb.h / 2], br({ page: "video", playing: false, address: `${SITE}/watch/${es ? "lago-alpino" : "alpine-lake"}` })), wait(500)]),
    b(4, ["Reproduciendo el video", "Playing the video"], [click(L.play, br({ playing: true })), wait(4200)]),
  ] };
}

const SCENES = [paintScene, installScene, browseScene];

function AgentsDemo() {
  const box = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [scene, setScene] = useState(0);
  const [plan, setPlan] = useState<Plan | null>(null);
  const [stage, setStage] = useState<Stage>(EMPTY);
  const [step, setStep] = useState<LiveEvent | null>(null);
  const timers = useRef<number[]>([]);
  /** The scene playing now: steps and timers of one that ended never reach the desktop. */
  const current = useRef<Plan | null>(null);
  useSite();
  const lang = getLang();
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const measure = () => { const r = el.getBoundingClientRect(); if (r.width > 0) setSize((s) => (s && s.w === Math.round(r.width) && s.h === Math.round(r.height - BAR) ? s : { w: Math.round(r.width), h: Math.round(r.height - BAR) })); };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => { ro.disconnect(); timers.current.forEach(clearTimeout); };
  }, []);
  // A new scene, size or language starts the scene over on a clear desktop...
  const sceneKey = size ? `${scene}|${size.w}x${size.h}|${lang}` : "";
  useLayoutEffect(() => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
    current.current = null;
    setPlan(null); setStage(EMPTY); setStep(null);
  }, [sceneKey]);
  // ...where its script is laid out, with the taskbar's buttons found where they are drawn.
  useLayoutEffect(() => {
    const root = box.current;
    if (plan || stage !== EMPTY || !size || !root) return;
    const r0 = root.getBoundingClientRect();
    const pin = (id: string): Pt => {
      const r = root.querySelector(`[data-pin="${CSS.escape(id)}"]`)?.getBoundingClientRect();
      return r ? [r.left - r0.left + r.width / 2, r.top - r0.top + r.height / 2] : [size.w / 2, size.h + BAR / 2];
    };
    const made = { ...SCENES[scene]({ W: size.w, H: size.h, es: lang === "es", pin }), key: sceneKey };
    current.current = made;
    setPlan(made);
  }, [plan, stage, size, scene, lang, sceneKey]);
  const onStep = useCallback((ev: LiveEvent | null) => {
    const playing = current.current;
    if (!playing || !ev || !playing.beats.includes(ev as Beat)) return;
    setStep(ev);
    for (const [ms, f] of (ev as Beat).then ?? []) timers.current.push(window.setTimeout(() => { if (current.current === playing) setStage(f); }, ms));
  }, []);
  const next = useCallback(() => setScene((n) => (n + 1) % SCENES.length), []);
  const item: StatusItem = step
    ? { id: "live", kind: "live", clientName: "Claude Code", method: step.method ?? null, intent: step.intent ?? null, shape: step.shapes?.[0]?.type ?? null }
    : { id: "live", kind: "live", clientName: "Claude Code", thinking: true };
  return (
    <div className="site-agents">
      <div className="site-agents-screen" ref={box}>
        <MachineDesktop vm="agent" locked stage={stage}>
          {plan && plan.key === sceneKey && <LiveOverlay key={sceneKey} script={plan.beats} keep pause={420} onStep={onStep} onEnd={next} />}
        </MachineDesktop>
      </div>
      <div className="site-agents-notch sn"><StatusRow item={item} onAction={async () => {}} /></div>
    </div>
  );
}

/* ---------- Mounting ---------- */

/** Everything inside a demo is drawn again when the language changes, as the app does (without starting it over). */
function Root({ children }: { children: () => ReactNode }) {
  useSite();
  return <div className="demo-lang">{children()}</div>;
}

// The size the whole app is drawn at before it is scaled to the page: a desktop window, or on a phone a narrow
// one with the sidebar collapsed, so its text stays readable once scaled.
const appSize = (width: number) => (width < 700 ? { w: 560, h: 860 } : { w: 1200, h: 750 });

// The app's stylesheet, scoped to the shadow root: its :root tokens (theme, accent) become the host's, and the fonts
// come from the page (the same family), so nothing is downloaded twice.
const scopedCss = appCss
  .replace(/@import[^;]+;/g, "")
  .replace(/:root\[([^\]]+)\]/g, ":host([$1])")
  .replace(/:root/g, ":host")
  + `:host { display: block; background: none; color: var(--text); font-family: "Plus Jakarta Sans", system-ui, sans-serif; font-size: 14px; }
  .demo-root, .demo-lang { display: flex; flex-direction: column; gap: 16px; height: 100%; }
  .demo-root > .demo-lang > .main { padding: 0; overflow: visible; mask-image: none; }
  .prompt-demo { min-height: 158px; }
  /* In the demos, a group of options spans its row: each option takes an equal share of the width. */
  .segment-row > .segmented { display: flex; width: 100%; }
  .segment-row > .segmented > button { flex: 1 1 0; justify-content: center; min-width: 0; }
  /* On a phone the cleanup's closing line (what is never touched) sits centered under the list. */
  @media (max-width: 600px) { .levels-safe { flex-direction: column; align-items: center; justify-content: center; text-align: center; gap: 6px; }
    .prompt-head strong, .prompt-name { white-space: normal; overflow: visible; text-overflow: clip; }
    .prompt-actions { flex-wrap: wrap; } .prompt-actions > button { flex: 1 1 auto; justify-content: center; }
    .opt-ctl { width: 100%; } .opt-ctl > .segmented { display: flex; width: 100%; } .opt-ctl > .segmented > button { flex: 1 1 0; justify-content: center; min-width: 0; } }
  /* Narrow (a phone): the card grows with its text instead of letting it run out of the box. */
  .prompt-demo .prompt-card { height: auto; min-height: 158px; }
  /* Narrow (a phone): option groups that don't fit in one row become a grid of equal cells. */
  .demo-root { container-type: inline-size; }
  @container (max-width: 720px) {
    .opt-row .segmented { display: grid; grid-template-columns: 1fr 1fr; width: 100%; }
    .opt-row .segmented button { justify-content: center; }
    .opt-row .opt-ctl { width: 100%; }
  }
  /* The decoration panel shows there is more below it, until its end. */
  .site-customize-panel { -webkit-mask-image: linear-gradient(#000 calc(100% - 48px), transparent); mask-image: linear-gradient(#000 calc(100% - 48px), transparent);
    animation: panel-end linear both; animation-timeline: scroll(self); }
  @keyframes panel-end { 0%, 96% { -webkit-mask-image: linear-gradient(#000 calc(100% - 48px), transparent); mask-image: linear-gradient(#000 calc(100% - 48px), transparent); } 100% { -webkit-mask-image: none; mask-image: none; } }
  /* The cubes fill the box the page gives them. */
  .demo-root.cube, .demo-root.cube .demo-lang { height: 100%; }
  .demo-root.cube .machine-cube { width: 100%; height: 100%; }
  .site-cube { position: relative; padding: 0; overflow: hidden; min-height: 0; }
  .site-cube .machine-cube { position: absolute; inset: 0; }
  .site-machine { display: grid; grid-template-rows: minmax(300px, 1fr) auto; gap: 12px; height: 100%; }
  .site-customize { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 600px); gap: 12px; height: 100%; }
  .site-customize-panel { min-height: 0; overflow: auto; border-radius: var(--r-lg); scrollbar-width: none; }
  .site-customize-panel .customize { min-height: 100%; }
  @media (max-width: 760px) { .site-customize { grid-template-columns: 1fr; grid-template-rows: 340px minmax(0, 1fr); } }
  .site-games { position: relative; height: 100%; border-radius: var(--r-lg); overflow: hidden; background: var(--surface); }
  .site-games .machine-cube { position: absolute; inset: 0; }
  .site-games .space-games { opacity: 1; }
  .site-viewer { display: grid; grid-template-columns: minmax(0, 1fr) 340px; height: 100%; border-radius: var(--r-lg); overflow: hidden; background: var(--bg); box-shadow: inset 0 0 0 1px var(--line); }
  .site-viewer-picture { position: relative; min-width: 0; background: #000; }
  .site-viewer-picture > * { position: absolute; inset: 0; width: 100%; height: 100%; }
  .pixel-scene { object-fit: cover; image-rendering: pixelated; }
  .site-viewer-panel { position: relative; min-height: 0; }
  .site-agents { position: relative; height: 100%; border-radius: var(--r-lg); overflow: hidden; background: #000; box-shadow: inset 0 0 0 1px var(--line); }
  .site-agents-screen { position: absolute; inset: 0; }
  .site-agents-screen .lv-root { position: absolute; }
  .site-agents-notch { position: absolute; left: 50%; bottom: 46px; transform: translateX(-50%); border-radius: 14px; z-index: 6; max-width: calc(100% - 24px); }
  .site-agents-notch .sn-row { white-space: nowrap; }
  .site-viewer-panel .viewer-panel { position: absolute; }
  @media (max-width: 760px) { .site-viewer { grid-template-columns: 1fr !important; grid-template-rows: 220px minmax(0, 1fr); } .site-viewer-panel .viewer-panel-edge { display: none; } }
  /* The whole app: drawn at a desktop window's size and scaled to fit. The transform also keeps its dialogs and
     toasts (position: fixed) inside the window instead of the page. */
  .demo-root.full { display: block; transform-origin: 0 0; background: var(--bg); }
  .demo-root.full .demo-lang { display: block; height: 100%; }
  .demo-root.full .app { height: 100%; }
  .demo-root.full .dialog { max-height: calc(100% - var(--titlebar) - 48px); }
  .demo-root.full .overlay { inset: var(--titlebar) 0 0; }`;

// On the website the cubes are decoration beside the text, several at once: 30 frames a second is plenty and
// halves their cost.
(window as { __gpuvmFps?: number }).__gpuvmFps = 30;

function mount(el: HTMLElement, options: { view: View; vm?: string }) {
  seed();
  const shadow = el.shadowRoot ?? el.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = scopedCss;
  const host = document.createElement("div");
  host.className = "demo-root";
  shadow.replaceChildren(style, host);
  hosts.add(el);
  paintHosts();
  // The wheel scrolls the page over a demo until the demo is clicked: from then on, while the pointer stays on it, the
  // wheel zooms the cube (and scrolls the app's own rows) as in the app.
  let engaged = false;
  el.addEventListener("pointerdown", () => { engaged = true; }, true);
  el.addEventListener("pointerleave", () => { engaged = false; });
  el.addEventListener("wheel", (e) => { if (!engaged && !e.ctrlKey) e.stopPropagation(); }, true);
  // Menus and lists open inside the demo that was touched, where its styles are.
  if (options.view !== "app") el.addEventListener("pointerdown", () => setPortalRoot(host), true);
  const root = createRoot(host);
  const render = (make: () => ReactNode) => root.render(<Root>{make}</Root>);
  const view = options.view;
  if (view === "app") {
    host.classList.add("full");
    setPortalRoot(host);
    el.addEventListener("pointerdown", () => setPortalRoot(host), true);
    const size = appSize(el.clientWidth);
    if (size.w < 700) { try { localStorage.setItem("gpuvm.collapsed", "1"); } catch { /* no storage */ } }
    host.style.width = `${size.w}px`;
    host.style.height = `${size.h}px`;
    const fit = () => {
      const scale = Math.min(1, el.clientWidth / size.w);
      host.style.transform = `scale(${scale})`;
      el.style.height = `${size.h * scale}px`;
    };
    new ResizeObserver(fit).observe(el);
    fit();
    render(() => <App embedded />);
    return;
  }
  if (view === "prompt") { showSamplePrompt(); render(() => <Prompt />); return; }
  if (view === "cube") { host.classList.add("cube"); render(() => <HeroCube />); return; }
  if (view === "machine") { host.classList.add("cube"); render(() => <MachineDemo />); return; }
  if (view === "customize") { host.classList.add("cube"); render(() => <CustomizeDemo />); return; }
  if (view === "games") { host.classList.add("cube"); render(() => <GamesDemo />); return; }
  if (view === "viewer") { host.classList.add("cube"); render(() => <ViewerDemo />); return; }
  if (view === "agents") { host.classList.add("cube"); render(() => <AgentsDemo />); return; }
  render(() => <Demo view={view} vmName={options.vm ?? "win10"} />);
}

(window as unknown as { GpuVMEmbed: unknown }).GpuVMEmbed = { mount, configure, randomize, lang: getLang };
