// Runs before the stylesheet so overlay windows are transparent from their first frame (no white flash).
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
  } catch (e) {}
})();
