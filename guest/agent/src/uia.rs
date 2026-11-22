//! Chromium builds its accessibility tree only after the first query, so Chromium windows are queried twice.
use crate::capture::{output_rect, CallResult};
use crate::state::*;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::time::{Duration, Instant};
use windows::core::BSTR;
use windows::Win32::System::Com::*;
use windows::Win32::UI::Accessibility::*;

thread_local! {
    static AUTO: RefCell<Option<IUIAutomation>> = const { RefCell::new(None) };
    static LAST: RefCell<Vec<IUIAutomationElement>> = const { RefCell::new(Vec::new()) };
    static WARM: RefCell<Vec<isize>> = const { RefCell::new(Vec::new()) };
}

fn automation() -> Result<IUIAutomation, (&'static str, String)> {
    AUTO.with(|a| {
        if let Some(x) = a.borrow().as_ref() {
            return Ok(x.clone());
        }
        let x: IUIAutomation = unsafe { CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) }.map_err(|e| ("internal", format!("UI Automation: {e}")))?;
        // don't let one hung app block the helper for long
        if let Ok(x2) = windows::core::Interface::cast::<IUIAutomation2>(&x) {
            unsafe {
                let _ = x2.SetConnectionTimeout(2000);
                let _ = x2.SetTransactionTimeout(10000);
            }
        }
        *a.borrow_mut() = Some(x.clone());
        Ok(x)
    })
}

fn role(id: i32) -> &'static str {
    match id {
        50000 => "button", 50001 => "calendar", 50002 => "checkbox", 50003 => "combobox", 50004 => "edit",
        50005 => "hyperlink", 50006 => "image", 50007 => "listitem", 50008 => "list", 50009 => "menu",
        50010 => "menubar", 50011 => "menuitem", 50012 => "progressbar", 50013 => "radiobutton", 50014 => "scrollbar",
        50015 => "slider", 50016 => "spinner", 50017 => "statusbar", 50018 => "tab", 50019 => "tabitem",
        50020 => "text", 50021 => "toolbar", 50022 => "tooltip", 50023 => "tree", 50024 => "treeitem",
        50025 => "custom", 50026 => "group", 50027 => "thumb", 50028 => "datagrid", 50029 => "dataitem",
        50030 => "document", 50031 => "splitbutton", 50032 => "window", 50033 => "pane", 50034 => "header",
        50035 => "headeritem", 50036 => "table", 50037 => "titlebar", 50038 => "separator", 50039 => "semanticzoom",
        50040 => "appbar",
        _ => "other",
    }
}

fn interactive_role(r: &str) -> bool {
    matches!(r, "button" | "checkbox" | "combobox" | "edit" | "hyperlink" | "listitem" | "menuitem" | "radiobutton" | "slider" | "spinner"
        | "tabitem" | "treeitem" | "splitbutton" | "dataitem" | "document" | "scrollbar" | "headeritem")
}

const PATTERNS: [(UIA_PROPERTY_ID, &str); 6] = [
    (UIA_IsInvokePatternAvailablePropertyId, "invoke"),
    (UIA_IsTogglePatternAvailablePropertyId, "toggle"),
    (UIA_IsSelectionItemPatternAvailablePropertyId, "select"),
    (UIA_IsExpandCollapsePatternAvailablePropertyId, "expand"),
    (UIA_IsValuePatternAvailablePropertyId, "setValue"),
    (UIA_IsScrollPatternAvailablePropertyId, "scroll"),
];

fn cached_bool(e: &IUIAutomationElement, id: UIA_PROPERTY_ID) -> bool {
    unsafe { e.GetCachedPropertyValue(id).ok().and_then(|v| bool::try_from(&v).ok()).unwrap_or(false) }
}

struct Walk {
    nodes: Vec<Value>,
    elems: Vec<IUIAutomationElement>,
    bytes: usize,
    total: usize,
    max: usize,
    truncated: bool,
    visible_only: bool,
    interactive_only: bool,
    ox: i32,
    oy: i32,
}

unsafe fn walk(e: &IUIAutomationElement, depth: usize, w: &mut Walk) {
    w.total += 1;
    if depth > 60 {
        return;
    }
    let ct = e.CachedControlType().map(|c| c.0).unwrap_or(0);
    let r = role(ct);
    let rect = e.CachedBoundingRectangle().unwrap_or_default();
    let off = e.CachedIsOffscreen().map(|b| b.as_bool()).unwrap_or(true);
    let visible = !off && rect.right > rect.left && rect.bottom > rect.top;
    let patterns: Vec<&str> = PATTERNS.iter().filter(|(id, _)| cached_bool(e, *id)).map(|(_, n)| *n).collect();
    let interactive = interactive_role(r) || patterns.iter().any(|p| *p != "scroll");
    if (!w.visible_only || visible) && (!w.interactive_only || interactive) {
        if w.nodes.len() >= w.max || w.bytes > 56 * 1024 {
            w.truncated = true;
        } else {
            let name: String = e.CachedName().map(|b| b.to_string()).unwrap_or_default().chars().take(120).collect();
            let n = json!({
                "id": w.elems.len(), "role": r, "name": name,
                "bbox": [rect.left - w.ox, rect.top - w.oy, rect.right - rect.left, rect.bottom - rect.top],
                "enabled": e.CachedIsEnabled().map(|b| b.as_bool()).unwrap_or(false),
                "patterns": patterns,
            });
            w.bytes += n.to_string().len() + 1;
            w.nodes.push(n);
            w.elems.push(e.clone());
        }
    }
    if let Ok(kids) = e.GetCachedChildren() {
        for i in 0..kids.Length().unwrap_or(0) {
            if let Ok(k) = kids.GetElement(i) {
                walk(&k, depth + 1, w);
            }
        }
    }
}

/// Open menus and popups live in their own top-level windows, outside the window in front.
fn popups(fg: windows::Win32::Foundation::HWND) -> Vec<windows::Win32::Foundation::HWND> {
    use windows::Win32::Foundation::*;
    use windows::Win32::UI::WindowsAndMessaging::*;
    struct Ctx { fg: HWND, pid: u32, out: Vec<HWND> }
    unsafe extern "system" fn each(h: HWND, l: LPARAM) -> windows::core::BOOL {
        let c = &mut *(l.0 as *mut Ctx);
        if h == c.fg || !IsWindowVisible(h).as_bool() || c.out.len() >= 8 {
            return TRUE;
        }
        let mut pid = 0u32;
        GetWindowThreadProcessId(h, Some(&mut pid));
        let style = GetWindowLongW(h, GWL_STYLE) as u32;
        let owned = GetWindow(h, GW_OWNER).map_or(false, |o| o == c.fg);
        let menu = window_class(h) == "#32768";
        let popup = pid == c.pid && style & WS_POPUP.0 != 0;
        if (menu || owned || popup) && window_block(h).0.is_none() {
            c.out.push(h);
        }
        TRUE
    }
    let mut c = Ctx { fg, pid: 0, out: vec![] };
    unsafe {
        GetWindowThreadProcessId(fg, Some(&mut c.pid));
        let _ = EnumWindows(Some(each), LPARAM(&mut c as *mut Ctx as isize));
    }
    c.out
}

pub fn ui_tree(p: &Value) -> CallResult {
    let scope = p["scope"].as_str().unwrap_or("foreground");
    if scope != "foreground" {
        return Err(("bad_request", "scope is \"foreground\"".into()));
    }
    let f = foreground(Duration::from_millis(500));
    if let Some(code) = f.blocked {
        return Err((code, block_message(code, &f)));
    }
    let auto = automation()?;
    let t0 = Instant::now();
    let origin = output_rect().map(|r| (r.left, r.top)).unwrap_or((0, 0));
    let mut w = Walk {
        nodes: vec![],
        elems: vec![],
        bytes: 0,
        total: 0,
        max: p["maxNodes"].as_u64().unwrap_or(300).clamp(1, 1000) as usize,
        truncated: false,
        visible_only: p["visibleOnly"].as_bool().unwrap_or(true),
        interactive_only: p["interactiveOnly"].as_bool().unwrap_or(true),
        ox: origin.0,
        oy: origin.1,
    };
    let chromium = window_class(f.hwnd).starts_with("Chrome_WidgetWin");
    let twice = chromium
        && WARM.with(|w| {
            let mut w = w.borrow_mut();
            let h = f.hwnd.0 as isize;
            if w.contains(&h) {
                false
            } else {
                if w.len() > 64 {
                    w.clear();
                }
                w.push(h);
                true
            }
        });
    let mut queries = 0;
    unsafe {
        let cr = auto.CreateCacheRequest().map_err(|e| ("internal", e.to_string()))?;
        for id in [UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_BoundingRectanglePropertyId, UIA_IsEnabledPropertyId, UIA_IsOffscreenPropertyId, UIA_ProcessIdPropertyId]
            .into_iter()
            .chain(PATTERNS.iter().map(|(id, _)| *id))
        {
            let _ = cr.AddProperty(id);
        }
        let _ = cr.SetTreeScope(TreeScope(TreeScope_Element.0 | TreeScope_Descendants.0));
        if let Ok(c) = auto.ControlViewCondition() {
            let _ = cr.SetTreeFilter(&c);
        }
        // Full mode: the cached elements stay usable for ui.invoke
        let _ = cr.SetAutomationElementMode(AutomationElementMode_Full);
        let mut root = None;
        let mut first_total = 0;
        for _ in 0..if twice { 2 } else { 1 } {
            queries += 1;
            let r = auto.ElementFromHandleBuildCache(f.hwnd, &cr).map_err(|e| ("internal", format!("UI Automation: {e}")))?;
            let mut n = 0usize;
            fn count(e: &IUIAutomationElement, n: &mut usize) {
                *n += 1;
                if let Ok(k) = unsafe { e.GetCachedChildren() } {
                    for i in 0..unsafe { k.Length() }.unwrap_or(0) {
                        if let Ok(c) = unsafe { k.GetElement(i) } {
                            count(&c, n);
                        }
                    }
                }
            }
            count(&r, &mut n);
            first_total = first_total.max(n);
            root = Some(r);
        }
        let _ = first_total;
        walk(root.as_ref().unwrap(), 0, &mut w);
        for h in popups(f.hwnd) {
            if let Ok(r) = auto.ElementFromHandleBuildCache(h, &cr) {
                queries += 1;
                walk(&r, 0, &mut w);
            }
        }
    }
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    LAST.with(|l| *l.borrow_mut() = w.elems);
    Ok((
        json!({"window": f.title, "process": f.process, "nodes": w.nodes, "total": w.total, "truncated": w.truncated,
               "chromium": chromium, "queries": queries, "ms": (ms * 10.0).round() / 10.0}),
        None,
    ))
}

pub fn ui_invoke(p: &Value) -> CallResult {
    let id = p["id"].as_u64().ok_or(("bad_request", "id is required".to_string()))? as usize;
    let action = p["action"].as_str().unwrap_or("invoke");
    let e = LAST.with(|l| l.borrow().get(id).cloned()).ok_or(("not_found", "no such element: call ui.tree again".to_string()))?;
    let desk = desktop_state();
    if desk != "default" {
        return Err(("secure_desktop", format!("the input desktop is {desk}: only the person can act there")));
    }
    unsafe {
        let pid = e.CachedProcessId().unwrap_or(0) as u32;
        let info = crate::token::process_info(pid);
        if info.integrity.map_or(true, |il| il > own_integrity()) {
            return Err(("blocked_elevated", format!("the element belongs to {} that runs elevated", info.image)));
        }
        let gone = |e: windows::core::Error| ("not_found", format!("the element is gone or refused: {e}"));
        let no = |what: &str| ("bad_request", format!("this element has no {what} pattern"));
        match action {
            "invoke" => e.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId).map_err(|_| no("invoke"))?.Invoke().map_err(gone)?,
            "toggle" => e.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId).map_err(|_| no("toggle"))?.Toggle().map_err(gone)?,
            "select" => e.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId).map_err(|_| no("selection item"))?.Select().map_err(gone)?,
            "expand" | "collapse" => {
                let x = e.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId).map_err(|_| no("expand/collapse"))?;
                if action == "expand" { x.Expand() } else { x.Collapse() }.map_err(gone)?
            }
            "setValue" => {
                let v = p["value"].as_str().ok_or(("bad_request", "value is required".to_string()))?;
                if v.chars().count() > 10_000 {
                    return Err(("too_large", "value takes at most 10000 characters".into()));
                }
                e.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId).map_err(|_| no("value"))?.SetValue(&BSTR::from(v)).map_err(gone)?
            }
            "focus" => e.SetFocus().map_err(gone)?,
            a => return Err(("bad_request", format!("unknown action '{a}'"))),
        }
    }
    Ok((json!({}), None))
}
