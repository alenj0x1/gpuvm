import { createRoot } from "react-dom/client";
import { App } from "./App";
import { PromptCard } from "./PromptCard";
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
// The administrator-prompt card runs in its own small window (label "prompt"; "?prompt" in the browser).
const isPrompt = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "prompt"
  : new URLSearchParams(location.search).has("prompt");
if (isPrompt) document.documentElement.classList.add("prompt-window");
// A change of language draws the app again from the top, so every text (memoized ones too) comes out in the new one.
function Root() {
  const lang = resolveLang(usePrefs().lang);
  return isPrompt ? <PromptCard key={lang} /> : <App key={lang} />;
}
createRoot(document.getElementById("root")!).render(<Root />);
