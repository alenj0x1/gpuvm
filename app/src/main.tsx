import { createRoot } from "react-dom/client";
import { App } from "./App";
import { PromptCard } from "./PromptCard";
import { initPrefs } from "./prefs";
// Fonts load with the app, not from styles.css, so the website demos can reuse the stylesheet without them.
import "@fontsource/plus-jakarta-sans/400.css";
import "@fontsource/plus-jakarta-sans/500.css";
import "@fontsource/plus-jakarta-sans/600.css";
import "./styles.css";

initPrefs();
// The administrator-prompt card runs in its own small window (label "prompt"; "?prompt" in the browser).
const isPrompt = "__TAURI_INTERNALS__" in window
  ? (window as unknown as { __TAURI_INTERNALS__: { metadata: { currentWindow: { label: string } } } }).__TAURI_INTERNALS__.metadata.currentWindow.label === "prompt"
  : new URLSearchParams(location.search).has("prompt");
if (isPrompt) document.documentElement.classList.add("prompt-window");
createRoot(document.getElementById("root")!).render(isPrompt ? <PromptCard /> : <App />);
