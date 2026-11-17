# Lab 040: the viewer panel's widget board

The panel beside GpuVM's viewer (`app/src/ViewerPanel.tsx`, `app/src/ViewerWidgets.tsx`) is a board of widgets that
people move and resize. This lab checks every state a widget can be in and every move, so nothing looks broken.

## What it checks (`check.js`)

- **Sizes**: each widget alone at every size it allows (`SPEC` limits), at panel widths 300, 340, 440 and 560 px, in
  dark and light. Fails when something sticks out of its widget, a text is cut without an ellipsis, or content is
  clipped in a widget that does not scroll.
- **Drags**: in edit mode, every widget of the default layout dropped at every cell (each column, rows 0 to 6) with
  real pointer events, frame by frame. It must land in that column, at that row or higher (widgets move up into free
  cells), with nothing overlapping, nothing left lifted, and what is saved equal to what is shown.
- **Edge**: the last widget pulled down with the pointer held at the panel's bottom edge: the panel scrolls gently,
  the widget grows up to its limit and stops there, its bottom stays in view.

## How to run

With the dev server up (`npm --prefix app run dev`, or the `gpuvm-ui-widgets` preview on 1440):

```
node labs/040-viewer-widgets/run.mjs 1440
node labs/040-viewer-widgets/run.mjs 1440 '{"themes":["dark"],"widths":[340],"dragWidths":[340]}'
node labs/040-viewer-widgets/shots.mjs 1440 <outDir>
```

`run.mjs` drives a headless Chrome of its own over CDP: the page's clock runs at full speed (a hidden preview pane
freezes animations and synthetic drags) and nothing moves on screen. Don't save app files while it runs: the dev
server reloads the page and the run is lost (it says so). `shots.mjs` saves screenshots of the default and a crowded
layout at each width and theme, normal and in edit mode, for the review by eye that the checks can't do.

## Results (2026-11-17)

- Sizes 400/400 (all widgets, all sizes, 4 widths, 2 themes).
- Drags: first version (order with holes filled) failed: a 1×1 widget always went back to the first hole, so it
  could not be put lower (seen with the clock widget). Second version (order without going back) still could
  not leave a widget in the right column with the left one empty. Final version: each widget keeps its own column and
  row and moves up into free cells; what is shown while held is exactly where it stays. 140/140 at 340 and 560 px.
- Edge: before the fix a pulled widget grew without limit and the panel scrolled to the end (1,680 px); now it stops
  at its maximum (scrolled 168 px, grew 84 px, bottom in view).
