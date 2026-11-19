//! UI Automation tree of the foreground window, fetched in one cross-process call with a CacheRequest
//! (control view, subtree; role, name, bounding box, enabled, offscreen, automation id).
use crate::util::*;
use std::time::Instant;
use windows::Win32::System::Com::*;
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow;

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

fn interactive(r: &str) -> bool {
    matches!(r, "button" | "checkbox" | "combobox" | "edit" | "hyperlink" | "listitem" | "menuitem" | "radiobutton"
        | "slider" | "spinner" | "tabitem" | "treeitem" | "splitbutton" | "dataitem" | "document" | "scrollbar")
}

struct Acc {
    total: usize,
    visible: usize,
    interactive_visible: usize,
    lines: Vec<String>,
    max_lines: usize,
    max_depth: usize,
}

unsafe fn walk(e: &IUIAutomationElement, depth: usize, acc: &mut Acc) {
    acc.total += 1;
    acc.max_depth = acc.max_depth.max(depth);
    let ct = e.CachedControlType().map(|c| c.0).unwrap_or(0);
    let r = role(ct);
    let name = e.CachedName().map(|b| b.to_string()).unwrap_or_default();
    let rect = e.CachedBoundingRectangle().unwrap_or_default();
    let enabled = e.CachedIsEnabled().map(|b| b.as_bool()).unwrap_or(false);
    let off = e.CachedIsOffscreen().map(|b| b.as_bool()).unwrap_or(true);
    let vis = !off && rect.right > rect.left && rect.bottom > rect.top;
    if vis {
        acc.visible += 1;
        if interactive(r) {
            acc.interactive_visible += 1;
            if acc.lines.len() < acc.max_lines {
                let n: String = name.chars().take(80).collect();
                acc.lines.push(format!(
                    "{{\"role\":\"{r}\",\"name\":{},\"bbox\":[{},{},{},{}],\"enabled\":{enabled},\"depth\":{depth}}}",
                    jstr(&n), rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top
                ));
            }
        }
    }
    if let Ok(kids) = e.GetCachedChildren() {
        let n = kids.Length().unwrap_or(0);
        for i in 0..n {
            if let Ok(k) = kids.GetElement(i) {
                walk(&k, depth + 1, acc);
            }
        }
    }
}

/// focused : the focused element's role, name, value (ValuePattern) and vertical scroll percent (ScrollPattern of it
/// or its nearest scrollable ancestor), to verify that typed text and scrolling really landed.
pub fn cmd_focused() -> String {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let auto: IUIAutomation = match CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) {
            Ok(a) => a,
            Err(e) => return format!("{{\"ok\":false,\"error\":\"{:#x}\"}}", e.code().0),
        };
        let el = match auto.GetFocusedElement() {
            Ok(e) => e,
            Err(e) => return format!("{{\"ok\":false,\"error\":\"GetFocusedElement {:#x}\"}}", e.code().0),
        };
        let ct = el.CurrentControlType().map(|c| c.0).unwrap_or(0);
        let name = el.CurrentName().map(|b| b.to_string()).unwrap_or_default();
        let value = el
            .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
            .and_then(|p| p.CurrentValue())
            .map(|b| b.to_string());
        let value = match value {
            Ok(v) => jstr(&v.chars().take(400).collect::<String>()),
            Err(e) => format!("\"error {:#x}\"", e.code().0),
        };
        let walker = auto.ControlViewWalker().ok();
        let mut cur = Some(el.clone());
        let mut scroll = "null".to_string();
        for _ in 0..6 {
            let Some(c) = cur.clone() else { break };
            if let Ok(sp) = c.GetCurrentPatternAs::<IUIAutomationScrollPattern>(UIA_ScrollPatternId) {
                if let Ok(v) = sp.CurrentVerticalScrollPercent() {
                    scroll = format!("{v:.2}");
                    break;
                }
            }
            cur = walker.as_ref().and_then(|w| w.GetParentElement(&c).ok());
        }
        format!("{{\"ok\":true,\"role\":\"{}\",\"name\":{},\"value\":{value},\"verticalScrollPercent\":{scroll}}}", role(ct), jstr(&name))
    }
}

/// uia [--max-lines 400] [--raw] : tree of the foreground window. Times: create automation, one BuildCache call,
/// local walk. With --raw uses the raw view instead of the control view (to show how much filtering saves).
pub fn cmd_uia(args: &[String]) -> String {
    let max_lines: usize = arg_or(args, "--max-lines", "400").parse().unwrap();
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let t0 = Instant::now();
        let auto: IUIAutomation = match CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER) {
            Ok(a) => a,
            Err(e) => return format!("{{\"ok\":false,\"error\":\"CoCreateInstance {:#x}\"}}", e.code().0),
        };
        let create_ms = t0.elapsed().as_secs_f64() * 1e3;
        let cr = auto.CreateCacheRequest().unwrap();
        for p in [UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_BoundingRectanglePropertyId, UIA_IsEnabledPropertyId, UIA_IsOffscreenPropertyId, UIA_AutomationIdPropertyId] {
            cr.AddProperty(p).unwrap();
        }
        cr.SetTreeScope(TreeScope(TreeScope_Element.0 | TreeScope_Descendants.0)).unwrap();
        let cond = if has(args, "--raw") { auto.RawViewCondition().unwrap() } else { auto.ControlViewCondition().unwrap() };
        cr.SetTreeFilter(&cond).unwrap();
        cr.SetAutomationElementMode(AutomationElementMode_None).unwrap();
        let hwnd = GetForegroundWindow();
        let t1 = Instant::now();
        let root = match auto.ElementFromHandleBuildCache(hwnd, &cr) {
            Ok(r) => r,
            Err(e) => return format!("{{\"ok\":false,\"error\":\"ElementFromHandleBuildCache {:#x}\"}}", e.code().0),
        };
        let fetch_ms = t1.elapsed().as_secs_f64() * 1e3;
        let t2 = Instant::now();
        let mut acc = Acc { total: 0, visible: 0, interactive_visible: 0, lines: Vec::new(), max_lines, max_depth: 0 };
        walk(&root, 0, &mut acc);
        let walk_ms = t2.elapsed().as_secs_f64() * 1e3;
        let title = root.CachedName().map(|b| b.to_string()).unwrap_or_default();
        format!(
            "{{\"ok\":true,\"window\":{},\"view\":\"{}\",\"createMs\":{create_ms:.1},\"fetchMs\":{fetch_ms:.1},\"walkMs\":{walk_ms:.2},\"total\":{},\"visible\":{},\"interactiveVisible\":{},\"maxDepth\":{},\"elements\":[{}]}}",
            jstr(&title),
            if has(args, "--raw") { "raw" } else { "control" },
            acc.total,
            acc.visible,
            acc.interactive_visible,
            acc.max_depth,
            acc.lines.join(",")
        )
    }
}
