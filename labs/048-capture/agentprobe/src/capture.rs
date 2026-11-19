//! Screen capture probes: DXGI Desktop Duplication and Windows.Graphics.Capture, lossless encoding, secure desktop.
use crate::util::*;
use std::time::{Duration, Instant};
use windows::core::{Interface, BOOL};
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::HMONITOR;
use windows::Win32::System::StationsAndDesktops::*;
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

pub struct OutputInfo {
    pub adapter_index: u32,
    pub output_index: u32,
    pub adapter: IDXGIAdapter1,
    pub output: IDXGIOutput,
    pub adapter_name: String,
    pub device_name: String,
    pub rect: RECT,
    pub attached: bool,
    pub monitor: HMONITOR,
    pub vram_mb: u64,
    pub software: bool,
}

pub fn enumerate() -> windows::core::Result<Vec<OutputInfo>> {
    let mut v = Vec::new();
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1()?;
        let mut i = 0;
        while let Ok(adapter) = factory.EnumAdapters1(i) {
            let d = adapter.GetDesc1()?;
            let name = wstr(&d.Description);
            let software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE.0 as u32) != 0;
            let mut j = 0;
            while let Ok(output) = adapter.EnumOutputs(j) {
                let od = output.GetDesc()?;
                v.push(OutputInfo {
                    adapter_index: i,
                    output_index: j,
                    adapter: adapter.clone(),
                    output,
                    adapter_name: name.clone(),
                    device_name: wstr(&od.DeviceName),
                    rect: od.DesktopCoordinates,
                    attached: od.AttachedToDesktop.as_bool(),
                    monitor: od.Monitor,
                    vram_mb: d.DedicatedVideoMemory as u64 >> 20,
                    software,
                });
                j += 1;
            }
            if j == 0 {
                ADAPTERS_NO_OUTPUT.with(|a| a.borrow_mut().push(format!("{{\"adapter\":{i},\"adapterName\":{},\"vramMB\":{},\"software\":{software}}}", jstr(&name), d.DedicatedVideoMemory as u64 >> 20)));
            }
            i += 1;
        }
    }
    Ok(v)
}

thread_local! {
    pub static ADAPTERS_NO_OUTPUT: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) };
}

pub fn outputs_json(list: &[OutputInfo]) -> String {
    let mut extra = ADAPTERS_NO_OUTPUT.with(|a| std::mem::take(&mut *a.borrow_mut()));
    extra.dedup();
    let items: Vec<String> = list
        .iter()
        .map(|o| {
            format!(
                "{{\"adapter\":{},\"output\":{},\"adapterName\":{},\"vramMB\":{},\"software\":{},\"device\":{},\"rect\":[{},{},{},{}],\"attached\":{}}}",
                o.adapter_index,
                if o.output_index == u32::MAX { -1 } else { o.output_index as i64 },
                jstr(&o.adapter_name),
                o.vram_mb,
                o.software,
                jstr(&o.device_name),
                o.rect.left, o.rect.top, o.rect.right, o.rect.bottom,
                o.attached
            )
        })
        .collect();
    let mut all = items;
    all.extend(extra);
    format!("[{}]", all.join(","))
}

/// The output the person sees: attached, containing (0,0) (primary), on a hardware adapter. Falls back to any attached.
pub fn pick(list: Vec<OutputInfo>) -> Option<OutputInfo> {
    let mut best: Option<OutputInfo> = None;
    for o in list {
        if o.output_index == u32::MAX || !o.attached {
            continue;
        }
        let primary = o.rect.left <= 0 && o.rect.top <= 0 && o.rect.right > 0 && o.rect.bottom > 0;
        let score = (primary as u8) * 2 + (!o.software as u8);
        let cur = best.as_ref().map(|b| {
            let p = b.rect.left <= 0 && b.rect.top <= 0 && b.rect.right > 0 && b.rect.bottom > 0;
            (p as u8) * 2 + (!b.software as u8)
        });
        if cur.map_or(true, |c| score > c) {
            best = Some(o);
        }
    }
    best
}

pub fn device_for(adapter: &IDXGIAdapter1) -> windows::core::Result<(ID3D11Device, ID3D11DeviceContext)> {
    let mut dev = None;
    let mut ctx = None;
    unsafe {
        D3D11CreateDevice(
            adapter,
            D3D_DRIVER_TYPE_UNKNOWN,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            None,
            D3D11_SDK_VERSION,
            Some(&mut dev),
            None,
            Some(&mut ctx),
        )?;
    }
    Ok((dev.unwrap(), ctx.unwrap()))
}

/// Copies a GPU texture to CPU memory as tightly packed BGRA.
pub fn read_texture(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, tex: &ID3D11Texture2D) -> windows::core::Result<(u32, u32, Vec<u8>)> {
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
        dev.CreateTexture2D(&sd, None, Some(&mut staging))?;
        let staging = staging.unwrap();
        ctx.CopyResource(&staging, tex);
        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
        ctx.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
        let w = desc.Width as usize;
        let h = desc.Height as usize;
        let mut out = vec![0u8; w * h * 4];
        for y in 0..h {
            let src = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
            out[y * w * 4..(y + 1) * w * 4].copy_from_slice(src);
        }
        ctx.Unmap(&staging, 0);
        Ok((desc.Width, desc.Height, out))
    }
}

/// True when (a sample of) the picture is all black.
pub fn is_blank(bgra: &[u8]) -> bool {
    bgra.chunks_exact(4).step_by(97).all(|p| p[0] < 4 && p[1] < 4 && p[2] < 4)
}

pub fn bgra_to_rgb(bgra: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(bgra.len() / 4 * 3);
    for p in bgra.chunks_exact(4) {
        rgb.extend_from_slice(&[p[2], p[1], p[0]]);
    }
    rgb
}

/// Area-average downscale of RGB to fit inside max_w x max_h keeping the aspect ratio.
pub fn scale_fit(rgb: &[u8], w: u32, h: u32, max_w: u32, max_h: u32) -> (u32, u32, Vec<u8>) {
    let k = f64::min(max_w as f64 / w as f64, max_h as f64 / h as f64).min(1.0);
    let nw = ((w as f64 * k).round() as u32).max(1);
    let nh = ((h as f64 * k).round() as u32).max(1);
    if nw == w && nh == h {
        return (w, h, rgb.to_vec());
    }
    let (w, h) = (w as usize, h as usize);
    let mut out = vec![0u8; nw as usize * nh as usize * 3];
    let sx = w as f64 / nw as f64;
    let sy = h as f64 / nh as f64;
    for oy in 0..nh as usize {
        let y0 = (oy as f64 * sy) as usize;
        let y1 = (((oy + 1) as f64 * sy).ceil() as usize).min(h).max(y0 + 1);
        for ox in 0..nw as usize {
            let x0 = (ox as f64 * sx) as usize;
            let x1 = (((ox + 1) as f64 * sx).ceil() as usize).min(w).max(x0 + 1);
            let mut acc = [0u32; 3];
            for y in y0..y1 {
                let row = &rgb[(y * w + x0) * 3..(y * w + x1) * 3];
                for p in row.chunks_exact(3) {
                    acc[0] += p[0] as u32;
                    acc[1] += p[1] as u32;
                    acc[2] += p[2] as u32;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let o = (oy * nw as usize + ox) * 3;
            out[o] = (acc[0] / n) as u8;
            out[o + 1] = (acc[1] / n) as u8;
            out[o + 2] = (acc[2] / n) as u8;
        }
    }
    (nw, nh, out)
}

pub fn encode_png(rgb: &[u8], w: u32, h: u32, fast: bool) -> Vec<u8> {
    let mut buf = Vec::new();
    {
        let mut e = png::Encoder::new(&mut buf, w, h);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.set_compression(if fast { png::Compression::Fast } else { png::Compression::Balanced });
        let mut wr = e.write_header().unwrap();
        wr.write_image_data(rgb).unwrap();
    }
    buf
}

pub fn encode_webp(rgb: &[u8], w: u32, h: u32) -> Vec<u8> {
    let mut buf = Vec::new();
    image_webp::WebPEncoder::new(&mut buf)
        .encode(rgb, w, h, image_webp::ColorType::Rgb8)
        .unwrap();
    buf
}

/// Name of the input desktop as this process sees it, or the Win32 error opening it.
pub fn input_desktop() -> Result<String, u32> {
    unsafe {
        match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x0001)) {
            Ok(h) => {
                let mut name = [0u16; 128];
                let mut need = 0u32;
                let ok = windows::Win32::System::StationsAndDesktops::GetUserObjectInformationW(
                    HANDLE(h.0),
                    UOI_NAME,
                    Some(name.as_mut_ptr() as *mut _),
                    (name.len() * 2) as u32,
                    Some(&mut need),
                );
                let _ = CloseDesktop(h);
                if ok.is_ok() { Ok(wstr(&name)) } else { Err(GetLastError().0) }
            }
            Err(e) => Err((e.code().0 as u32) & 0xffff),
        }
    }
}

pub struct Dup {
    pub dev: ID3D11Device,
    pub ctx: ID3D11DeviceContext,
    pub dup: IDXGIOutputDuplication,
    pub latest: Option<ID3D11Texture2D>,
    pub frames: u64,
}

pub fn dup_open(o: &OutputInfo) -> windows::core::Result<Dup> {
    // AGENTPROBE_DEVADAPTER=i: create the device on adapter i instead of the output's own (GPU-P shows several).
    let (dev, ctx) = match std::env::var("AGENTPROBE_DEVADAPTER").ok().and_then(|v| v.parse::<u32>().ok()) {
        Some(i) => unsafe {
            let f: IDXGIFactory1 = CreateDXGIFactory1()?;
            device_for(&f.EnumAdapters1(i)?)?
        },
        None => device_for(&o.adapter)?,
    };
    // DuplicateOutput1 (IDXGIOutput5) first: the modern call, required for per-monitor-aware processes and what
    // Sunshine's ddx uses; DuplicateOutput as fallback. AGENTPROBE_DUP=1 forces the old call.
    let dup = unsafe {
        let old = std::env::var("AGENTPROBE_DUP").map(|v| v == "1").unwrap_or(false);
        match (old, o.output.cast::<IDXGIOutput5>()) {
            (false, Ok(o5)) => o5.DuplicateOutput1(&dev, 0, &[DXGI_FORMAT_B8G8R8A8_UNORM])?,
            _ => o.output.cast::<IDXGIOutput1>()?.DuplicateOutput(&dev)?,
        }
    };
    Ok(Dup { dev, ctx, dup, latest: None, frames: 0 })
}

/// One acquire: Ok(true) new frame copied, Ok(false) timeout (screen unchanged), Err(hresult).
pub fn dup_acquire(d: &mut Dup, timeout_ms: u32) -> Result<bool, i32> {
    unsafe {
        let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
        let mut res: Option<IDXGIResource> = None;
        match d.dup.AcquireNextFrame(timeout_ms, &mut info, &mut res) {
            Ok(()) => {}
            Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => return Ok(false),
            Err(e) => return Err(e.code().0),
        }
        let r = (|| -> windows::core::Result<bool> {
            if info.LastPresentTime == 0 && d.latest.is_some() {
                return Ok(false); // pointer-only update
            }
            let tex: ID3D11Texture2D = res.unwrap().cast()?;
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            tex.GetDesc(&mut desc);
            let mut own = None;
            let od = D3D11_TEXTURE2D_DESC { BindFlags: 0, CPUAccessFlags: 0, MiscFlags: 0, Usage: D3D11_USAGE_DEFAULT, ..desc };
            d.dev.CreateTexture2D(&od, None, Some(&mut own))?;
            let own = own.unwrap();
            d.ctx.CopyResource(&own, &tex);
            d.latest = Some(own);
            d.frames += 1;
            Ok(true)
        })();
        let _ = d.dup.ReleaseFrame();
        r.map_err(|e| e.code().0)
    }
}

pub struct Wgc {
    pub dev: ID3D11Device,
    pub ctx: ID3D11DeviceContext,
    pub pool: Direct3D11CaptureFramePool,
    pub session: windows::Graphics::Capture::GraphicsCaptureSession,
    pub latest: Option<ID3D11Texture2D>,
    pub frames: u64,
    pub d3d: IDirect3DDevice,
    pub size: windows::Graphics::SizeInt32,
    pub recreated: u32,
}

pub fn wgc_open(o: &OutputInfo, cursor: bool) -> windows::core::Result<Wgc> {
    let (dev, ctx) = device_for(&o.adapter)?;
    let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>()?;
    let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(o.monitor)? };
    let dxgi: IDXGIDevice = dev.cast()?;
    let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi)?.cast()? };
    let size = item.Size()?;
    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size)?;
    let session = pool.CreateCaptureSession(&item)?;
    let _ = session.SetIsCursorCaptureEnabled(cursor);
    session.StartCapture()?;
    Ok(Wgc { dev, ctx, pool, session, latest: None, frames: 0, d3d, size, recreated: 0 })
}

/// Takes the newest frame if one arrived (drains the pool). Ok(true) when there was a new one.
pub fn wgc_poll(w: &mut Wgc) -> windows::core::Result<bool> {
    let mut got = false;
    while let Ok(frame) = w.pool.TryGetNextFrame() {
        // The display changed size: rebuild the pool at the new size (frames keep the old size otherwise).
        let cs = frame.ContentSize()?;
        if cs.Width != w.size.Width || cs.Height != w.size.Height {
            w.size = cs;
            w.pool.Recreate(&w.d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, cs)?;
            w.recreated += 1;
            let _ = frame.Close();
            continue;
        }
        let surface = frame.Surface()?;
        let access: IDirect3DDxgiInterfaceAccess = surface.cast()?;
        let tex: ID3D11Texture2D = unsafe { access.GetInterface()? };
        unsafe {
            let mut desc = D3D11_TEXTURE2D_DESC::default();
            tex.GetDesc(&mut desc);
            let od = D3D11_TEXTURE2D_DESC { BindFlags: 0, CPUAccessFlags: 0, MiscFlags: 0, Usage: D3D11_USAGE_DEFAULT, ..desc };
            let mut own = None;
            w.dev.CreateTexture2D(&od, None, Some(&mut own))?;
            let own = own.unwrap();
            w.ctx.CopyResource(&own, &tex);
            w.latest = Some(own);
        }
        let _ = frame.Close();
        w.frames += 1;
        got = true;
    }
    Ok(got)
}

fn ms(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1e3
}

/// capture --method dxgi|wgc --n 30 [--save dir] [--max 1280x800]
/// Per sample: grab the newest frame (wait up to 50 ms for one), copy to CPU, convert, scale, encode PNG (fast and
/// balanced) and lossless WebP at full size and scaled. Reports per-step ms and bytes.
pub fn cmd_capture(args: &[String]) -> String {
    let method = arg_or(args, "--method", "dxgi");
    let n: usize = arg_or(args, "--n", "30").parse().unwrap();
    let save = arg(args, "--save");
    let (mw, mh) = parse_wh(&arg_or(args, "--max", "1280x800"));
    let t_open = Instant::now();
    let list = match enumerate() {
        Ok(l) => l,
        Err(e) => return format!("{{\"ok\":false,\"stage\":\"enumerate\",\"hr\":{}}}", e.code().0),
    };
    let outputs = outputs_json(&list);
    let o = match pick(list) {
        Some(o) => o,
        None => return format!("{{\"ok\":false,\"stage\":\"pick\",\"outputs\":{outputs}}}"),
    };
    let chosen = format!("{{\"adapter\":{},\"output\":{},\"name\":{}}}", o.adapter_index, o.output_index, jstr(&o.adapter_name));
    let desk = input_desktop();
    let mut samples = Vec::new();
    let mut open_ms = 0.0;
    let mut reopened = 0u32;
    let mut first_ms = 0.0;
    let result: Result<(), String> = (|| {
        if method == "wgc" {
            let mut w = wgc_open(&o, false).map_err(|e| format!("wgc_open {:#x}", e.code().0))?;
            open_ms = ms(t_open);
            let t = Instant::now();
            while w.latest.is_none() {
                wgc_poll(&mut w).map_err(|e| format!("wgc_poll {:#x}", e.code().0))?;
                if t.elapsed() > Duration::from_secs(5) {
                    return Err("wgc: no first frame in 5 s".into());
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            first_ms = ms(t);
            for i in 0..n {
                let t0 = Instant::now();
                let fresh = wgc_poll(&mut w).map_err(|e| format!("{:#x}", e.code().0))?;
                let tex = w.latest.clone().unwrap();
                samples.push(process(&w.dev, &w.ctx, &tex, t0, fresh, i, &save, mw, mh, &method));
                std::thread::sleep(Duration::from_millis(30 + (i as u64 * 37) % 70));
            }
            let _ = w.session.Close();
            let _ = w.pool.Close();
        } else {
            let mut d = dup_open(&o).map_err(|e| format!("dup_open {:#x}", e.code().0))?;
            open_ms = ms(t_open);
            let t = Instant::now();
            while d.latest.is_none() {
                if let Err(hr) = dup_acquire(&mut d, 100) {
                    // ACCESS_LOST (mode change, desktop switch): re-open like the real agent would, once per 100 ms
                    reopened += 1;
                    if reopened > 100 {
                        return Err(format!("acquire {:#x} after {reopened} re-opens", hr));
                    }
                    std::thread::sleep(Duration::from_millis(100));
                    let o2 = enumerate().ok().and_then(pick).ok_or("no output after access lost")?;
                    d = dup_open(&o2).map_err(|e| format!("dup_open {:#x}", e.code().0))?;
                }
                if t.elapsed() > Duration::from_secs(10) {
                    return Err(format!("dxgi: no first frame in 10 s ({reopened} re-opens)"));
                }
            }
            first_ms = ms(t);
            // The first duplicated frame can be all black (no present yet): give it up to 1 s to get a real one.
            let mut black_first = 0;
            loop {
                let (_, _, px) = read_texture(&d.dev, &d.ctx, d.latest.as_ref().unwrap()).map_err(|e| format!("{:#x}", e.code().0))?;
                if !is_blank(&px) || t.elapsed() > Duration::from_millis(1000) {
                    break;
                }
                black_first += 1;
                dup_acquire(&mut d, 100).map_err(|hr| format!("acquire {:#x}", hr))?;
            }
            first_ms = if black_first > 0 { -ms(t) } else { first_ms };
            for i in 0..n {
                let t0 = Instant::now();
                let fresh = match dup_acquire(&mut d, 0) {
                    Ok(f) => f,
                    Err(_) => {
                        reopened += 1;
                        let o2 = enumerate().ok().and_then(pick).ok_or("no output after access lost")?;
                        let keep = d.latest.take();
                        d = dup_open(&o2).map_err(|e| format!("dup_open {:#x}", e.code().0))?;
                        let _ = dup_acquire(&mut d, 200);
                        if d.latest.is_none() { d.latest = keep; }
                        true
                    }
                };
                let tex = d.latest.clone().unwrap();
                samples.push(process(&d.dev, &d.ctx, &tex, t0, fresh, i, &save, mw, mh, &method));
                std::thread::sleep(Duration::from_millis(30 + (i as u64 * 37) % 70));
            }
        }
        Ok(())
    })();
    format!(
        "{{\"ok\":{},\"error\":{},\"method\":{},\"desktop\":{},\"outputs\":{},\"chosen\":{},\"openMs\":{:.1},\"firstFrameMs\":{:.1},\"reopened\":{},\"samples\":[{}]}}",
        result.is_ok(),
        jstr(&result.err().unwrap_or_default()),
        jstr(&method),
        match desk { Ok(n) => jstr(&n), Err(e) => format!("\"error {e}\"") },
        outputs,
        chosen,
        open_ms,
        first_ms,
        reopened,
        samples.join(",")
    )
}

#[allow(clippy::too_many_arguments)]
fn process(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, tex: &ID3D11Texture2D, t0: Instant, fresh: bool, i: usize, save: &Option<String>, mw: u32, mh: u32, method: &str) -> String {
    let grab = ms(t0);
    let t = Instant::now();
    let (w, h, bgra) = read_texture(dev, ctx, tex).unwrap();
    let readback = ms(t);
    let blank = is_blank(&bgra);
    let t = Instant::now();
    let rgb = bgra_to_rgb(&bgra);
    let convert = ms(t);
    let t = Instant::now();
    let (sw, sh, small) = scale_fit(&rgb, w, h, mw, mh);
    let scale = ms(t);
    let t = Instant::now();
    let png_full_fast = encode_png(&rgb, w, h, true);
    let t_png_full_fast = ms(t);
    let t = Instant::now();
    let png_small_fast = encode_png(&small, sw, sh, true);
    let t_png_small_fast = ms(t);
    let t = Instant::now();
    let png_small_bal = encode_png(&small, sw, sh, false);
    let t_png_small_bal = ms(t);
    let t = Instant::now();
    let webp_full = encode_webp(&rgb, w, h);
    let t_webp_full = ms(t);
    let t = Instant::now();
    let webp_small = encode_webp(&small, sw, sh);
    let t_webp_small = ms(t);
    if let Some(dir) = save {
        if i == 0 {
            let _ = std::fs::write(format!("{dir}\\{method}-full.png"), &png_full_fast);
            let _ = std::fs::write(format!("{dir}\\{method}-small.png"), &png_small_bal);
            let _ = std::fs::write(format!("{dir}\\{method}-small.webp"), &webp_small);
        }
    }
    format!(
        "{{\"i\":{i},\"fresh\":{fresh},\"blank\":{blank},\"w\":{w},\"h\":{h},\"sw\":{sw},\"sh\":{sh},\"grabMs\":{grab:.2},\"readbackMs\":{readback:.2},\"convertMs\":{convert:.2},\"scaleMs\":{scale:.2},\
\"pngFullFastMs\":{t_png_full_fast:.2},\"pngFullFastB\":{},\"pngSmallFastMs\":{t_png_small_fast:.2},\"pngSmallFastB\":{},\"pngSmallBalMs\":{t_png_small_bal:.2},\"pngSmallBalB\":{},\
\"webpFullMs\":{t_webp_full:.2},\"webpFullB\":{},\"webpSmallMs\":{t_webp_small:.2},\"webpSmallB\":{}}}",
        png_full_fast.len(),
        png_small_fast.len(),
        png_small_bal.len(),
        webp_full.len(),
        webp_small.len()
    )
}

/// watch --seconds N [--method dxgi|wgc] : logs every change of the input desktop and of the capture state
/// (frames flowing, access lost, re-open failures) with timestamps, re-opening the capture when it is lost.
/// This is how a helper reports `secure_desktop` and survives mode changes.
pub fn cmd_watch(args: &[String]) {
    let seconds: u64 = arg_or(args, "--seconds", "60").parse().unwrap();
    let method = arg_or(args, "--method", "dxgi");
    let end = Instant::now() + Duration::from_secs(seconds);
    let mut last_state = String::new();
    let mut dup: Option<Dup> = None;
    let mut wgc: Option<Wgc> = None;
    let mut size = (0u32, 0u32);
    let mut frames_window = 0u64;
    let mut window_start = Instant::now();
    emit(&format!("{{\"ev\":\"watch_start\",\"t\":{},\"method\":{}}}", now_ms(), jstr(&method)));
    while Instant::now() < end {
        let desk = input_desktop();
        let desk_s = match &desk { Ok(n) => n.clone(), Err(e) => format!("error {e}") };
        let secure = !matches!(&desk, Ok(n) if n.eq_ignore_ascii_case("Default"));
        let mut cap_state = String::from("ok");
        if method == "wgc" {
            if wgc.is_none() {
                match enumerate().ok().and_then(pick) {
                    Some(o) => match wgc_open(&o, false) { Ok(w) => wgc = Some(w), Err(e) => cap_state = format!("open_failed {:#x}", e.code().0) },
                    None => cap_state = "no_output".into(),
                }
            }
            if let Some(w) = wgc.as_mut() {
                match wgc_poll(w) {
                    Ok(true) => {
                        frames_window += 1;
                        if let Some(t) = &w.latest { let mut d = D3D11_TEXTURE2D_DESC::default(); unsafe { t.GetDesc(&mut d) }; size = (d.Width, d.Height); }
                    }
                    Ok(false) => {}
                    Err(e) => { cap_state = format!("poll_failed {:#x}", e.code().0); wgc = None; }
                }
            }
        } else {
            if dup.is_none() {
                match enumerate().ok().and_then(pick) {
                    Some(o) => match dup_open(&o) { Ok(d) => dup = Some(d), Err(e) => cap_state = format!("open_failed {:#x}", e.code().0) },
                    None => cap_state = "no_output".into(),
                }
            }
            if let Some(d) = dup.as_mut() {
                match dup_acquire(d, 50) {
                    Ok(true) => {
                        frames_window += 1;
                        if let Some(t) = &d.latest { let mut dd = D3D11_TEXTURE2D_DESC::default(); unsafe { t.GetDesc(&mut dd) }; size = (dd.Width, dd.Height); }
                    }
                    Ok(false) => {}
                    Err(hr) => { cap_state = format!("access_lost {:#x}", hr); dup = None; }
                }
            }
        }
        let state = format!("{}|{}|{}|{}x{}", if secure { "secure_desktop" } else { "default" }, desk_s, cap_state, size.0, size.1);
        if state != last_state {
            emit(&format!(
                "{{\"ev\":\"state\",\"t\":{},\"desktop\":{},\"secureDesktop\":{},\"capture\":{},\"w\":{},\"h\":{}}}",
                now_ms(), jstr(&desk_s), secure, jstr(&cap_state), size.0, size.1
            ));
            last_state = state;
        }
        if window_start.elapsed() >= Duration::from_secs(5) {
            emit(&format!("{{\"ev\":\"rate\",\"t\":{},\"framesPerSec\":{:.1}}}", now_ms(), frames_window as f64 / window_start.elapsed().as_secs_f64()));
            frames_window = 0;
            window_start = Instant::now();
        }
        if !cap_state.starts_with("ok") || dup.is_none() && wgc.is_none() {
            std::thread::sleep(Duration::from_millis(100));
        } else if method == "wgc" {
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    emit(&format!("{{\"ev\":\"watch_end\",\"t\":{}}}", now_ms()));
    let _ = BOOL(0);
}
