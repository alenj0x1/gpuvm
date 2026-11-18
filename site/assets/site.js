// GpuVM landing: language, mode, accent and world (the page and every live piece of the app follow them), the
// screenshots per language and mode, the release data and the entrances. No dependencies.
(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const root = document.documentElement;
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const KEY = "gpuvm-site";
  const read = () => { try { return JSON.parse(localStorage.getItem(KEY) || "{}") || {}; } catch { return {}; } };
  const write = (v) => { try { localStorage.setItem(KEY, JSON.stringify(v)); } catch { /* no storage */ } };
  // Each feature starts on its own: one failing piece never takes the rest of the page down.
  const safe = (f) => { try { f(); } catch (e) { console.warn(e); } };

  /* ---------- Icons (Tabler, outline) ---------- */
  const ICONS = {
    github: '<path d="M9 19c-4.3 1.4 -4.3 -2.5 -6 -3m12 5v-3.5c0 -1 .1 -1.4 -.5 -2c2.8 -.3 5.5 -1.4 5.5 -6a4.6 4.6 0 0 0 -1.3 -3.2a4.2 4.2 0 0 0 -.1 -3.2s-1.1 -.3 -3.5 1.3a12.3 12.3 0 0 0 -6.2 0c-2.4 -1.6 -3.5 -1.3 -3.5 -1.3a4.2 4.2 0 0 0 -.1 3.2a4.6 4.6 0 0 0 -1.3 3.2c0 4.6 2.7 5.7 5.5 6c-.6 .6 -.6 1.2 -.5 2v3.5"/>',
    download: '<path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2"/><path d="M7 11l5 5l5 -5"/><path d="M12 4l0 12"/>',
    sun: '<path d="M8 12a4 4 0 1 0 8 0a4 4 0 1 0 -8 0"/><path d="M3 12h1m8 -9v1m8 8h1m-9 8v1m-6.4 -15.4l.7 .7m12.1 -.7l-.7 .7m0 11.4l.7 .7m-12.1 -.7l-.7 .7"/>',
    moon: '<path d="M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446a9 9 0 1 1 -8.313 -12.454z"/>',
    sunset: '<path d="M3 17h1m16 0h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7m-9.7 5.7a4 4 0 0 1 8 0"/><path d="M3 21l18 0"/><path d="M12 9v-6l3 3m-6 0l3 -3"/>',
    cube: '<path d="M21 16.008v-8.018a1.98 1.98 0 0 0 -1 -1.717l-7 -4.008a2.016 2.016 0 0 0 -2 0l-7 4.008c-.619 .355 -1 1.01 -1 1.718v8.018c0 .709 .381 1.363 1 1.717l7 4.008a2.016 2.016 0 0 0 2 0l7 -4.008c.619 -.355 1 -1.01 1 -1.718z"/><path d="M12 22v-10"/><path d="M12 12l8.73 -5.04"/><path d="M3.27 6.96l8.73 5.04"/>',
    circuit: '<path d="M2 12h2l2 -5l3 10l3 -10l3 10l3 -10l1.5 5h2.5"/>',
    lego: '<path d="M9.5 11l.01 0"/><path d="M14.5 11l.01 0"/><path d="M9.5 15a3.5 3.5 0 0 0 5 0"/><path d="M7 5h1v-2h8v2h1a3 3 0 0 1 3 3v9a3 3 0 0 1 -3 3v1h-10v-1a3 3 0 0 1 -3 -3v-9a3 3 0 0 1 3 -3"/>',
    dice: '<path d="M3 5a2 2 0 0 1 2 -2h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14z"/><path d="M8.5 8.5m-.5 0a.5 .5 0 1 0 1 0a.5 .5 0 1 0 -1 0" fill="currentColor"/><path d="M15.5 8.5m-.5 0a.5 .5 0 1 0 1 0a.5 .5 0 1 0 -1 0" fill="currentColor"/><path d="M15.5 15.5m-.5 0a.5 .5 0 1 0 1 0a.5 .5 0 1 0 -1 0" fill="currentColor"/><path d="M8.5 15.5m-.5 0a.5 .5 0 1 0 1 0a.5 .5 0 1 0 -1 0" fill="currentColor"/><path d="M12 12m-.5 0a.5 .5 0 1 0 1 0a.5 .5 0 1 0 -1 0" fill="currentColor"/>',
    layers: '<path d="M12 4l-8 4l8 4l8 -4l-8 -4"/><path d="M4 12l8 4l8 -4"/><path d="M4 16l8 4l8 -4"/>',
    world: '<path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M3.6 9h16.8"/><path d="M3.6 15h16.8"/><path d="M11.5 3a17 17 0 0 0 0 18"/><path d="M12.5 3a17 17 0 0 1 0 18"/>',
    drag: '<path d="M19 11v-2a2 2 0 0 0 -2 -2h-8a2 2 0 0 0 -2 2v8a2 2 0 0 0 2 2h2"/><path d="M13 13l9 3l-4 2l-2 4l-3 -9"/><path d="M3 3l0 .01"/><path d="M7 3l0 .01"/><path d="M11 3l0 .01"/><path d="M15 3l0 .01"/><path d="M3 7l0 .01"/><path d="M3 11l0 .01"/><path d="M3 15l0 .01"/>',
    bolt: '<path d="M13 3l0 7l6 0l-8 11l0 -7l-6 0l8 -11"/>',
    focus: '<path d="M4 8v-2a2 2 0 0 1 2 -2h2"/><path d="M4 16v2a2 2 0 0 0 2 2h2"/><path d="M16 4h2a2 2 0 0 1 2 2v2"/><path d="M16 20h2a2 2 0 0 0 2 -2v-2"/><path d="M9 12a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/>',
    rotate: '<path d="M12 16h4v4"/><path d="M19.458 11.042c.86 -2.366 .722 -4.58 -.6 -5.9c-2.272 -2.274 -7.185 -1.045 -10.973 2.743c-3.788 3.788 -5.017 8.701 -2.744 10.974c2.227 2.226 6.987 1.093 10.74 -2.515"/>',
    sticker: '<path d="M20 12l-2 .5a6 6 0 0 1 -6.5 -6.5l.5 -2l8 8"/><path d="M20 12a8 8 0 1 1 -8 -8"/>',
    copy: '<path d="M7 7m0 2.667a2.667 2.667 0 0 1 2.667 -2.667h8.666a2.667 2.667 0 0 1 2.667 2.667v8.666a2.667 2.667 0 0 1 -2.667 2.667h-8.666a2.667 2.667 0 0 1 -2.667 -2.667z"/><path d="M4.012 16.737a2.005 2.005 0 0 1 -1.012 -1.737v-10c0 -1.1 .9 -2 2 -2h10c.75 0 1.158 .385 1.5 1"/>',
    layout: '<path d="M4 6a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2z"/><path d="M15 4v16"/>',
    gauge: '<path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 1 0 -18 0"/><path d="M12 12m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M13.41 10.59l2.59 -2.59"/><path d="M7 12a5 5 0 0 1 5 -5"/>',
    gamepad: '<path d="M12 5h3.5a5 5 0 0 1 0 10h-5.5l-4.015 4.227a2.3 2.3 0 0 1 -3.923 -2.035l1.634 -8.173a5 5 0 0 1 4.904 -4.019h3.4z"/><path d="M14 15l4.07 4.284a2.3 2.3 0 0 0 3.925 -2.023l-1.6 -8.232"/><path d="M8 9v2"/><path d="M7 10h2"/><path d="M14 10h2"/>',
    "eye-off": '<path d="M10.585 10.587a2 2 0 0 0 2.829 2.828"/><path d="M16.681 16.673a8.717 8.717 0 0 1 -4.681 1.327c-3.6 0 -6.6 -2 -9 -6c1.272 -2.12 2.712 -3.678 4.32 -4.674m2.86 -1.146a9.055 9.055 0 0 1 1.82 -.18c3.6 0 6.6 2 9 6c-.666 1.11 -1.379 2.067 -2.138 2.87"/><path d="M3 3l18 18"/>',
    shield: '<path d="M12 3a12 12 0 0 0 8.5 3a12 12 0 0 1 -8.5 15a12 12 0 0 1 -8.5 -15a12 12 0 0 0 8.5 -3"/><path d="M9 12l2 2l4 -4"/>',
    signature: '<path d="M14 3v4a1 1 0 0 0 1 1h4"/><path d="M5 8v-3a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2h-5"/><path d="M6 14m-3 0a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/><path d="M4.5 17l-1.5 5l3 -1.5l3 1.5l-1.5 -5"/>',
    disk: '<path d="M4 6a8 3 0 1 0 16 0a8 3 0 1 0 -16 0"/><path d="M4 6v6a8 3 0 0 0 16 0v-6"/><path d="M4 12v6a8 3 0 0 0 16 0v-6"/>',
    adjust: '<path d="M4 10a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M6 4v4"/><path d="M6 12v8"/><path d="M10 16a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M12 4v10"/><path d="M12 18v2"/><path d="M16 7a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M18 4v1"/><path d="M18 9v11"/>',
    rocket: '<path d="M4 13a8 8 0 0 1 7 7a6 6 0 0 0 3 -5a9 9 0 0 0 6 -8a3 3 0 0 0 -3 -3a9 9 0 0 0 -8 6a6 6 0 0 0 -5 3"/><path d="M7 14a6 6 0 0 0 -3 6a6 6 0 0 0 6 -3"/><path d="M15 9m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/>',
    jump: '<path d="M9 20v-8h-3.586a1 1 0 0 1 -.707 -1.707l6.586 -6.586a1 1 0 0 1 1.414 0l6.586 6.586a1 1 0 0 1 -.707 1.707h-3.586v8a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1z"/>',
    trophy: '<path d="M8 21l8 0"/><path d="M12 17l0 4"/><path d="M7 4l10 0"/><path d="M17 4v8a5 5 0 0 1 -10 0v-8"/><path d="M5 9m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M19 9m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/>',
    language: '<path d="M4 5h7"/><path d="M9 3v2c0 4.418 -2.239 8 -5 8"/><path d="M5 9c0 2.144 2.952 3.908 6.7 4"/><path d="M12 20l4 -9l4 9"/><path d="M19.1 18h-6.2"/>',
    "arrows-h": '<path d="M7 8l-4 4l4 4"/><path d="M17 8l4 4l-4 4"/><path d="M3 12l18 0"/>',
    lock: '<path d="M5 13a2 2 0 0 1 2 -2h10a2 2 0 0 1 2 2v6a2 2 0 0 1 -2 2h-10a2 2 0 0 1 -2 -2v-6z"/><path d="M11 16a1 1 0 1 0 2 0a1 1 0 0 0 -2 0"/><path d="M8 11v-4a4 4 0 1 1 8 0v4"/>',
    network: '<path d="M6 9a6 6 0 1 0 12 0a6 6 0 0 0 -12 0"/><path d="M12 3c1.333 .333 2 2.333 2 6s-.667 5.667 -2 6"/><path d="M12 3c-1.333 .333 -2 2.333 -2 6s.667 5.667 2 6"/><path d="M6 9h12"/><path d="M3 20h7"/><path d="M14 20h7"/><path d="M10 20a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M12 15v3"/>',
    key: '<path d="M16.555 3.843l3.602 3.602a2.877 2.877 0 0 1 0 4.069l-2.643 2.643a2.877 2.877 0 0 1 -4.069 0l-.301 -.301l-6.558 6.558a2 2 0 0 1 -1.239 .578l-.175 .008h-1.172a1 1 0 0 1 -.993 -.883l-.007 -.117v-1.172a2 2 0 0 1 .467 -1.284l.119 -.13l.414 -.414h2v-2h2v-2l2.144 -2.144l-.301 -.301a2.877 2.877 0 0 1 0 -4.069l2.643 -2.643a2.877 2.877 0 0 1 4.069 0z"/><path d="M15 9h.01"/>',
    clipboard: '<path d="M9 5h-2a2 2 0 0 0 -2 2v12a2 2 0 0 0 2 2h10a2 2 0 0 0 2 -2v-12a2 2 0 0 0 -2 -2h-2"/><path d="M9 3m0 2a2 2 0 0 1 2 -2h2a2 2 0 0 1 2 2v0a2 2 0 0 1 -2 2h-2a2 2 0 0 1 -2 -2z"/><path d="M9 14l2 2l4 -4"/>',
    book: '<path d="M3 19a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6l0 13"/><path d="M12 6l0 13"/><path d="M21 6l0 13"/>',
    arrow: '<path d="M5 12l14 0"/><path d="M13 18l6 -6"/><path d="M13 6l6 6"/>',
    chevron: '<path d="M6 9l6 6l6 -6"/>',
    heart: '<path d="M19.5 12.572l-7.5 7.428l-7.5 -7.428a5 5 0 1 1 7.5 -6.566a5 5 0 1 1 7.5 6.572"/>',
  };
  const paintIcons = (scope = document) => $$("i[data-ic]", scope).forEach((el) => {
    const name = el.dataset.ic === "mode" ? (root.dataset.mode === "dark" ? "sun" : "moon") : el.dataset.ic;
    el.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] ?? ""}</svg>`;
  });

  /* ---------- The page's choices ---------- */
  const ACCENTS = [["blue", "Azul", "Blue", "#2f5bd3", "#7d9cf0"], ["violet", "Violeta", "Violet", "#6a4fd2", "#a796f2"], ["teal", "Turquesa", "Teal", "#1d7f7c", "#6ccfca"],
    ["green", "Verde", "Green", "#2f8550", "#7dd19c"], ["amber", "Ámbar", "Amber", "#a8650f", "#e7b45e"]];
  const state = { mode: root.dataset.mode, lang: root.dataset.lang, accent: root.dataset.accent, world: root.dataset.world, time: root.dataset.time };
  const embed = () => window.GpuVMEmbed;
  const toEmbed = () => embed()?.configure({ lang: state.lang, theme: state.mode, accent: state.accent, world: state.world, time: state.time });

  function set(change) {
    const before = { ...state };
    Object.assign(state, change);
    write(state);
    root.dataset.mode = state.mode; root.dataset.theme = state.mode;
    root.dataset.lang = state.lang; root.lang = state.lang;
    root.dataset.accent = state.accent; root.dataset.world = state.world; root.dataset.time = state.time;
    if (before.lang !== state.lang) onLang();
    if (before.mode !== state.mode) paintIcons($("[data-toggle-mode]").parentElement);
    syncControls();
    $$("img[data-shot]").forEach(setShot);
    toEmbed();
    if (before.lang !== state.lang || before.mode !== state.mode) renderNews();
    // The live demos are drawn again in the new language; one of them taking focus scrolled the page to the app.
    // The page stays where it was (unless the visitor scrolls meanwhile).
    if (before.lang !== state.lang) holdScroll();
  }
  function holdScroll(ms = 900) {
    const y = scrollY, until = performance.now() + ms;
    let moved = false;
    const stop = () => { moved = true; };
    addEventListener("wheel", stop, { once: true, passive: true });
    addEventListener("touchmove", stop, { once: true, passive: true });
    addEventListener("keydown", stop, { once: true });
    const keep = () => {
      if (moved) return;
      if (Math.abs(scrollY - y) > 1) scrollTo({ top: y, behavior: "instant" });
      if (performance.now() < until) requestAnimationFrame(keep);
    };
    requestAnimationFrame(keep);
  }
  function onLang() {
    document.title = root.getAttribute(state.lang === "es" ? "data-title-es" : "data-title-en");
    // The docs open in the visitor's language.
    $$("a[data-docs]").forEach((a) => { a.href = `docs/${state.lang === "es" ? "es/" : ""}${a.dataset.docsPath ?? ""}`; });
    $$("[data-count]").forEach((el) => { if (!el.dataset.counting) el.textContent = fmtNum(Number(el.dataset.count), Number(el.dataset.dec ?? 0)); });
    $$(".swatch").forEach((b, i) => { b.setAttribute("aria-label", ACCENTS[i][state.lang === "es" ? 1 : 2]); });
  }
  const fmtNum = (v, dec) => v.toLocaleString(state.lang === "es" ? "es" : "en", { minimumFractionDigits: dec, maximumFractionDigits: dec });

  /* ---------- Segmented controls with a sliding pill, and the accent swatches ---------- */
  const segValue = (seg) => state[seg.dataset.seg];
  function placePill(seg) {
    const on = $$("button", seg).find((b) => b.getAttribute("aria-checked") === "true");
    const pill = $(".seg-pill", seg);
    if (!on || !pill || !on.offsetWidth) return;
    pill.style.width = `${on.offsetWidth}px`;
    pill.style.transform = `translateX(${on.offsetLeft}px)`;
  }
  function syncControls() {
    $$("[data-seg]").forEach((seg) => {
      $$("button", seg).forEach((b) => b.setAttribute("aria-checked", String(b.dataset.value === segValue(seg))));
      placePill(seg);
    });
    $$(".swatch").forEach((b) => b.setAttribute("aria-checked", String(b.dataset.value === state.accent)));
  }
  function initControls() {
    $$("[data-seg]").forEach((seg) => {
      const pill = document.createElement("span");
      pill.className = "seg-pill";
      seg.prepend(pill);
      $$("button", seg).forEach((b) => b.addEventListener("click", () => set({ [seg.dataset.seg]: b.dataset.value })));
      new ResizeObserver(() => { seg.classList.add("no-anim"); placePill(seg); requestAnimationFrame(() => seg.classList.remove("no-anim")); }).observe(seg);
    });
    const box = $("[data-swatches]");
    box.innerHTML = ACCENTS.map(([id, es, en, l, d]) => `<button type="button" role="radio" class="swatch" data-value="${id}" style="--l:${l};--d:${d}" aria-label="${state.lang === "es" ? es : en}"></button>`).join("");
    $$(".swatch", box).forEach((b) => b.addEventListener("click", () => set({ accent: b.dataset.value })));
    $("[data-toggle-mode]").addEventListener("click", () => set({ mode: state.mode === "dark" ? "light" : "dark" }));
    $("[data-randomize]").addEventListener("click", () => embed()?.randomize());
    document.fonts?.ready.then(() => $$("[data-seg]").forEach(placePill));
    syncControls();
  }

  /* ---------- Screenshots in the page's language and mode ---------- */
  function setShot(img) {
    let name = img.dataset.shot;
    // Home's screenshot shows the world picked above when there is one of it.
    if (name === "home" && state.world === "board") name = "home-board";
    const src = `images/${name}-${img.dataset.langShot ?? state.lang}-${state.mode}.webp`;
    if (img.getAttribute("src") === src) return;
    if (!img.getAttribute("src")) { img.src = src; return; }
    const next = new Image();
    next.src = src;
    // Swap only once the new one is decoded, so nothing flashes.
    (next.decode ? next.decode() : Promise.resolve()).catch(() => {}).then(() => { img.src = src; });
  }

  /* ---------- Spanish beside English ---------- */
  function initCompare() {
    const box = $("[data-compare]");
    if (!box) return;
    const handle = $(".compare-handle", box);
    const put = (k) => {
      k = Math.max(0, Math.min(1, k));
      box.style.setProperty("--split", `${k * 100}%`);
      box.style.setProperty("--split-n", k);
      handle.setAttribute("aria-valuenow", String(Math.round(k * 100)));
    };
    let k = 0.5, dragging = false;
    const at = (e) => { const r = box.getBoundingClientRect(); return (e.clientX - r.left - 8) / (r.width - 16); };
    box.addEventListener("pointerdown", (e) => { dragging = true; box.setPointerCapture(e.pointerId); put(k = at(e)); });
    box.addEventListener("pointermove", (e) => { if (dragging) put(k = at(e)); });
    box.addEventListener("pointerup", () => { dragging = false; });
    box.addEventListener("pointercancel", () => { dragging = false; });
    handle.addEventListener("keydown", (e) => {
      if (e.key === "ArrowLeft" || e.key === "ArrowRight") { put(k += e.key === "ArrowLeft" ? -0.05 : 0.05); e.preventDefault(); }
    });
    put(k);
  }

  /* ---------- Apps ---------- */
  const APPS = [["steam", "Steam"], ["epic", "Epic Games"], ["battlenet", "Battle.net"], ["ea", "EA app"], ["gog", "GOG Galaxy"], ["ubisoft", "Ubisoft Connect"],
    ["chrome", "Chrome"], ["brave", "Brave"], ["firefox", "Firefox"], ["vlc", "VLC"], ["obs", "OBS Studio"], ["spotify", "Spotify"],
    ["discord", "Discord"], ["7zip", "7-Zip"], ["winrar", "WinRAR"], ["protonvpn", "Proton VPN"]];
  function renderApps() {
    const box = $("[data-apps]");
    box.innerHTML = APPS.map(([id, name]) => `<div class="app-tile"><img src="images/apps/${id}.${id === "spotify" ? "svg" : "png"}" alt="" loading="lazy" width="44" height="44"><span>${name}</span></div>`).join("");
  }

  /* ---------- What's new, from the changelog ---------- */
  let release = null;
  const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const inline = (s) => escape(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "$1").replace(/\*([^*]+)\*/g, "$1");
  // "**Title.** Long text…" -> the title, and the first whole sentence of the text.
  function summarize(text) {
    const m = text.match(/^\*\*(.+?)\*\*\s*(.*)$/);
    const title = m ? m[1].replace(/[.:,]$/, "") : null;
    // Links keep their text; asides in parentheses read better left out; nested points start without their dash.
    const body = (m ? m[2] : text).replace(/\[([^\]]+)\]\([^)]*\)/g, "$1").replace(/\s*\([^()]*\)/g, "").replace(/^-\s*/, "");
    const end = body.search(/\.(\s|$)/);
    let sentence = end > 0 ? body.slice(0, end + 1) : body;
    // A first sentence that is a whole paragraph keeps what comes before its first colon, a whole idea on its own.
    if (sentence.length > 180) {
      const lead = sentence.split(/[:;]/)[0].trim();
      sentence = lead.length <= 180 ? lead.replace(/[,.]?$/, ".") : "";
    }
    // A title that runs on into the text ("**Choose the user** when creating…") leaves the text starting lowercase.
    return { title, body: sentence.charAt(0).toUpperCase() + sentence.slice(1) };
  }
  // A screenshot of the change itself, when the app has a screen for it.
  const THUMBS = [[/personali/i, "personalize"], [/juegos|games/i, "games"], [/mundos|worlds/i, "home-board"], [/espacios|spaces/i, "home"],
    [/biblioteca|library/i, "library"], [/interfaz|interface/i, "machine"], [/crear|create/i, "create"]];
  const thumbFor = (title) => THUMBS.find(([re]) => re.test(title))?.[1] ?? null;
  function renderNews() {
    const box = $("[data-news]");
    if (!box || !release) return;
    const lang = state.lang;
    const sections = release[lang] ?? release.en;
    const tags = { added: ["Nuevo", "New"], changed: ["Cambió", "Changed"], security: ["Seguridad", "Security"], fixed: ["Arreglo", "Fixed"] };
    const items = Object.entries(sections).filter(([k]) => k !== "fixed").flatMap(([kind, list]) => list.map((text) => {
      const s = summarize(text);
      return { kind, ...s, thumb: s.title ? thumbFor(s.title) : null };
    })).filter((i) => i.body);
    // Each row: a wide card with a screenshot of the change (each screen once) beside two text cards, on alternating
    // sides. Without screenshots, rows of three text cards.
    const used = new Set();
    const wide = items.filter((i) => i.thumb && !used.has(i.thumb) && used.add(i.thumb)).slice(0, 3);
    const rest = items.filter((i) => !wide.includes(i));
    const card = ({ kind, title, body, thumb }, isWide, right) => {
      const tag = tags[kind]?.[lang === "es" ? 0 : 1] ?? kind;
      const img = isWide ? `<div class="news-thumb" data-thumb="${thumb}"><img src="images/${thumb}-${lang}-${state.mode}.webp" alt="" loading="lazy" width="1600" height="1000"></div>` : "";
      return `<article class="news${isWide ? " wide" : ""}${right ? " right" : ""}">${img}<div class="news-body">${kind === "added" ? "" : `<span class="news-tag">${tag}</span>`}${title ? `<b>${inline(title)}</b>` : ""}<p class="news-text">${inline(body)}</p></div></article>`;
    };
    let html = "";
    if (wide.length) {
      wide.forEach((w, r) => {
        const pair = rest.slice(r * 2, r * 2 + 2);
        const side = `<div class="news-pair">${pair.map((i) => card(i, false)).join("")}</div>`;
        html += r % 2 ? side + card(w, true, true) : card(w, true, false) + side;
      });
    } else {
      // Full rows of three; a release with one or two changes shows them side by side, filling the row.
      const n = Math.min(rest.length, 6), count = n >= 3 ? n - (n % 3) : n;
      html = rest.slice(0, count).map((i) => card(i, false)).join("");
    }
    // Drawn again (another language or mode) after it was seen: the cards come in already shown, no entrance again.
    const seen = !!box.querySelector(".reveal.in");
    box.innerHTML = html;
    if (seen) box.querySelectorAll(".reveal").forEach((el) => el.classList.add("in"));
    box.dataset.cols = wide.length ? "" : String(Math.min(3, box.children.length));
    const date = release.date ? new Date(release.date + "T12:00:00").toLocaleDateString(lang === "es" ? "es-MX" : "en-US", { year: "numeric", month: "long", day: "numeric" }) : "";
    $("[data-release-date]").textContent = date ? (lang === "es" ? `Publicada el ${date}` : `Released ${date}`) : "";
  }
  async function loadRelease() {
    try {
      const data = await (await fetch("data/changelog.json")).json();
      release = data.releases[0];
      if (!release) return;
      $$("[data-version]").forEach((el) => { el.textContent = release.version; });
      // The download goes straight to this version's installer.
      $$("a[data-download]").forEach((a) => { a.href = `https://github.com/alenj0x1/gpuvm/releases/download/v${release.version}/GpuVM_${release.version}_x64-setup.exe`; });
      $("[data-news-section]").hidden = false;
      renderNews();
      observeReveals();
    } catch { /* the page keeps its links to the latest release */ }
  }

  /* ---------- The app's real components ---------- */
  function mountDemos() {
    const api = embed();
    if (!api) return;
    toEmbed();
    // Each one is built when it comes near the screen, and draws only while it is in view.
    const io = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      io.unobserve(e.target);
      safe(() => api.mount(e.target, { view: e.target.dataset.demo, vm: e.target.dataset.vm }));
    }), { rootMargin: "600px 0px" });
    $$("[data-demo]").forEach((el) => io.observe(el));
    // The app's own Settings change the page.
    addEventListener("gpuvm-embed-prefs", (e) => {
      const d = e.detail || {};
      set({ mode: d.theme === "dark" ? "dark" : "light", accent: d.accent || state.accent, lang: d.lang === "en" ? "en" : "es" });
    });
  }

  /* ---------- Entrances and counters ---------- */
  let revealIo = null;
  function observeReveals() {
    if (!revealIo) return;
    $$(".reveal:not(.in)").forEach((el) => revealIo.observe(el));
  }
  function motion() {
    if (reduced || !("IntersectionObserver" in window)) return;
    root.classList.add("motion");
    revealIo = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (e.isIntersecting) { e.target.classList.add("in"); revealIo.unobserve(e.target); }
    }), { rootMargin: "0px 0px -8% 0px" });
    observeReveals();
    // Counters count up once, in the visitor's number format.
    const countIo = new IntersectionObserver((entries) => entries.forEach((e) => {
      if (!e.isIntersecting) return;
      countIo.unobserve(e.target);
      const el = e.target, target = Number(el.dataset.count), dec = Number(el.dataset.dec ?? 0), t0 = performance.now();
      el.dataset.counting = "1";
      const step = (now) => {
        const k = Math.min(1, (now - t0) / 1400), v = target * (1 - Math.pow(1 - k, 3));
        el.textContent = fmtNum(k < 1 ? v : target, dec);
        if (k < 1) requestAnimationFrame(step); else delete el.dataset.counting;
      };
      requestAnimationFrame(step);
    }), { threshold: 0.6 });
    $$("[data-count]").forEach((el) => countIo.observe(el));
  }

  /* ---------- Start ---------- */
  safe(paintIcons);
  safe(initControls);
  safe(onLang);
  safe(() => $$("img[data-shot]").forEach(setShot));
  safe(renderApps);
  safe(initCompare);
  safe(motion);
  const nav = $("#nav");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();
  loadRelease();
  // The demos' script loads deferred, after this one: mount them once it has run.
  if (embed()) mountDemos(); else addEventListener("DOMContentLoaded", mountDemos);
})();

// The hero's rotating word: each one rises in with its color while the last one leaves, every few seconds; the box
// eases to the new word's width. Paused while the hero is out of view or the tab hidden; still with reduced motion.
(function rotors() {
  const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
  document.querySelectorAll(".rotor").forEach((box) => {
    const words = (box.dataset.words || "").split("|").filter(Boolean);
    if (words.length < 2) return;
    box.textContent = "";
    const spans = words.map((w) => { const s = document.createElement("span"); s.textContent = w; box.appendChild(s); return s; });
    let i = 0;
    const fit = () => { box.style.width = `${spans[i].offsetWidth}px`; };
    spans[0].classList.add("on");
    requestAnimationFrame(fit);
    if (document.fonts) document.fonts.ready.then(fit);
    addEventListener("resize", fit);
    if (reduced) return;
    let visible = true;
    new IntersectionObserver(([e]) => { visible = e.isIntersecting; }).observe(box);
    setInterval(() => {
      if (!visible || document.hidden || !box.offsetParent) return;
      const prev = spans[i];
      i = (i + 1) % spans.length;
      prev.classList.remove("on"); prev.classList.add("out");
      spans[i].classList.remove("out");
      // Back below without being seen, then up.
      spans[i].style.transition = "none"; spans[i].getBoundingClientRect(); spans[i].style.transition = "";
      spans[i].classList.add("on");
      fit();
      setTimeout(() => prev.classList.remove("out"), 650);
    }, 2600);
  });
})();

// The titles' colored half takes the hero word's colors in turn, section after section (both languages alike).
document.querySelectorAll("main h2").forEach((h, i) => {
  h.querySelectorAll("em").forEach((em) => { em.style.color = `var(--rot-${(i % 5) + 1})`; });
});
