import { createRoot } from "react-dom/client";
import { App } from "./App";
import { initPrefs } from "./prefs";
import "./styles.css";

initPrefs();
createRoot(document.getElementById("root")!).render(<App />);
