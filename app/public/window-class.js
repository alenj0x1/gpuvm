// Runs before the stylesheet paints anything: GpuVM's small windows over a machine's picture (the agent's request,
// the status notch, the admin dock...) are transparent from their first frame. Without it they showed the app's white
// background for a moment while the page loaded (2026-11-21: a white strip over the picture).
(function () {
  var classes = {
    "prompt": "prompt-window", "viewer-panel": "viewer-panel-window", "prompt-dock": "prompt-dock-window",
    "viewer-drop": "drop-window", "agent-live": "agent-live-window", "agent-dock": "agent-dock-window",
    "status-notch": "status-notch-window",
  };
  try {
    var label = window.__TAURI_INTERNALS__.metadata.currentWindow.label;
    if (classes[label]) {
      document.documentElement.classList.add(classes[label]);
      document.documentElement.style.background = "transparent";
    }
  } catch (e) { /* in a browser: main.tsx reads the URL instead */ }
})();
