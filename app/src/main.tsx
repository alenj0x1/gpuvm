import { createRoot } from "react-dom/client";
import { App } from "./App";
import { PromptCard } from "./PromptCard";
import { PromptDock } from "./PromptDock";
import { ViewerPanel } from "./ViewerPanel";
import { DropZone } from "./DropZone";
import { AgentDock } from "./AgentDock";
import { LiveOverlay } from "./LiveOverlay";
import { StatusNotch } from "./StatusNotch";
import { initPrefs, usePrefs } from "./prefs";
import { logError } from "./ui";
import { resolveLang } from "./i18n";
// Fonts load with the app, not from styles.css, so the website demos can reuse the stylesheet without them.
import "@fontsource/plus-jakarta-sans/400.css";
import "@fontsource/plus-jakarta-sans/500.css";
import "@fontsource/plus-jakarta-sans/600.css";
import "./styles.css";

initPrefs();
window.addEventListener("contextmenu", (e) => {
  if (!(e.target as HTMLElement)?.closest?.("input, textarea, [contenteditable='true']")) e.preventDefault();
});
// Only GpuVM's own drags: the web view's text/image drag swallowed the pointer, so sliders stopped following it.
window.addEventListener("dragstart", (e) => {
  if (!(e.target as HTMLElement)?.closest?.("[draggable='true']")) e.preventDefault();
});
const isPrompt = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "prompt"
  : new URLSearchParams(location.search).has("prompt");
if (isPrompt) document.documentElement.classList.add("prompt-window");
const isViewerPanel = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "viewer-panel"
  : new URLSearchParams(location.search).has("viewer-panel");
if (isViewerPanel) document.documentElement.classList.add("viewer-panel-window");
const isPromptDock = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "prompt-dock"
  : new URLSearchParams(location.search).has("prompt-dock");
if (isPromptDock) document.documentElement.classList.add("prompt-dock-window");
const isDropZone = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "viewer-drop"
  : new URLSearchParams(location.search).has("viewer-drop");
if (isDropZone) document.documentElement.classList.add("drop-window");
const label = (name: string) => "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === name
  : new URLSearchParams(location.search).has(name);
const isAgentDock = label("agent-dock"), isStatusNotch = label("status-notch"), isLive = label("agent-live");
if (isLive) document.documentElement.classList.add("agent-live-window");
if (isAgentDock) document.documentElement.classList.add("agent-dock-window");
if (isStatusNotch) document.documentElement.classList.add("status-notch-window");
// Re-render, not remount: a remount reset panel sizes and left scenes gray until their data came back.
function Root() {
  resolveLang(usePrefs().lang);
  return isLive ? <LiveOverlay /> : isAgentDock ? <AgentDock /> : isStatusNotch ? <StatusNotch /> : isPromptDock ? <PromptDock /> : isPrompt ? <PromptCard /> : isViewerPanel ? <ViewerPanel /> : isDropZone ? <DropZone /> : <App />;
}
window.addEventListener("error", (e) => logError(`${e.message} (${e.filename}:${e.lineno})`));
window.addEventListener("unhandledrejection", (e) => logError(`Unhandled: ${String(e.reason)}`));
createRoot(document.getElementById("root")!).render(<Root />);
