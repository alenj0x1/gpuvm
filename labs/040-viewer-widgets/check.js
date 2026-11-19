// Lab 040: the viewer panel's widget board, checked in every state.
// Run in the browser preview on any page of the dev server (javascript_tool or the console). It loads the panel
// (?viewer-panel&vm=win10, mock data) in an iframe per case and returns a report:
//   sizes: every widget at every size it allows, at panel widths 300/340/440/560, light and dark. A case fails when
//          something sticks out of its widget, a text is cut without an ellipsis, or content is clipped in a widget
//          that does not scroll.
//   drags: in edit mode, every widget dropped onto every other one (real pointer events, frame by frame). A case
//          fails when it does not end at the other one's place in the order, or the order goes back and forth
//          during the drag.
// The page's own settings (layout, theme) are saved first and put back at the end.
(async () => {
  // window.LAB040 = { themes, widths, dragWidths } runs a part (a whole run takes several minutes).
  const OPT = window.LAB040 ?? {};
  const WIDTHS = OPT.widths ?? [300, 340, 440, 560];
  // OPT.spec checks only these kinds; OPT.vm and OPT.query load another machine and mock state (lab 054: the agent
  // widget on ?agents=working, paused, many).
  const SPEC = OPT.spec ?? {
    // [minW, maxW, minH, maxH], as SPEC in app/src/ViewerWidgets.tsx.
    machines: [1, 3, 1, 6], actions: [1, 3, 1, 2], stats: [1, 3, 1, 3], clock: [1, 3, 1, 2],
    shelf: [1, 3, 1, 4], games: [1, 3, 1, 3], weather: [1, 3, 1, 2], agent: [2, 3, 1, 4],
  };
  const KEYS = ["gpuvm.viewerPanelWidgets", "gpuvm.prefs", "gpuvm.decor.win10", "gpuvm.decor.win11-pruebas", "gpuvm.weather"];
  const saved = Object.fromEntries(KEYS.map((k) => [k, localStorage.getItem(k)]));
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const figs = (list) => list.map((f, i) => ({ id: "f" + i, figure: f, x: 0, z: 0, rot: 0, size: 1 }));
  localStorage.setItem("gpuvm.decor.win10", JSON.stringify({ color: null, led: null, stickers: [], figures: figs(["duck", "cactus", "robot"]) }));
  localStorage.setItem("gpuvm.decor.win11-pruebas", JSON.stringify({ color: null, led: null, stickers: [], figures: figs(["lucky-cat", "mushroom", "penguin", "bonsai"]) }));
  localStorage.removeItem("gpuvm.weather");

  const frame = document.createElement("iframe");
  frame.style.cssText = "position:fixed;left:0;top:0;height:900px;border:0;z-index:99999;background:#fff";
  document.body.appendChild(frame);
  const load = async (width, layout, theme) => {
    localStorage.setItem("gpuvm.viewerPanelWidgets", JSON.stringify(layout));
    localStorage.setItem("gpuvm.prefs", JSON.stringify({ ...JSON.parse(saved["gpuvm.prefs"] || "{}"), theme }));
    frame.style.width = width + "px";
    frame.src = `/?viewer-panel&vm=${OPT.vm ?? "win10"}${OPT.query ? "&" + OPT.query : ""}&t=` + Math.random();
    await new Promise((r) => (frame.onload = r));
    await sleep(900);
    return frame.contentDocument;
  };

  // Problems inside one widget.
  const inspect = (w) => {
    const box = w.getBoundingClientRect(), out = [];
    const content = w.firstElementChild;
    const scrolls = (el) => el.closest(".vp-scroll");
    if (content && !content.classList.contains("vp-scroll") && content.scrollHeight > content.clientHeight + 1) out.push(`clipped ${content.scrollHeight - content.clientHeight}px`);
    for (const el of w.querySelectorAll("*")) {
      if (el.closest(".vp-remove, .vp-grip")) continue;
      const r = el.getBoundingClientRect();
      if (!r.width || !r.height) continue;
      const sc = scrolls(el);
      const lim = sc && sc !== el ? sc.getBoundingClientRect() : box;
      const inScroll = sc && sc !== el;
      if (!inScroll && (r.left < lim.left - 1 || r.right > lim.right + 1 || r.bottom > lim.bottom + 1 || r.top < lim.top - 1)) out.push(`out ${el.tagName.toLowerCase()}.${el.className?.baseVal ?? el.className}`.slice(0, 80));
      if (inScroll && (r.left < lim.left - 1 || r.right > lim.right + 1)) out.push(`sideways ${el.tagName.toLowerCase()}.${el.className?.baseVal ?? el.className}`.slice(0, 80));
      const cs = getComputedStyle(el);
      if (el.children.length === 0 && el.textContent.trim() && el.scrollWidth > el.clientWidth + 1 && cs.textOverflow !== "ellipsis" && cs.overflow !== "visible")
        out.push(`cut text "${el.textContent.trim().slice(0, 24)}"`);
    }
    return [...new Set(out)];
  };

  const report = { sizes: { cases: 0, fails: [] }, drags: { cases: 0, fails: [] } };
  for (const theme of OPT.themes ?? ["dark", "light"]) {
    for (const width of WIDTHS) {
      for (const [type, [minW, maxW, minH, maxH]] of Object.entries(SPEC)) {
        for (let w = minW; w <= maxW; w++) for (let h = minH; h <= maxH; h++) {
          const cols = width - 24 >= 416 ? 3 : 2;
          if (w > cols) continue;
          const doc = await load(width, [{ type, w, h }], theme);
          const el = doc.querySelector(".vp-widget");
          report.sizes.cases++;
          if (!el) { report.sizes.fails.push(`${theme} ${width}px ${type} ${w}x${h}: not shown`); continue; }
          const bad = inspect(el);
          if (bad.length) report.sizes.fails.push(`${theme} ${width}px ${type} ${w}x${h}: ${bad.join("; ")}`);
        }
      }
    }
  }

  // Drags: in the default layout, every widget to every cell (each column, rows 0 to 6). It must land in that column,
  // at that row or higher (widgets move up while the cells above are free), with nothing overlapping, and never stay
  // lifted. Widgets whose width fills the row only try the first column.
  const DEFAULT = [{ type: "machines", w: 2, h: 2 }, { type: "stats", w: 1, h: 2 }, { type: "clock", w: 1, h: 2 }, { type: "actions", w: 2, h: 2 }, { type: "shelf", w: 3, h: 2 }, { type: "games", w: 3, h: 2 }];
  for (const width of OPT.skipDrags ? [] : OPT.dragWidths ?? [300, 340, 560]) {
    const cols = width - 24 >= 416 ? 3 : 2;
    for (const item of DEFAULT) {
      const w = Math.min(item.w, cols);
      for (let cx = 0; cx <= cols - w; cx++) for (let cy = 0; cy <= 6; cy++) {
        const doc = await load(width, DEFAULT, "dark");
        const win = frame.contentWindow;
        doc.querySelector(".vp-edit").click();
        await sleep(250);
        const board = doc.querySelector(".vp-board"), br = board.getBoundingClientRect();
        const cellW = (br.width - 8 * (cols - 1)) / cols;
        const el = doc.querySelector(`.vp-w-${item.type}`), fr = el.getBoundingClientRect();
        const fire = (type, x, y, t) => (t || win).dispatchEvent(new win.PointerEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0, pointerId: 1, isPrimary: true }));
        const gx = 20, gy = 20, sx = fr.left + gx, sy = fr.top + gy;
        const tx = br.left + cx * (cellW + 8) + gx, ty = br.top + cy * 84 + gy;
        fire("pointerdown", sx, sy, el);
        for (let i = 1; i <= 16; i++) {
          fire("pointermove", sx + (tx - sx) * i / 16, sy + (ty - sy) * i / 16);
          await new Promise((r) => win.requestAnimationFrame(() => win.requestAnimationFrame(r)));
        }
        fire("pointerup", tx, ty);
        await sleep(450);
        report.drags.cases++;
        const saved = JSON.parse(localStorage.getItem("gpuvm.viewerPanelWidgets"));
        const me = saved.find((x) => x.type === item.type);
        const rects = [...doc.querySelectorAll(".vp-widget")].map((n) => n.getBoundingClientRect());
        const overlap = rects.some((a, i) => rects.some((b, j) => j > i && a.left < b.right - 1 && b.left < a.right - 1 && a.top < b.bottom - 1 && b.top < a.bottom - 1));
        const lifted = doc.querySelector(".lifted");
        const shownAt = el.getBoundingClientRect();
        const col = Math.round((shownAt.left - br.left) / (cellW + 8)), row = Math.round((shownAt.top - br.top) / 84);
        const bad = [];
        if (col !== cx) bad.push(`column ${col}`);
        if (row > cy) bad.push(`row ${row}`);
        if (overlap) bad.push("overlap");
        if (lifted) bad.push("stuck lifted");
        // Dropped where it already was: nothing to save.
        if (me.x !== undefined && (me.x !== col || me.y !== row)) bad.push(`saved ${me.x},${me.y} but shown ${col},${row}`);
        if (bad.length) report.drags.fails.push(`${width}px ${item.type} to ${cx},${cy}: ${bad.join(", ")}`);
      }
    }
  }

  // Edge: pulling the last widget down with the pointer held at the panel's bottom edge scrolls the panel and keeps
  // growing the widget up to its limit, then stops (it must stay in view, its bottom inside the panel).
  report.edge = [];
  for (const width of OPT.skipDrags ? [] : OPT.dragWidths ?? [300, 340, 560]) {
    const doc = await load(width, DEFAULT.map((x) => (x.type === "games" ? { ...x, h: 2 } : x)), "dark");
    frame.style.height = "620px";
    await sleep(300);
    const win = frame.contentWindow;
    doc.querySelector(".vp-edit").click();
    await sleep(250);
    const body = doc.querySelector(".viewer-panel-body");
    body.scrollTop = body.scrollHeight;
    await sleep(200);
    const games = doc.querySelector(".vp-w-games"), grip = games.querySelector(".vp-grip").getBoundingClientRect();
    const fire = (type, x, y, el) => (el || win).dispatchEvent(new win.PointerEvent(type, { bubbles: true, clientX: x, clientY: y, button: 0, pointerId: 1, isPrimary: true }));
    const top0 = body.scrollTop, h0 = games.getBoundingClientRect().height, bottom = body.getBoundingClientRect().bottom;
    fire("pointerdown", grip.left + 8, grip.top + 8, games.querySelector(".vp-grip"));
    fire("pointermove", grip.left + 8, bottom - 6);
    await sleep(1500);
    const r = games.getBoundingClientRect();
    const res = { width, scrolled: Math.round(body.scrollTop - top0), grew: Math.round(r.height - h0), bottomInView: r.bottom <= bottom + 2 };
    fire("pointerup", grip.left + 8, bottom - 6);
    await sleep(400);
    res.savedH = JSON.parse(localStorage.getItem("gpuvm.viewerPanelWidgets")).find((x) => x.type === "games").h;
    report.edge.push(res);
    frame.style.height = "900px";
  }

  frame.remove();
  for (const [k, v] of Object.entries(saved)) v === null ? localStorage.removeItem(k) : localStorage.setItem(k, v);
  window.__lab040 = report;
  return { sizes: `${report.sizes.cases - report.sizes.fails.length}/${report.sizes.cases} ok`, drags: `${report.drags.cases - report.drags.fails.length}/${report.drags.cases} ok`, edge: report.edge, sizeFails: report.sizes.fails.slice(0, 40), dragFails: report.drags.fails.slice(0, 30) };
})();
