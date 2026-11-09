// Data for the docs diagrams (components/Diagram.astro), shared by the English and Spanish pages.
// Layouts are vertical where they would otherwise be wide, so the text keeps its size on a phone.
type Lang = 'en' | 'es';
const t = (lang: Lang, en: string, es: string) => (lang === 'es' ? es : en);

// Host and VM: the GPU goes down to the VM through GPU-P, image and sound come back to Moonlight.
export const overview = (lang: Lang) => ({
  width: 440,
  height: 520,
  label: t(lang,
    'The host shares its GPU with the VM through GPU-P; GpuVM configures the VM; inside it, Sunshine captures the virtual display and sends image and audio back to Moonlight.',
    'El equipo comparte su GPU con la VM mediante GPU-P; GpuVM configura la VM; dentro, Sunshine captura la pantalla virtual y devuelve imagen y audio a Moonlight.'),
  groups: [
    { x: 10, y: 20, w: 420, h: 170, title: t(lang, 'Your PC · Windows 10/11', 'Tu PC · Windows 10/11'), icon: 'device-desktop-analytics' },
    { x: 10, y: 330, w: 420, h: 170, title: 'VM · Hyper-V', icon: 'brand-windows', titleAt: 'bottom' as const },
  ],
  nodes: [
    { id: 'gpu', x: 80, y: 115, icon: 'gpu', label: 'RTX 4060' },
    { id: 'app', x: 220, y: 115, icon: 'app-window', label: t(lang, 'GpuVM app', 'App GpuVM') },
    { id: 'moon', x: 360, y: 115, icon: 'device-desktop', label: 'Moonlight' },
    { id: 'part', x: 80, y: 405, icon: 'cpu-2', label: t(lang, 'GPU\npartition', 'Parte de\nla GPU') },
    { id: 'disp', x: 220, y: 405, icon: 'device-tv', label: t(lang, 'Virtual\ndisplay', 'Pantalla\nvirtual') },
    { id: 'sun', x: 360, y: 405, icon: 'broadcast', label: 'Sunshine' },
  ],
  edges: [
    { from: 'gpu', to: 'part', label: 'GPU-P' },
    { from: 'app', to: 'disp', label: t(lang, 'configures', 'configura'), dashed: true },
    { from: 'sun', to: 'moon', label: t(lang, 'image + audio', 'imagen + audio') },
    { from: 'disp', to: 'sun' },
  ],
});

// How the app reaches Hyper-V: UI → Rust → (named pipe) GpuVM service → bridge.ps1 → module → Hyper-V, with the CLI
// on the same module. The app runs as the user; only the service is elevated.
export const architecture = (lang: Lang) => ({
  width: 400,
  height: 1110,
  label: t(lang,
    'The React UI calls the Rust side, which runs as the user and talks through a named pipe to the GpuVM service; the service starts bridge.ps1 in PowerShell 7 with the elevated token of the user, the bridge runs cmdlets of the GpuVM module, which the CLI also imports, and the module drives Hyper-V through its backend.',
    'La interfaz en React llama a la parte en Rust, que corre como el usuario y habla por un pipe con nombre con el servicio GpuVM; el servicio inicia bridge.ps1 en PowerShell 7 con el token elevado del usuario, el puente ejecuta cmdlets del módulo GpuVM, que también importa la CLI, y el módulo controla Hyper-V mediante su backend.'),
  groups: [
    { x: 10, y: 20, w: 250, h: 320, title: t(lang, 'GpuVM app · as the user', 'App GpuVM · como el usuario'), icon: 'app-window' },
    { x: 10, y: 400, w: 250, h: 160, title: t(lang, 'Windows service · elevated', 'Servicio de Windows · elevado'), icon: 'shield-lock' },
    { x: 10, y: 620, w: 380, h: 310, title: 'PowerShell 7', icon: 'terminal-2' },
  ],
  nodes: [
    { id: 'ui', x: 135, y: 105, icon: 'brand-react', label: t(lang, 'React UI', 'Interfaz') },
    { id: 'rust', x: 135, y: 265, icon: 'brand-rust', label: t(lang, 'Rust side', 'Parte en Rust') },
    { id: 'host', x: 135, y: 485, icon: 'server-2', label: 'gpuvm-host.exe' },
    { id: 'bridge', x: 135, y: 705, icon: 'code', label: 'bridge.ps1' },
    { id: 'module', x: 135, y: 865, icon: 'packages', label: t(lang, 'GpuVM module', 'Módulo GpuVM') },
    { id: 'cli', x: 315, y: 865, icon: 'terminal', label: 'gpuvm.ps1' },
    { id: 'hyperv', x: 135, y: 1050, icon: 'server', label: 'Hyper-V' },
  ],
  edges: [
    { from: 'ui', to: 'rust', label: 'invoke' },
    { from: 'rust', to: 'host', label: t(lang, 'named pipe', 'pipe con nombre') },
    { from: 'host', to: 'bridge', label: t(lang, 'JSON per line', 'JSON por línea') },
    { from: 'bridge', to: 'module', label: 'cmdlet' },
    { from: 'cli', to: 'module', label: t(lang, 'imports', 'importa'), dashed: true },
    { from: 'module', to: 'hyperv', label: 'backend' },
  ],
});

// Administrator prompts with WGC capture: the guest watcher publishes the prompt through Hyper-V's data exchange, the
// app shows it on the host, and the person's answer goes back through the module to a helper on the secure desktop.
export const adminPrompt = (lang: Lang) => ({
  width: 460,
  height: 520,
  label: t(lang,
    'Inside the VM a watcher publishes the open administrator prompt through Hyper-V data exchange (KVP); the app shows it in a card on the host; Allow or Deny goes to the GpuVM module, which starts a helper on the secure desktop of the VM through PowerShell Direct to press the button.',
    'Dentro de la VM un vigilante publica el aviso de administrador abierto por el intercambio de datos de Hyper-V (KVP); la app lo muestra en una tarjeta en el equipo; Permitir o Rechazar va al módulo GpuVM, que inicia por PowerShell Direct un ayudante en el escritorio seguro de la VM que presiona el botón.'),
  groups: [
    { x: 10, y: 20, w: 440, h: 170, title: t(lang, 'Your PC', 'Tu PC'), icon: 'device-desktop-analytics' },
    { x: 10, y: 330, w: 440, h: 170, title: 'VM · SYSTEM', icon: 'brand-windows', titleAt: 'bottom' as const },
  ],
  nodes: [
    { id: 'card', x: 100, y: 115, icon: 'message-2', label: t(lang, 'App card', 'Tarjeta\nde la app') },
    { id: 'module', x: 350, y: 115, icon: 'packages', label: t(lang, 'GpuVM module', 'Módulo\nGpuVM') },
    { id: 'watcher', x: 100, y: 405, icon: 'eye', label: t(lang, 'Prompt\nwatcher', 'Vigilante\nde avisos') },
    { id: 'helper', x: 350, y: 405, icon: 'hand-click', label: t(lang, 'Secure desktop\nhelper', 'Ayudante del\nescritorio seguro') },
  ],
  edges: [
    { from: 'watcher', to: 'card', label: 'KVP' },
    { from: 'card', to: 'module', label: t(lang, 'Allow / Deny', 'Permitir / Rechazar') },
    { from: 'module', to: 'helper', label: 'PowerShell Direct' },
  ],
});

// Profile inheritance: max-performance extends balanced, which extends base.
export const profiles = (lang: Lang) => ({
  width: 240,
  height: 410,
  label: t(lang, 'max-performance extends balanced, which extends base.', 'max-performance extiende balanced, que extiende base.'),
  nodes: [
    { id: 'max', x: 120, y: 52, icon: 'rocket', label: 'max-performance' },
    { id: 'balanced', x: 120, y: 205, icon: 'adjustments-horizontal', label: 'balanced' },
    { id: 'base', x: 120, y: 358, icon: 'box', label: 'base' },
  ],
  edges: [
    { from: 'max', to: 'balanced', label: 'extends' },
    { from: 'balanced', to: 'base', label: 'extends' },
  ],
});
