import { createRoot } from "react-dom/client";
import { App } from "./App";
import { PromptCard } from "./PromptCard";
import { ViewerPanel } from "./ViewerPanel";
import { initPrefs, usePrefs } from "./prefs";
import { resolveLang } from "./i18n";
// Fonts load with the app, not from styles.css, so the website demos can reuse the stylesheet without them.
import "@fontsource/plus-jakarta-sans/400.css";
import "@fontsource/plus-jakarta-sans/500.css";
import "@fontsource/plus-jakarta-sans/600.css";
import "./styles.css";

initPrefs();
// The web view's own menu (Back, Reload, Inspect) has no place in an app: right click only opens GpuVM's menus.
// Text fields keep it, for copy and paste.
window.addEventListener("contextmenu", (e) => {
  if (!(e.target as HTMLElement)?.closest?.("input, textarea, [contenteditable='true']")) e.preventDefault();
});
// Only GpuVM's own drags (machines, spaces) start a drag: the web view's drag of selected text or of an image showed
// the "not allowed" cursor and swallowed the pointer, so sliders and handles stopped following the mouse.
window.addEventListener("dragstart", (e) => {
  if (!(e.target as HTMLElement)?.closest?.("[draggable='true']")) e.preventDefault();
});
// The administrator-prompt card runs in its own small window (label "prompt"; "?prompt" in the browser).
const isPrompt = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "prompt"
  : new URLSearchParams(location.search).has("prompt");
if (isPrompt) document.documentElement.classList.add("prompt-window");
// The side panel over GpuVM's viewer (label "viewer-panel"; "?viewer-panel" in the browser).
const isViewerPanel = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "viewer-panel"
  : new URLSearchParams(location.search).has("viewer-panel");
if (isViewerPanel) document.documentElement.classList.add("viewer-panel-window");
// A change of language draws the app again (the root re-renders everything under it) without starting it over: a
// remount reset the panels' sizes and left the scenes and cards gray until their data came back.
function Root() {
  resolveLang(usePrefs().lang);
  return isPrompt ? <PromptCard /> : isViewerPanel ? <ViewerPanel /> : <App />;
}
createRoot(document.getElementById("root")!).render(<Root />);
