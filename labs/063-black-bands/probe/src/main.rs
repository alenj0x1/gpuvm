//! GpuVM lab 063: black bands in the stream. Captures the streamed display with Windows.Graphics.Capture, as the
//! signed-in user, the way Sunshine's WGC helper does, and copies every frame twice while it holds it: copy A
//! `delay` µs after Windows composed the frame (the delays rotate through a list; 0 = at once, like the helper), copy
//! B `hold` ms after. Windows doesn't draw into a frame the app still holds, so any difference between A and B means
//! the frame was handed over before Windows finished drawing it.
//!
//! Usage: wgc-race.exe <seconds> <out-dir> [delays_us=0,500,1000,2000,4000] [hold_ms=20] [pool=3] [save=6]
//! Writes <out-dir>\result.json (and prints it) plus A/B/mask PNGs of the first `save` frames that changed.
use serde_json::{json, Value};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};
use windows::core::Interface;
use windows::Graphics::Capture::{Direct3D11CaptureFramePool, GraphicsCaptureItem};
use windows::Graphics::DirectX::Direct3D11::IDirect3DDevice;
use windows::Graphics::DirectX::DirectXPixelFormat;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Direct3D::*;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::Common::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::WinRT::Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess};
use windows::Win32::System::WinRT::Graphics::Capture::IGraphicsCaptureItemInterop;

fn wstr(s: &[u16]) -> String {
    String::from_utf16_lossy(&s[..s.iter().position(|&c| c == 0).unwrap_or(s.len())])
}

/// Now on the clock of SystemRelativeTime (QPC in 100 ns units).
fn now_100ns() -> i64 {
    let (mut c, mut f) = (0i64, 0i64);
    unsafe {
        let _ = QueryPerformanceCounter(&mut c);
        let _ = QueryPerformanceFrequency(&mut f);
    }
    (c as i128 * 10_000_000 / f as i128) as i64
}

/// The GDI device name of the display GpuVM streams (its virtual display driver), else the primary one.
fn target_device() -> Option<String> {
    let mut found: Vec<(String, String, bool)> = Vec::new();
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
            found.push((wstr(&dd.DeviceName), wstr(&dd.DeviceString), (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE).0 != 0));
        }
    }
    let vdd = |a: &str| {
        let a = a.to_ascii_lowercase();
        a.contains("virtual display") || a.contains("iddsample") || a.contains("mttvdd")
    };
    found.iter().find(|d| vdd(&d.1)).or_else(|| found.iter().find(|d| d.2)).map(|d| d.0.clone())
}

struct Bucket {
    delay_us: i64,
    samples: u64,
    changed: u64,
    changed_px: u64,
    max_px: u64,
    black_frames: u64,
    glitches: u64,
    alpha0: u64,
    alpha255: u64,
    alpha_other: u64,
    age_a_us: Vec<i64>,
    copy_a_us: Vec<i64>,
}

fn pct(v: &mut Vec<i64>, p: f64) -> i64 {
    if v.is_empty() {
        return -1;
    }
    v.sort_unstable();
    v[((v.len() - 1) as f64 * p).round() as usize]
}

fn save_png(path: &std::path::Path, w: u32, h: u32, rgb: &[u8]) {
    if let Ok(f) = std::fs::File::create(path) {
        let mut e = png::Encoder::new(std::io::BufWriter::new(f), w, h);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.set_compression(png::Compression::Fast);
        if let Ok(mut wr) = e.write_header() {
            let _ = wr.write_image_data(rgb);
        }
    }
}

fn bgra_to_rgb(b: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(b.len() / 4 * 3);
    for p in b.chunks_exact(4) {
        v.extend_from_slice(&[p[2], p[1], p[0]]);
    }
    v
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    let seconds: u64 = a.get(1).and_then(|s| s.parse().ok()).unwrap_or(30);
    let out = std::path::PathBuf::from(a.get(2).cloned().unwrap_or_else(|| ".".into()));
    let delays: Vec<i64> = a.get(3).map(|s| s.split(',').filter_map(|x| x.trim().parse().ok()).collect()).unwrap_or(vec![0, 500, 1000, 2000, 4000]);
    let hold_ms: i64 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(20);
    let pool_n: i32 = a.get(5).and_then(|s| s.parse().ok()).unwrap_or(3);
    let save: usize = a.get(6).and_then(|s| s.parse().ok()).unwrap_or(6);
    // GPU priority like Sunshine's WGC helper: none | high | rt (process class; GPU thread priority 7 with either).
    let prio = a.get(7).cloned().unwrap_or_else(|| "none".into());
    std::fs::create_dir_all(&out).ok();
    // "wgc-race.exe <seconds> <out> loadonly <batch>": only the GPU load, on the first adapter (run on the host to
    // load the GPU the machines share).
    if a.get(3).map(String::as_str) == Some("loadonly") {
        let batch: u32 = a.get(4).and_then(|s| s.parse().ok()).unwrap_or(8);
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let st = stop.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(seconds));
            st.store(true, std::sync::atomic::Ordering::Relaxed);
        });
        let ad: IDXGIAdapter1 = unsafe { CreateDXGIFactory1::<IDXGIFactory1>().unwrap().EnumAdapters1(0).unwrap() };
        let n = gpu_load(ad, batch, stop);
        println!("{{\"loadonly\": {batch}, \"batches\": {n}}}");
        return;
    }
    let result = match run(seconds, &out, &delays, hold_ms, pool_n, save, &prio) {
        Ok(v) => v,
        Err(e) => json!({"error": e}),
    };
    let s = serde_json::to_string_pretty(&result).unwrap();
    std::fs::write(out.join("result.json"), &s).ok();
    println!("{s}");
}

/// D3DKMTSetProcessSchedulingPriorityClass, as Sunshine and its WGC helper call it (5 = REALTIME, 4 = HIGH).
fn set_process_gpu_class(class: i32) -> i32 {
    use windows::Win32::System::LibraryLoader::{GetProcAddress, LoadLibraryA};
    unsafe {
        let Ok(gdi) = LoadLibraryA(windows::core::s!("gdi32.dll")) else { return -1 };
        let Some(f) = GetProcAddress(gdi, windows::core::s!("D3DKMTSetProcessSchedulingPriorityClass")) else { return -2 };
        let f: extern "system" fn(HANDLE, i32) -> i32 = std::mem::transmute(f);
        f(windows::Win32::System::Threading::GetCurrentProcess(), class)
    }
}

/// 96x54 grey cells (area average of a 2x2-sampled BGRA frame), as lab 057's glitches.py sees a recording.
fn grey_cells(b: &[u8], w: usize, h: usize) -> Vec<u8> {
    const GW: usize = 96;
    const GH: usize = 54;
    let mut acc = vec![0u32; GW * GH];
    let mut n = vec![0u32; GW * GH];
    for y in (0..h).step_by(2) {
        let cy = y * GH / h;
        let row = &b[y * w * 4..(y + 1) * w * 4];
        for x in (0..w).step_by(2) {
            let c = cy * GW + x * GW / w;
            let p = &row[x * 4..x * 4 + 3];
            acc[c] += (p[0] as u32 + p[1] as u32 + p[2] as u32) / 3;
            n[c] += 1;
        }
    }
    acc.iter().zip(&n).map(|(a, n)| (a / (*n).max(1)) as u8).collect()
}

/// Cells black in `b` only (bright in the frames around it): lab 057's glitch test (>= 20 cells = a glitch frame).
fn transient_black(a: &[u8], b: &[u8], c: &[u8]) -> usize {
    a.iter().zip(b).zip(c).filter(|((x, y), z)| **y < 6 && **x > 30 && **z > 30).count()
}

/// GPU load like a game's (lab 063): another device, at normal priority, copying two 4096x4096 textures back and
/// forth in batches of `batch` copies, waiting for each batch, until `stop`. Returns the batches done.
fn gpu_load(adapter: IDXGIAdapter1, batch: u32, stop: Arc<std::sync::atomic::AtomicBool>) -> u64 {
    let r = (|| -> windows::core::Result<u64> {
        let (mut dev, mut ctx) = (None, None);
        unsafe { D3D11CreateDevice(&adapter, D3D_DRIVER_TYPE_UNKNOWN, HMODULE::default(), D3D11_CREATE_DEVICE_FLAG(0), None, D3D11_SDK_VERSION, Some(&mut dev), None, Some(&mut ctx))? };
        let (dev, ctx): (ID3D11Device, ID3D11DeviceContext) = (dev.unwrap(), ctx.unwrap());
        let d = D3D11_TEXTURE2D_DESC {
            Width: 4096,
            Height: 4096,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_R8G8B8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: 0,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let (mut a, mut b, mut q) = (None, None, None);
        unsafe {
            dev.CreateTexture2D(&d, None, Some(&mut a))?;
            dev.CreateTexture2D(&d, None, Some(&mut b))?;
            dev.CreateQuery(&D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 }, Some(&mut q))?;
        }
        let (a, b, q) = (a.unwrap(), b.unwrap(), q.unwrap());
        let mut n = 0u64;
        while !stop.load(std::sync::atomic::Ordering::Relaxed) {
            for i in 0..batch {
                unsafe {
                    if i % 2 == 0 { ctx.CopyResource(&a, &b) } else { ctx.CopyResource(&b, &a) }
                }
            }
            gpu_wait(&ctx, &q);
            n += 1;
        }
        Ok(n)
    })();
    r.unwrap_or(0)
}

/// Waits until the context's queued work finished on the GPU (like the helper's copy wait); returns µs.
fn gpu_wait(ctx: &ID3D11DeviceContext, q: &ID3D11Query) -> u64 {
    let t = Instant::now();
    unsafe {
        ctx.End(q);
        // S_FALSE (not done) is a success code here: the query writes TRUE only once the work is done.
        let mut done: i32 = 0;
        loop {
            let _ = ctx.GetData(q, Some(&mut done as *mut i32 as *mut _), 4, 0);
            if done != 0 {
                break;
            }
            if t.elapsed() > Duration::from_millis(50) {
                break;
            }
            std::hint::spin_loop();
        }
    }
    t.elapsed().as_micros() as u64
}

/// Full-rate mode ("fast"): every frame is consumed as the helper does (copy to a GPU texture, wait for the copy,
/// release), then copied a second time while still held (A2). Only 54 rows of each are read back, so the probe keeps
/// up with ~180 frames a second. Counts frames whose A2 differs from A (still being drawn when handed over) and lab
/// 057's transient-black frames in A (what the encoder would have got); saves the first `save` of those whole.
fn fast_loop(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, d3d: &IDirect3DDevice, pool: &Direct3D11CaptureFramePool, signal: &Arc<(Mutex<u64>, Condvar)>, mut size: windows::Graphics::SizeInt32, pool_n: i32, seconds: u64, out: &std::path::Path, save: usize) -> Result<Value, String> {
    const ROWS: usize = 54;
    const GW: usize = 96;
    let e = |x: windows::core::Error| x.to_string();
    let mk = |w: u32, h: u32, staging: bool| -> Result<ID3D11Texture2D, String> {
        let d = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: if staging { D3D11_USAGE_STAGING } else { D3D11_USAGE_DEFAULT },
            BindFlags: 0,
            CPUAccessFlags: if staging { D3D11_CPU_ACCESS_READ.0 as u32 } else { 0 },
            MiscFlags: 0,
        };
        let mut t = None;
        unsafe { dev.CreateTexture2D(&d, None, Some(&mut t)).map_err(e)? };
        Ok(t.unwrap())
    };
    let q = unsafe {
        let mut q = None;
        dev.CreateQuery(&D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 }, Some(&mut q)).map_err(e)?;
        q.unwrap()
    };
    let make_all = |w: u32, h: u32| -> Result<(Vec<ID3D11Texture2D>, ID3D11Texture2D, ID3D11Texture2D, ID3D11Texture2D, ID3D11Texture2D), String> {
        Ok((vec![mk(w, h, false)?, mk(w, h, false)?, mk(w, h, false)?], mk(w, h, false)?, mk(w, ROWS as u32, true)?, mk(w, ROWS as u32, true)?, mk(w, h, true)?))
    };
    let (mut ring, mut a2, mut rows_a, mut rows_b, mut full) = make_all(size.Width as u32, size.Height as u32)?;
    let read_rows = |t: &ID3D11Texture2D, w: usize| -> Result<Vec<u8>, String> {
        let mut v = vec![0u8; w * 4 * ROWS];
        unsafe {
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(t, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
            for r in 0..ROWS {
                let src = std::slice::from_raw_parts((m.pData as *const u8).add(r * m.RowPitch as usize), w * 4);
                v[r * w * 4..(r + 1) * w * 4].copy_from_slice(src);
            }
            ctx.Unmap(t, 0);
        }
        Ok(v)
    };
    let start = Instant::now();
    let deadline = start + Duration::from_secs(seconds);
    let (mut seen, mut n, mut drained, mut moving, mut late_changed, mut late_px) = (0u64, 0usize, 0u64, 0u64, 0u64, 0u64);
    let (mut wait_sum, mut wait_max) = (0u64, 0u64);
    let mut hist: std::collections::VecDeque<(Vec<u8>, usize, f64, u64)> = std::collections::VecDeque::new();
    let (mut glitches, mut saved, mut late_events) = (Vec::<Value>::new(), 0usize, Vec::<Value>::new());
    let mut prev_rows: Vec<u8> = Vec::new();
    while Instant::now() < deadline {
        {
            let (l, c) = &**signal;
            let g = l.lock().unwrap();
            let (g, _) = c.wait_timeout_while(g, Duration::from_millis(200), |k| *k == seen).unwrap();
            seen = *g;
        }
        let mut newest = None;
        while let Ok(f) = pool.TryGetNextFrame() {
            if let Some(old) = newest.replace(f) {
                let old: windows::Graphics::Capture::Direct3D11CaptureFrame = old;
                let _ = old.Close();
                drained += 1;
            }
        }
        let Some(frame) = newest else { continue };
        let cs = frame.ContentSize().map_err(e)?;
        if cs.Width != size.Width || cs.Height != size.Height {
            let _ = frame.Close();
            size = cs;
            pool.Recreate(d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, pool_n, size).map_err(e)?;
            (ring, a2, rows_a, rows_b, full) = make_all(size.Width as u32, size.Height as u32)?;
            hist.clear();
            continue;
        }
        let access: IDirect3DDxgiInterfaceAccess = frame.Surface().map_err(e)?.cast().map_err(e)?;
        let tex: ID3D11Texture2D = unsafe { access.GetInterface().map_err(e)? };
        let (w, h) = (size.Width as usize, size.Height as usize);
        let slot = n % 3;
        n += 1;
        unsafe { ctx.CopyResource(&ring[slot], &tex) };
        let us = gpu_wait(ctx, &q);
        wait_sum += us;
        wait_max = wait_max.max(us);
        unsafe { ctx.CopyResource(&a2, &tex) };
        gpu_wait(ctx, &q);
        let _ = frame.Close();
        for r in 0..ROWS {
            let y = (r * h / ROWS + h / (2 * ROWS)) as u32;
            let b = D3D11_BOX { left: 0, top: y, front: 0, right: w as u32, bottom: y + 1, back: 1 };
            unsafe {
                ctx.CopySubresourceRegion(&rows_a, 0, 0, r as u32, 0, &ring[slot], 0, Some(&b));
                ctx.CopySubresourceRegion(&rows_b, 0, 0, r as u32, 0, &a2, 0, Some(&b));
            }
        }
        let ra = read_rows(&rows_a, w)?;
        let rb = read_rows(&rows_b, w)?;
        let px = ra.chunks_exact(4).zip(rb.chunks_exact(4)).filter(|(x, y)| x != y).count() as u64;
        if px > 0 {
            late_changed += 1;
            late_px += px;
            if late_events.len() < 200 {
                late_events.push(json!({"t": (start.elapsed().as_secs_f64() * 1000.0).round() / 1000.0, "px": px}));
            }
        }
        if ra != prev_rows {
            moving += 1;
        }
        let mut grey = vec![0u8; ROWS * GW];
        for r in 0..ROWS {
            for c in 0..GW {
                let (x0, x1) = (c * w / GW, (c + 1) * w / GW);
                let s: u32 = (x0..x1).map(|x| {
                    let p = &ra[(r * w + x) * 4..(r * w + x) * 4 + 3];
                    (p[0] as u32 + p[1] as u32 + p[2] as u32) / 3
                }).sum();
                grey[r * GW + c] = (s / (x1 - x0) as u32) as u8;
            }
        }
        prev_rows = ra;
        if hist.len() == 2 {
            let k = transient_black(&hist[0].0, &hist[1].0, &grey);
            if k >= 20 {
                let (gslot, gt, gpx) = (hist[1].1, hist[1].2, hist[1].3);
                let mut g = json!({"t": (gt * 1000.0).round() / 1000.0, "cells": k, "a2DiffPx": gpx});
                // The glitch frame is still in its ring slot (the ring holds the last three).
                if saved < save && gslot != slot {
                    unsafe {
                        ctx.CopyResource(&full, &ring[gslot]);
                        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
                        ctx.Map(&full, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
                        let mut b = vec![0u8; w * h * 4];
                        for y in 0..h {
                            b[y * w * 4..(y + 1) * w * 4].copy_from_slice(std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4));
                        }
                        ctx.Unmap(&full, 0);
                        save_png(&out.join(format!("fast-glitch{saved}.png")), w as u32, h as u32, &bgra_to_rgb(&b));
                    }
                    g["saved"] = json!(saved);
                    saved += 1;
                }
                glitches.push(g);
            }
            hist.pop_front();
        }
        hist.push_back((grey, slot, start.elapsed().as_secs_f64(), px));
    }
    let secs = start.elapsed().as_secs_f64();
    Ok(json!({
        "mode": "fast", "seconds": (secs * 10.0).round() / 10.0, "arrived": seen, "processed": n, "drained": drained,
        "processedFps": (n as f64 / secs * 10.0).round() / 10.0, "movingPct": if n > 0 { (moving as f64 / n as f64 * 1000.0).round() / 10.0 } else { 0.0 },
        "copyWaitUs": {"avg": if n > 0 { wait_sum / n as u64 } else { 0 }, "max": wait_max},
        "a2Changed": late_changed, "a2ChangedPx": late_px, "glitches": glitches.len(),
        "glitchesPerMin": (glitches.len() as f64 / secs * 600.0).round() / 10.0,
        "glitchFrames": glitches, "a2Events": late_events,
    }))
}

/// Helper-exact mode ("fast2"): the FrameArrived handler itself copies the frame into a ring texture, waits for the
/// copy on the GPU and releases the frame (what sunshine_wgc_capture does), so it is ready for the next frame at once;
/// another thread reads 54 rows of each ring slot and runs lab 057's transient-black test on them.
/// `delayUs` > 0 (from the 8th argument) waits that long, spinning, before each copy: the candidate fix.
#[allow(clippy::too_many_arguments)]
fn fast2_loop(dev: &ID3D11Device, ctx: &ID3D11DeviceContext, d3d: &IDirect3DDevice, item: &GraphicsCaptureItem, size: windows::Graphics::SizeInt32, pool_n: i32, seconds: u64, out: &std::path::Path, save: usize) -> Result<Value, String> {
    const ROWS: usize = 54;
    const GW: usize = 96;
    const RING: usize = 8;
    let e = |x: windows::core::Error| x.to_string();
    // 8th argument: variants used in turn, frame by frame: a number = spin that many µs before the copy; "fix" =
    // check each copy for places Windows hadn't drawn yet (transparent where the last frame was opaque) and copy
    // again once it has (the candidate fix).
    let variants: Vec<String> = std::env::args().nth(8).unwrap_or_else(|| "0".into()).split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
    let variants = if variants.is_empty() { vec!["0".to_string()] } else { variants };
    let nvar = variants.len();
    unsafe {
        let mt: ID3D11Multithread = ctx.cast().map_err(e)?;
        let _ = mt.SetMultithreadProtected(true);
    }
    let (w, h) = (size.Width as usize, size.Height as usize);
    let mk = |w: u32, h: u32, staging: bool| -> Result<ID3D11Texture2D, String> {
        let d = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: if staging { D3D11_USAGE_STAGING } else { D3D11_USAGE_DEFAULT },
            BindFlags: 0,
            CPUAccessFlags: if staging { D3D11_CPU_ACCESS_READ.0 as u32 } else { 0 },
            MiscFlags: 0,
        };
        let mut t = None;
        unsafe { dev.CreateTexture2D(&d, None, Some(&mut t)).map_err(e)? };
        Ok(t.unwrap())
    };
    let mut ring = Vec::new();
    for _ in 0..RING {
        ring.push(mk(w as u32, h as u32, false)?);
    }
    let rows = mk(w as u32, ROWS as u32, true)?;
    let full = mk(w as u32, h as u32, true)?;
    let q = unsafe {
        let mut q = None;
        dev.CreateQuery(&D3D11_QUERY_DESC { Query: D3D11_QUERY_EVENT, MiscFlags: 0 }, Some(&mut q)).map_err(e)?;
        q.unwrap()
    };
    // The fix's check: a copy with mips; mip 5 (one texel per 32x32 block) read back, so any block with transparent
    // pixels shows as alpha < 250 for the whole frame at the cost of ~2 KB.
    const MIP: u32 = 5;
    let (mw, mh) = (((w as u32) >> MIP).max(1), ((h as u32) >> MIP).max(1));
    let check = unsafe {
        let d = D3D11_TEXTURE2D_DESC {
            Width: w as u32,
            Height: h as u32,
            MipLevels: MIP + 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: (D3D11_BIND_SHADER_RESOURCE.0 | D3D11_BIND_RENDER_TARGET.0) as u32,
            CPUAccessFlags: 0,
            MiscFlags: D3D11_RESOURCE_MISC_GENERATE_MIPS.0 as u32,
        };
        let mut t = None;
        dev.CreateTexture2D(&d, None, Some(&mut t)).map_err(e)?;
        t.unwrap()
    };
    let srv = unsafe {
        let mut v = None;
        dev.CreateShaderResourceView(&check, None, Some(&mut v)).map_err(e)?;
        v.unwrap()
    };
    let stage = mk(mw, mh, true)?;
    // Shared between the handler and the analysis: queue of (slot, seq, variant), and stats.
    #[derive(Default, Clone)]
    struct Var {
        frames: u64,
        fixed: u64,
        retries: u64,
        extra_us: u64,
        extra_max_us: u64,
        exhausted: u64,
    }
    struct St {
        queue: std::collections::VecDeque<(usize, u64, usize)>,
        busy: [bool; 8],
        seq: u64,
        skipped: u64,
        wait_sum: u64,
        wait_max: u64,
        stop: bool,
        var: Vec<Var>,
        // the fix's detections: (seconds since start, blocks bad at first, checks, µs until complete or given up, gave up)
        fix_events: Vec<(f64, usize, u64, u64, bool)>,
    }
    // 12th argument: how long the fix keeps checking a frame before giving up (ms).
    let fix_budget_ms: u64 = std::env::args().nth(12).and_then(|s| s.parse().ok()).unwrap_or(10);
    let started = Instant::now();
    let st = Arc::new((Mutex::new(St { queue: Default::default(), busy: [false; 8], seq: 0, skipped: 0, wait_sum: 0, wait_max: 0, stop: false, var: vec![Var::default(); nvar], fix_events: Vec::new() }), Condvar::new()));
    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, pool_n, size).map_err(e)?;
    struct Ctx {
        ctx: ID3D11DeviceContext,
        q: ID3D11Query,
        ring: Vec<ID3D11Texture2D>,
        check: ID3D11Texture2D,
        srv: ID3D11ShaderResourceView,
        stage: ID3D11Texture2D,
        prev: Vec<u8>,
    }
    unsafe impl Send for Ctx {}
    let hc = Mutex::new(Ctx { ctx: ctx.clone(), q: q.clone(), ring: ring.clone(), check, srv, stage, prev: vec![255; (mw * mh) as usize] });
    let st2 = st.clone();
    let variants2 = variants.clone();
    let token = pool
        .FrameArrived(&windows::Foundation::TypedEventHandler::new(move |sender: windows::core::Ref<Direct3D11CaptureFramePool>, _| {
            let Ok(pool) = sender.ok() else { return Ok(()) };
            let Ok(frame) = pool.TryGetNextFrame() else { return Ok(()) };
            let (slot, vi) = {
                let (l, _) = &*st2;
                let mut s = l.lock().unwrap();
                let vi = s.seq as usize % nvar;
                let free = (0..8).map(|i| (s.seq as usize + i) % 8).find(|&i| !s.busy[i]);
                match free {
                    Some(i) => {
                        s.busy[i] = true;
                        (i, vi)
                    }
                    None => {
                        s.skipped += 1;
                        let _ = frame.Close();
                        return Ok(());
                    }
                }
            };
            let access: IDirect3DDxgiInterfaceAccess = frame.Surface()?.cast()?;
            let tex: ID3D11Texture2D = unsafe { access.GetInterface()? };
            let v = &variants2[vi];
            let mut hc = hc.lock().unwrap();
            let t0 = Instant::now();
            let (mut first_bad, mut tries, mut exhausted) = (0usize, 0u64, false);
            let us;
            if v == "fix" {
                // Copy + check in one submission, one wait; again (every 250 µs, up to 10 ms) while blocks that were
                // opaque in the last frame come out transparent.
                let mut alpha = vec![0u8; (mw * mh) as usize];
                loop {
                    unsafe {
                        hc.ctx.CopyResource(&hc.ring[slot], &tex);
                        hc.ctx.CopySubresourceRegion(&hc.check, 0, 0, 0, 0, &tex, 0, None);
                        hc.ctx.GenerateMips(&hc.srv);
                        hc.ctx.CopySubresourceRegion(&hc.stage, 0, 0, 0, 0, &hc.check, MIP, None);
                        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
                        hc.ctx.Map(&hc.stage, 0, D3D11_MAP_READ, 0, Some(&mut m))?;
                        for y in 0..mh as usize {
                            let row = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), mw as usize * 4);
                            for x in 0..mw as usize {
                                alpha[y * mw as usize + x] = row[x * 4 + 3];
                            }
                        }
                        hc.ctx.Unmap(&hc.stage, 0);
                    }
                    let bad = alpha.iter().zip(&hc.prev).filter(|(a, p)| **a < 250 && **p >= 250).count();
                    if tries == 0 {
                        first_bad = bad;
                    }
                    tries += 1;
                    if bad == 0 {
                        break;
                    }
                    if t0.elapsed() > Duration::from_millis(fix_budget_ms) {
                        exhausted = true;
                        break;
                    }
                    let t = Instant::now();
                    while t.elapsed() < Duration::from_micros(250) {
                        std::hint::spin_loop();
                    }
                }
                hc.prev = alpha;
                us = t0.elapsed().as_micros() as u64;
            } else {
                let delay_us: u64 = v.parse().unwrap_or(0);
                while t0.elapsed() < Duration::from_micros(delay_us) {
                    std::hint::spin_loop();
                }
                unsafe { hc.ctx.CopyResource(&hc.ring[slot], &tex) };
                us = gpu_wait(&hc.ctx, &hc.q);
            }
            drop(hc);
            let _ = frame.Close();
            let (l, c) = &*st2;
            let mut s = l.lock().unwrap();
            s.wait_sum += us;
            s.wait_max = s.wait_max.max(us);
            {
                let var = &mut s.var[vi];
                var.frames += 1;
                if first_bad > 0 {
                    var.fixed += 1;
                    var.retries += tries - 1;
                    let extra = t0.elapsed().as_micros() as u64;
                    var.extra_us += extra;
                    var.extra_max_us = var.extra_max_us.max(extra);
                }
                if exhausted {
                    var.exhausted += 1;
                }
            }
            if first_bad > 0 && s.fix_events.len() < 500 {
                s.fix_events.push((started.elapsed().as_secs_f64(), first_bad, tries, t0.elapsed().as_micros() as u64, exhausted));
            }
            let seq = s.seq;
            s.seq += 1;
            s.queue.push_back((slot, seq, vi));
            c.notify_all();
            Ok(())
        }))
        .map_err(e)?;
    let session = pool.CreateCaptureSession(item).map_err(e)?;
    // 9th argument "cursor": Windows draws the cursor into the frames, as the helper asks when the cursor is shown.
    let cursor = std::env::args().nth(9).as_deref() == Some("cursor");
    let _ = session.SetIsCursorCaptureEnabled(cursor);
    session.StartCapture().map_err(e)?;

    let start = Instant::now();
    let (mut alpha0_frames, mut alpha0_px) = (0u64, 0u64);
    let deadline = start + Duration::from_secs(seconds);
    let (mut analysed, mut moving, mut gaps, mut last_seq) = (0u64, 0u64, 0u64, None::<u64>);
    let mut hist: std::collections::VecDeque<(Vec<u8>, usize, f64, u64)> = std::collections::VecDeque::new();
    let (mut glitches, mut saved) = (Vec::<Value>::new(), 0usize);
    let (mut alpha0_v, mut glitch_v) = (vec![0u64; nvar], vec![0u64; nvar]);
    let mut prev_rows: Vec<u8> = Vec::new();
    let mut held: Option<usize> = None; // the slot kept back for saving (the middle frame of the test)
    while Instant::now() < deadline {
        let (slot, seq, vi) = {
            let (l, c) = &*st;
            let s = l.lock().unwrap();
            let (mut s, _) = c.wait_timeout_while(s, Duration::from_millis(200), |s| s.queue.is_empty()).unwrap();
            match s.queue.pop_front() {
                Some(x) => x,
                None => continue,
            }
        };
        if let Some(p) = last_seq {
            if seq != p + 1 {
                gaps += 1;
                hist.clear();
            }
        }
        last_seq = Some(seq);
        for r in 0..ROWS {
            let y = (r * h / ROWS + h / (2 * ROWS)) as u32;
            let b = D3D11_BOX { left: 0, top: y, front: 0, right: w as u32, bottom: y + 1, back: 1 };
            unsafe { ctx.CopySubresourceRegion(&rows, 0, 0, r as u32, 0, &ring[slot], 0, Some(&b)) };
        }
        let mut ra = vec![0u8; w * 4 * ROWS];
        unsafe {
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&rows, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
            for r in 0..ROWS {
                ra[r * w * 4..(r + 1) * w * 4].copy_from_slice(std::slice::from_raw_parts((m.pData as *const u8).add(r * m.RowPitch as usize), w * 4));
            }
            ctx.Unmap(&rows, 0);
        }
        analysed += 1;
        // A whole desktop frame is opaque: transparent pixels are places Windows hadn't drawn yet.
        let a0 = ra.chunks_exact(4).filter(|p| p[3] == 0).count() as u64;
        if a0 > 0 {
            alpha0_frames += 1;
            alpha0_px += a0;
            alpha0_v[vi] += 1;
        }
        if ra != prev_rows {
            moving += 1;
        }
        let mut grey = vec![0u8; ROWS * GW];
        for r in 0..ROWS {
            for c in 0..GW {
                let (x0, x1) = (c * w / GW, (c + 1) * w / GW);
                let s: u32 = (x0..x1).map(|x| {
                    let p = &ra[(r * w + x) * 4..(r * w + x) * 4 + 3];
                    (p[0] as u32 + p[1] as u32 + p[2] as u32) / 3
                }).sum();
                grey[r * GW + c] = (s / (x1 - x0) as u32) as u8;
            }
        }
        prev_rows = ra;
        // Free the slot that is no longer needed: the oldest of the three under test, unless kept to be saved.
        let mut release = Vec::new();
        if hist.len() == 2 {
            let k = transient_black(&hist[0].0, &hist[1].0, &grey);
            if k >= 20 {
                let (gslot, gt, gvi) = (hist[1].1, hist[1].2, hist[1].3 as usize);
                glitch_v[gvi] += 1;
                let mut g = json!({"t": (gt * 1000.0).round() / 1000.0, "cells": k, "variant": variants[gvi]});
                if saved < save {
                    unsafe {
                        ctx.CopyResource(&full, &ring[gslot]);
                        let mut m = D3D11_MAPPED_SUBRESOURCE::default();
                        ctx.Map(&full, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
                        let mut b = vec![0u8; w * h * 4];
                        for y in 0..h {
                            b[y * w * 4..(y + 1) * w * 4].copy_from_slice(std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4));
                        }
                        ctx.Unmap(&full, 0);
                        save_png(&out.join(format!("fast2-glitch{saved}.png")), w as u32, h as u32, &bgra_to_rgb(&b));
                    }
                    g["saved"] = json!(saved);
                    saved += 1;
                }
                glitches.push(g);
            }
            release.push(hist.pop_front().unwrap().1);
        }
        let _ = held.take();
        hist.push_back((grey, slot, start.elapsed().as_secs_f64(), vi as u64));
        {
            let (l, _) = &*st;
            let mut s = l.lock().unwrap();
            for r in release {
                s.busy[r] = false;
            }
        }
    }
    {
        let (l, _) = &*st;
        l.lock().unwrap().stop = true;
    }
    let _ = pool.RemoveFrameArrived(token);
    let _ = session.Close();
    let _ = pool.Close();
    let secs = start.elapsed().as_secs_f64();
    let s = st.0.lock().unwrap();
    let per: Vec<Value> = variants
        .iter()
        .enumerate()
        .map(|(i, v)| {
            let x = &s.var[i];
            json!({"variant": v, "frames": x.frames, "alpha0Frames": alpha0_v[i], "glitches": glitch_v[i], "fixed": x.fixed,
                   "retries": x.retries, "extraUsAvg": if x.fixed > 0 { x.extra_us / x.fixed } else { 0 }, "extraUsMax": x.extra_max_us, "exhausted": x.exhausted})
        })
        .collect();
    Ok(json!({
        "mode": "fast2", "variants": per, "cursor": cursor, "fixBudgetMs": fix_budget_ms,
        "fixEvents": s.fix_events.iter().map(|e| json!({"t": (e.0 * 1000.0).round() / 1000.0, "bad": e.1, "checks": e.2, "us": e.3, "gaveUp": e.4})).collect::<Vec<_>>(), "alpha0Frames": alpha0_frames, "alpha0Px": alpha0_px, "seconds": (secs * 10.0).round() / 10.0, "captured": s.seq, "analysed": analysed,
        "capturedFps": (s.seq as f64 / secs * 10.0).round() / 10.0, "skipped": s.skipped, "gaps": gaps,
        "movingPct": if analysed > 0 { (moving as f64 / analysed as f64 * 1000.0).round() / 10.0 } else { 0.0 },
        "copyWaitUs": {"avg": if s.seq > 0 { s.wait_sum / s.seq } else { 0 }, "max": s.wait_max},
        "glitches": glitches.len(), "glitchesPerMin": (glitches.len() as f64 / secs * 600.0).round() / 10.0,
        "glitchFrames": glitches,
    }))
}

fn run(seconds: u64, out: &std::path::Path, delays: &[i64], hold_ms: i64, pool_n: i32, save: usize, prio: &str) -> Result<Value, String> {
    let e = |x: windows::core::Error| x.to_string();
    let fast2 = std::env::args().nth(3).as_deref() == Some("fast2");
    let target = target_device().ok_or("no display")?;
    // Adapters, their outputs, and the one that has the streamed display.
    let mut adapters = Vec::new();
    let mut chosen: Option<(IDXGIAdapter1, HMONITOR, String)> = None;
    unsafe {
        let factory: IDXGIFactory1 = CreateDXGIFactory1().map_err(e)?;
        let mut i = 0;
        while let Ok(ad) = factory.EnumAdapters1(i) {
            i += 1;
            let d = ad.GetDesc1().map_err(e)?;
            let mut outs = Vec::new();
            let mut j = 0;
            while let Ok(o) = ad.EnumOutputs(j) {
                j += 1;
                let od = o.GetDesc().map_err(e)?;
                let name = wstr(&od.DeviceName);
                if name.eq_ignore_ascii_case(&target) {
                    chosen = Some((ad.clone(), od.Monitor, wstr(&d.Description)));
                }
                outs.push(name);
            }
            adapters.push(json!({"name": wstr(&d.Description), "luid": format!("{:x}:{:x}", d.AdapterLuid.HighPart, d.AdapterLuid.LowPart), "flags": d.Flags, "outputs": outs}));
        }
    }
    let (adapter, monitor, adapter_name) = chosen.ok_or(format!("no DXGI output for {target}"))?;

    let (dev, ctx) = unsafe {
        let mut dev = None;
        let mut ctx = None;
        D3D11CreateDevice(&adapter, D3D_DRIVER_TYPE_UNKNOWN, HMODULE::default(), D3D11_CREATE_DEVICE_BGRA_SUPPORT, None, D3D11_SDK_VERSION, Some(&mut dev), None, Some(&mut ctx)).map_err(e)?;
        (dev.unwrap(), ctx.unwrap())
    };
    let mut prio_status = json!({"asked": prio});
    if prio != "none" {
        // Like the helper: REALTIME, then HIGH when the user's token can't have REALTIME.
        let mut st = if prio == "rt" { set_process_gpu_class(5) } else { -1 };
        if st < 0 {
            st = set_process_gpu_class(4);
            prio_status["fellBackToHigh"] = json!(prio == "rt");
        }
        prio_status["class"] = json!(st);
        let dx: IDXGIDevice = dev.cast().map_err(e)?;
        prio_status["thread7"] = json!(unsafe { dx.SetGPUThreadPriority(7) }.is_ok());
    }
    let interop = windows::core::factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(e)?;
    let item: GraphicsCaptureItem = unsafe { interop.CreateForMonitor(monitor).map_err(e)? };
    let dxgi: IDXGIDevice = dev.cast().map_err(e)?;
    let d3d: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi).map_err(e)?.cast().map_err(e)? };
    let mut size = item.Size().map_err(e)?;
    if fast2 {
        // 10th argument: GPU load (copies per batch of the load thread; 0 = none).
        let load_batch: u32 = std::env::args().nth(10).and_then(|s| s.parse().ok()).unwrap_or(0);
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let loader = (load_batch > 0).then(|| {
            let (ad, st) = (adapter.clone(), stop.clone());
            struct SendAd(IDXGIAdapter1);
            unsafe impl Send for SendAd {}
            let ad = SendAd(ad);
            std::thread::spawn(move || {
                let ad = ad;
                gpu_load(ad.0, load_batch, st)
            })
        });
        // 11th argument: CPU load (threads spinning at normal priority, like a game or a busy browser).
        let cpu_threads: usize = std::env::args().nth(11).and_then(|s| s.parse().ok()).unwrap_or(0);
        let spinners: Vec<_> = (0..cpu_threads)
            .map(|_| {
                let st = stop.clone();
                std::thread::spawn(move || {
                    let mut x = 0u64;
                    while !st.load(std::sync::atomic::Ordering::Relaxed) {
                        for i in 0..100_000u64 {
                            x = x.wrapping_mul(6364136223846793005).wrapping_add(i);
                        }
                        std::hint::black_box(x);
                    }
                })
            })
            .collect();
        let r = fast2_loop(&dev, &ctx, &d3d, &item, size, pool_n, seconds, out, save);
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        for s in spinners {
            let _ = s.join();
        }
        let batches = loader.map(|h| h.join().unwrap_or(0)).unwrap_or(0);
        let mut v = r?;
        v["gpuLoad"] = json!({"batch": load_batch, "batches": batches});
        v["cpuThreads"] = json!(cpu_threads);
        v["display"] = json!(target);
        v["adapter"] = json!(adapter_name);
        v["prio"] = prio_status;
        v["pool"] = json!(pool_n);
        return Ok(v);
    }
    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, pool_n, size).map_err(e)?;
    let signal: Arc<(Mutex<u64>, Condvar)> = Arc::new((Mutex::new(0), Condvar::new()));
    let s2 = signal.clone();
    let token = pool
        .FrameArrived(&windows::Foundation::TypedEventHandler::new(move |_, _| {
            let (l, c) = &*s2;
            *l.lock().unwrap() += 1;
            c.notify_all();
            Ok(())
        }))
        .map_err(e)?;
    let session = pool.CreateCaptureSession(&item).map_err(e)?;
    let _ = session.SetIsCursorCaptureEnabled(false);
    session.StartCapture().map_err(e)?;

    if delays.is_empty() {
        let r = fast_loop(&dev, &ctx, &d3d, &pool, &signal, size, pool_n, seconds, out, save);
        let _ = pool.RemoveFrameArrived(token);
        let _ = session.Close();
        let _ = pool.Close();
        let mut v = r?;
        v["display"] = json!(target);
        v["adapter"] = json!(adapter_name);
        v["prio"] = prio_status;
        v["pool"] = json!(pool_n);
        return Ok(v);
    }

    let staging =|w: u32, h: u32| -> Result<(ID3D11Texture2D, ID3D11Texture2D), String> {
        let sd = D3D11_TEXTURE2D_DESC {
            Width: w,
            Height: h,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_B8G8R8A8_UNORM,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_STAGING,
            BindFlags: 0,
            CPUAccessFlags: D3D11_CPU_ACCESS_READ.0 as u32,
            MiscFlags: 0,
        };
        let (mut x, mut y) = (None, None);
        unsafe {
            dev.CreateTexture2D(&sd, None, Some(&mut x)).map_err(e)?;
            dev.CreateTexture2D(&sd, None, Some(&mut y)).map_err(e)?;
        }
        Ok((x.unwrap(), y.unwrap()))
    };
    let (mut st_a, mut st_b) = staging(size.Width as u32, size.Height as u32)?;
    let mut buckets: Vec<Bucket> = delays
        .iter()
        .map(|&d| Bucket { delay_us: d, samples: 0, changed: 0, changed_px: 0, max_px: 0, black_frames: 0, glitches: 0, alpha0: 0, alpha255: 0, alpha_other: 0, age_a_us: vec![], copy_a_us: vec![] })
        .collect();
    let mut buf_a: Vec<u8> = Vec::new();
    let mut prev_sum: u64 = 0;
    let (mut moving, mut drained, mut processed, mut saved, mut late_hold) = (0u64, 0u64, 0u64, 0usize, 0u64);
    let mut events: Vec<Value> = Vec::new();
    let start = Instant::now();
    let deadline = start + Duration::from_secs(seconds);
    let mut seen = 0u64;
    let mut idx = 0usize;
    // Content test, one frame behind: (grey, full BGRA, bucket, time) of the last two frames looked at.
    let mut hist: std::collections::VecDeque<(Vec<u8>, Vec<u8>, usize, f64, u64)> = std::collections::VecDeque::new();
    let (mut glitches, mut glitch_saved) = (Vec::<Value>::new(), 0usize);

    while Instant::now() < deadline {
        {
            let (l, c) = &*signal;
            let g = l.lock().unwrap();
            let (g, _) = c.wait_timeout_while(g, Duration::from_millis(200), |n| *n == seen).unwrap();
            seen = *g;
        }
        let mut newest = None;
        while let Ok(f) = pool.TryGetNextFrame() {
            if let Some(old) = newest.replace(f) {
                let old: windows::Graphics::Capture::Direct3D11CaptureFrame = old;
                let _ = old.Close();
                drained += 1;
            }
        }
        let Some(frame) = newest else { continue };
        let cs = frame.ContentSize().map_err(e)?;
        if cs.Width != size.Width || cs.Height != size.Height {
            let _ = frame.Close();
            size = cs;
            pool.Recreate(&d3d, DirectXPixelFormat::B8G8R8A8UIntNormalized, pool_n, size).map_err(e)?;
            (st_a, st_b) = staging(size.Width as u32, size.Height as u32)?;
            continue;
        }
        let srt = frame.SystemRelativeTime().map_err(e)?.Duration;
        let access: IDirect3DDxgiInterfaceAccess = frame.Surface().map_err(e)?.cast().map_err(e)?;
        let tex: ID3D11Texture2D = unsafe { access.GetInterface().map_err(e)? };
        let (w, h) = (size.Width as usize, size.Height as usize);
        let bi = idx % buckets.len();
        idx += 1;
        let delay = buckets[bi].delay_us;
        // A: `delay` µs after Windows composed the frame (spin: a sleep would oversleep by a timer tick).
        while (now_100ns() - srt) / 10 < delay {
            std::hint::spin_loop();
        }
        let age_a = (now_100ns() - srt) / 10;
        let t = Instant::now();
        unsafe {
            ctx.CopyResource(&st_a, &tex);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&st_a, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
            let copy_us = t.elapsed().as_micros() as i64;
            buf_a.resize(w * h * 4, 0);
            for y in 0..h {
                let src = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
                buf_a[y * w * 4..(y + 1) * w * 4].copy_from_slice(src);
            }
            ctx.Unmap(&st_a, 0);
            buckets[bi].copy_a_us.push(copy_us);
        }
        buckets[bi].age_a_us.push(age_a);
        // B: `hold` ms after, the frame still held.
        let until = srt + hold_ms * 10_000;
        let left = (until - now_100ns()) / 10;
        if left > 0 {
            std::thread::sleep(Duration::from_micros(left as u64));
        } else {
            late_hold += 1;
        }
        let (mut diff, mut black, mut a0, mut a255, mut aother) = (0u64, 0u64, 0u64, 0u64, 0u64);
        let (mut ymin, mut ymax) = (usize::MAX, 0usize);
        let mut buf_b: Option<Vec<u8>> = None;
        unsafe {
            ctx.CopyResource(&st_b, &tex);
            let mut m = D3D11_MAPPED_SUBRESOURCE::default();
            ctx.Map(&st_b, 0, D3D11_MAP_READ, 0, Some(&mut m)).map_err(e)?;
            for y in 0..h {
                let rb = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
                let ra = &buf_a[y * w * 4..(y + 1) * w * 4];
                if ra == rb {
                    continue;
                }
                for x in 0..w {
                    let (pa, pb) = (&ra[x * 4..x * 4 + 4], &rb[x * 4..x * 4 + 4]);
                    if pa != pb {
                        diff += 1;
                        ymin = ymin.min(y);
                        ymax = ymax.max(y);
                        if pa[0] < 8 && pa[1] < 8 && pa[2] < 8 && (pb[0].max(pb[1]).max(pb[2])) > 40 {
                            black += 1;
                        }
                        match pa[3] {
                            0 => a0 += 1,
                            255 => a255 += 1,
                            _ => aother += 1,
                        }
                    }
                }
            }
            if diff > 0 && saved < save {
                let mut b = vec![0u8; w * h * 4];
                for y in 0..h {
                    let rb = std::slice::from_raw_parts((m.pData as *const u8).add(y * m.RowPitch as usize), w * 4);
                    b[y * w * 4..(y + 1) * w * 4].copy_from_slice(rb);
                }
                buf_b = Some(b);
            }
            ctx.Unmap(&st_b, 0);
        }
        let _ = frame.Close();
        processed += 1;
        // The frames that came while this one was held are already old: drop them and wait for a new one, so copy A
        // happens as soon after composition as the helper's copy does.
        while let Ok(f) = pool.TryGetNextFrame() {
            let _ = f.Close();
            drained += 1;
        }
        seen = *signal.0.lock().unwrap();
        // Lab 057's glitch test on what this capture got (copy A): black for this frame only.
        let grey = grey_cells(&buf_a, w, h);
        if hist.len() == 2 {
            let k = transient_black(&hist[0].0, &hist[1].0, &grey);
            if k >= 20 {
                let (gb, gt, gdiff) = (hist[1].2, hist[1].3, hist[1].4);
                buckets[gb].glitches += 1;
                let mut g = json!({"t": (gt * 1000.0).round() / 1000.0, "delayUs": buckets[gb].delay_us, "cells": k, "changedAfterHandover": gdiff});
                if glitch_saved < save {
                    save_png(&out.join(format!("glitch{glitch_saved}.png")), w as u32, h as u32, &bgra_to_rgb(&hist[1].1));
                    g["saved"] = json!(glitch_saved);
                    glitch_saved += 1;
                }
                glitches.push(g);
            }
            hist.pop_front();
        }
        hist.push_back((grey, buf_a.clone(), bi, start.elapsed().as_secs_f64(), diff));
        // Did the picture move since the last frame looked at? (a sparse checksum; the load must keep it moving)
        let mut sum = 0u64;
        for i in (0..buf_a.len()).step_by(4 * 97) {
            sum = sum.wrapping_mul(31).wrapping_add(buf_a[i] as u64 ^ ((buf_a[i + 1] as u64) << 8) ^ ((buf_a[i + 2] as u64) << 16));
        }
        if sum != prev_sum {
            moving += 1;
        }
        prev_sum = sum;
        let bk = &mut buckets[bi];
        bk.samples += 1;
        if diff > 0 {
            bk.changed += 1;
            bk.changed_px += diff;
            bk.max_px = bk.max_px.max(diff);
            if black > 500 {
                bk.black_frames += 1;
            }
            bk.alpha0 += a0;
            bk.alpha255 += a255;
            bk.alpha_other += aother;
            let at = start.elapsed().as_secs_f64();
            let mut ev = json!({"t": (at * 1000.0).round() / 1000.0, "delayUs": delay, "ageAUs": age_a, "px": diff, "blackPx": black, "rows": [ymin, ymax], "alpha": [a0, a255, aother]});
            if let Some(b) = buf_b {
                let n = saved;
                saved += 1;
                save_png(&out.join(format!("ev{n}-a.png")), w as u32, h as u32, &bgra_to_rgb(&buf_a));
                save_png(&out.join(format!("ev{n}-b.png")), w as u32, h as u32, &bgra_to_rgb(&b));
                let mut mask = vec![0u8; w * h * 3];
                for i in 0..w * h {
                    if buf_a[i * 4..i * 4 + 4] != b[i * 4..i * 4 + 4] {
                        mask[i * 3..i * 3 + 3].copy_from_slice(&[255, 255, 255]);
                    }
                }
                save_png(&out.join(format!("ev{n}-mask.png")), w as u32, h as u32, &mask);
                ev["saved"] = json!(n);
            }
            if events.len() < 400 {
                events.push(ev);
            }
        }
    }
    let _ = pool.RemoveFrameArrived(token);
    let _ = session.Close();
    let _ = pool.Close();
    let secs = start.elapsed().as_secs_f64();
    let b: Vec<Value> = buckets
        .iter_mut()
        .map(|b| {
            json!({"delayUs": b.delay_us, "samples": b.samples, "changed": b.changed,
                   "changedPct": if b.samples > 0 { (b.changed as f64 / b.samples as f64 * 10000.0).round() / 100.0 } else { 0.0 },
                   "blackFrames": b.black_frames, "glitches": b.glitches, "meanPx": if b.changed > 0 { b.changed_px / b.changed } else { 0 }, "maxPx": b.max_px,
                   "alphaOfChangedInA": {"0": b.alpha0, "255": b.alpha255, "other": b.alpha_other},
                   "ageAUs": {"p50": pct(&mut b.age_a_us, 0.5), "p95": pct(&mut b.age_a_us, 0.95)},
                   "copyAUs": {"p50": pct(&mut b.copy_a_us, 0.5), "p95": pct(&mut b.copy_a_us, 0.95), "max": pct(&mut b.copy_a_us, 1.0)}})
        })
        .collect();
    Ok(json!({
        "display": target, "adapter": adapter_name, "size": [size.Width, size.Height], "adapters": adapters,
        "seconds": (secs * 10.0).round() / 10.0, "arrived": seen, "processed": processed, "drained": drained,
        "movingPct": if processed > 0 { (moving as f64 / processed as f64 * 1000.0).round() / 10.0 } else { 0.0 },
        "holdMs": hold_ms, "pool": pool_n, "prio": prio_status, "glitchFrames": glitches, "lateHold": late_hold, "buckets": b, "events": events,
    }))
}
