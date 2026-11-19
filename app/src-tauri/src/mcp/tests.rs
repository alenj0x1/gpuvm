//! End-to-end tests of the MCP server over JSON-RPC lines, against the fake broker.

use super::fake::FakeBroker;
use super::server::{Out, Server};
use serde_json::{json, Value};
use std::io::Write;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

#[derive(Clone, Default)]
struct Buf(Arc<Mutex<Vec<u8>>>);

impl Write for Buf {
    fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(b);
        Ok(b.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

struct H {
    server: Arc<Server>,
    fake: Arc<FakeBroker>,
    buf: Buf,
    next: u64,
    modern: bool,
    caps: Value,
}

impl H {
    fn new(modern: bool) -> H {
        H::with(modern, json!({}))
    }

    fn with(modern: bool, caps: Value) -> H {
        let fake = Arc::new(FakeBroker::new());
        let buf = Buf::default();
        let out: Out = Arc::new(Mutex::new(Box::new(buf.clone())));
        let server = Server::new(fake.clone(), out);
        server.ctx.poll_ms.store(5, std::sync::atomic::Ordering::Relaxed);
        let mut h = H { server, fake, buf, next: 0, modern, caps };
        if !modern {
            let r = h.rpc("initialize", json!({ "protocolVersion": "2025-11-25", "capabilities": h.caps.clone(),
                "clientInfo": { "name": "claude-code", "version": "2.1" } }));
            assert_eq!(r["result"]["protocolVersion"], "2025-11-25");
            h.notify("notifications/initialized", json!({}));
        }
        h
    }

    fn lines(&self) -> Vec<Value> {
        let text = String::from_utf8(self.buf.0.lock().unwrap().clone()).unwrap();
        text.lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn notify(&mut self, method: &str, params: Value) {
        self.server.handle_line(&json!({ "jsonrpc": "2.0", "method": method, "params": params }).to_string());
    }

    fn send(&mut self, method: &str, mut params: Value) -> u64 {
        self.next += 1;
        if self.modern {
            params["_meta"] = json!({ "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientInfo": { "name": "claude-code", "version": "3.0" },
                "io.modelcontextprotocol/clientCapabilities": self.caps.clone() });
        }
        self.server.handle_line(&json!({ "jsonrpc": "2.0", "id": self.next, "method": method, "params": params }).to_string());
        self.next
    }

    fn wait_for(&self, id: u64) -> Value {
        let end = Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(v) = self.lines().into_iter().find(|v| v["id"] == id && (v.get("result").is_some() || v.get("error").is_some())) {
                return v;
            }
            assert!(Instant::now() < end, "no reply to {id}");
            std::thread::sleep(Duration::from_millis(2));
        }
    }

    fn rpc(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params);
        self.wait_for(id)
    }

    fn tool(&mut self, name: &str, args: Value) -> Value {
        self.rpc("tools/call", json!({ "name": name, "arguments": args }))["result"].clone()
    }

    fn text(result: &Value) -> String {
        result["content"].as_array().unwrap().iter().filter_map(|c| c["text"].as_str()).collect::<Vec<_>>().join("\n")
    }

    fn ok(&mut self, name: &str, args: Value) -> String {
        let r = self.tool(name, args);
        assert_ne!(r["isError"], true, "{name}: {}", H::text(&r));
        H::text(&r)
    }

    fn err(&mut self, name: &str, args: Value) -> String {
        let r = self.tool(name, args);
        assert_eq!(r["isError"], true, "{name} should fail: {}", H::text(&r));
        H::text(&r)
    }

    fn last_action(&self, machine: &str) -> Value {
        self.fake.with(|s| s.machines.iter().find(|m| m.name == machine).unwrap().actions.last().cloned().unwrap())
    }

    /// A disposable machine taken by this connection, with a default screenshot.
    fn machine(&mut self) -> String {
        let t = self.ok("create_disposable", json!({ "template": "win11-agent", "name": "t1" }));
        assert!(t.contains("ready"), "{t}");
        let r = self.tool("screenshot", json!({ "machine": "t1" }));
        assert_eq!(r["content"][0]["type"], "image");
        "t1".into()
    }
}

#[test]
fn legacy_handshake_and_tool_list() {
    let mut h = H::new(false);
    let r = h.rpc("tools/list", json!({}));
    let tools = r["result"]["tools"].as_array().unwrap();
    assert_eq!(tools.len(), 25);
    let mut names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    names.sort();
    names.dedup();
    assert_eq!(names.len(), 25);
    for t in tools {
        assert_eq!(t["inputSchema"]["type"], "object");
        let a = &t["annotations"];
        assert!(a["readOnlyHint"].is_boolean() && a["destructiveHint"].is_boolean() && a["openWorldHint"].is_boolean());
        if a["readOnlyHint"] == true {
            assert_eq!(a["destructiveHint"], false);
        }
    }
    let destructive: Vec<&str> = tools.iter().filter(|t| t["annotations"]["destructiveHint"] == true).map(|t| t["name"].as_str().unwrap()).collect();
    assert_eq!(destructive, ["run", "write_file", "restore_point_revert", "destroy"]);
    // Legacy results don't carry the modern fields.
    assert!(r["result"].get("resultType").is_none() && r["result"].get("ttlMs").is_none());
    assert_eq!(h.rpc("ping", json!({}))["result"], json!({}));
    // The client is registered with GpuVM by name.
    h.ok("list_machines", json!({}));
    assert_eq!(h.fake.with(|s| s.connections.values().next().unwrap()["name"].clone()), "claude-code");
}

#[test]
fn legacy_version_negotiation() {
    for (asked, chosen) in [("2025-06-18", "2025-06-18"), ("2099-01-01", "2025-11-25"), ("2026-07-28", "2025-11-25")] {
        let h = H::new(true);
        h.server.handle_line(&json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": { "protocolVersion": asked, "capabilities": {}, "clientInfo": { "name": "x", "version": "1" } } }).to_string());
        assert_eq!(h.wait_for(1)["result"]["protocolVersion"], chosen);
    }
}

#[test]
fn modern_discover_and_versions() {
    let mut h = H::new(true);
    let d = h.rpc("server/discover", json!({}));
    assert_eq!(d["result"]["resultType"], "complete");
    assert_eq!(d["result"]["supportedVersions"][0], "2026-07-28");
    assert!(d["result"]["supportedVersions"].as_array().unwrap().contains(&json!("2025-11-25")));
    assert_eq!(d["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["name"], "gpuvm");
    let l = h.rpc("tools/list", json!({}));
    assert_eq!(l["result"]["cacheScope"], "private");
    assert!(l["result"]["ttlMs"].is_u64());
    // Unsupported version: the modern error with the list.
    h.server.handle_line(&json!({ "jsonrpc": "2.0", "id": 99, "method": "tools/list",
        "params": { "_meta": { "io.modelcontextprotocol/protocolVersion": "1900-01-01" } } }).to_string());
    let e = h.wait_for(99);
    assert_eq!(e["error"]["code"], -32022);
    assert_eq!(e["error"]["data"]["requested"], "1900-01-01");
    // No era at all.
    let fresh = H::new(true);
    fresh.server.handle_line(r#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#);
    assert_eq!(fresh.wait_for(5)["error"]["code"], -32600);
    fresh.server.handle_line("not json");
    assert_eq!(fresh.lines().last().unwrap()["error"]["code"], -32700);
    fresh.server.handle_line(r#"{"jsonrpc":"2.0","id":6,"method":"nope","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#);
    assert_eq!(fresh.wait_for(6)["error"]["code"], -32601);
    // A modern tool call carries resultType and serverInfo too.
    let mut h2 = H::new(true);
    let r = h2.rpc("tools/call", json!({ "name": "list_templates", "arguments": {} }));
    assert_eq!(r["result"]["resultType"], "complete");
    assert!(H::text(&r["result"]).contains("win11-agent"));
}

#[test]
fn screenshot_and_coordinate_round_trip() {
    let mut h = H::new(false);
    let m = h.machine();
    let shot = h.tool("screenshot", json!({ "machine": m }));
    assert_eq!(shot["content"][0]["mimeType"], "image/png");
    let t = H::text(&shot);
    assert!(t.contains("1280x720") && t.contains("desktop 1920x1080"), "{t}");
    h.ok("click", json!({ "machine": m, "x": 640, "y": 360 }));
    assert_eq!(h.last_action(&m), json!({ "type": "click", "x": 960, "y": 540, "button": "left", "count": 1 }));
    h.ok("click", json!({ "machine": m, "x": 0, "y": 0 }));
    assert_eq!(h.last_action(&m)["x"], 0);
    h.ok("click", json!({ "machine": m, "x": 1279, "y": 719 }));
    assert_eq!(h.last_action(&m), json!({ "type": "click", "x": 1919, "y": 1079, "button": "left", "count": 1 }));

    // A smaller picture: its own scale, kept per screenshot.
    let small = h.tool("screenshot", json!({ "machine": m, "maxWidth": 640, "maxHeight": 640 }));
    assert!(H::text(&small).contains("640x360"));
    h.ok("click", json!({ "machine": m, "x": 100, "y": 50 }));
    assert_eq!(h.last_action(&m)["x"], 301);
    assert_eq!(h.last_action(&m)["y"], 151);
    // The earlier 1280x720 screenshot (id 2) still maps with its own scale.
    h.ok("click", json!({ "machine": m, "x": 640, "y": 360, "screenshot": 2 }));
    assert_eq!(h.last_action(&m)["x"], 960);

    // Zoom: a part at native resolution; actions keep using the full screenshot.
    let z = h.tool("screenshot", json!({ "machine": m, "zoom": [100, 100, 200, 100] }));
    let zt = H::text(&z);
    assert!(zt.contains("[300, 300, 600, 300]") && zt.contains("600x300"), "{zt}");
    h.ok("click", json!({ "machine": m, "x": 100, "y": 50 }));
    assert_eq!(h.last_action(&m)["x"], 301);

    // Big pictures stay within Anthropic's limits.
    let big = h.tool("screenshot", json!({ "machine": m, "maxWidth": 2576, "maxHeight": 2576 }));
    assert!(H::text(&big).contains("1920x1080"));

    // Drag, scroll, act and screenshotAfter.
    h.ok("drag", json!({ "machine": m, "x": 10, "y": 10, "toX": 20, "toY": 20, "screenshot": 2 }));
    assert_eq!(h.last_action(&m), json!({ "type": "drag", "x": 15, "y": 15, "toX": 30, "toY": 30 }));
    let a = h.tool("act", json!({ "machine": m, "screenshot": 2, "screenshotAfter": true, "actions": [
        { "type": "click", "x": 2, "y": 2 }, { "type": "type", "text": "hello" }, { "type": "key", "keys": "Ctrl+S" }, { "type": "wait", "ms": 10 } ] }));
    assert!(H::text(&a).contains("Done 4 of 4"));
    assert_eq!(a["content"][1]["type"], "image");
    assert_eq!(h.last_action(&m), json!({ "type": "wait", "ms": 10 }));
}

#[test]
fn ui_tree_uses_screenshot_pixels() {
    let mut h = H::new(false);
    let m = h.machine();
    let t = h.ok("ui_tree", json!({ "machine": m }));
    assert!(t.contains("n3 button \"Close\" [960, 100, 40, 27] centre (980, 113) (invoke)"), "{t}");
    assert!(t.contains("n4 button \"Off screen\" (not visible)"), "{t}");
    h.ok("ui_invoke", json!({ "machine": m, "id": "n3", "action": "invoke" }));
    assert!(h.err("ui_invoke", json!({ "machine": m, "id": "zz", "action": "invoke" })).contains("No such element"));
    assert!(h.err("ui_invoke", json!({ "machine": m, "id": "n2", "action": "setValue" })).contains("needs `value`"));
}

#[test]
fn misuse_gets_plain_errors() {
    let mut h = H::new(false);
    assert!(h.err("nope", json!({})).contains("no tool named nope"));
    assert!(h.err("screenshot", json!({})).contains("`machine` is required"));
    assert!(h.err("screenshot", json!({ "machine": "ghost" })).contains("no machine named ghost"));
    let m = h.machine();
    assert!(h.err("click", json!({ "machine": m, "x": "a", "y": 1 })).contains("`x` must be a number"));
    assert!(h.err("click", json!({ "machine": m, "x": 5000, "y": 1 })).contains("outside screenshot"));
    assert!(h.err("click", json!({ "machine": m, "x": 1, "y": 1, "screenshot": 999 })).contains("isn't known"));
    assert!(h.err("click", json!({ "machine": m, "x": 1, "y": 1, "button": "side" })).contains("left, right or middle"));
    assert!(h.err("scroll", json!({ "machine": m, "x": 1, "y": 1 })).contains("dx"));
    assert!(h.err("type", json!({ "machine": m, "text": "x".repeat(6000) })).contains("at most"));
    assert!(h.err("act", json!({ "machine": m, "actions": [{ "type": "click", "x": 1, "y": 1 }, { "type": "fly" }] })).contains("Action 2: Unknown action type fly"));
    assert!(h.err("act", json!({ "machine": m, "actions": [] })).contains("1 to 50"));
    assert!(h.err("screenshot", json!({ "machine": m, "zoom": [1, 2] })).contains("[x, y, width, height]"));
    assert!(h.err("screenshot", json!({ "machine": m, "maxWidth": 9000 })).contains("64 to 2576"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "C:\\Windows\\win.ini" })).contains("C:\\Users\\agent"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\..\\admin\\x.txt" })).contains("no '..'"));
    assert!(h.err("offer_file", json!({ "machine": m, "path": "C:\\Users\\agent\\x.txt", "note": "n" })).contains("Outbox"));
    assert!(h.err("send_file", json!({ "machine": m, "hostPath": "relative.txt" })).contains("full path"));
    assert!(h.err("create_disposable", json!({ "template": "win11-agent", "name": "bad name!" })).contains("letters"));
    assert!(h.err("run", json!({ "machine": m, "command": "x", "args": ["a"] })).contains("shell 'none'"));
    // Arguments that aren't an object.
    let r = h.rpc("tools/call", json!({ "name": "list_machines", "arguments": [1] }));
    assert_eq!(r["result"]["isError"], true);
}

#[test]
fn guest_and_broker_states() {
    let mut h = H::new(false);
    let m = h.machine();
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().elevated_foreground = true);
    assert_eq!(h.err("click", json!({ "machine": m, "x": 1, "y": 1 })), "An administrator window is in front; ask the person with request_human.");
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.elevated_foreground = false; x.secure_desktop = true; });
    assert!(h.err("screenshot", json!({ "machine": m })).contains("secure screen"));
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.secure_desktop = false; x.paused = true; });
    let paused = h.err("click", json!({ "machine": m, "x": 1, "y": 1 }));
    assert!(paused.contains("took control") && paused.contains("fresh screenshot"), "{paused}");
    assert!(h.ok("list_machines", json!({})).contains("paused: the person took control"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().paused = false);
    // Someone else's machine.
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().taken_by = Some("other".into()));
    assert!(h.err("take_machine", json!({ "machine": "work-pc" })).contains("another agent"));
    // Destroyed machine.
    h.ok("destroy", json!({ "machine": m }));
    assert!(h.err("screenshot", json!({ "machine": m })).contains("no machine named t1"));
    // Kill switch: refused from then on without asking GpuVM again.
    h.fake.with(|s| s.killed = true);
    assert!(h.err("list_machines", json!({})).contains("stopped this agent connection"));
    let calls = h.fake.with(|s| s.calls.len());
    assert!(h.err("list_templates", json!({})).contains("stopped"));
    assert_eq!(h.fake.with(|s| s.calls.len()), calls);
}

#[test]
fn commands_files_and_offers() {
    let mut h = H::new(false);
    let m = h.machine();
    let r = h.ok("run", json!({ "machine": m, "command": "Get-Date" }));
    assert!(r.starts_with("Exit code 0") && r.contains("powershell.exe -NoProfile -NonInteractive -Command Get-Date"), "{r}");
    let huge = h.ok("run", json!({ "machine": m, "command": "huge", "shell": "none" }));
    assert!(huge.chars().count() < super::tools::MAX_TEXT + 200 && huge.contains("characters cut") && huge.contains("cut the output at 1 MiB"));
    let slow = h.ok("run", json!({ "machine": m, "command": "sleep", "shell": "none", "timeoutSeconds": 5 }));
    assert!(slow.starts_with("Timed out after 5 s") && slow.contains("partial"), "{slow}");
    let blob = h.ok("run", json!({ "machine": m, "command": "blob", "shell": "none" }));
    assert!(blob.starts_with("Exit code 3") && blob.contains("--- stdout ---\nout-in-blob") && blob.contains("--- stderr ---\nerr-in-blob"), "{blob}");
    h.ok("write_file", json!({ "machine": m, "path": "C:/Users/agent/Desktop/Outbox/report.md", "content": "# Report\nok" }));
    assert!(h.ok("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\Desktop\\Outbox\\report.md" })).ends_with("# Report\nok"));
    h.ok("write_file", json!({ "machine": m, "path": "C:\\Users\\agent\\b.bin", "content": "AAEC/w==", "encoding": "base64" }));
    assert!(h.ok("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\b.bin" })).contains("binary file (4 bytes)"));
    h.ok("write_file", json!({ "machine": m, "path": "C:\\Users\\agent\\u16.txt", "content": "//5oAGkA", "encoding": "base64" }));
    assert!(h.ok("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\u16.txt" })).ends_with("hi"));
    assert!(h.ok("send_file", json!({ "machine": m, "hostPath": "C:\\Builds\\GpuVM-setup.exe" })).contains("Received\\GpuVM-setup.exe"));
    let o = h.ok("offer_file", json!({ "machine": m, "path": "C:\\Users\\agent\\Desktop\\Outbox\\report.md", "note": "Test report" }));
    assert!(o.contains("offer o"), "{o}");
    let id = h.fake.with(|s| s.offers.keys().next().unwrap().clone());
    assert!(h.ok("offer_status", json!({ "machine": m, "offerId": id })).contains("still waiting"));
    h.fake.with(|s| s.offers.get_mut(&id).unwrap().1 = "approved".into());
    assert!(h.ok("offer_status", json!({ "machine": m, "offerId": id })).contains("approved"));
    // Restore points: not on disposable machines (turning them off deletes them), only on taken normal ones.
    assert!(h.err("restore_point_create", json!({ "machine": m })).contains("is disposable"));
    assert!(h.ok("open_viewer", json!({ "machine": m })).contains("viewer"));
    assert!(h.err("destroy", json!({ "machine": "work-pc" })).contains("Take work-pc first"));
    assert!(h.err("restore_point_create", json!({ "machine": "work-pc" })).contains("Take work-pc first"));
    // A normal machine that is off: take starts it.
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().off = true);
    assert!(h.ok("list_machines", json!({})).contains("work-pc: off"));
    assert!(h.ok("take_machine", json!({ "machine": "work-pc" })).contains("ready (screen 1920x1080)"));
    h.ok("screenshot", json!({ "machine": "work-pc" }));
    let p = h.ok("restore_point_create", json!({ "machine": "work-pc", "label": "clean" }));
    assert!(p.contains("clean"));
    assert!(h.ok("restore_point_revert", json!({ "machine": "work-pc", "point": "clean" })).contains("back at clean"));
    assert!(h.err("click", json!({ "machine": "work-pc", "x": 1, "y": 1 })).contains("Take a screenshot"), "revert forgets old screenshots");
    assert!(h.err("restore_point_revert", json!({ "machine": "work-pc", "point": "nope" })).contains("no restore point"));
    assert!(h.err("destroy", json!({ "machine": "work-pc" })).contains("isn't disposable"));
    h.ok("release_machine", json!({ "machine": "work-pc" }));
    assert!(!h.ok("list_machines", json!({})).contains("work-pc: ready, taken"));
}

#[test]
fn budgets_and_human_requests() {
    let mut h = H::new(false);
    h.fake.with(|s| s.max_steps = 3);
    let m = h.machine(); // the capture is 1 step (the screen size came with take)
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
    assert!(h.err("key", json!({ "machine": m, "keys": "enter" })).contains("budget"));

    let mut h = H::new(false);
    let m = h.machine();
    assert!(h.ok("request_human", json!({ "machine": m, "message": "Please accept the UAC prompt." })).contains("paused"));
    assert!(h.err("click", json!({ "machine": m, "x": 1, "y": 1 })).contains("took control"));
    // Waiting: handed back during the wait.
    let fake = h.fake.clone();
    let name = m.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        fake.with(|s| s.machines.iter_mut().find(|x| x.name == name).unwrap().paused = false);
    });
    let r = h.ok("request_human", json!({ "machine": m, "message": "Again", "waitSeconds": 10 }));
    assert!(r.contains("handed t1 back"), "{r}");
    // Cancelled while waiting: returns at once.
    let started = Instant::now();
    let id = h.send("tools/call", json!({ "name": "request_human", "arguments": { "machine": m, "message": "x", "waitSeconds": 600 } }));
    std::thread::sleep(Duration::from_millis(30));
    h.notify("notifications/cancelled", json!({ "requestId": id }));
    let r = h.wait_for(id);
    assert!(H::text(&r["result"]).contains("hasn't handed"));
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn approvals_modern_multi_round_trip() {
    let mut h = H::with(true, json!({ "elicitation": { "form": {} } }));
    h.fake.with(|s| s.elicitation = true);
    let m = h.machine();
    let args = json!({ "machine": m, "command": "whoami" });
    let first = h.rpc("tools/call", json!({ "name": "run", "arguments": args }))["result"].clone();
    assert_eq!(first["resultType"], "input_required");
    assert!(first["inputRequests"]["confirm"]["params"]["message"].as_str().unwrap().contains("whoami"));
    let state = first["requestState"].as_str().unwrap().to_string();
    // Tampered or mismatched state is refused.
    let bad = h.rpc("tools/call", json!({ "name": "run", "arguments": { "machine": m, "command": "del *" }, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept" } } }))["result"].clone();
    assert_eq!(bad["isError"], true);
    let first = h.rpc("tools/call", json!({ "name": "run", "arguments": args }))["result"].clone();
    let state = first["requestState"].as_str().unwrap().to_string();
    let ok = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept", "content": {} } } }))["result"].clone();
    assert!(H::text(&ok).starts_with("Exit code 0"), "{ok}");
    assert_eq!(ok["resultType"], "complete");
    // Single use.
    let again = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept" } } }))["result"].clone();
    assert_eq!(again["isError"], true);
    // Declined.
    let first = h.rpc("tools/call", json!({ "name": "run", "arguments": args }))["result"].clone();
    let declined = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": first["requestState"],
        "inputResponses": { "confirm": { "action": "decline" } } }))["result"].clone();
    assert!(H::text(&declined).contains("declined"));
    // Tools that aren't low-risk confirmations run without asking.
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
}

#[test]
fn approvals_off_by_default_and_legacy_elicitation() {
    // Off by default: no question even if the client could ask.
    let mut h = H::with(true, json!({ "elicitation": {} }));
    let m = h.machine();
    assert!(h.ok("run", json!({ "machine": m, "command": "whoami" })).starts_with("Exit code 0"));

    // Legacy clients get an elicitation/create request.
    let mut h = H::with(false, json!({ "elicitation": {} }));
    h.fake.with(|s| s.elicitation = true);
    // The setting is read when the connection registers (at initialize): register again.
    h.server.ctx.disconnect();
    let m = h.machine();
    for (answer, expect_ok) in [("accept", true), ("decline", false)] {
        let id = h.send("tools/call", json!({ "name": "run", "arguments": { "machine": m, "command": "whoami" } }));
        let end = Instant::now() + Duration::from_secs(10);
        let ask = loop {
            if let Some(a) = h.lines().into_iter().rev().find(|v| v["method"] == "elicitation/create") {
                if h.lines().iter().filter(|v| v["method"] == "elicitation/create").count() == if expect_ok { 1 } else { 2 } {
                    break a;
                }
            }
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(2));
        };
        assert!(ask["params"]["message"].as_str().unwrap().contains("whoami"));
        h.server.handle_line(&json!({ "jsonrpc": "2.0", "id": ask["id"], "result": { "action": answer } }).to_string());
        let r = h.wait_for(id)["result"].clone();
        assert_eq!(r["isError"] != true, expect_ok, "{r}");
    }
}
