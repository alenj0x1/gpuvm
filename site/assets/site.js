// GpuVM landing: language, mode, the machines' figures, release data and the motion (GSAP).
(() => {
  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => [...el.querySelectorAll(s)];
  const root = document.documentElement;
  const store = { get: (k) => { try { return localStorage.getItem(k); } catch { return null; } }, set: (k, v) => { try { localStorage.setItem(k, v); } catch { /* no storage */ } } };

  /* ---------- Icons (Tabler outline paths) ---------- */
  const ICONS = {
    github: '<path d="M9 19c-4.3 1.4 -4.3 -2.5 -6 -3m12 5v-3.5c0 -1 .1 -1.4 -.5 -2c2.8 -.3 5.5 -1.4 5.5 -6a4.6 4.6 0 0 0 -1.3 -3.2a4.2 4.2 0 0 0 -.1 -3.2s-1.1 -.3 -3.5 1.3a12.3 12.3 0 0 0 -6.2 0c-2.4 -1.6 -3.5 -1.3 -3.5 -1.3a4.2 4.2 0 0 0 -.1 3.2a4.6 4.6 0 0 0 -1.3 3.2c0 4.6 2.7 5.7 5.5 6c-.6 .6 -.6 1.2 -.5 2v3.5"/>',
    download: '<path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2"/><path d="M7 11l5 5l5 -5"/><path d="M12 4l0 12"/>',
    gpu: '<path d="M3 5h18v11h-18z"/><path d="M7 9a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M14 8h3"/><path d="M14 11h3"/><path d="M6 16v3"/><path d="M10 16v3"/><path d="M14 16v3"/>',
    play: '<path d="M7 4v16l13 -8z"/>',
    shield: '<path d="M12 3a12 12 0 0 0 8.5 3a12 12 0 0 1 -8.5 15a12 12 0 0 1 -8.5 -15a12 12 0 0 0 8.5 -3"/><path d="M9 12l2 2l4 -4"/>',
    network: '<path d="M6 9a6 6 0 1 0 12 0a6 6 0 0 0 -12 0"/><path d="M12 3c1.333 .333 2 2.333 2 6s-.667 5.667 -2 6"/><path d="M12 3c-1.333 .333 -2 2.333 -2 6s.667 5.667 2 6"/><path d="M6 9h12"/><path d="M3 20h7"/><path d="M14 20h7"/><path d="M10 20a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M12 15v3"/>',
    sign: '<path d="M14 3v4a1 1 0 0 0 1 1h4"/><path d="M17 21h-10a2 2 0 0 1 -2 -2v-14a2 2 0 0 1 2 -2h7l5 5v11a2 2 0 0 1 -2 2z"/><path d="M9 15l2 2l4 -4"/>',
    key: '<path d="M16.555 3.843l3.602 3.602a2.877 2.877 0 0 1 0 4.069l-2.643 2.643a2.877 2.877 0 0 1 -4.069 0l-.301 -.301l-6.558 6.558a2 2 0 0 1 -1.239 .578l-.175 .008h-1.172a1 1 0 0 1 -.993 -.883l-.007 -.117v-1.172a2 2 0 0 1 .467 -1.284l.119 -.13l.414 -.414h2v-2h2v-2l2.144 -2.144l-.301 -.301a2.877 2.877 0 0 1 0 -4.069l2.643 -2.643a2.877 2.877 0 0 1 4.069 0z"/><path d="M15 9h.01"/>',
    disk: '<path d="M4 6a8 3 0 1 0 16 0a8 3 0 1 0 -16 0"/><path d="M4 6v6a8 3 0 0 0 16 0v-6"/><path d="M4 12v6a8 3 0 0 0 16 0v-6"/>',
    palette: '<path d="M12 21a9 9 0 0 1 0 -18c4.97 0 9 3.582 9 8c0 1.06 -.474 2.078 -1.318 2.828c-.844 .75 -1.989 1.172 -3.182 1.172h-2.5a2 2 0 0 0 -1 3.75a1.3 1.3 0 0 1 -1 2.25"/><path d="M8.5 10.5m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M12.5 7.5m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M16.5 10.5m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/>',
    arrow: '<path d="M5 12l14 0"/><path d="M13 18l6 -6"/><path d="M13 6l6 6"/>',
    book: '<path d="M3 19a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6a9 9 0 0 1 9 0a9 9 0 0 1 9 0"/><path d="M3 6l0 13"/><path d="M12 6l0 13"/><path d="M21 6l0 13"/>',
    sun: '<path d="M12 12m-4 0a4 4 0 1 0 8 0a4 4 0 1 0 -8 0"/><path d="M3 12h1m8 -9v1m8 8h1m-9 8v1m-6.4 -15.4l.7 .7m12.1 -.7l-.7 .7m0 11.4l.7 .7m-12.1 -.7l-.7 .7"/>',
    moon: '<path d="M12 3c.132 0 .263 0 .393 0a7.5 7.5 0 0 0 7.92 12.446a9 9 0 1 1 -8.313 -12.454z"/>',
  };
  const paintIcons = (scope = document) => $$("i[data-ic]", scope).forEach((el) => {
    const name = el.dataset.ic === "mode" ? (root.dataset.mode === "dark" ? "sun" : "moon") : el.dataset.ic;
    el.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] ?? ""}</svg>`;
  });

  /* ---------- The machines' figures (same drawings as the app) ---------- */
  const NORMAL = { colors: { blue: "#2f5bd3", red: "#e5483f", yellow: "#f2b632", green: "#1f8f6a" }, l: "#f6f5f2", d: "#23252a", swap: "yellow", night: null };
  // The app's hidden palette: three quick clicks on a pattern turn every figure purple, black and blue.
  const PURPLE = { colors: { blue: "#6d3fd8", red: "#2f5bd3", yellow: "#9a6cf2", green: "#1e1b26" }, l: "#efe9ff", d: "#120f19", swap: "yellow", night: "green" };
  let pal = NORMAL;
  const FIGURES = {
    fox: ({ l, d }) => `<path d="M26 36 L34 18 L44 34 Z M56 34 L66 18 L74 36 Z" fill="${l}"/><path d="M24 36 L76 36 L50 82 Z" fill="${l}"/><path d="M39 56 L61 56 L50 82 Z" fill="${d}"/><circle cx="39" cy="46" r="3.5" fill="${d}"/><circle cx="61" cy="46" r="3.5" fill="${d}"/>`,
    owl: ({ l, d, a }) => `<path d="M24 30 L36 22 L64 22 L76 30 L76 66 A26 18 0 0 1 24 66 Z" fill="${d}"/><circle cx="38" cy="42" r="11" fill="${l}"/><circle cx="62" cy="42" r="11" fill="${l}"/><circle cx="38" cy="42" r="4.5" fill="${d}"/><circle cx="62" cy="42" r="4.5" fill="${d}"/><path d="M45 54 L55 54 L50 63 Z" fill="${a}"/>`,
    planet: ({ l, d, a }) => `<circle cx="50" cy="50" r="20" fill="${a}"/><ellipse cx="50" cy="50" rx="34" ry="9" fill="none" stroke="${d}" stroke-width="5" transform="rotate(-20 50 50)"/><circle cx="76" cy="24" r="4" fill="${d}"/><circle cx="24" cy="76" r="2.5" fill="${d}"/>`,
    rocket: ({ l, d, a, b }) => `<path d="M50 14 C63 25 65 48 59 66 L41 66 C35 48 37 25 50 14 Z" fill="${l}"/><circle cx="50" cy="38" r="6.5" fill="${b}"/><path d="M41 54 L30 70 L41 66 Z M59 54 L70 70 L59 66 Z" fill="${a}"/><path d="M45 66 L50 84 L55 66 Z" fill="${d}"/>`,
    penguin: ({ l, d, a }) => `<ellipse cx="50" cy="52" rx="24" ry="30" fill="${d}"/><ellipse cx="50" cy="58" rx="15" ry="21" fill="${l}"/><circle cx="43" cy="40" r="4" fill="${l}"/><circle cx="57" cy="40" r="4" fill="${l}"/><circle cx="43" cy="40" r="2" fill="${d}"/><circle cx="57" cy="40" r="2" fill="${d}"/><path d="M45 46 L55 46 L50 53 Z" fill="${a}"/><path d="M36 80 H46 M54 80 H64" stroke="${a}" stroke-width="5" stroke-linecap="round"/>`,
    moon: ({ l }) => `<path d="M58 18 A32 32 0 1 0 82 66 A26 26 0 1 1 58 18 Z" fill="${l}"/><path d="M70 22 L72 28 L78 30 L72 32 L70 38 L68 32 L62 30 L68 28 Z" fill="${l}"/><circle cx="78" cy="48" r="2.5" fill="${l}"/>`,
    sailboat: ({ l, d, a }) => `<path d="M48 16 L48 62 L22 62 Z" fill="${l}"/><path d="M53 26 L53 62 L76 62 Z" fill="${a}"/><path d="M16 66 H84 L74 80 H26 Z" fill="${d}"/>`,
    bear: ({ l, d }) => `<circle cx="30" cy="30" r="10" fill="${d}"/><circle cx="70" cy="30" r="10" fill="${d}"/><circle cx="50" cy="54" r="28" fill="${d}"/><ellipse cx="50" cy="64" rx="12" ry="9" fill="${l}"/><circle cx="50" cy="60" r="3.5" fill="${d}"/><circle cx="40" cy="48" r="3.5" fill="${l}"/><circle cx="60" cy="48" r="3.5" fill="${l}"/>`,
    cat: ({ d, a }) => `<path d="M26 46 L28 20 L46 34 Z M74 46 L72 20 L54 34 Z" fill="${d}"/><circle cx="50" cy="56" r="26" fill="${d}"/><circle cx="40" cy="53" r="5" fill="${a}"/><circle cx="60" cy="53" r="5" fill="${a}"/><path d="M46 64 L54 64 L50 69 Z" fill="${a}"/>`,
    whale: ({ l, d }) => `<path d="M14 58 C14 42 32 34 50 36 C64 38 72 46 72 54 L84 42 L86 66 L74 62 C68 70 54 74 40 72 C24 70 14 66 14 58 Z" fill="${l}"/><path d="M20 62 C32 66 50 66 64 60" fill="none" stroke="${d}" stroke-width="3" stroke-linecap="round"/><circle cx="30" cy="50" r="3.5" fill="${d}"/><path d="M40 30 V20 M40 24 L32 16 M40 24 L48 16" stroke="${l}" stroke-width="4" stroke-linecap="round"/>`,
  };
  function paintFigures() {
    $$(".fig[data-fig]").forEach((el) => {
      const key = el.dataset.c in pal.colors ? el.dataset.c : "blue";
      const bg = pal.colors[key];
      // On the palest background the light ink barely shows (light and dark swap); on the near-black one the dark
      // ink would vanish (it becomes purple), as in the app.
      const [l, d] = key === pal.swap ? [pal.d, pal.l] : key === pal.night ? [pal.l, pal.colors.yellow] : [pal.l, pal.d];
      const others = Object.values(pal.colors).filter((c) => c !== bg && c !== d);
      const art = FIGURES[el.dataset.fig]?.({ l, d, a: others[0], b: others[1] }) ?? "";
      el.innerHTML = `<svg viewBox="0 0 100 100" aria-hidden="true"><rect width="100" height="100" rx="24" fill="${bg}"/>${art}</svg>`;
    });
  }

  /* ---------- The pattern you can change ---------- */
  const CYCLE = ["fox", "owl", "planet", "rocket", "penguin", "moon", "sailboat", "bear", "cat", "whale"];
  const HUES = ["red", "blue", "yellow", "green"];
  let step = 0;
  // A triple click, as in the app: each click less than 300 ms after the previous one.
  let streak = 0, lastClick = -Infinity;
  function nextPattern() {
    const big = $("[data-pattern]");
    // Three quick clicks switch the palette of every figure on the page; the clicks before it are undone.
    const now = performance.now();
    streak = now - lastClick < 300 ? streak + 1 : 1;
    lastClick = now;
    if (streak >= 3) {
      streak = 0;
      pal = pal === NORMAL ? PURPLE : NORMAL;
      step = Math.max(0, step - 2);
    } else step++;
    big.dataset.fig = CYCLE[step % CYCLE.length];
    big.dataset.c = HUES[(step * 3 + 1) % HUES.length];
    paintFigures();
    if (window.gsap && !matchMedia("(prefers-reduced-motion: reduce)").matches) {
      gsap.fromTo(big, { rotation: -14, scale: .82 }, { rotation: 0, scale: 1, duration: .7, ease: "back.out(2.2)" });
    }
  }

  /* ---------- Language and mode ---------- */
  function setLang(lang) {
    root.dataset.lang = lang;
    root.lang = lang;
    document.title = root.dataset[lang === "es" ? "titleEs" : "titleEn"];
    $$("[data-set-lang]").forEach((b) => b.classList.toggle("on", b.dataset.setLang === lang));
    // The docs open in the visitor's language.
    $$("a[data-docs]").forEach((a) => { a.href = `docs/${lang === "es" ? "es/" : ""}${a.dataset.docsPath ?? ""}`; });
    store.set("gpuvm-site:lang", lang);
    renderNews();
  }
  function setMode(mode) {
    root.dataset.mode = mode;
    store.set("gpuvm-site:mode", mode);
    paintIcons($("[data-toggle-mode]").parentElement);
    $$("img[data-shot]").forEach(setShot);
    renderNews();
    window.GpuVMEmbed?.setTheme(mode);
  }
  function setShot(img) {
    const src = `images/${img.dataset.shot}${root.dataset.mode === "dark" ? "-dark" : ""}.webp`;
    if (img.getAttribute("src") === src) return;
    const next = new Image();
    next.src = src;
    // Swap only once the new one is decoded, so nothing flashes.
    (next.decode ? next.decode() : Promise.resolve()).catch(() => {}).then(() => { img.src = src; });
  }

  /* ---------- Apps and release data ---------- */
  const APPS = [["steam", "Steam"], ["epic", "Epic Games"], ["battlenet", "Battle.net"], ["ea", "EA app"], ["gog", "GOG Galaxy"], ["ubisoft", "Ubisoft Connect"],
    ["chrome", "Chrome"], ["brave", "Brave"], ["firefox", "Firefox"], ["vlc", "VLC"], ["obs", "OBS Studio"], ["spotify", "Spotify"],
    ["discord", "Discord"], ["7zip", "7-Zip"], ["winrar", "WinRAR"], ["protonvpn", "Proton VPN"]];
  function renderApps() {
    const box = $("[data-apps]");
    if (!box) return;
    box.innerHTML = APPS.map(([id, name]) => `<div class="app-tile"><img src="images/apps/${id}.${id === "spotify" ? "svg" : "png"}" alt="${name}" loading="lazy" width="64" height="64"><span>${name}</span></div>`).join("");
  }

  let release = null;
  const escape = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  const inline = (s) => escape(s).replace(/`([^`]+)`/g, "<code>$1</code>").replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/\*([^*]+)\*/g, "<em>$1</em>");
  // "**Title.** Long text…" -> the title, and the first sentence of the text (no cut mid-sentence).
  function summarize(text) {
    const m = text.match(/^\*\*(.+?)\*\*\s*(.*)$/);
    const title = m ? m[1].replace(/[.:,]$/, "") : null;
    // Asides in parentheses are examples or menu paths: the summary reads better without them.
    const body = (m ? m[2] : text).replace(/\s*\([^()]*\)/g, "");
    // Only a full stop ends the sentence: a colon or semicolon would leave it hanging.
    const end = body.search(/\.(\s|$)/);
    let sentence = end > 0 ? body.slice(0, end + 1) : body;
    // A first sentence that is a whole paragraph keeps what comes before its first colon, a whole idea on its own.
    if (sentence.length > 200) {
      const lead = sentence.split(/[:;]/)[0].trim();
      sentence = lead.length <= 200 ? lead.replace(/[,.]?$/, ".") : "";
    }
    return { title, body: sentence };
  }
  // A thumbnail of the change itself, when the app has a screen for it.
  const THUMBS = [[/inicio|home/i, "home-memory"], [/memoria|memory/i, "memory"], [/plantilla|template/i, "templates-card"],
    [/compartido|shared/i, "shared-card"], [/windows limpio|clean windows/i, "windows"], [/apps/i, "apps"]];
  const WIDE_THUMBS = new Set(["memory", "templates-card", "shared-card"]);
  const thumbFor = (text) => THUMBS.find(([re]) => re.test(text))?.[1] ?? null;
  function renderNews() {
    const box = $("[data-news]");
    if (!box || !release) return;
    const lang = root.dataset.lang;
    const sections = release[lang] ?? release.en;
    const tags = { added: ["Nuevo", "New"], changed: ["Cambió", "Changed"], security: ["Seguridad", "Security"], fixed: ["Arreglo", "Fixed"] };
    // The highlights: the changes the app can show (with a thumbnail) first, six at most, in their own order.
    const items = Object.entries(sections).flatMap(([kind, list]) => list.map((text) => ({ kind, text, thumb: thumbFor(summarize(text).title ?? text.slice(0, 60)) })));
    let shown = [...items.filter((i) => i.thumb), ...items.filter((i) => !i.thumb)].slice(0, 6);
    // Bento rows: a wide card and a narrow one, on alternating sides. Wide thumbnails go in the wide cards.
    const wide = shown.filter((i) => WIDE_THUMBS.has(i.thumb)), narrow = shown.filter((i) => !WIDE_THUMBS.has(i.thumb));
    if (wide.length === narrow.length) {
      shown = wide.flatMap((w, r) => (r % 2 ? [{ ...w, wide: true }, narrow[r]] : [narrow[r], { ...w, wide: true }]));
    }
    const dark = root.dataset.mode === "dark" ? "-dark" : "";
    box.innerHTML = shown.map(({ kind, text, thumb, wide }) => {
      const tag = tags[kind]?.[lang === "es" ? 0 : 1] ?? kind;
      const { title, body } = summarize(text);
      const img = thumb ? `<div class="news-thumb"><img src="images/${thumb}${dark}.webp" alt="" loading="lazy"></div>` : "";
      return `<div class="news-item${wide ? " wide" : ""}">${img}<div class="news-body"><span class="news-tag">${tag}</span>${title ? `<b>${inline(title)}</b>` : ""}<div>${inline(body)}</div></div></div>`;
    }).join("");
    const date = release.date ? new Date(release.date + "T12:00:00").toLocaleDateString(lang === "es" ? "es-MX" : "en-US", { year: "numeric", month: "long", day: "numeric" }) : "";
    const dateEl = $("[data-release-date]");
    if (dateEl) dateEl.textContent = date ? (lang === "es" ? `Publicada el ${date}` : `Released ${date}`) : "";
  }
  async function loadRelease() {
    try {
      const data = await (await fetch("data/changelog.json")).json();
      release = data.releases[0];
      $$("[data-version]").forEach((el) => { el.textContent = release.version; });
      // The download goes straight to this version's installer.
      $$("a[data-download]").forEach((a) => { a.href = `https://github.com/alenj0x1/gpuvm/releases/download/v${release.version}/GpuVM_${release.version}_x64-setup.exe`; });
      renderNews();
    } catch { /* the page keeps its links to the latest release */ }
  }

  /* ---------- The app's real components ---------- */
  function mountDemos() {
    if (!window.GpuVMEmbed) return;
    $$("[data-demo]").forEach((el) => window.GpuVMEmbed.mount(el, { view: el.dataset.demo, vm: el.dataset.vm, theme: root.dataset.mode }));
  }

  /* ---------- Motion ---------- */
  function motion() {
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (!window.gsap || reduced) return;
    gsap.registerPlugin(ScrollTrigger);
    root.classList.add("js-motion");

    // The formation: each figure flies in from its own side, far and turned, and settles into a V
    // around the lead one, which arrives last from below.
    const figs = $$(".formation .fig");
    const tl = gsap.timeline({ defaults: { ease: "expo.out" } });
    figs.forEach((fig) => {
      const pos = Number(fig.dataset.pos);
      if (pos === 0) return;
      const side = Math.sign(pos);
      const rest = { x: 0, y: -Math.abs(pos) * 14, rotation: pos * 3.2 };
      gsap.set(fig, { x: side * (260 + Math.abs(pos) * 120), y: -120 - Math.abs(pos) * 40, rotation: side * (40 + Math.abs(pos) * 25), scale: .4, opacity: 0 });
      tl.to(fig, { ...rest, scale: 1, opacity: 1, duration: 1.6 }, 0.12 * (3 - Math.abs(pos)));
    });
    const lead = $(".formation .fig.lead");
    gsap.set(lead, { y: 90, scale: .6, opacity: 0 });
    tl.to(lead, { y: 0, scale: 1, opacity: 1, duration: 1.4, ease: "back.out(1.6)" }, 0.45);
    // Then the formation breathes, very gently, each figure on its own phase.
    tl.add(() => figs.forEach((fig, i) => gsap.to(fig, { y: `+=${i % 2 ? 5 : -5}`, duration: 2.6 + (i % 3) * .4, ease: "sine.inOut", yoyo: true, repeat: -1 })), "+=0.2");

    gsap.from(".hero-title .line", { y: 40, opacity: 0, duration: 1.1, stagger: .12, ease: "expo.out", delay: .35 });
    gsap.from([".hero-sub", ".hero-actions", ".hero-note"], { y: 20, opacity: 0, duration: 1, stagger: .1, ease: "expo.out", delay: .65 });

    // The app window rises tilted and flattens as you scroll.
    gsap.fromTo(".hero-shot .window", { rotateX: 22, y: 60, opacity: 0 }, { y: 0, opacity: 1, duration: 1.4, ease: "expo.out", delay: .8 });
    gsap.to(".hero-shot .window", { rotateX: 0, ease: "none", scrollTrigger: { trigger: ".hero-shot", start: "top 90%", end: "top 25%", scrub: .6 } });
    // The formation drifts up and apart while leaving.
    figs.forEach((fig) => {
      const pos = Number(fig.dataset.pos);
      gsap.to(fig, { xPercent: pos * 40, yPercent: -60 - Math.abs(pos) * 10, ease: "none", scrollTrigger: { trigger: ".hero", start: "top top", end: "bottom top", scrub: .8 } });
    });

    $$(".reveal").forEach((el) => {
      gsap.to(el, { opacity: 1, y: 0, duration: 1, ease: "expo.out", scrollTrigger: { trigger: el, start: "top 88%", once: true } });
    });
    $$(".app-tile").forEach((tile, i) => gsap.from(tile, { scale: .6, opacity: 0, duration: .8, ease: "back.out(1.8)", delay: (i % 8) * .05, scrollTrigger: { trigger: tile, start: "top 92%", once: true } }));
    $$(".feature-media .window, .feature-media .shot-card, .tree").forEach((el) => gsap.from(el, { y: 50, opacity: 0, duration: 1.2, ease: "expo.out", scrollTrigger: { trigger: el, start: "top 90%", once: true } }));
    $$(".tree-kids > div").forEach((kid, i) => gsap.from(kid, { y: -30, opacity: 0, duration: .9, ease: "back.out(1.6)", delay: .3 + i * .12, scrollTrigger: { trigger: ".tree", start: "top 80%", once: true } }));

    // Counters count up once, in the visitor's number format.
    $$("[data-count]").forEach((el) => {
      const target = Number(el.dataset.count), dec = Number(el.dataset.dec ?? 0), obj = { v: 0 };
      const fmt = () => obj.v.toLocaleString(root.dataset.lang === "es" ? "es" : "en", { minimumFractionDigits: dec, maximumFractionDigits: dec });
      el.textContent = fmt();
      gsap.to(obj, { v: target, duration: 1.6, ease: "power2.out", onUpdate: () => { el.textContent = fmt(); }, scrollTrigger: { trigger: el, start: "top 90%", once: true } });
    });
    $$(".closing-figs .fig").forEach((fig, i) => gsap.from(fig, { y: 40, rotation: (i - 1) * 25, opacity: 0, duration: 1.2, ease: "back.out(1.7)", delay: i * .1, scrollTrigger: { trigger: ".closing", start: "top 75%", once: true } }));
  }

  /* ---------- Start ---------- */
  paintFigures();
  paintIcons();
  renderApps();
  $$("img[data-shot]").forEach(setShot);
  setLang(root.dataset.lang);
  $$("[data-set-lang]").forEach((b) => b.addEventListener("click", () => setLang(b.dataset.setLang)));
  $$("[data-pattern], [data-next-pattern]").forEach((b) => b.addEventListener("click", nextPattern));
  $("[data-toggle-mode]").addEventListener("click", () => setMode(root.dataset.mode === "dark" ? "light" : "dark"));
  const nav = $("#nav");
  const onScroll = () => nav.classList.toggle("scrolled", scrollY > 8);
  addEventListener("scroll", onScroll, { passive: true });
  onScroll();
  loadRelease();
  motion();
  // The demos' script loads deferred, after this one: mount them once it has run.
  if (window.GpuVMEmbed) mountDemos(); else addEventListener("DOMContentLoaded", mountDemos);
  // The app's own sun and moon switch the whole page.
  addEventListener("gpuvm-embed-theme", (e) => { if (e.detail !== root.dataset.mode) setMode(e.detail); });
})();
