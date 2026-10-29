// The app's real components for the website: Home, the Windows, Apps and Shared disks cards, running on the
// same sample data used to design the app (mock.ts). Each one mounts in a Shadow DOM with the app's own styles,
// so neither the site's CSS nor the app's leak into each other. Built by vite.embed.config.ts into site/assets.
import { useCallback, useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { api, onJob, startJob as runJob } from "./api";
import { App } from "./App";
import { Home } from "./Home";
import { readPrefs, resolvedTheme, savePrefs } from "./prefs";
import { setPortalRoot } from "./ui";
import { Apps, Cleanup, SharedDisks, type JobInfo } from "./VmView";
import type { VmOverview } from "./types";
import appCss from "./styles.css?inline";

type View = "app" | "home" | "cleanup" | "apps" | "shared";
interface RunningJob extends JobInfo { vm: string; after?: () => void }

// One job list for every mounted demo, like the app's: what one demo starts shows in the others too.
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
  jobs = { ...jobs, [id]: { vm, cmd, message: "Trabajando", log: [], after } };
  changed();
  runJob(id, cmd, args);
}

function Demo({ view, vmName }: { view: View; vmName: string }) {
  const [vms, setVms] = useState<VmOverview[]>([]);
  const [, tick] = useState(0);
  const refresh = useCallback(() => api.overview().then((v) => setVms([...v])), []);
  useEffect(() => {
    refresh();
    const update = () => { tick((n) => n + 1); refresh(); };
    listeners.add(update);
    return () => { listeners.delete(update); };
  }, [refresh]);
  const busyFor = (vm: string) => Object.values(jobs).find((j) => j.vm === vm) ?? null;
  const vm = vms.find((v) => v.name === vmName);
  if (!vms.length || (view !== "home" && !vm)) return null;
  if (view === "home") return <Home vms={vms} busyFor={busyFor} startJob={start} onOpenVm={() => {}} onRoute={() => {}} />;
  const props = { vm: vm!, busy: busyFor(vm!.name), startJob: start };
  if (view === "cleanup") return <Cleanup {...props} />;
  if (view === "apps") return <Apps {...props} />;
  return <SharedDisks {...props} />;
}

// The size the whole app is drawn at before it is scaled to the page: a desktop window, or on a phone a narrow
// one with the sidebar collapsed, so its text stays readable once scaled.
const appSize = (width: number) => (width < 700 ? { w: 560, h: 860 } : { w: 1200, h: 750 });

// The app's stylesheet, scoped to the shadow root: its :root tokens become the host's, and the fonts come from
// the page (the same family), so nothing is downloaded twice.
const scopedCss = appCss
  .replace(/@import[^;]+;/g, "")
  // The build minifies the stylesheet, which may drop the quotes around "dark".
  .replace(/:root\[data-theme="?dark"?\]/g, ':host([data-theme="dark"])')
  .replace(/:root/g, ":host")
  + `:host { display: block; background: none; color: var(--text); font-family: "Plus Jakarta Sans", system-ui, sans-serif; font-size: 14px; }
  .demo-root { display: flex; flex-direction: column; gap: 16px; }
  .demo-root > .main { padding: 0; overflow: visible; mask-image: none; }
  /* The whole app: drawn at a desktop window's size and scaled to fit. The transform also keeps its dialogs and
     toasts (position: fixed) inside the window instead of the page. */
  .demo-root.full { display: block; transform-origin: 0 0; background: var(--bg); }
  .demo-root.full .app { height: 100%; }
  .demo-root.full .dialog { max-height: calc(100% - var(--titlebar) - 48px); }
  .demo-root.full .overlay { inset: var(--titlebar) 0 0; }`;

function mount(el: HTMLElement, options: { view: View; vm?: string; theme?: "light" | "dark" }) {
  const shadow = el.shadowRoot ?? el.attachShadow({ mode: "open" });
  const style = document.createElement("style");
  style.textContent = scopedCss;
  const host = document.createElement("div");
  host.className = "demo-root";
  shadow.replaceChildren(style, host);
  el.dataset.theme = options.theme ?? "light";
  if (options.view === "app") {
    host.classList.add("full");
    setPortalRoot(host);
    // Its sun and moon follow the page, and switch it.
    savePrefs({ theme: el.dataset.theme as "light" | "dark" });
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
    createRoot(host).render(<App embedded />);
    return;
  }
  createRoot(host).render(<Demo view={options.view} vmName={options.vm ?? "win10"} />);
}

function setTheme(theme: "light" | "dark") {
  document.querySelectorAll<HTMLElement>("[data-demo]").forEach((el) => { el.dataset.theme = theme; });
  if (resolvedTheme(readPrefs().theme) !== theme) savePrefs({ theme });
}
// The app's theme button changed its preference: the page follows (and, through setTheme, every demo).
window.addEventListener("gpuvm-prefs", () => {
  const theme = resolvedTheme(readPrefs().theme);
  window.dispatchEvent(new CustomEvent("gpuvm-embed-theme", { detail: theme }));
});

(window as unknown as { GpuVMEmbed: unknown }).GpuVMEmbed = { mount, setTheme };
