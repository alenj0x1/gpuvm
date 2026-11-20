//! Lab 055: what Sunshine's DDX capture loop sees on an agent machine, without Sunshine. Runs as SYSTEM in the
//! console session (like sunshinesvc's Sunshine). For each output attached to the desktop: duplicate it and call
//! AcquireNextFrame for `secs` seconds, logging every non-timeout status, every time the DXGI factory stops being
//! current (Sunshine reinitializes silently on that, display_base.cpp capture()), and how long each re-init takes.
//! Usage: ddxprobe.exe <seconds> <log file> [nofactorycheck]
use std::io::Write;
use std::time::{Duration, Instant};
use windows::core::Interface;
use windows::Win32::Foundation::HMODULE;
use windows::Win32::Graphics::Direct3D::D3D_DRIVER_TYPE_UNKNOWN;
use windows::Win32::Graphics::Direct3D11::*;
use windows::Win32::Graphics::Dxgi::*;
use windows::Win32::System::StationsAndDesktops::*;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let secs: u64 = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(15);
    let path = args.get(2).cloned().unwrap_or_else(|| "ddxprobe.log".into());
    let check_factory = args.get(3).map(|s| s != "nofactorycheck").unwrap_or(true);
    let mut log = std::fs::OpenOptions::new().create(true).append(true).open(&path).unwrap();
    let t0 = Instant::now();
    macro_rules! w { ($($a:tt)*) => {{ let _ = writeln!(log, "{:>8.3} {}", t0.elapsed().as_secs_f64(), format!($($a)*)); }} }
    unsafe {
        // Like Sunshine's syncThreadDesktop.
        match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_ACCESS_FLAGS(0x10000000)) {
            Ok(d) => { let r = SetThreadDesktop(d); w!("input desktop set: {:?}", r.is_ok()); }
            Err(e) => w!("OpenInputDesktop failed: {e}"),
        }
        let end = t0 + Duration::from_secs(secs);
        let (mut inits, mut frames, mut timeouts, mut stale, mut lost, mut other) = (0u32, 0u32, 0u32, 0u32, 0u32, 0u32);
        'outer: while Instant::now() < end {
            let init_at = Instant::now();
            let factory: IDXGIFactory1 = match CreateDXGIFactory1() { Ok(f) => f, Err(e) => { w!("CreateDXGIFactory1 {e}"); break } };
            // First output attached to the desktop, as Sunshine picks it by name (here: the only attached one).
            let mut chosen = None;
            let mut i = 0;
            while let Ok(adapter) = factory.EnumAdapters1(i) {
                let ad = adapter.GetDesc1().unwrap();
                let aname = String::from_utf16_lossy(&ad.Description).trim_end_matches('\0').to_string();
                let mut j = 0;
                while let Ok(output) = adapter.EnumOutputs(j) {
                    let od = output.GetDesc().unwrap();
                    let oname = String::from_utf16_lossy(&od.DeviceName).trim_end_matches('\0').to_string();
                    if inits == 0 { w!("adapter {i} '{aname}' output {j} {oname} attached={} {}x{}", od.AttachedToDesktop.as_bool(),
                        od.DesktopCoordinates.right - od.DesktopCoordinates.left, od.DesktopCoordinates.bottom - od.DesktopCoordinates.top); }
                    if od.AttachedToDesktop.as_bool() && chosen.is_none() { chosen = Some((adapter.clone(), output.clone(), oname.clone())); }
                    j += 1;
                }
                i += 1;
            }
            let Some((adapter, output, oname)) = chosen else { w!("no attached output"); std::thread::sleep(Duration::from_millis(500)); continue };
            let mut device = None; let mut ctx = None;
            if let Err(e) = D3D11CreateDevice(&adapter, D3D_DRIVER_TYPE_UNKNOWN, HMODULE::default(), D3D11_CREATE_DEVICE_FLAG(0), None, D3D11_SDK_VERSION, Some(&mut device), None, Some(&mut ctx)) {
                w!("D3D11CreateDevice {e}"); break;
            }
            let device = device.unwrap();
            let output1: IDXGIOutput1 = output.cast().unwrap();
            let dup = match output1.DuplicateOutput(&device) {
                Ok(d) => d,
                Err(e) => { w!("DuplicateOutput {oname}: {e}"); other += 1; std::thread::sleep(Duration::from_millis(200)); inits += 1; continue }
            };
            inits += 1;
            w!("init #{inits} on {oname} in {} ms", init_at.elapsed().as_millis());
            loop {
                if Instant::now() >= end { break 'outer; }
                if check_factory && !factory.IsCurrent().as_bool() { stale += 1; w!("factory not current -> reinit"); break; }
                let mut info = DXGI_OUTDUPL_FRAME_INFO::default();
                let mut res = None;
                match dup.AcquireNextFrame(100, &mut info, &mut res) {
                    Ok(()) => { frames += 1; if frames <= 3 || frames % 100 == 0 { w!("frame {frames} (accumulated {})", info.AccumulatedFrames); } let _ = dup.ReleaseFrame(); }
                    Err(e) if e.code() == DXGI_ERROR_WAIT_TIMEOUT => { timeouts += 1; }
                    Err(e) if e.code() == DXGI_ERROR_ACCESS_LOST || e.code() == DXGI_ERROR_ACCESS_DENIED => { lost += 1; w!("AcquireNextFrame {e} -> reinit"); break; }
                    Err(e) => { other += 1; w!("AcquireNextFrame {e}"); break; }
                }
            }
        }
        w!("summary: inits {inits} frames {frames} timeouts {timeouts} factoryStale {stale} accessLost {lost} other {other}");
    }
}
