// The app's real components for the website, running on the same sample data used to design the app (mock.ts): the
// machine's cube (the hero, the machine's options, Customize), the games, Home, the Windows cleanup, the stream
// options, the administrator card and the whole app in a window. Each one mounts in a Shadow DOM with the app's own
// styles, so neither the site's CSS nor the app's leak into each other. They all follow the page's language, light or
// dark mode, accent and world (configure()), and the app's own Settings change the page back ("gpuvm-embed-prefs").
// Built by vite.embed.config.ts into site/assets/embed.js.
import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
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
import { MachineDesktop } from "./MachineDesktop";
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

/** The agents chapter: an agent drawing in Paint on its machine, with the app's own overlay (cursor, rings, strokes,
 *  keys) and its line in the status notch, in a loop. The script is laid out in fractions of the desktop and turned
 *  into its pixels once measured, so the strokes land on the Paint canvas at any size. */
function AgentsDemo() {
  const box = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  const [step, setStep] = useState<LiveEvent | null>(null);
  useSite();
  const es = getLang() === "es";
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const measure = () => { const r = el.getBoundingClientRect(); if (r.width > 0) setSize({ w: Math.round(r.width), h: Math.round(r.height - 34) }); };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const script = useMemo<LiveEvent[] | null>(() => {
    if (!size) return null;
    const { w: W, h: H } = size;
    // The Paint canvas, in fractions of the desktop above the taskbar (MachineDesktop's paint window).
    const P = (fx: number, fy: number): [number, number] => [Math.round(W * (0.165 + fx * 0.74)), Math.round(H * (0.2 + fy * 0.6))];
    const star = (cx: number, cy: number, r: number) => Array.from({ length: 11 }, (_, i) => {
      const a = -Math.PI / 2 + (i * Math.PI) / 5, rr = i % 2 ? r * 0.45 : r;
      return P(cx + Math.cos(a) * rr * 0.6, cy + Math.sin(a) * rr);
    });
    const moon = [...Array.from({ length: 14 }, (_, i) => { const a = Math.PI * 0.35 + (i / 13) * Math.PI * 1.3; return P(0.32 + Math.cos(a) * 0.09, 0.32 + Math.sin(a) * 0.17); }),
      ...Array.from({ length: 10 }, (_, i) => { const a = Math.PI * 1.65 - (i / 9) * Math.PI * 1.3; return P(0.355 + Math.cos(a) * 0.07, 0.32 + Math.sin(a) * 0.13); })];
    const hills = [P(0, 0.92), P(0.18, 0.7), P(0.34, 0.86), P(0.52, 0.62), P(0.7, 0.84), P(0.86, 0.68), P(1, 0.8)];
    const name = "Claude Code", screen = { w: W, h: H };
    const s = (n: number, intent: string, method: string, shapes: LiveEvent["shapes"]): LiveEvent => ({ phase: "start", step: n, clientName: name, screen, intent, method, shapes });
    return [
      s(1, es ? "Eligiendo el color" : "Picking a color", "input.act", [{ type: "click", x: Math.round(W * 0.175), y: Math.round(H * 0.125) }]),
      s(2, es ? "Dibujando la luna" : "Drawing the moon", "input.act", [{ type: "drag", strokes: [moon], ms: 1600 }]),
      s(3, es ? "Dibujando las estrellas" : "Drawing the stars", "input.act", [{ type: "drag", strokes: [star(0.62, 0.22, 0.07), star(0.8, 0.4, 0.05), star(0.12, 0.18, 0.045)], ms: 2000 }]),
      s(4, es ? "Dibujando las montañas" : "Drawing the mountains", "input.act", [{ type: "drag", strokes: [hills], ms: 1500 }]),
      s(5, es ? "Guardando el dibujo" : "Saving the drawing", "input.act", [{ type: "key", keys: "ctrl+s" }]),
      s(6, es ? "Entregándote el dibujo" : "Delivering the drawing to you", "outbox.offer", []),
    ];
  }, [size, es]);
  const item: StatusItem = step
    ? { id: "live", kind: "live", clientName: "Claude Code", method: step.method ?? null, intent: step.intent ?? null, shape: step.shapes?.[0]?.type ?? null }
    : { id: "live", kind: "live", clientName: "Claude Code", thinking: true };
  return (
    <div className="site-agents">
      <div className="site-agents-screen" ref={box}>
        <MachineDesktop vm="agent" locked>
          {script && <LiveOverlay key={`${size?.w}x${size?.h}-${es}`} script={script} keep onStep={setStep} />}
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
  .site-agents-notch { position: absolute; left: 50%; bottom: 34px; transform: translateX(-50%); border-radius: 14px 14px 0 0; z-index: 6; max-width: calc(100% - 24px); }
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
