//! screen.capture: Windows.Graphics.Capture of the display the person sees (lab 048: DXGI duplication loses access on
//! GpuVM's virtual display; WGC works), downscaled on the CPU and encoded lossless (WebP by default, PNG on request).
//! The capture session stays open between screenshots (opening costs ~250 ms) and is closed after 30 s unused.
use crate::util::wstr;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use windows::core::Interface;
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem, GraphicsCaptureSession};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Graphics::SizeInt32;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

#[derive(Clone)]
pub struct Output {
    pub adapter: IDXGIAdapter1,
    pub adapter_name: String,
    pub device: String,
    pub rect: RECT,
    pub monitor: HMONITOR,
}

unsafe impl Send for Output {}

/// One display attached to the desktop, as GDI sees it (physical pixels, independent of DPI awareness).
#[derive(Clone, Debug)]
pub struct Display {
    pub device: String,
    pub adapter: String,
    pub rect: RECT,
    pub primary: bool,
    pub monitor: HMONITOR,
}

pub fn displays() -> Vec<Display> {
    use windows::Win32::Graphics::Gdi::*;
    let mut v = Vec::new();
    unsafe {
        let mut i = 0;
        loop {
            let mut dd = DISPLAY_DEVICEW { cb: std::mem::size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
            if !EnumDisplayDevicesW(windows::core::PCWSTR::null(), i, &mut dd, 0).as_bool() {
                break;
            }
            i += 1;
            if (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP).0 == 0 {
                continue;
            }
            let mut dm = DEVMODEW { dmSize: std::mem::size_of::<DEVMODEW>() as u16, ..Default::default() };
            if !EnumDisplaySettingsW(windows::core::PCWSTR(dd.DeviceName.as_ptr()), ENUM_CURRENT_SETTINGS, &mut dm).as_bool() {
                continue;
            }
            let pos = dm.Anonymous1.Anonymous2.dmPosition;
            let rect = RECT { left: pos.x, top: pos.y, right: pos.x + dm.dmPelsWidth as i32, bottom: pos.y + dm.dmPelsHeight as i32 };
            let center = POINT { x: (rect.left + rect.right) / 2, y: (rect.top + rect.bottom) / 2 };
            v.push(Display {
                device: wstr(&dd.DeviceName),
                adapter: wstr(&dd.DeviceString),
                rect,
                primary: (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE).0 != 0,
                monitor: MonitorFromPoint(center, MONITOR_DEFAULTTONEAREST),
            });
        }
    }
    v
}

/// The display the agent works on: the one GpuVM streams (its virtual display driver), else the primary one.
/// With the agent's session a Hyper-V video display (1024x768) can be the primary while the person sees the
/// virtual display (broker finding, Nov 18).
pub fn target_display() -> Option<Display> {
    let all = displays();
    let vdd = |d: &&Display| {
        let a = d.adapter.to_ascii_lowercase();
        a.contains("virtual display") || a.contains("iddsample") || a.contains("mttvdd")
    };
    all.iter().find(vdd).or_else(|| all.iter().find(|d| d.primary)).or(all.first()).cloned()
}

pub fn displays_json() -> Value {
    let t = target_display().map(|d| d.device);
    json!(displays()
        .iter()
        .map(|d| json!({"device": d.device, "adapter": d.adapter, "rect": [d.rect.left, d.rect.top, d.rect.right - d.rect.left, d.rect.bottom - d.rect.top],
                         "primary": d.primary, "target": Some(&d.device) == t.as_ref()}))
        .collect::<Vec<_>>())
}

/// The DXGI output of the target display (for the capture device); the old primary/hardware heuristic as fallback.
pub fn primary_output() -> Option<Output> {
    let target = target_display();
    let mut best: Option<(u8, Output)> = None;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().ok()?;
        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            i += 1;
            let Ok(d) = adapter.GetDesc1() else { continue };
            let software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32) != 0;
            let mut j = 0;
            while let Ok(output) = adapter.EnumOutputs(j) {
                j += 1;
                let Ok(od) = output.GetDesc() else { continue };
                if !od.AttachedToDesktop.as_bool() {
                    continue;
                }
                let r = od.DesktopCoordinates;
                let primary = r.left <= 0 && r.top <= 0 && r.right > 0 && r.bottom > 0;
                let is_target = target.as_ref().is_some_and(|t| t.device.eq_ignore_ascii_case(&wstr(&od.DeviceName)) || t.monitor == od.Monitor);
                let score = (is_target as u8) * 4 + (primary as u8) * 2 + (!software as u8);
                if best.as_ref().map_or(true, |(s, _)| score > *s) {
                    best = Some((score, Output { adapter: adapter.clone(), adapter_name: wstr(&d.Description), device: wstr(&od.DeviceName), rect: r, monitor: od.Monitor }));
                }
            }
        }
    }
    best.map(|(_, o)| o)
}

/// How long after its request a screenshot takes the newest frame (`settleMs` changes it, ≤ MAX_SETTLE; lab 062):
/// an action that just answered "done" reaches the screen a few ms later (a drag's stroke, then the app redrawing the
/// finished stroke). Frames can't tell a change from a still screen: on GpuVM's display Windows delivers ~180 a
/// second either way, and dirty regions need Windows 11 24H2.
pub const SETTLE: Duration = Duration::from_millis(SETTLE_MS);
pub const SETTLE_MS: u64 = 30;
pub const MAX_SETTLE_MS: u64 = 1000;
/// How long a screenshot waits for the first frame of a session (a session opened right after a display change takes
/// longer for its first frame, lab 051).
const FIRST_WAIT: Duration = Duration::from_secs(3);

#[derive(Debug, PartialEq)]
enum Step {
    Take,
    /// wait for a newer frame, at most this long, then ask again
    Wait(Duration),
    Fail,
}

/// What a screenshot does with the newest frame it has (`at` = when it arrived), `start` = when it was asked for:
/// it takes the newest once `settle` passed since the request, never a frame from before that point while newer ones
/// may come; with no frame at all (a session just opened) it waits up to FIRST_WAIT, then fails.
fn step(at: Option<Instant>, start: Instant, now: Instant, settle: Duration) -> Step {
    match at {
        None if now >= start + FIRST_WAIT => Step::Fail,
        None => Step::Wait(start + FIRST_WAIT - now),
        Some(_) if now >= start + settle => Step::Take,
        Some(_) => Step::Wait(start + settle - now),
    }
}

/// The pool's side of a capture, used only by its FrameArrived handler.
struct Pool {
    dev: ID3D11Device,
    ctx: ID3D11DeviceContext,
    d3d: IDirect3DDevice,
    size: SizeInt32,
}

unsafe impl Send for Pool {}

impl Pool {
    /// Takes every frame waiting in the pool and returns a copy of the newest (`resized` when the display changed
    /// size). Run on each FrameArrived, so the pool's two buffers never stay full: with both full, Windows drops new
    /// frames, and a screenshot taken after a drag got the frame from before it (lab 062, 0/10 fresh with 0.4.8).
    fn drain(&mut self, pool: &Direct3D11CaptureFramePool, resized: &mut bool) -> windows::core::Result<Option<ID3D11Texture2D>> {
        let mut newest: Option<windows::Graphics::Capture::Direct3D11CaptureFrame> = None;
        while let Ok(frame) = pool.TryGetNextFrame() {
            let cs = frame.ContentSize()?;
            if cs.Width != self.size.Width || cs.Height != self.size.Height {
                self.size = cs;
                let _ = frame.Close();
                pool.Recreate(&self.d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, cs)?;
                *resized = true;
                if let Some(old) = newest.take() {
                    let _ = old.Close();
                }
                continue;
            }
            // only the newest is copied
            if let Some(old) = newest.replace(frame) {
                let _ = old.Close();
            }
        }
        let Some(frame) = newest else { return Ok(None) };
        let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
        let tex: ID3D11Texture2D = unsafe { access.GetInterface()? };
        let own = unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            tex.GetDesc(&mut desc);
            let od = D3D11_TEXTURE2D_DESC { BindFlags: 0, CPUAccessFlags: 0, MiscFlags: 0, Usage: D3D11_USAGE_DEFAULT, ..desc };
            let mut own = None;
            self.dev.CreateTexture2D(&od, None, Some(&mut own))?;
            let own = own.unwrap();
            self.ctx.CopyResource(&own, &tex);
            own
        };
        let _ = frame.Close();
        Ok(Some(own))
    }
}

/// What a screenshot reads: the newest frame's copy and when it arrived. Its lock is never held across a call into
/// Direct3D or the pool: the FrameArrived handler holds the device while it waits for this lock, and a screenshot
/// that copied the frame under it hung (lab 062).
#[derive(Default)]
struct Latest {
    frame: Option<(ID3D11Texture2D, Instant)>,
    /// frames delivered since the session opened
    count: u64,
    resized: bool,
    error: Option<String>,
}

unsafe impl Send for Latest {}

type Shared = std::sync::Arc<(Mutex<Latest>, std::sync::Condvar)>;

pub struct Wgc {
    dev: ID3D11Device,
    ctx: ID3D11DeviceContext,
    pool: Direct3D11CaptureFramePool,
    session: GraphicsCaptureSession,
    latest: Shared,
    arrived: i64,
    pub output: Output,
    pub last_used: Instant,
    pub opened_ms: f64,
    /// frames that arrived while the last screenshot waited for the screen to settle
    pub settle_frames: u64,
}

unsafe impl Send for Wgc {}

impl Drop for Wgc {
    fn drop(&mut self) {
        let _ = self.pool.RemoveFrameArrived(self.arrived);
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}

fn device_for(adapter: &IDXGIAdapter1) -> windows::core::Result<(ID3D11Device, ID3D11DeviceContext)> {
    let mut dev = None;
    let mut ctx = None;
    unsafe {
        D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, HMODULE::default(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, None, D3D11_SDK_VERSION, Some(&mut dev), None, Some(&mut ctx))?;
    }
    let (dev, ctx) = (dev.unwrap(), ctx.unwrap());
    // the handler's thread and the screenshot's both use the immediate context
    let mt: ID3D11Multithread = ctx.cast()?;
    unsafe {
        let _ = mt.SetMultithreadProtected(true);
    }
    Ok((dev, ctx))
}

impl Wgc {
    pub fn open(o: Output) -> windows::core::Result<Wgc> {
        let t = Instant::now();
        let (dev, ctx) = device_for(&o.adapter)?;
        let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
        let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(o.monitor)? };
        let dxgi: IDXGIDevice = dev.cast()?;
        let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)?.cast()? };
        let size = item.Size()?;
        let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size)?;
        let latest: Shared = std::sync::Arc::new((Mutex::new(Latest::default()), std::sync::Condvar::new()));
        let shared = latest.clone();
        let own = Mutex::new(Pool { dev: dev.clone(), ctx: ctx.clone(), d3d, size });
        // The handler gets the pool as its sender (holding the pool here would keep it alive through its own handler)
        // and returns at once when raised again on its own thread while draining (that loop takes the frame).
        let arrived = pool.FrameArrived(&windows::Foundation::TypedEventHandler::new(move |sender: windows::core::Ref<Direct3D11CaptureFramePool>, _| {
            thread_local!(static DRAINING: std::cell::Cell<bool> = const { std::cell::Cell::new(false) });
            if DRAINING.with(|d| d.replace(true)) {
                return Ok(());
            }
            if let Ok(pool) = sender.ok() {
                let mut resized = false;
                let got = own.lock().unwrap().drain(pool, &mut resized);
                let (lock, cv) = &*shared;
                let mut l = lock.lock().unwrap();
                l.resized |= resized;
                if resized {
                    l.frame = None;
                }
                match got {
                    Ok(Some(tex)) => {
                        l.frame = Some((tex, Instant::now()));
                        l.count += 1;
                    }
                    Ok(None) => {}
                    Err(e) => l.error = Some(e.to_string()),
                }
                drop(l);
                cv.notify_all();
            }
            DRAINING.with(|d| d.set(false));
            Ok(())
        }))?;
        let session = pool.CreateCaptureSession(&item)?;
        let _ = session.SetIsCursorCaptureEnabled(true);
        session.StartCapture()?;
        Ok(Wgc { dev, ctx, pool, session, latest, arrived, output: o, last_used: Instant::now(), opened_ms: t.elapsed().as_secs_f64() * 1e3, settle_frames: 0 })
    }

    /// The screen as tightly packed BGRA, never older than the request when the screen changed: a frame that arrives
    /// after the request started is taken at once; with none, the newest after FRESH_WAIT (see `step`).
    pub fn grab(&mut self, settle: Duration) -> Result<(u32, u32, Vec<u8>), String> {
        self.last_used = Instant::now();
        let start = Instant::now();
        let (lock, cv) = &*self.latest;
        let mut l = lock.lock().unwrap();
        let count = l.count;
        loop {
            if let Some(e) = l.error.take() {
                return Err(format!("capture failed: {e}"));
            }
            let now = Instant::now();
            match step(l.frame.as_ref().map(|f| f.1), start, now, settle) {
                Step::Take => break,
                Step::Fail => return Err("no frame from the display in 3 s".into()),
                Step::Wait(left) => l = cv.wait_timeout(l, left.max(Duration::from_millis(1))).unwrap().0,
            }
        }
        let tex = l.frame.as_ref().unwrap().0.clone();
        self.settle_frames = l.count - count;
        let resized = std::mem::take(&mut l.resized);
        drop(l);
        if resized {
            // the display mode changed: its rect on the desktop (used to place input) too
            if let Some(o) = primary_output().filter(|o| o.monitor == self.output.monitor) {
                self.output.rect = o.rect;
            }
        }
        unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            tex.GetDesc(&mut desc);
            let sd = D3D11_TEXTURE2D_DESC {
                Width: desc.Width,
                Height: desc.Height,
                MipLevels: 1,
                ArraySize: 1,
                Format: desc.Format,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                Usage: D3D11_USAGE_STAGING,
                BindFlags: 0,
                CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
                MiscFlags: 0,
            };
            let mut staging = None;
            self.dev.CreateTexture2D(&sd, None, Some(&mut staging)).map_err(|e| e.to_string())?;
            let staging = staging.unwrap();
            self.ctx.CopyResource(&staging, &tex);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            self.ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(|e| e.to_string())?;
            let (w, h) = (desc.Width as usize, desc.Height as usize);
            let mut out = vec![0u8; w * h * 4];
            for y in 0..h {
                let src = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
                out[y * w * 4..(y + 1) * w * 4].copy_from_slice(src);
            }
            self.ctx.Unmap(&staging, 0);
            Ok((desc.Width, desc.Height, out))
        }
    }
}

/// The open capture, shared by the request loop and the idle timer.
pub static CAPTURE: Mutex<Option<Wgc>> = Mutex::new(None);

/// Closes the capture when unused for 30 s (called by the events thread).
pub fn close_if_idle() {
    let mut g = CAPTURE.lock().unwrap();
    if g.as_ref().is_some_and(|w| w.last_used.elapsed() > Duration::from_secs(30)) {
        *g = None;
    }
}

/// [x,y,w,h] (non-negative integers) fully inside fw x fh, with no overflow on the way (security review 7).
pub fn region_inside(v: &[u64], fw: u32, fh: u32) -> Option<(u32, u32, u32, u32)> {
    if v.len() != 4 || v[2] == 0 || v[3] == 0 {
        return None;
    }
    let (x, y, w, h) = (v[0], v[1], v[2], v[3]);
    if x.checked_add(w)? > fw as u64 || y.checked_add(h)? > fh as u64 {
        return None;
    }
    Some((x as u32, y as u32, w as u32, h as u32))
}

#[cfg(test)]
mod tests {
    use super::{region_inside, step, Step, FIRST_WAIT, SETTLE};
    use std::time::{Duration, Instant};

    #[test]
    fn a_screenshot_takes_the_newest_frame_once_the_screen_had_time_to_show_the_last_action() {
        let start = Instant::now() + Duration::from_secs(10);
        let ms = |n: u64| start + Duration::from_millis(n);
        let before = Some(start - Duration::from_millis(5));
        // a frame from before the request, or one right after it: not yet (the action's frames may be on their way)
        assert_eq!(step(before, start, start, SETTLE), Step::Wait(SETTLE));
        assert_eq!(step(Some(ms(3)), start, ms(3), SETTLE), Step::Wait(SETTLE - Duration::from_millis(3)));
        // the newest, once SETTLE passed
        assert_eq!(step(before, start, start + SETTLE, SETTLE), Step::Take);
        assert_eq!(step(Some(ms(29)), start, start + SETTLE, SETTLE), Step::Take);
        // settleMs 0: whatever is newest, at once
        assert_eq!(step(before, start, start, Duration::ZERO), Step::Take);
        // no frame yet (a session just opened): up to FIRST_WAIT, then fail
        assert_eq!(step(None, start, ms(500), SETTLE), Step::Wait(FIRST_WAIT - Duration::from_millis(500)));
        assert_eq!(step(None, start, start + FIRST_WAIT, SETTLE), Step::Fail);
    }

    #[test]
    fn regions() {
        assert_eq!(region_inside(&[0, 0, 1366, 768], 1366, 768), Some((0, 0, 1366, 768)));
        assert_eq!(region_inside(&[1, 0, 1366, 768], 1366, 768), None);
        assert_eq!(region_inside(&[u64::MAX, 0, 2, 2], 1366, 768), None);
        assert_eq!(region_inside(&[0, 0, u64::MAX, 1], 1366, 768), None);
        assert_eq!(region_inside(&[0, 0, 0, 5], 1366, 768), None);
        assert_eq!(region_inside(&[0, 0, 5], 1366, 768), None);
    }
}

/// Crop of a BGRA frame.
fn crop(bgra: &[u8], w: u32, x: u32, y: u32, cw: u32, ch: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity((cw * ch * 4) as usize);
    for row in y..y + ch {
        let s = ((row * w + x) * 4) as usize;
        out.extend_from_slice(&bgra[s..s + (cw * 4) as usize]);
    }
    out
}

/// BGRA -> RGB with an area-average downscale to fit max_w x max_h (no upscaling), in one pass.
pub fn to_rgb_fit(bgra: &[u8], w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32, Vec<u8>) {
    let k = f64::min(max_w as f64 / w as f64, max_h as f64 / h as f64).min(1.0);
    let nw = ((w as f64 * k).round() as u32).max(1);
    let nh = ((h as f64 * k).round() as u32).max(1);
    let (w, h) = (w as usize, h as usize);
    if nw as usize == w && nh as usize == h {
        let mut rgb = Vec::with_capacity(w * h * 3);
        for p in bgra.chunks_exact(4) {
            rgb.extend_from_slice(&[p[2], p[1], p[0]]);
        }
        return (nw, nh, rgb);
    }
    let (nw_, nh_) = (nw as usize, nh as usize);
    let span = |n: usize, full: usize, i: usize| -> (usize, usize) {
        let a = i * full / n;
        let b = (((i + 1) * full + n - 1) / n).min(full).max(a + 1);
        (a, b)
    };
    let xs: Vec<(usize, usize)> = (0..nw_).map(|i| span(nw_, w, i)).collect();
    let mut out = vec![0u8; nw_ * nh_ * 3];
    let mut acc = vec![[0u32; 3]; nw_];
    for oy in 0..nh_ {
        let (y0, y1) = span(nh_, h, oy);
        acc.iter_mut().for_each(|a| *a = [0; 3]);
        for y in y0..y1 {
            let row = &bgra[y * w * 4..(y + 1) * w * 4];
            for (ox, &(x0, x1)) in xs.iter().enumerate() {
                let a = &mut acc[ox];
                for p in row[x0 * 4..x1 * 4].chunks_exact(4) {
                    a[0] += p[2] as u32;
                    a[1] += p[1] as u32;
                    a[2] += p[0] as u32;
                }
            }
        }
        for (ox, &(x0, x1)) in xs.iter().enumerate() {
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = (oy * nw_ + ox) * 3;
            out[o] = (acc[ox][0] / n) as u8;
            out[o + 1] = (acc[ox][1] / n) as u8;
            out[o + 2] = (acc[ox][2] / n) as u8;
        }
    }
    (nw, nh, out)
}

pub fn encode_png(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    {
        let mut e = png::Encoder::new(&mut buf, w, h);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.set_compression(png::Compression::Fast);
        let mut wr = e.write_header().unwrap();
        wr.write_image_data(rgb).unwrap();
    }
    buf
}

pub fn encode_webp(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    image_webp::WebPEncoder::new(&mut buf).encode(rgb, w, h, image_webp::ColorType::Rgb8).unwrap();
    buf
}

/// The captured display's rect on the virtual desktop (where protocol coordinates start), read fresh every time
/// (the mode can change under us, e.g. when the viewer connects): the primary monitor, as primary_output() picks.
pub fn output_rect() -> Option<RECT> {
    target_display().map(|d| d.rect).or_else(|| primary_output().map(|o| o.rect))
}

pub type CallResult = Result<(Value, Option<Vec<u8>>), (&'static str, String)>;

pub fn screen_capture(p: &Value) -> CallResult {
    let t0 = Instant::now();
    let desk = crate::state::desktop_state();
    if desk != "default" {
        return Err(("secure_desktop", format!("the input desktop is {desk}: only the person can act there")));
    }
    let max_w = p["maxW"].as_u64().unwrap_or(1280).clamp(16, 3840) as u32;
    let max_h = p["maxH"].as_u64().unwrap_or(800).clamp(16, 2160) as u32;
    let settle = Duration::from_millis(p["settleMs"].as_u64().unwrap_or(SETTLE_MS).min(MAX_SETTLE_MS));
    let format = p["format"].as_str().unwrap_or("webp");
    if format != "webp" && format != "png" {
        return Err(("bad_request", "format is webp or png".into()));
    }
    let mut g = CAPTURE.lock().unwrap();
    let mut open_ms = 0.0;
    // the target display changed (topology change, viewer connected): capture the new one
    let target = target_display().map(|d| d.monitor);
    if g.as_ref().is_some_and(|w| Some(w.output.monitor) != target) {
        *g = None;
    }
    if g.is_none() {
        let o = primary_output().ok_or(("internal", "no display output to capture".to_string()))?;
        let w = Wgc::open(o).map_err(|e| ("internal", format!("can't open the screen capture: {e}")))?;
        open_ms = w.opened_ms;
        *g = Some(w);
    }
    let wgc = g.as_mut().unwrap();
    let t = Instant::now();
    let grabbed = wgc.grab(settle);
    let (fw, fh, bgra) = match grabbed {
        Ok(x) => x,
        Err(e) => {
            *g = None; // reopen next time
            return Err(("internal", e));
        }
    };
    let grab_ms = t.elapsed().as_secs_f64() * 1e3;
    let settle_frames = wgc.settle_frames;
    drop(g);
    let (src, sw, sh, region) = match p.get("region").filter(|r| !r.is_null()) {
        Some(r) => {
            let v: Vec<u64> = r.as_array().map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default();
            let Some((x, y, w, h)) = region_inside(&v, fw, fh) else {
                return Err(("bad_request", format!("region must be [x,y,w,h] inside the {fw}x{fh} screen")));
            };
            (crop(&bgra, fw, x, y, w, h), w, h, Some([x, y, w, h]))
        }
        None => (bgra, fw, fh, None),
    };
    let t = Instant::now();
    let (w, h, rgb) = to_rgb_fit(&src, sw, sh, max_w, max_h);
    let scale_ms = t.elapsed().as_secs_f64() * 1e3;
    let t = Instant::now();
    let img = if format == "png" { encode_png(&rgb, w, h) } else { encode_webp(&rgb, w, h) };
    let encode_ms = t.elapsed().as_secs_f64() * 1e3;
    let mut res = json!({
        "w": w, "h": h, "scale": (w as f64 / sw as f64 * 10000.0).round() / 10000.0, "format": format,
        "screen": {"w": fw, "h": fh},
        "ms": {"open": (open_ms * 10.0).round() / 10.0, "grab": (grab_ms * 10.0).round() / 10.0, "scale": (scale_ms * 10.0).round() / 10.0,
               "encode": (encode_ms * 10.0).round() / 10.0, "total": (t0.elapsed().as_secs_f64() * 1e4).round() / 10.0},
        "settleFrames": settle_frames,
    });
    if let Some(r) = region {
        res["region"] = json!(r);
    }
    Ok((res, Some(img)))
}
