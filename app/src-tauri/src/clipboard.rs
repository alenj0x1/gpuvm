//! What was copied on this PC, ready to paste into a machine (the panel's Portapapeles widget).
//!
//! Only from the PC to the machines: nothing is ever read from a machine's clipboard. The recent copies (text, an
//! image or files) live in this process's memory only, never on disk, and only while a machine is open in GpuVM's
//! viewer. Copies that password managers and other programs mark as private (Windows' clipboard-history flags) are
//! skipped, as Windows' own clipboard history does.

use base64::Engine;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter};
use windows_sys::Win32::Foundation::{HANDLE, HGLOBAL, HWND, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::DataExchange::{
    AddClipboardFormatListener, CloseClipboard, GetClipboardData, IsClipboardFormatAvailable, OpenClipboard,
    RegisterClipboardFormatW,
};
use windows_sys::Win32::System::Memory::{GlobalLock, GlobalSize, GlobalUnlock};
use windows_sys::Win32::System::Ole::{CF_DIB, CF_HDROP, CF_UNICODETEXT};
use windows_sys::Win32::UI::Shell::{DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, RegisterClassW, HWND_MESSAGE, MSG, WM_CLIPBOARDUPDATE,
    WNDCLASSW,
};

/// Copies kept.
const KEEP: usize = 8;
/// Larger copies are not kept (a text of a million characters, a 30 MB image).
const MAX_TEXT: usize = 1 << 20;
const MAX_IMAGE: usize = 30 << 20;
/// Images up to this size are shown in the widget as they are; larger ones by their size only.
const MAX_THUMB: usize = 1 << 20;

enum Payload {
    Text(String),
    Png(Vec<u8>),
    Files(Vec<String>),
}

struct Item {
    id: u64,
    payload: Payload,
    /// What the widget shows.
    view: Value,
}

static ITEMS: Mutex<Vec<Item>> = Mutex::new(Vec::new());
static NEXT: AtomicU64 = AtomicU64::new(1);
/// Machine every new text or image goes to on its own ("On copy"), if any. Off by default.
static AUTO: Mutex<Option<String>> = Mutex::new(None);
static APP: Mutex<Option<AppHandle>> = Mutex::new(None);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

/// Starts listening to the clipboard (once).
pub fn start(app: &AppHandle) {
    {
        let mut slot = APP.lock().unwrap_or_else(|e| e.into_inner());
        if slot.is_some() {
            return;
        }
        *slot = Some(app.clone());
    }
    std::thread::spawn(|| {
        // SAFETY: a message-only window of this thread that receives WM_CLIPBOARDUPDATE; the loop runs for the life
        // of the process.
        unsafe {
            let class = wide("GpuVMClipboard");
            let wc = WNDCLASSW { lpfnWndProc: Some(proc_), lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(0, class.as_ptr(), class.as_ptr(), 0, 0, 0, 0, 0, HWND_MESSAGE, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null());
            if hwnd.is_null() || AddClipboardFormatListener(hwnd) == 0 {
                return;
            }
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                DispatchMessageW(&msg);
            }
        }
    });
}

unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if msg == WM_CLIPBOARDUPDATE {
        // Only while a machine is open: the rest of the time nothing of what is copied is looked at.
        if crate::viewer::any_open() {
            if let Some(payload) = read(hwnd) {
                add(payload);
            }
        }
        return 0;
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

/// Marked private by the program that copied it (password managers): skipped, as Windows' clipboard history does.
unsafe fn private() -> bool {
    for name in ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"] {
        if IsClipboardFormatAvailable(RegisterClipboardFormatW(wide(name).as_ptr())) != 0 {
            return true;
        }
    }
    let history = RegisterClipboardFormatW(wide("CanIncludeInClipboardHistory").as_ptr());
    if IsClipboardFormatAvailable(history) != 0 {
        if let Some(bytes) = global_bytes(GetClipboardData(history)) {
            if bytes.len() >= 4 && u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) == 0 {
                return true;
            }
        }
    }
    false
}

unsafe fn global_bytes(h: HANDLE) -> Option<Vec<u8>> {
    if h.is_null() {
        return None;
    }
    let size = GlobalSize(h as HGLOBAL);
    let ptr = GlobalLock(h as HGLOBAL) as *const u8;
    if ptr.is_null() {
        return None;
    }
    let out = std::slice::from_raw_parts(ptr, size).to_vec();
    GlobalUnlock(h as HGLOBAL);
    Some(out)
}

unsafe fn read(hwnd: HWND) -> Option<Payload> {
    // Another program may hold the clipboard for a moment.
    let mut opened = false;
    for _ in 0..10 {
        if OpenClipboard(hwnd) != 0 {
            opened = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
    }
    if !opened {
        return None;
    }
    let payload = (|| {
        if private() {
            return None;
        }
        if IsClipboardFormatAvailable(CF_HDROP as u32) != 0 {
            let drop = GetClipboardData(CF_HDROP as u32) as HDROP;
            let count = DragQueryFileW(drop, u32::MAX, std::ptr::null_mut(), 0);
            let mut files = Vec::new();
            for i in 0..count.min(1000) {
                let len = DragQueryFileW(drop, i, std::ptr::null_mut(), 0) as usize;
                let mut buf = vec![0u16; len + 1];
                DragQueryFileW(drop, i, buf.as_mut_ptr(), buf.len() as u32);
                files.push(String::from_utf16_lossy(&buf[..len]));
            }
            return (!files.is_empty()).then_some(Payload::Files(files));
        }
        let png = RegisterClipboardFormatW(wide("PNG").as_ptr());
        if IsClipboardFormatAvailable(png) != 0 {
            if let Some(bytes) = global_bytes(GetClipboardData(png)) {
                if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && bytes.len() <= MAX_IMAGE {
                    return Some(Payload::Png(bytes));
                }
            }
        }
        if IsClipboardFormatAvailable(CF_DIB as u32) != 0 {
            if let Some(png) = global_bytes(GetClipboardData(CF_DIB as u32)).and_then(|dib| dib_to_png(&dib)) {
                return Some(Payload::Png(png));
            }
        }
        if IsClipboardFormatAvailable(CF_UNICODETEXT as u32) != 0 {
            let bytes = global_bytes(GetClipboardData(CF_UNICODETEXT as u32))?;
            let units: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|&u| u != 0).collect();
            let text = String::from_utf16_lossy(&units);
            return (!text.trim().is_empty() && text.len() <= MAX_TEXT).then_some(Payload::Text(text));
        }
        None
    })();
    CloseClipboard();
    payload
}

/// A device-independent bitmap (what Print Screen and most programs copy) as a PNG: 24 or 32 bits per pixel.
fn dib_to_png(dib: &[u8]) -> Option<Vec<u8>> {
    let u32_at = |o: usize| dib.get(o..o + 4).map(|b| u32::from_le_bytes([b[0], b[1], b[2], b[3]]));
    let header = u32_at(0)? as usize;
    let width = u32_at(4)? as i32;
    let height = u32_at(8)? as i32;
    let bpp = u16::from_le_bytes([*dib.get(14)?, *dib.get(15)?]);
    let compression = u32_at(16)?;
    if width <= 0 || height == 0 || width > 16384 || height.abs() > 16384 || !(bpp == 24 || bpp == 32) || !(compression == 0 || compression == 3) {
        return None;
    }
    // BI_BITFIELDS with the old header: three masks follow it.
    let masks = if compression == 3 && header == 40 { 12 } else { 0 };
    let start = header + masks;
    let (w, h) = (width as usize, height.unsigned_abs() as usize);
    let stride = (w * bpp as usize / 8 + 3) & !3;
    if dib.len() < start + stride * h {
        return None;
    }
    let mut rgba = Vec::with_capacity(w * h * 4);
    for y in 0..h {
        // Bottom-up unless the height is negative.
        let row = if height > 0 { h - 1 - y } else { y };
        let line = &dib[start + row * stride..];
        for x in 0..w {
            let p = &line[x * bpp as usize / 8..];
            rgba.extend_from_slice(&[p[2], p[1], p[0], if bpp == 32 && header > 40 { p[3] } else { 255 }]);
        }
    }
    let mut out = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut out, w as u32, h as u32);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        let mut writer = encoder.write_header().ok()?;
        writer.write_image_data(&rgba).ok()?;
    }
    (out.len() <= MAX_IMAGE).then_some(out)
}

fn png_size(png: &[u8]) -> (u32, u32) {
    let at = |o: usize| png.get(o..o + 4).map(|b| u32::from_be_bytes([b[0], b[1], b[2], b[3]])).unwrap_or(0);
    (at(16), at(20))
}

fn view_of(id: u64, payload: &Payload) -> Value {
    match payload {
        Payload::Text(text) => {
            let preview: String = text.chars().take(300).collect();
            json!({ "id": id, "kind": "text", "text": preview, "chars": text.chars().count() })
        }
        Payload::Png(png) => {
            let (w, h) = png_size(png);
            let thumb = (png.len() <= MAX_THUMB).then(|| format!("data:image/png;base64,{}", base64::engine::general_purpose::STANDARD.encode(png)));
            json!({ "id": id, "kind": "image", "width": w, "height": h, "bytes": png.len(), "thumb": thumb })
        }
        Payload::Files(files) => {
            let names: Vec<&str> = files.iter().map(|f| f.rsplit('\\').next().unwrap_or(f)).collect();
            let bytes: u64 = files.iter().filter_map(|f| std::fs::metadata(f).ok()).filter(|m| m.is_file()).map(|m| m.len()).sum();
            json!({ "id": id, "kind": "files", "names": names, "count": files.len(), "bytes": bytes })
        }
    }
}

fn same(a: &Payload, b: &Payload) -> bool {
    match (a, b) {
        (Payload::Text(x), Payload::Text(y)) => x == y,
        (Payload::Png(x), Payload::Png(y)) => x == y,
        (Payload::Files(x), Payload::Files(y)) => x == y,
        _ => false,
    }
}

fn add(payload: Payload) {
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let view = view_of(id, &payload);
    let auto = AUTO.lock().unwrap_or_else(|e| e.into_inner()).clone();
    let auto_send = auto.is_some() && !matches!(payload, Payload::Files(_));
    {
        let mut items = ITEMS.lock().unwrap_or_else(|e| e.into_inner());
        // Copying the same thing again moves it to the top instead of repeating it.
        items.retain(|i| !same(&i.payload, &payload));
        items.insert(0, Item { id, payload, view });
        items.truncate(KEEP);
    }
    let app = APP.lock().unwrap_or_else(|e| e.into_inner()).clone();
    if let Some(app) = app {
        let _ = app.emit("clipboard", list());
        if let (true, Some(vm)) = (auto_send, auto) {
            tauri::async_runtime::spawn(async move {
                let result = send(vm.clone(), id, String::new()).await;
                let _ = app.emit("clipboard-sent", json!({ "id": id, "vm": vm, "error": result.err() }));
            });
        }
    }
}

fn list() -> Vec<Value> {
    ITEMS.lock().unwrap_or_else(|e| e.into_inner()).iter().map(|i| i.view.clone()).collect()
}

/// Forgets every copy (the widget's Borrar, and when the last machine closes).
pub fn clear() {
    ITEMS.lock().unwrap_or_else(|e| e.into_inner()).clear();
    *AUTO.lock().unwrap_or_else(|e| e.into_inner()) = None;
    if let Some(app) = APP.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        let _ = app.emit("clipboard", Vec::<Value>::new());
    }
}

async fn send(vm: String, id: u64, folder: String) -> Result<Value, String> {
    let args = {
        let items = ITEMS.lock().unwrap_or_else(|e| e.into_inner());
        let item = items.iter().find(|i| i.id == id).ok_or("That copy is no longer there.")?;
        match &item.payload {
            Payload::Text(text) => json!({ "Name": vm, "Text": text }),
            Payload::Png(png) => json!({ "Name": vm, "Image": base64::engine::general_purpose::STANDARD.encode(png) }),
            Payload::Files(files) => json!({ "Name": vm, "Files": files, "Folder": if folder.is_empty() { "Recibidos".to_string() } else { folder } }),
        }
    };
    // Files may take a while: their own connection, without the 180 s limit of quick requests.
    let request = json!({ "id": format!("clip{id}"), "cmd": "Send-GpuVMClipboard", "args": args });
    let result = tauri::async_runtime::spawn_blocking(move || {
        let mut conn = crate::backend::connect()?;
        conn.call(&request, |_| {})
    })
    .await
    .map_err(|e| e.to_string())??;
    crate::into_data(result)
}

#[tauri::command]
pub fn clipboard_items() -> Vec<Value> {
    list()
}

/// Puts one of the recent copies into a machine's clipboard.
#[tauri::command]
pub async fn clipboard_send(vm: String, id: u64, folder: String) -> Result<Value, String> {
    send(vm, id, folder).await
}

/// "On copy": every new text or image goes to `vm` on its own; None turns it off.
#[tauri::command]
pub fn clipboard_auto(vm: Option<String>) {
    *AUTO.lock().unwrap_or_else(|e| e.into_inner()) = vm.filter(|v| !v.is_empty());
}

#[tauri::command]
pub fn clipboard_clear() {
    clear();
}
