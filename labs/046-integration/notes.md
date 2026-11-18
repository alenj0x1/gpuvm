# Lab 046: the four new features together in the installed app

**Question:** after merging the admin-prompt dock (042), files and clipboard (043), screenshots and recordings (044) and
restore points, disposable machines and export/import (045), do they all work together in the installed build?

**Setup:** main at 4dd6fa8, installed silently with `labs/039-viewer-bridge/install-build.ps1`; machine `win-gpu`
(HEVC 1080p180); app in English. Screenshots in `shots/` (07-09 are half-scale frames from a film).

| Check | Result |
|---|---|
| Side panel shows Capture, Files and Clipboard | Partial: on a board saved by earlier one-feature builds, Files and Clipboard were missing (01-03). Fixed afterwards, see below. |
| Screenshot (Ctrl+Alt+Shift+P) | PASS: 1920x1080 PNG in Pictures\GpuVM\win-gpu, shown in the widget (04) |
| Recording (Ctrl+Alt+Shift+R, ~11 s) | PASS: HEVC + AAC 48 kHz, 0 ffmpeg errors; AAC decodes in Media Foundation, HEVC needs Microsoft's extension (05-06) |
| Drop a folder (4 files, 41 MB) | PASS: veil, progress card, done card; all 4 SHA-256 match in the guest (07-09) |
| Admin prompt dock | PASS: dock B over the darkened picture; a real click on Deny closed the prompt (10-11) |
| Machine page / Library | PASS: Restore points section shown (12); no templates to show the disposable icon (13) |
| Settings | PASS: "When quitting GpuVM" = Shut them down (14); Captures shows the HEVC hint (15) |

**Found and fixed after the run**
- The panel loads its board more than once; the first load added the new widgets and marked them offered without
  saving the board, so the next load dropped them. Now the board is saved with them at once, and the offered list
  key is `gpuvm.viewerPanelWidgetsOffered.v2` so boards left by the one-feature test builds get them once more.
- In Edit, the tray of widgets to add was below the panel's edge; it now scrolls into view with a 16 px margin.

**Known, left as is:** the capture shortcuts work while the viewer has the keyboard, not while the side panel does.
