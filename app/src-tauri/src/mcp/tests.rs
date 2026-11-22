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
    assert_eq!(tools.len(), 29);
    let mut names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    names.sort();
    names.dedup();
    assert_eq!(names.len(), 29);
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
    assert!(r["result"].get("resultType").is_none() && r["result"].get("ttlMs").is_none());
    assert_eq!(h.rpc("ping", json!({}))["result"], json!({}));
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
    h.server.handle_line(&json!({ "jsonrpc": "2.0", "id": 99, "method": "tools/list",
        "params": { "_meta": { "io.modelcontextprotocol/protocolVersion": "1900-01-01" } } }).to_string());
    let e = h.wait_for(99);
    assert_eq!(e["error"]["code"], -32022);
    assert_eq!(e["error"]["data"]["requested"], "1900-01-01");
    let fresh = H::new(true);
    fresh.server.handle_line(r#"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#);
    assert_eq!(fresh.wait_for(5)["error"]["code"], -32600);
    fresh.server.handle_line("not json");
    assert_eq!(fresh.lines().last().unwrap()["error"]["code"], -32700);
    fresh.server.handle_line(r#"{"jsonrpc":"2.0","id":6,"method":"nope","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#);
    assert_eq!(fresh.wait_for(6)["error"]["code"], -32601);
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

    let small = h.tool("screenshot", json!({ "machine": m, "maxWidth": 640, "maxHeight": 640 }));
    assert!(H::text(&small).contains("640x360"));
    h.ok("click", json!({ "machine": m, "x": 100, "y": 50 }));
    assert_eq!(h.last_action(&m)["x"], 301);
    assert_eq!(h.last_action(&m)["y"], 151);
    h.ok("click", json!({ "machine": m, "x": 640, "y": 360, "screenshot": 2 }));
    assert_eq!(h.last_action(&m)["x"], 960);

    let z = h.tool("screenshot", json!({ "machine": m, "zoom": [100, 100, 200, 100] }));
    let zt = H::text(&z);
    assert!(zt.contains("[300, 300, 600, 300]") && zt.contains("600x300"), "{zt}");
    h.ok("click", json!({ "machine": m, "x": 100, "y": 50 }));
    assert_eq!(h.last_action(&m)["x"], 301);

    let big = h.tool("screenshot", json!({ "machine": m, "maxWidth": 2576, "maxHeight": 2576 }));
    assert!(H::text(&big).contains("1920x1080"));

    h.ok("drag", json!({ "machine": m, "x": 10, "y": 10, "toX": 20, "toY": 20, "screenshot": 2 }));
    assert_eq!(h.last_action(&m), json!({ "type": "drag", "x": 15, "y": 15, "toX": 30, "toY": 30 }));
    let a = h.tool("act", json!({ "machine": m, "screenshot": 2, "screenshotAfter": true, "actions": [
        { "type": "click", "x": 2, "y": 2 }, { "type": "type", "text": "hello" }, { "type": "key", "keys": "Ctrl+S" }, { "type": "wait", "ms": 10 } ] }));
    assert!(H::text(&a).contains("Done 4 of 4"));
    assert_eq!(a["content"][1]["type"], "image");
    assert_eq!(h.last_action(&m), json!({ "type": "wait", "ms": 10 }));
}

#[test]
fn drag_along_paths_and_strokes() {
    let mut h = H::new(true);
    let m = h.machine();
    h.ok("drag", json!({ "machine": m, "path": [[0, 0], [640, 360], [1279, 719]], "button": "right" }));
    let a = h.last_action(&m);
    assert_eq!(a["strokes"], json!([[0, 0, 960, 540, 1919, 1079]]));
    assert_eq!(a["button"], "right");
    assert!((1460..=1480).contains(&a["ms"].as_u64().unwrap()), "{a}");
    h.ok("drag", json!({ "machine": m, "strokes": [[[10, 10], [20, 10]], [[30, 30]]], "durationMs": 800 }));
    assert_eq!(h.last_action(&m), json!({ "type": "drag", "strokes": [[15, 15, 30, 15], [45, 45]], "ms": 800 }));
    h.ok("drag", json!({ "machine": m, "path": [[0, 0], [10, 0]], "durationMs": 60000 }));
    assert!(h.fake.with(|s| s.timeouts.last().copied().flatten()).unwrap() >= 70);
    h.ok("act", json!({ "machine": m, "actions": [{ "type": "drag", "path": [[1, 1], [2, 2]] }, { "type": "drag", "x": 1, "y": 1, "toX": 5, "toY": 5, "button": "middle" }] }));
    assert_eq!(h.last_action(&m)["button"], "middle");

    for (args, says) in [
        (json!({ "path": [[0, 0]], "strokes": [[[0, 0]]] }), "not both"),
        (json!({ "path": [[1280, 0]] }), "outside screenshot"),
        (json!({ "path": [[0, 0]], "button": "back" }), "`button`"),
        (json!({ "path": [] }), "list of [x, y]"),
        (json!({ "strokes": [[[0, 0]], [["a", 0]]] }), "Stroke 2"),
        (json!({ "strokes": 5 }), "list of paths"),
        (json!({ "path": [[0, 0]], "durationMs": 60001 }), "durationMs"),
        (json!({ "x": 1, "y": 1 }), "toX"),
    ] {
        let mut args = args;
        args["machine"] = json!(m);
        let e = h.err("drag", args.clone());
        assert!(e.contains(says), "{args}: {e}");
    }
    let half: Vec<_> = (0..2001).map(|i| json!([i % 1280, 5])).collect();
    let e = h.err("act", json!({ "machine": m, "actions": [{ "type": "drag", "path": half }, { "type": "drag", "path": half }] }));
    assert!(e.contains("At most 4000"), "{e}");
}

#[test]
fn ui_tree_uses_screenshot_pixels() {
    let mut h = H::new(false);
    let m = h.machine();
    let t = h.ok("ui_tree", json!({ "machine": m }));
    assert!(t.contains("3 button \"Close\" [960, 100, 40, 27] centre (980, 113) (invoke)"), "{t}");
    assert!(t.contains("4 button \"Off screen\" (not visible)"), "{t}");
    h.ok("ui_invoke", json!({ "machine": m, "id": 3, "action": "invoke" }));
    h.ok("ui_invoke", json!({ "machine": m, "id": "2", "action": "setValue", "value": "hi" }));
    assert!(h.err("ui_invoke", json!({ "machine": m, "id": 99, "action": "invoke" })).contains("No such element"));
    assert!(h.err("ui_invoke", json!({ "machine": m, "id": 2, "action": "setValue" })).contains("needs `value`"));
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
    assert!(h.err("read_file", json!({ "machine": m, "path": "C:\\Windows\\win.ini" })).contains("home folder"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\..\\admin\\x.txt" })).contains("no '..'"));
    assert!(h.err("offer_file", json!({ "machine": m, "path": "C:\\Users\\agent\\x.txt", "note": "n" })).contains("Outbox"));
    assert!(h.err("send_file", json!({ "machine": m, "hostPath": "relative.txt" })).contains("full path"));
    assert!(h.err("create_disposable", json!({ "template": "win11-agent", "name": "bad name!" })).contains("letters"));
    assert!(h.err("run", json!({ "machine": m, "command": "x", "args": ["a"] })).contains("shell 'none'"));
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
    assert!(h.err("click", json!({ "machine": m, "x": 1, "y": 1 })).contains("took control"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().paused = false);
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().taken_by = Some("other".into()));
    assert!(h.err("take_machine", json!({ "machine": "work-pc" })).contains("another agent"));
    h.ok("destroy", json!({ "machine": m }));
    assert!(h.err("screenshot", json!({ "machine": m })).contains("no machine named t1"));
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
    assert!(h.ok("read_file", json!({ "machine": m, "path": "Desktop\\Outbox\\report.md" })).ends_with("# Report\nok"));
    assert!(h.ok("offer_file", json!({ "machine": m, "path": "Desktop/Outbox/report.md", "note": "relative" })).contains("offer o"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "\\\\server\\share\\x" })).contains("home folder"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "D:\\x.txt" })).contains("home folder"));
    assert!(h.err("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\x.txt:stream" })).contains("home folder"));
    h.ok("write_file", json!({ "machine": m, "path": "C:\\Users\\agent\\b.bin", "content": "AAEC/w==", "encoding": "base64" }));
    assert!(h.ok("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\b.bin" })).contains("binary file (4 bytes)"));
    h.ok("write_file", json!({ "machine": m, "path": "C:\\Users\\agent\\u16.txt", "content": "//5oAGkA", "encoding": "base64" }));
    assert!(h.ok("read_file", json!({ "machine": m, "path": "C:\\Users\\agent\\u16.txt" })).ends_with("hi"));
    assert!(h.err("send_file", json!({ "machine": m, "hostPath": "C:\\Builds\\missing.exe" })).contains("can't be read"));
    let host = std::env::temp_dir().join(format!("gpuvm-mcp-test-{}.bin", std::process::id()));
    std::fs::write(&host, vec![7u8; 1000]).unwrap();
    let host_path = host.to_string_lossy().to_string();
    h.fake.with(|s| s.approval_answer = "denied".into());
    let no = h.err("send_file", json!({ "machine": m, "hostPath": host_path, "reason": "test" }));
    assert!(no.contains("said no") && no.contains("Copy gpuvm-mcp-test"), "{no}");
    assert!(h.fake.with(|s| !s.calls.iter().any(|c| c == "file.send")), "nothing is sent without the approval");
    h.fake.with(|s| s.approval_answer = "allowed".into());
    assert!(h.ok("send_file", json!({ "machine": m, "hostPath": host_path })).contains("1000 bytes, checked"));
    let asked = h.fake.with(|s| s.last_approval.clone());
    assert_eq!((asked["kind"].as_str(), asked["path"].as_str()), (Some("send"), Some(host_path.as_str())));
    assert_eq!(asked["timeoutSec"], 600);
    assert!(asked.get("sizeBytes").is_none() && asked.get("files").is_none() && asked.get("title").is_none(), "{asked}");
    let dir = std::env::temp_dir().join(format!("gpuvm-mcp-dir-{}", std::process::id()));
    std::fs::create_dir_all(dir.join("sub")).unwrap();
    std::fs::write(dir.join("a.txt"), b"12345").unwrap();
    std::fs::write(dir.join("sub").join("b.txt"), b"678").unwrap();
    h.fake.with(|s| s.approval_answer = "denied".into());
    let no = h.err("send_file", json!({ "machine": m, "hostPath": dir.to_string_lossy() }));
    assert!(no.contains("2 files, 8 bytes"), "{no}");
    h.fake.with(|s| s.approval_answer = "allowed".into());
    h.ok("send_file", json!({ "machine": m, "hostPath": dir.to_string_lossy() }));
    let _ = std::fs::remove_dir_all(&dir);
    h.fake.with(|s| s.send_changed = true);
    assert!(h.err("send_file", json!({ "machine": m, "hostPath": host_path })).contains("changed after the person allowed it"));
    h.fake.with(|s| s.send_changed = false);
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().drop_sends = true);
    std::fs::write(host.with_extension("lost"), b"x").unwrap();
    assert!(h.err("send_file", json!({ "machine": m, "hostPath": host.with_extension("lost").to_string_lossy() })).contains("wasn't delivered"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().drop_sends = false);
    let _ = std::fs::remove_file(&host);
    let _ = std::fs::remove_file(host.with_extension("lost"));
    let o = h.ok("offer_file", json!({ "machine": m, "path": "C:\\Users\\agent\\Desktop\\Outbox\\report.md", "note": "Test report" }));
    assert!(o.contains("offer o"), "{o}");
    let id = h.fake.with(|s| s.offers.keys().next().unwrap().clone());
    assert!(h.ok("offer_status", json!({ "machine": m, "offerId": id })).contains("still waiting"));
    let refused = h.err("destroy", json!({ "machine": m }));
    assert!(refused.contains("still waiting") && refused.contains("force"), "{refused}");
    h.fake.with(|s| s.offers.get_mut(&id).unwrap().1 = "accepted".into());
    let acc = h.ok("offer_status", json!({ "machine": m, "offerId": id }));
    assert!(acc.contains("accepted") && acc.contains("(report.md)") && acc.contains("Downloads\\GpuVM") && !acc.contains("C:\\Users\\person"), "{acc}");
    assert!(h.err("offer_file", json!({ "machine": m, "path": "C:\\Users\\agent\\Desktop\\Outbox\\sub\\x.txt", "note": "n" })).contains("directly inside"));
    assert!(h.err("restore_point_create", json!({ "machine": m })).contains("is disposable"));
    assert!(h.ok("open_viewer", json!({ "machine": m, "waitSeconds": 0 })).contains(m.as_str()));
    assert!(h.err("open_viewer", json!({ "machine": "work-pc" })).contains("Take work-pc first"));
    h.ok("type", json!({ "machine": m, "text": "secret-password-123" }));
    h.ok("run", json!({ "machine": m, "command": "echo top-secret", "stdin": "more-secret" }));
    let notes = h.fake.with(|s| s.notes.join("\n"));
    assert!(!notes.contains("secret") && notes.contains("(19 characters)"), "{notes}");
    assert!(h.err("destroy", json!({ "machine": "work-pc" })).contains("Take work-pc first"));
    assert!(h.err("restore_point_create", json!({ "machine": "work-pc" })).contains("Take work-pc first"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().off = true);
    assert!(h.ok("list_machines", json!({})).contains("work-pc: off"));
    assert!(h.ok("take_machine", json!({ "machine": "work-pc" })).contains("ready (screen 1920x1080)"));
    h.ok("screenshot", json!({ "machine": "work-pc" }));
    let p = h.ok("restore_point_create", json!({ "machine": "work-pc", "label": "clean" }));
    assert!(p.contains("clean"));
    assert!(h.ok("restore_point_revert", json!({ "machine": "work-pc", "point": "clean" })).contains("back at clean"));
    h.fake.with(|s| s.approval_answer = "denied".into());
    assert!(h.err("restore_point_revert", json!({ "machine": "work-pc", "point": "clean" })).contains("said no"));
    assert!(h.err("request_approval", json!({ "machine": "work-pc", "kind": "network", "title": "Open the network", "reason": "Download a tool" })).contains("said no"));
    h.fake.with(|s| s.approval_answer = "allowed".into());
    assert!(h.ok("request_approval", json!({ "machine": "work-pc", "kind": "admin", "title": "Install as admin", "reason": "Test the installer" })).contains("allowed"));
    assert!(h.err("request_approval", json!({ "machine": "work-pc", "kind": "delete", "title": "x", "reason": "y" })).contains("admin, network or other"));
    h.fake.with(|s| s.approval_answer = "pending".into());
    let late = h.err("request_approval", json!({ "machine": "work-pc", "kind": "other", "title": "x", "reason": "y", "waitSeconds": 0 }));
    assert!(late.contains("was withdrawn"), "{late}");
    assert!(h.fake.with(|s| s.approvals.values().any(|(_, st)| st == "withdrawn")));
    h.fake.with(|s| s.approval_answer = "allowed".into());
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
    let m = h.machine();
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
    assert!(h.err("key", json!({ "machine": m, "keys": "enter" })).contains("budget"));

    let mut h = H::new(false);
    let m = h.machine();
    assert!(h.ok("request_human", json!({ "machine": m, "message": "Please accept the UAC prompt." })).contains("paused"));
    let waiting = h.err("click", json!({ "machine": m, "x": 1, "y": 1 }));
    assert!(waiting.contains("waiting for the person to do what you asked") && !waiting.contains("took control"), "{waiting}");
    let fake = h.fake.clone();
    let name = m.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(50));
        fake.with(|s| s.machines.iter_mut().find(|x| x.name == name).unwrap().paused = false);
    });
    let r = h.ok("request_human", json!({ "machine": m, "message": "Again", "waitSeconds": 10 }));
    assert!(r.contains("handed t1 back"), "{r}");
    let started = Instant::now();
    let id = h.send("tools/call", json!({ "name": "request_human", "arguments": { "machine": m, "message": "x", "waitSeconds": 600 } }));
    std::thread::sleep(Duration::from_millis(30));
    h.notify("notifications/cancelled", json!({ "requestId": id }));
    let r = h.wait_for(id);
    assert!(H::text(&r["result"]).contains("hasn't handed") && H::text(&r["result"]).contains("cancel_request"));
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(h.err("write_file", json!({ "machine": m, "path": "Desktop\\Outbox\\r.md", "content": "x" })).contains("cancel_request"));
    assert!(h.ok("cancel_request", json!({ "machine": m })).contains("yours again"));
    h.ok("write_file", json!({ "machine": m, "path": "Desktop\\Outbox\\r.md", "content": "report" }));
    assert!(h.err("cancel_request", json!({ "machine": m })).contains("no request to the person pending"));
    h.ok("request_human", json!({ "machine": m, "message": "z" }));
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.human_request = None; x.paused = false; });
    let answered = h.err("cancel_request", json!({ "machine": m }));
    assert!(answered.contains("already answered") && !answered.contains("took control"), "{answered}");
    h.ok("request_human", json!({ "machine": m, "message": "y" }));
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.human_request = None; x.paused_by = "control".into(); });
    assert!(h.err("cancel_request", json!({ "machine": m })).contains("took control"));
    assert!(h.err("screenshot", json!({ "machine": m })).contains("took control"));
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
    let bad = h.rpc("tools/call", json!({ "name": "run", "arguments": { "machine": m, "command": "del *" }, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept" } } }))["result"].clone();
    assert_eq!(bad["isError"], true);
    let first = h.rpc("tools/call", json!({ "name": "run", "arguments": args }))["result"].clone();
    let state = first["requestState"].as_str().unwrap().to_string();
    let ok = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept", "content": {} } } }))["result"].clone();
    assert!(H::text(&ok).starts_with("Exit code 0"), "{ok}");
    assert_eq!(ok["resultType"], "complete");
    let again = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": state,
        "inputResponses": { "confirm": { "action": "accept" } } }))["result"].clone();
    assert_eq!(again["isError"], true);
    let first = h.rpc("tools/call", json!({ "name": "run", "arguments": args }))["result"].clone();
    let declined = h.rpc("tools/call", json!({ "name": "run", "arguments": args, "requestState": first["requestState"],
        "inputResponses": { "confirm": { "action": "decline" } } }))["result"].clone();
    assert!(H::text(&declined).contains("declined"));
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
}

#[test]
fn approvals_off_by_default_and_legacy_elicitation() {
    let mut h = H::with(true, json!({ "elicitation": {} }));
    let m = h.machine();
    assert!(h.ok("run", json!({ "machine": m, "command": "whoami" })).starts_with("Exit code 0"));

    let mut h = H::with(false, json!({ "elicitation": {} }));
    h.fake.with(|s| s.elicitation = true);
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

#[test]
fn approvals_fail_closed_when_the_client_cannot_ask() {
    let mut h = H::with(true, json!({}));
    h.fake.with(|s| s.elicitation = true);
    let m = h.machine();
    let e = h.err("run", json!({ "machine": m, "command": "whoami" }));
    assert!(e.contains("can't show the question"), "{e}");
    assert!(h.fake.with(|s| s.notes.iter().all(|n| !n.starts_with("run"))), "the command never reached the machine");
    let mut h = H::with(false, json!({}));
    h.fake.with(|s| s.elicitation = true);
    h.server.ctx.disconnect();
    let m = h.machine();
    assert!(h.err("write_file", json!({ "machine": m, "path": "Desktop\\x.txt", "content": "x" })).contains("can't show the question"));
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
}


#[test]
fn review_three_fixes() {
    let mut h = H::new(false);
    let m = h.machine();
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().screen_changed_at = Some(1_000));
    let stale = h.err("click", json!({ "machine": m, "x": 1, "y": 1 }));
    assert!(stale.contains("changed size after screenshot"), "{stale}");
    h.ok("screenshot", json!({ "machine": m }));
    h.ok("click", json!({ "machine": m, "x": 1, "y": 1 }));
    h.ok("act", json!({ "machine": m, "actions": (0..12).map(|_| json!({ "type": "wait", "ms": 5000 })).collect::<Vec<_>>() }));
    let t = h.fake.with(|s| *s.timeouts.last().unwrap());
    assert!(t.unwrap() >= 12 * 6, "{t:?}");
    h.ok("key", json!({ "machine": m, "keys": "enter" }));
    assert_eq!(h.fake.with(|s| *s.timeouts.last().unwrap()), Some(30));
    assert!(h.err("run", json!({ "machine": m, "command": "x", "timeoutSeconds": 600 })).contains("1 to 580"));
    h.ok("run", json!({ "machine": m, "command": "x", "timeoutSeconds": 580 }));
    assert_eq!(h.fake.with(|s| *s.timeouts.last().unwrap()), Some(600));
    let host = std::env::temp_dir().join(format!("gpuvm-mcp-twice-{}.txt", std::process::id()));
    std::fs::write(&host, b"twice").unwrap();
    let hp = host.to_string_lossy().to_string();
    h.ok("send_file", json!({ "machine": m, "hostPath": hp }));
    let second = h.ok("send_file", json!({ "machine": m, "hostPath": hp }));
    assert!(second.contains(&format!("gpuvm-mcp-twice-{} (2).txt", std::process::id())) && second.contains("5 bytes, checked"), "{second}");
    let _ = std::fs::remove_file(&host);
    let mut h2 = H::new(false);
    h2.ok("take_machine", json!({ "machine": "work-pc" }));
    h2.fake.with(|s| s.answer_late = true);
    assert!(h2.ok("request_approval", json!({ "machine": "work-pc", "kind": "other", "title": "x", "reason": "y", "waitSeconds": 0 })).contains("allowed"));
}

#[test]
fn closing_stdin_ends_waits_at_once() {
    let mut h = H::new(false);
    let m = h.machine();
    let started = Instant::now();
    h.send("tools/call", json!({ "name": "request_human", "arguments": { "machine": m, "message": "x", "waitSeconds": 1800 } }));
    std::thread::sleep(Duration::from_millis(50));
    h.server.finish();
    assert!(started.elapsed() < Duration::from_secs(5), "finish waited {:?}", started.elapsed());
    assert!(h.fake.with(|s| s.connections.is_empty()), "the session was closed");
}

#[test]
fn ready_when_the_signed_in_event_came_after_a_stale_snapshot() {
    let mut h = H::new(false);
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().stale_snapshot = true);
    let started = Instant::now();
    let t = h.ok("take_machine", json!({ "machine": "work-pc", "waitSeconds": 20 }));
    assert!(t.contains("its agent is ready") && started.elapsed() < Duration::from_secs(5), "{t}");
    assert!(H::text(&h.tool("screenshot", json!({ "machine": "work-pc" }))).contains("desktop 1920x1080"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().stale_snapshot = false);
}

#[test]
fn a_copy_with_no_display_fails_at_once_and_is_deleted() {
    let mut h = H::new(false);
    h.fake.with(|s| s.next_no_display = true);
    let started = Instant::now();
    let e = h.err("create_disposable", json!({ "template": "win11-agent", "name": "nd1" }));
    assert!(e.contains("nd1 can't be used: The agent is signed in but has seen no display") && e.contains("deleted again"), "{e}");
    assert!(started.elapsed() < Duration::from_secs(5), "no 600 s wait");
    assert!(h.fake.with(|s| !s.machines.iter().any(|m| m.name == "nd1")), "the copy was deleted");
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == "work-pc").unwrap().no_display = true);
    assert!(h.err("take_machine", json!({ "machine": "work-pc" })).contains("can't be used"));
}

#[test]
fn control_changes_are_said_once_and_wait_for_person_waits() {
    let mut h = H::new(false);
    let m = h.machine();
    assert!(h.ok("wait_for_person", json!({ "machine": m })).contains("isn't paused"));
    h.ok("screenshot", json!({ "machine": m }));
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.paused = true; x.paused_by = "control".into(); });
    let refused = h.err("screenshot", json!({ "machine": m }));
    assert_eq!(refused.matches("took control").count(), 1, "{refused}");
    assert!(h.ok("wait_for_person", json!({ "machine": m, "waitSeconds": 1 })).contains("still has"));
    h.fake.with(|s| s.machines.iter_mut().find(|x| x.name == m).unwrap().paused = false);
    let back = h.ok("screenshot", json!({ "machine": m }));
    assert!(back.contains("handed") && back.contains("fresh screenshot"), "{back}");
    assert!(!h.ok("screenshot", json!({ "machine": m })).contains("handed"));
}

#[test]
fn screenshots_and_input_do_not_wait_for_a_running_command() {
    let mut h = H::new(false);
    let m = h.machine();
    let run = h.send("tools/call", json!({ "name": "run", "arguments": { "machine": m, "command": "wait", "shell": "none", "args": ["3000"] } }));
    std::thread::sleep(Duration::from_millis(50));
    h.ok("screenshot", json!({ "machine": m }));
    h.ok("key", json!({ "machine": m, "keys": "shift" }));
    assert!(!h.lines().iter().any(|v| v["id"] == run), "the screenshot and the key were answered only after the run");
    let r = h.wait_for(run);
    assert!(H::text(&r["result"]).contains("Exit code 0"), "{r}");

    let t = Instant::now();
    let started = h.ok("run", json!({ "machine": m, "command": "wait", "shell": "none", "args": ["3000"], "background": true }));
    assert!(t.elapsed() < Duration::from_millis(2000) && started.contains("run-1"), "{started}");
    for _ in 0..3 {
        h.ok("screenshot", json!({ "machine": m }));
        h.ok("click", json!({ "machine": m, "x": 10, "y": 10 }));
    }
    assert!(h.ok("run_result", json!({ "machine": m, "runId": "run-1" })).contains("still running"));
    let out = h.ok("run_result", json!({ "machine": m, "runId": "run-1", "waitSeconds": 10 }));
    assert!(out.contains("Exit code 0") && out.contains("wait 3000"), "{out}");
    assert!(h.err("run_result", json!({ "machine": m, "runId": "run-1" })).contains("no background run"));
    assert!(h.err("run_result", json!({ "machine": "work-pc", "runId": "run-1" })).contains("no background run"));
}

#[test]
fn background_runs_are_limited_and_keep_the_pause() {
    let mut h = H::new(false);
    let m = h.machine();
    for i in 1..=4 {
        assert!(h.ok("run", json!({ "machine": m, "command": "wait", "shell": "none", "args": ["800"], "background": true })).contains(&format!("run-{i}")));
    }
    assert!(h.err("run", json!({ "machine": m, "command": "wait", "shell": "none", "args": ["1"], "background": true })).contains("already running"));
    for i in 1..=4 {
        assert!(h.ok("run_result", json!({ "machine": m, "runId": format!("run-{i}"), "waitSeconds": 10 })).contains("Exit code 0"));
    }
    h.fake.with(|s| { let x = s.machines.iter_mut().find(|x| x.name == m).unwrap(); x.paused = true; x.paused_by = "control".into(); });
    let started = h.ok("run", json!({ "machine": m, "command": "whoami", "background": true }));
    let id = started.split_whitespace().find(|w| w.starts_with("run-")).unwrap().to_string();
    assert!(h.err("run_result", json!({ "machine": m, "runId": id, "waitSeconds": 10 })).contains("took control"));
}

#[test]
fn delay_ms_waits_before_the_screenshot_and_after_actions() {
    let mut h = H::new(false);
    let m = h.machine();
    let t = Instant::now();
    h.ok("screenshot", json!({ "machine": m, "delayMs": 300 }));
    assert!(t.elapsed() >= Duration::from_millis(300), "{:?}", t.elapsed());
    let before = h.fake.with(|s| s.machines.iter().find(|x| x.name == m).unwrap().actions.len());
    let r = h.send("tools/call", json!({ "name": "key", "arguments": { "machine": m, "keys": "enter", "delayMs": 1500, "screenshotAfter": true } }));
    let t = Instant::now();
    while h.fake.with(|s| s.machines.iter().find(|x| x.name == m).unwrap().actions.len()) == before {
        assert!(t.elapsed() < Duration::from_millis(1000), "the key waited for the delay");
        std::thread::sleep(Duration::from_millis(2));
    }
    let r = h.wait_for(r);
    assert!(t.elapsed() >= Duration::from_millis(1400), "{:?}", t.elapsed());
    assert!(r["result"]["content"].as_array().unwrap().iter().any(|c| c["type"] == "image"));
    assert!(h.err("screenshot", json!({ "machine": m, "delayMs": 10001 })).contains("0 to 10000"));
    let n = h.fake.with(|s| s.machines.iter().find(|x| x.name == m).unwrap().actions.len());
    assert!(h.err("key", json!({ "machine": m, "keys": "a", "delayMs": -1 })).contains("delayMs"));
    assert_eq!(h.fake.with(|s| s.machines.iter().find(|x| x.name == m).unwrap().actions.len()), n);
}

#[test]
fn input_calls_keep_their_order() {
    let mut h = H::new(false);
    let m = h.machine();
    let ids: Vec<u64> = (0..30).map(|i| h.send("tools/call", json!({ "name": "type", "arguments": { "machine": m, "text": format!("t{i}") } }))).collect();
    for id in ids {
        h.wait_for(id);
    }
    let typed: Vec<String> = h.fake.with(|s| s.machines.iter().find(|x| x.name == m).unwrap().actions.iter()
        .filter_map(|a| a["text"].as_str().map(str::to_string)).collect());
    assert_eq!(typed, (0..30).map(|i| format!("t{i}")).collect::<Vec<_>>());
}

#[test]
fn bytes_that_are_not_utf8_do_not_end_the_session() {
    let h = H::new(false);
    let mut input = b"{\"jsonrpc\":\"2.0\",\"id\":91,\"method\":\"tools/list\",\"params\":{\"x\":\"a\xf1b\"}}\r\n".to_vec();
    input.extend_from_slice(b"{\"jsonrpc\":\"2.0\",\"id\":92,\"method\":\"ping\"}\n");
    h.server.serve(std::io::Cursor::new(input));
    assert!(h.wait_for(91).get("result").is_some());
    assert!(h.wait_for(92).get("result").is_some());
}
