// Never activated: activating a window mid-drag makes Windows cancel the drag.
// The web view can't take the drop: wry registers its drop target when the window is built, and this one is built hidden.

use serde_json::{json, Value};
use std::ffi::c_void;
use std::sync::atomic::{AtomicBool, AtomicIsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use windows_sys::core::GUID;
use windows_sys::Win32::Foundation::{HWND, POINTL};
use windows_sys::Win32::System::Com::{FORMATETC, STGMEDIUM};
use windows_sys::Win32::System::Ole::{OleInitialize, RegisterDragDrop, ReleaseStgMedium, CF_HDROP, DROPEFFECT_COPY, DROPEFFECT_NONE};
use windows_sys::Win32::UI::Shell::{DragQueryFileW, HDROP};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, GetMessageW, GetWindowLongPtrW, RegisterClassW, SetLayeredWindowAttributes,
    SetWindowLongPtrW, SetWindowPos, ShowWindow, GWLP_HWNDPARENT, GWL_EXSTYLE, HWND_TOP, LWA_ALPHA, MSG, SWP_NOACTIVATE,
    SWP_SHOWWINDOW, SW_HIDE, WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_POPUP,
};

pub const LABEL: &str = "viewer-drop";
const UNCONFIRMED: Duration = Duration::from_millis(1500);
const KEEP: usize = 20;

struct Zone {
    vm: Option<String>,
    shown_at: Option<Instant>,
    state: &'static str,
    id: Option<String>,
}
static ZONE: Mutex<Zone> = Mutex::new(Zone { vm: None, shown_at: None, state: "drag", id: None });
static HOVER: AtomicBool = AtomicBool::new(false);
static APP: Mutex<Option<AppHandle>> = Mutex::new(None);
static CATCHER: AtomicIsize = AtomicIsize::new(0);

fn zone() -> std::sync::MutexGuard<'static, Zone> {
    ZONE.lock().unwrap_or_else(|e| e.into_inner())
}

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn drop_window(app: &AppHandle) -> Option<tauri::WebviewWindow> {
    if let Some(w) = app.get_webview_window(LABEL) {
        return Some(w);
    }
    let w = WebviewWindowBuilder::new(app, LABEL, WebviewUrl::App("index.html".into())).additional_browser_args(crate::BROWSER_ARGS).general_autofill_enabled(false)
        .title("GpuVM")
        .decorations(false)
        .transparent(true).no_redirection_bitmap(true)
        .shadow(false)
        .resizable(false)
        .skip_taskbar(true)
        .focused(false)
        .visible(false)
        .disable_drag_drop_handler()
        .build()
        .ok()?;
    if let Ok(h) = w.hwnd() {
        // SAFETY: style bits on our own window: never activated by a click or by being shown.
        unsafe {
            let ex = GetWindowLongPtrW(h.0 as HWND, GWL_EXSTYLE);
            SetWindowLongPtrW(h.0 as HWND, GWL_EXSTYLE, ex | (WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW) as isize);
        }
    }
    Some(w)
}

fn tell(app: &AppHandle, state: &'static str, id: Option<&str>) {
    let vm = {
        let mut z = zone();
        z.state = state;
        z.id = id.map(str::to_string);
        z.vm.clone()
    };
    let _ = app.emit_to(LABEL, "viewer-drop", json!({ "vm": vm, "state": state, "id": id }));
}

pub fn on_drag(app: &AppHandle, vm: &str) {
    let Some(viewer) = crate::viewer::viewer_hwnd(vm) else { return };
    let Some((x, y, w, h)) = crate::overlay::picture_rect(viewer, vm) else { return };
    let Some(window) = drop_window(app) else { return };
    let catcher = ensure_catcher(app);
    {
        let mut z = zone();
        z.vm = Some(vm.to_string());
        z.shown_at = Some(Instant::now());
    }
    HOVER.store(false, Ordering::Relaxed);
    tell(app, "drag", None);
    if let Ok(own) = window.hwnd() {
        // SAFETY: our own windows, owned by the viewer and by the drop area, shown without activation.
        unsafe {
            SetWindowLongPtrW(own.0 as HWND, GWLP_HWNDPARENT, viewer);
            SetWindowPos(own.0 as HWND, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
            if catcher != 0 {
                SetWindowLongPtrW(catcher as HWND, GWLP_HWNDPARENT, own.0 as isize);
                SetWindowPos(catcher as HWND, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
            }
        }
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(UNCONFIRMED);
        let stale = zone().shown_at.is_some_and(|t| t.elapsed() >= UNCONFIRMED);
        if stale && !HOVER.load(Ordering::Relaxed) {
            hide(&app);
        }
    });
}

const CARD: (f64, f64) = (300.0, 76.0);
const CARD_MARGIN: f64 = 16.0;

fn show_card(app: &AppHandle, vm: &str, id: &str) {
    zone().shown_at = None;
    HOVER.store(false, Ordering::Relaxed);
    hide_catcher();
    let (Some(window), Some(viewer)) = (app.get_webview_window(LABEL), crate::viewer::viewer_hwnd(vm)) else { return hide(app) };
    let Some((x, y, w, h)) = crate::overlay::picture_rect(viewer, vm) else { return hide(app) };
    // SAFETY: plain query on the viewer's window.
    let scale = unsafe { windows_sys::Win32::UI::HiDpi::GetDpiForWindow(viewer as HWND).max(96) } as f64 / 96.0;
    let (cw, ch, m) = ((CARD.0 * scale) as i32, (CARD.1 * scale) as i32, (CARD_MARGIN * scale) as i32);
    tell(app, "card", Some(id));
    if let Ok(own) = window.hwnd() {
        // SAFETY: our window, still owned by the viewer, moved without activation.
        unsafe { SetWindowPos(own.0 as HWND, HWND_TOP, x + w - cw - m, y + h - ch - m, cw, ch, SWP_SHOWWINDOW | SWP_NOACTIVATE) };
    }
}

fn hide_catcher() {
    let catcher = CATCHER.load(Ordering::Relaxed);
    if catcher != 0 {
        // SAFETY: our own window.
        unsafe { ShowWindow(catcher as HWND, SW_HIDE) };
    }
}

// Hidden with Win32: shown with Win32 without activation, Tauri still takes it for hidden and its hide() does nothing.
pub fn hide(app: &AppHandle) {
    zone().shown_at = None;
    HOVER.store(false, Ordering::Relaxed);
    hide_catcher();
    if let Some(w) = app.get_webview_window(LABEL) {
        if let Ok(own) = w.hwnd() {
            // SAFETY: our own window.
            unsafe { ShowWindow(own.0 as HWND, SW_HIDE) };
        }
    }
}

fn dropped(app: &AppHandle, paths: Vec<String>) {
    let vm = zone().vm.clone();
    let (Some(vm), false) = (vm, paths.is_empty()) else {
        crate::diag::log_error("drop", "nothing to send: no machine or no files in the drop");
        return hide(app);
    };
    let folder = "Received";
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match start(&app, vm.clone(), paths, None, folder.to_string()).await {
            Ok(id) => show_card(&app, &vm, &id),
            Err(e) => {
                crate::diag::log_error("drop", &e);
                hide(&app)
            }
        }
    });
}

#[repr(C)]
struct DropTargetVtbl {
    query_interface: unsafe extern "system" fn(*mut c_void, *const GUID, *mut *mut c_void) -> i32,
    add_ref: unsafe extern "system" fn(*mut c_void) -> u32,
    release: unsafe extern "system" fn(*mut c_void) -> u32,
    drag_enter: unsafe extern "system" fn(*mut c_void, *mut c_void, u32, POINTL, *mut u32) -> i32,
    drag_over: unsafe extern "system" fn(*mut c_void, u32, POINTL, *mut u32) -> i32,
    drag_leave: unsafe extern "system" fn(*mut c_void) -> i32,
    drop: unsafe extern "system" fn(*mut c_void, *mut c_void, u32, POINTL, *mut u32) -> i32,
}
#[repr(C)]
struct DropTarget {
    vtbl: *const DropTargetVtbl,
}
// SAFETY: the object holds only a pointer to a static vtable.
unsafe impl Sync for DropTarget {}

const IID_IUNKNOWN: GUID = GUID::from_u128(0x00000000_0000_0000_c000_000000000046);
const IID_IDROPTARGET: GUID = GUID::from_u128(0x00000122_0000_0000_c000_000000000046);
const E_NOINTERFACE: i32 = 0x8000_4002_u32 as i32;

static VTBL: DropTargetVtbl = DropTargetVtbl { query_interface, add_ref, release, drag_enter, drag_over, drag_leave, drop };
static TARGET: DropTarget = DropTarget { vtbl: &VTBL };

fn same_guid(a: &GUID, b: &GUID) -> bool {
    a.data1 == b.data1 && a.data2 == b.data2 && a.data3 == b.data3 && a.data4 == b.data4
}

unsafe extern "system" fn query_interface(this: *mut c_void, riid: *const GUID, out: *mut *mut c_void) -> i32 {
    if !riid.is_null() && (same_guid(&*riid, &IID_IUNKNOWN) || same_guid(&*riid, &IID_IDROPTARGET)) {
        *out = this;
        return 0;
    }
    *out = std::ptr::null_mut();
    E_NOINTERFACE
}
unsafe extern "system" fn add_ref(_: *mut c_void) -> u32 {
    2
}
unsafe extern "system" fn release(_: *mut c_void) -> u32 {
    1
}
// Only Medium integrity or above: a Low viewer taken over by the stream could drag this PC's files onto the drop area.
static SOURCE_OK: AtomicBool = AtomicBool::new(false);

unsafe fn source_trusted() -> bool {
    use windows_sys::Win32::Security::{GetSidSubAuthority, GetSidSubAuthorityCount, GetTokenInformation, TokenIntegrityLevel, TOKEN_MANDATORY_LABEL, TOKEN_QUERY};
    use windows_sys::Win32::System::Com::{CoImpersonateClient, CoRevertToSelf};
    use windows_sys::Win32::System::Threading::{GetCurrentThread, OpenThreadToken};
    // RPC_E_CALL_COMPLETE / no call context: not a call from another process.
    if CoImpersonateClient() != 0 {
        return true;
    }
    let mut level = 0u32;
    let mut token = std::ptr::null_mut();
    if OpenThreadToken(GetCurrentThread(), TOKEN_QUERY, 1, &mut token) != 0 {
        let mut buf = [0u8; 128];
        let mut len = 0u32;
        if GetTokenInformation(token, TokenIntegrityLevel, buf.as_mut_ptr().cast(), buf.len() as u32, &mut len) != 0 {
            let label = &*(buf.as_ptr() as *const TOKEN_MANDATORY_LABEL);
            let count = *GetSidSubAuthorityCount(label.Label.Sid);
            if count > 0 {
                level = *GetSidSubAuthority(label.Label.Sid, count as u32 - 1);
            }
        }
        windows_sys::Win32::Foundation::CloseHandle(token);
    }
    CoRevertToSelf();
    // SECURITY_MANDATORY_MEDIUM_RID
    level >= 0x2000
}

unsafe extern "system" fn drag_enter(_: *mut c_void, _: *mut c_void, _: u32, _: POINTL, effect: *mut u32) -> i32 {
    let trusted = source_trusted();
    SOURCE_OK.store(trusted, Ordering::Relaxed);
    if !trusted {
        *effect = DROPEFFECT_NONE;
        return 0;
    }
    HOVER.store(true, Ordering::Relaxed);
    zone().shown_at = None;
    if let Some(app) = APP.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        tell(&app, "over", None);
    }
    *effect = DROPEFFECT_COPY;
    0
}
unsafe extern "system" fn drag_over(_: *mut c_void, _: u32, _: POINTL, effect: *mut u32) -> i32 {
    *effect = if SOURCE_OK.load(Ordering::Relaxed) { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
    0
}
unsafe extern "system" fn drag_leave(_: *mut c_void) -> i32 {
    if let Some(app) = APP.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        hide(&app);
    }
    0
}
unsafe extern "system" fn drop(_: *mut c_void, data: *mut c_void, _: u32, _: POINTL, effect: *mut u32) -> i32 {
    // Checked again at the drop itself (not only at the enter): a source below Medium never names files here.
    if !SOURCE_OK.swap(false, Ordering::Relaxed) || !source_trusted() {
        crate::diag::log_error("drop", "refused: the program the files came from isn't trusted");
        *effect = DROPEFFECT_NONE;
        if let Some(app) = APP.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            hide(&app);
        }
        return 0;
    }
    let paths = paths_of(data);
    *effect = if paths.is_empty() { DROPEFFECT_NONE } else { DROPEFFECT_COPY };
    if let Some(app) = APP.lock().unwrap_or_else(|e| e.into_inner()).clone() {
        hide_catcher();
        dropped(&app, paths);
    }
    0
}

unsafe fn paths_of(data: *mut c_void) -> Vec<String> {
    if data.is_null() {
        return Vec::new();
    }
    type GetData = unsafe extern "system" fn(*mut c_void, *const FORMATETC, *mut STGMEDIUM) -> i32;
    let vtbl = *(data as *const *const usize);
    let get_data: GetData = std::mem::transmute(*vtbl.add(3));
    let format = FORMATETC { cfFormat: CF_HDROP, ptd: std::ptr::null_mut(), dwAspect: 1, lindex: -1, tymed: 1 };
    let mut medium: STGMEDIUM = std::mem::zeroed();
    if get_data(data, &format, &mut medium) != 0 {
        return Vec::new();
    }
    let drop = medium.u.hGlobal as HDROP;
    let count = DragQueryFileW(drop, u32::MAX, std::ptr::null_mut(), 0).min(1000);
    let mut paths = Vec::new();
    for i in 0..count {
        let len = DragQueryFileW(drop, i, std::ptr::null_mut(), 0) as usize;
        let mut buf = vec![0u16; len + 1];
        DragQueryFileW(drop, i, buf.as_mut_ptr(), buf.len() as u32);
        paths.push(String::from_utf16_lossy(&buf[..len]));
    }
    ReleaseStgMedium(&mut medium);
    paths
}

// OLE drop targets need a single-threaded apartment that runs its messages.
fn ensure_catcher(app: &AppHandle) -> isize {
    let current = CATCHER.load(Ordering::Relaxed);
    if current != 0 {
        return current;
    }
    *APP.lock().unwrap_or_else(|e| e.into_inner()) = Some(app.clone());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // SAFETY: a window of this thread with OLE set up on it; the loop runs for the life of the process.
        unsafe {
            OleInitialize(std::ptr::null_mut());
            unsafe extern "system" fn proc_(hwnd: HWND, msg: u32, w: usize, l: isize) -> isize {
                DefWindowProcW(hwnd, msg, w, l)
            }
            let class = wide("GpuVMDropCatcher");
            let wc = WNDCLASSW { lpfnWndProc: Some(proc_), lpszClassName: class.as_ptr(), ..std::mem::zeroed() };
            RegisterClassW(&wc);
            let hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, class.as_ptr(), class.as_ptr(), WS_POPUP,
                0, 0, 0, 0, std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null());
            // Alpha 1: invisible, but it still takes the pointer (a fully transparent one would let it through).
            if hwnd.is_null() || SetLayeredWindowAttributes(hwnd, 0, 1, LWA_ALPHA) == 0
                || RegisterDragDrop(hwnd, &TARGET as *const DropTarget as *mut c_void) != 0
            {
                let _ = tx.send(0);
                return;
            }
            let _ = tx.send(hwnd as isize);
            let mut msg: MSG = std::mem::zeroed();
            while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
                DispatchMessageW(&msg);
            }
        }
    });
    let hwnd = rx.recv_timeout(Duration::from_secs(2)).unwrap_or(0);
    CATCHER.store(hwnd, Ordering::Relaxed);
    hwnd
}

#[tauri::command]
pub fn viewer_drop_state() -> Value {
    let z = zone();
    json!({ "vm": z.vm, "state": z.state, "id": z.id })
}

static TRANSFERS: Mutex<Vec<Value>> = Mutex::new(Vec::new());

fn update(app: &AppHandle, id: &str, change: impl FnOnce(&mut Value)) {
    let snapshot = {
        let mut list = TRANSFERS.lock().unwrap_or_else(|e| e.into_inner());
        let Some(t) = list.iter_mut().find(|t| t["id"] == id) else { return };
        change(t);
        t.clone()
    };
    let _ = app.emit("transfer", snapshot);
}

fn new_id() -> String {
    let mut bytes = [0u8; 16];
    // SAFETY: fills the buffer with random bytes.
    unsafe {
        windows_sys::Win32::Security::Cryptography::BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), 16,
            windows_sys::Win32::Security::Cryptography::BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn percent_of(message: &str) -> Option<u32> {
    let rest = message.strip_prefix("Sending ")?;
    rest.split_whitespace().next()?.parse().ok()
}

#[tauri::command]
pub async fn transfer_start(app: AppHandle, vm: String, paths: Vec<String>, from: Option<String>, folder: String) -> Result<String, String> {
    start(&app, vm, paths, from, folder).await
}

async fn start(app: &AppHandle, vm: String, paths: Vec<String>, from: Option<String>, folder: String) -> Result<String, String> {
    if paths.is_empty() || paths.len() > 1000 {
        return Err("Choose between 1 and 1000 items.".into());
    }
    let from = from.filter(|f| !f.is_empty());
    let id = new_id();
    let names: Vec<String> = paths.iter().map(|p| p.rsplit(['\\', '/']).next().unwrap_or(p).to_string()).collect();
    let entry = json!({ "id": id, "vm": vm, "from": from, "names": names, "state": "running", "percent": 0, "message": "", "error": null, "items": [] });
    {
        let mut list = TRANSFERS.lock().unwrap_or_else(|e| e.into_inner());
        list.push(entry.clone());
        let ended = list.iter().filter(|t| t["state"] != "running").count();
        if ended > KEEP {
            let mut drop_n = ended - KEEP;
            list.retain(|t| if drop_n > 0 && t["state"] != "running" { drop_n -= 1; false } else { true });
        }
    }
    let _ = app.emit("transfer", entry);
    let mut args = json!({ "Name": vm, "Path": paths, "Folder": folder, "TransferId": id });
    if let Some(f) = &from {
        args["FromVM"] = json!(f);
    }
    let request = json!({ "id": id, "cmd": "Send-GpuVMFile", "args": args });
    let mut conn = tauri::async_runtime::spawn_blocking(crate::backend::connect).await.map_err(|e| e.to_string())??;
    let (app2, id2) = (app.clone(), id.clone());
    std::thread::spawn(move || {
        let result = conn.call(&request, |event| {
            if event["type"] == "progress" {
                let message = event["message"].as_str().unwrap_or("").to_string();
                update(&app2, &id2, |t| {
                    if let Some(p) = percent_of(&message) {
                        t["percent"] = json!(p);
                    }
                    t["message"] = json!(message);
                });
            }
        });
        update(&app2, &id2, |t| match result {
            Ok(r) if r["ok"] == true => {
                t["state"] = json!("done");
                t["percent"] = json!(100);
                t["items"] = r["data"][0]["items"].clone();
                t["folder"] = r["data"][0]["folder"].clone();
            }
            Ok(r) => {
                let error = r["error"].as_str().unwrap_or("It couldn't be copied.").to_string();
                t["state"] = json!(if error == "Copy cancelled." { "cancelled" } else { "error" });
                t["error"] = json!(error);
            }
            Err(e) => {
                t["state"] = json!("error");
                t["error"] = json!(e);
            }
        });
    });
    Ok(id)
}

#[tauri::command]
pub async fn transfer_cancel(state: tauri::State<'_, crate::AppState>, id: String) -> Result<(), String> {
    if !id.chars().all(|c| c.is_ascii_hexdigit()) || id.len() != 32 {
        return Err("Unknown copy.".into());
    }
    let request = json!({ "id": crate::next_id(&state), "cmd": "Stop-GpuVMTransfer", "args": { "TransferId": id } });
    crate::into_data(crate::query(&state, request).await?).map(|_| ())
}

#[tauri::command]
pub fn transfer_list() -> Vec<Value> {
    TRANSFERS.lock().unwrap_or_else(|e| e.into_inner()).clone()
}

#[tauri::command]
pub fn viewer_drop_hide(app: AppHandle) {
    hide(&app);
}
