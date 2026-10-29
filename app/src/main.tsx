import { createRoot } from "react-dom/client";
import { App } from "./App";
import { initPrefs } from "./prefs";
// Fonts load with the app, not from styles.css, so the website demos can reuse the stylesheet without them.
import "@fontsource/plus-jakarta-sans/400.css";
import "@fontsource/plus-jakarta-sans/500.css";
import "@fontsource/plus-jakarta-sans/600.css";
import "./styles.css";

initPrefs();
createRoot(document.getElementById("root")!).render(<App />);
