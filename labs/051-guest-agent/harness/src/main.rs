//! Lab 051 host-side harness: a minimal stand-in for the host broker. Listens on HV_GUID_CHILDREN:{service id},
//! does the host side of the handshake, calls every method of docs/agents/protocol.md and measures.
//!
//!   harness serve --secret <file> --vm <guid> --name <vm> --out <dir> [--scenarios a,b,c]
//!   harness guest-system-window <exe>   (inside the guest, as SYSTEM)
//!   harness guest-errorbox              (inside the guest, as the agent user)
mod guestside;

use gpuvm_agent::hv::*;
use gpuvm_agent::proto::*;
use serde_json::{json, Value};
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

fn arg(a: &[String], n: &str) -> Option<String> {
    a.iter().position(|x| x == n).and_then(|i| a.get(i + 1).cloned())
}

fn pct(v: &[f64], p: f64) -> f64 {
    let mut s = v.to_vec();
    s.sort_by(|a, b| a.partial_cmp(b).unwrap());
    if s.is_empty() {
        return f64::NAN;
    }
    s[((p / 100.0) * (s.len() - 1) as f64).round() as usize]
}

fn stats(v: &[f64]) -> Value {
    json!({"n": v.len(), "p50": (pct(v, 50.0) * 100.0).round() / 100.0, "p95": (pct(v, 95.0) * 100.0).round() / 100.0,
           "min": (pct(v, 0.0) * 100.0).round() / 100.0, "max": (pct(v, 100.0) * 100.0).round() / 100.0})
}

struct Out {
    dir: std::path::PathBuf,
    file: std::fs::File,
    t0: Instant,
}

impl Out {
    fn rec(&mut self, kind: &str, v: Value) {
        let line = json!({"t": (self.t0.elapsed().as_secs_f64() * 1000.0).round() / 1000.0, "kind": kind, "data": v});
        let _ = writeln!(self.file, "{line}");
        let s = line.to_string();
        println!("{}", if s.len() > 400 { format!("{}...", &s[..400]) } else { s });
    }
}

// ---------------------------------------------------------------------------------------------------------------

struct Conn {
    s: Arc<HvStream>,
    sealer: Arc<Mutex<Sealer>>,
    opener: Opener,
    next: u64,
    events: Vec<(Instant, Value)>,
    stop: Arc<AtomicBool>,
}

struct Reply {
    ok: bool,
    result: Value,
    code: String,
    message: String,
    blob: Option<Vec<u8>>,
    ms: f64,
}

#[derive(PartialEq, Clone, Copy)]
enum Hs {
    Good,
    WrongChallengeMac,
}

impl Drop for Conn {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.s.shutdown();
    }
}

fn accept(l: &HvListener, secret: &[u8; 32], vm: &str, mode: Hs, wait_ms: i32) -> Result<(Conn, f64), String> {
    let t = Instant::now();
    let (s, peer) = l.accept_timeout(wait_ms).map_err(|e| format!("accept: {e}"))?.ok_or("no connection in time")?;
    let accept_ms = t.elapsed().as_secs_f64() * 1e3;
    let peer = fmt_guid(&peer);
    if !vm.is_empty() && peer != vm {
        return Err(format!("connection from another VM {peer}"));
    }
    s.set_timeouts(10000, 10000);
    let mut r = &s;
    let Frame::Json(b) = read_frame(&mut r).map_err(|e| format!("hello: {e}"))? else { return Err("hello: blob".into()) };
    let h: Value = serde_json::from_slice(&b).map_err(|_| "hello json")?;
    let ng = h["ng"].as_str().unwrap_or("").to_string();
    if h["t"] != "hello" || h["v"] != 1 || !is_nonce(&ng) {
        return Err(format!("bad hello {h}"));
    }
    let nh = hex(&gpuvm_agent::util::random::<16>());
    let mut mac = host_mac(secret, &peer, &ng, &nh);
    if mode == Hs::WrongChallengeMac {
        mac[0] ^= 1;
    }
    write_frame(&mut r, KIND_JSON, &serde_json::to_vec(&json!({"t": "challenge", "nh": nh, "mac": hex(&mac)})).unwrap()).map_err(|e| e.to_string())?;
    if mode == Hs::WrongChallengeMac {
        let t = Instant::now();
        let res = read_frame(&mut r);
        return Err(format!("guest answered a wrong challenge with {:?} after {:.1} ms", res.map(|_| "a frame (BAD)").map_err(|e| e.to_string()), t.elapsed().as_secs_f64() * 1e3));
    }
    let Frame::Json(b) = read_frame(&mut r).map_err(|e| format!("proof: {e}"))? else { return Err("proof: blob".into()) };
    let p: Value = serde_json::from_slice(&b).map_err(|_| "proof json")?;
    let got = p["mac"].as_str().and_then(unhex).unwrap_or_default();
    if p["t"] != "proof" || !ct_eq(&got, &guest_mac(secret, &peer, &ng, &nh)) {
        return Err("the guest's proof is wrong".into());
    }
    let key = session_key(secret, &ng, &nh);
    s.set_timeouts(DEAD_AFTER_MS as u32, 10000);
    let s = Arc::new(s);
    let sealer = Arc::new(Mutex::new(Sealer::new(key)));
    let stop = Arc::new(AtomicBool::new(false));
    {
        let (s, sealer, stop) = (s.clone(), sealer.clone(), stop.clone());
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(1000));
                let f = sealer.lock().unwrap().seal(json!({"t": "ping"}));
                let mut w = &*s;
                if write_frame(&mut w, KIND_JSON, &f).is_err() {
                    break;
                }
            }
        });
    }
    Ok((Conn { s, sealer, opener: Opener::new(key), next: 0, events: vec![], stop }, accept_ms))
}

impl Conn {
    fn send(&self, v: Value, blob: Option<&[u8]>) -> Result<(), String> {
        let mut g = self.sealer.lock().unwrap();
        let mut v = v;
        if let Some(b) = blob {
            v["blob"] = json!(true);
            v["blobLen"] = json!(b.len());
            v["blobSha256"] = json!(hex(&sha256(b)));
        }
        let f = g.seal(v);
        let mut w = &*self.s;
        write_frame(&mut w, KIND_JSON, &f).map_err(|e| e.to_string())?;
        if let Some(b) = blob {
            write_frame(&mut w, KIND_BLOB, b).map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    fn raw(&self, bytes: &[u8]) -> Result<(), String> {
        let _g = self.sealer.lock().unwrap();
        let mut w = &*self.s;
        w.write_all(bytes).map_err(|e| e.to_string())
    }

    /// Reads one frame (events are kept); Err when the connection is closed.
    fn read(&mut self) -> Result<(Value, Option<Vec<u8>>), String> {
        loop {
            let mut r = &*self.s;
            let f = read_frame(&mut r).map_err(|e| e.to_string())?;
            let Frame::Json(b) = f else { return Err("unannounced blob from the guest".into()) };
            let v = self.opener.open(&b).map_err(|e| format!("guest frame rejected: {e}"))?;
            let blob = if v["blob"] == true {
                let mut r = &*self.s;
                match read_frame(&mut r).map_err(|e| e.to_string())? {
                    Frame::Blob(b) => {
                        if v["blobLen"].as_u64() != Some(b.len() as u64) || v["blobSha256"].as_str() != Some(&hex(&sha256(&b))) {
                            return Err("blob doesn't match blobLen/blobSha256".into());
                        }
                        Some(b)
                    }
                    _ => return Err("announced blob missing".into()),
                }
            } else {
                None
            };
            match v["t"].as_str() {
                Some("ping") => continue,
                Some("evt") => {
                    self.events.push((Instant::now(), v));
                    continue;
                }
                _ => return Ok((v, blob)),
            }
        }
    }

    fn call(&mut self, method: &str, params: Value) -> Result<Reply, String> {
        self.call_blob(method, params, None)
    }

    fn call_blob(&mut self, method: &str, params: Value, blob: Option<&[u8]>) -> Result<Reply, String> {
        self.next += 1;
        let id = self.next;
        let t = Instant::now();
        self.send(json!({"t": "req", "id": id, "method": method, "params": params}), blob)?;
        loop {
            let (v, blob) = self.read()?;
            if v["t"] == "res" && v["id"] == id {
                return Ok(Reply {
                    ok: v["ok"] == true,
                    result: v["result"].clone(),
                    code: v["error"]["code"].as_str().unwrap_or("").into(),
                    message: v["error"]["message"].as_str().unwrap_or("").into(),
                    blob,
                    ms: t.elapsed().as_secs_f64() * 1e3,
                });
            }
        }
    }

    /// Waits for an event (already received ones count) matching `f`; returns how long after `since` it arrived.
    fn wait_event(&mut self, since: Instant, timeout: Duration, f: impl Fn(&Value) -> bool) -> Option<(f64, Value)> {
        let found = |c: &Conn| c.events.iter().find(|(t, v)| *t >= since && f(v)).map(|(t, v)| ((*t - since).as_secs_f64() * 1e3, v.clone()));
        if let Some(x) = found(self) {
            return Some(x);
        }
        // no request in flight: read frames (pings arrive every 2 s, so this returns regularly)
        let end = since + timeout;
        while Instant::now() < end {
            self.s.set_timeouts(500, 10000);
            let r = self.read();
            self.s.set_timeouts(DEAD_AFTER_MS as u32, 10000);
            match r {
                Ok(_) => {}
                Err(e) if e.contains("10060") => {}
                Err(_) => return None,
            }
            if let Some(x) = found(self) {
                return Some(x);
            }
        }
        None
    }

    /// Whether the guest closes the connection within `ms` (reads until EOF/error).
    fn closed_within(&mut self, ms: u64) -> (bool, f64, String) {
        let t = Instant::now();
        self.s.set_timeouts(ms as u32, 10000);
        loop {
            match self.read() {
                Ok(_) => {
                    if t.elapsed() > Duration::from_millis(ms) {
                        return (false, t.elapsed().as_secs_f64() * 1e3, "still open".into());
                    }
                }
                Err(e) => {
                    let timed_out = e.contains("10060");
                    return (!timed_out, t.elapsed().as_secs_f64() * 1e3, e);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------------------------------------------

struct Lab {
    l: HvListener,
    secret: [u8; 32],
    vm: String,
    name: String,
    psd: String,
    out: Out,
}

impl Lab {
    fn connect(&mut self, wait_ms: i32) -> Result<Conn, String> {
        let (c, ms) = accept(&self.l, &self.secret, &self.vm, Hs::Good, wait_ms)?;
        self.out.rec("connect", json!({"acceptWaitMs": ms}));
        Ok(c)
    }

    /// Runs a PowerShell command in the guest as its administrator (PowerShell Direct) and returns stdout.
    fn psd(&self, cmd: &str) -> String {
        let o = std::process::Command::new("pwsh").args(["-NoProfile", "-File", &self.psd, "-Name", &self.name, "-Command", cmd]).output();
        match o {
            Ok(o) => format!("{}{}", String::from_utf8_lossy(&o.stdout).trim(), String::from_utf8_lossy(&o.stderr).trim()),
            Err(e) => format!("psd failed: {e}"),
        }
    }
}

fn need(r: Result<Reply, String>) -> Reply {
    match r {
        Ok(r) => r,
        Err(e) => panic!("call failed: {e}"),
    }
}

fn title_of(c: &mut Conn) -> String {
    c.call("screen.state", json!({})).map(|r| r.result["foreground"]["title"].as_str().unwrap_or("").to_string()).unwrap_or_default()
}

fn wait_title(c: &mut Conn, f: impl Fn(&str) -> bool, secs: u64) -> Option<String> {
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(secs) {
        let s = title_of(c);
        if f(&s) {
            return Some(s);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    None
}

fn exec(c: &mut Conn, file: &str, args: &[&str], timeout: u64) -> Reply {
    need(c.call("exec.run", json!({"file": file, "args": args, "timeoutMs": timeout})))
}

fn decode_png(b: &[u8]) -> (u32, u32, Vec<u8>) {
    let d = png::Decoder::new(std::io::Cursor::new(b));
    let mut r = d.read_info().unwrap();
    let mut buf = vec![0; r.output_buffer_size().unwrap()];
    let info = r.next_frame(&mut buf).unwrap();
    buf.truncate(info.buffer_size());
    (info.width, info.height, buf)
}

fn diff_px(a: &[u8], b: &[u8]) -> usize {
    a.chunks_exact(3).zip(b.chunks_exact(3)).filter(|(p, q)| p != q).count()
}

fn find_node<'a>(tree: &'a Value, f: impl Fn(&Value) -> bool) -> Option<&'a Value> {
    tree["nodes"].as_array()?.iter().find(|n| f(n))
}

fn center(n: &Value) -> (f64, f64) {
    let b = &n["bbox"];
    (b[0].as_f64().unwrap() + b[2].as_f64().unwrap() / 2.0, b[1].as_f64().unwrap() + b[3].as_f64().unwrap() / 2.0)
}

// ---- scenarios ------------------------------------------------------------------------------------------------

fn sc_info(lab: &mut Lab, c: &mut Conn) {
    let r = need(c.call("agent.info", json!({})));
    lab.out.rec("agent.info", json!({"ok": r.ok, "result": r.result, "ms": r.ms}));
    let r = need(c.call("screen.state", json!({})));
    lab.out.rec("screen.state", json!({"ok": r.ok, "result": r.result, "ms": r.ms}));
    let mut a = vec![];
    let mut s = vec![];
    for _ in 0..200 {
        a.push(need(c.call("agent.info", json!({}))).ms);
        s.push(need(c.call("screen.state", json!({}))).ms);
    }
    lab.out.rec("rtt", json!({"agent.info": stats(&a), "screen.state": stats(&s)}));
}

fn sc_capture(lab: &mut Lab, c: &mut Conn) {
    let cells = [
        ("webp-1280", json!({"format": "webp"})),
        ("png-1280", json!({"format": "png"})),
        ("webp-native", json!({"format": "webp", "maxW": 3840, "maxH": 2160})),
        ("webp-region-400x300", json!({"format": "webp", "region": [200, 150, 400, 300]})),
    ];
    // interleaved rounds
    let mut data: Vec<(Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>, Vec<f64>)> = vec![Default::default(); cells.len()];
    for round in 0..40 {
        for (i, (name, p)) in cells.iter().enumerate() {
            let r = need(c.call("screen.capture", p.clone()));
            if !r.ok {
                lab.out.rec("capture-error", json!({"cell": name, "code": r.code, "message": r.message}));
                continue;
            }
            let b = r.blob.as_ref().unwrap();
            let d = &mut data[i];
            d.0.push(r.ms);
            d.1.push(r.result["ms"]["total"].as_f64().unwrap_or(0.0));
            d.2.push(b.len() as f64 / 1024.0);
            d.3.push(r.result["ms"]["scale"].as_f64().unwrap_or(0.0));
            d.4.push(r.result["ms"]["encode"].as_f64().unwrap_or(0.0));
            if round == 0 {
                let ext = if name.starts_with("png") { "png" } else { "webp" };
                let _ = std::fs::write(lab.out.dir.join(format!("capture-{name}.{ext}")), b);
                lab.out.rec("capture-first", json!({"cell": name, "result": r.result}));
            }
            std::thread::sleep(Duration::from_millis(20 + (round * 37 % 60) as u64));
        }
    }
    for (i, (name, _)) in cells.iter().enumerate() {
        let d = &data[i];
        lab.out.rec("capture", json!({"cell": name, "hostMs": stats(&d.0), "guestMs": stats(&d.1), "kb": stats(&d.2), "scaleMs": stats(&d.3), "encodeMs": stats(&d.4)}));
    }
}

fn open_notepad(c: &mut Conn) -> Option<String> {
    let _ = exec(c, "cmd.exe", &["/c", "taskkill", "/im", "notepad.exe", "/f"], 5000);
    let _ = exec(c, "cmd.exe", &["/c", "start", "", "notepad.exe"], 5000);
    wait_title(c, |t| t.contains("Bloc de notas") || t.contains("Notepad"), 15)
}

fn sc_latency(lab: &mut Lab, c: &mut Conn) {
    let Some(t) = open_notepad(c) else {
        lab.out.rec("latency", json!({"error": "notepad didn't come to the front"}));
        return;
    };
    let tree = need(c.call("ui.tree", json!({})));
    let Some(edit) = find_node(&tree.result, |n| n["role"] == "edit" || n["role"] == "document").cloned() else {
        lab.out.rec("latency", json!({"error": "no edit box", "tree": tree.result}));
        return;
    };
    let (cx, cy) = center(&edit);
    let _ = need(c.call("input.act", json!({"actions": [{"type": "click", "x": cx, "y": cy}]})));
    let b = &edit["bbox"];
    let region = json!([b[0].as_i64().unwrap() + 2, b[1].as_i64().unwrap() + 2, 320, 60]);
    let mut lat = vec![];
    let mut polls = vec![];
    let mut timeouts = 0;
    for i in 0..40 {
        std::thread::sleep(Duration::from_millis(150 + (i * 53 % 250) as u64));
        let base = need(c.call("screen.capture", json!({"format": "png", "region": region})));
        let (_, _, before) = decode_png(base.blob.as_ref().unwrap());
        let act = if i % 2 == 0 { json!({"type": "type", "text": "m"}) } else { json!({"type": "key", "keys": "backspace"}) };
        let t = Instant::now();
        let r = need(c.call("input.act", json!({"actions": [act]})));
        if !r.ok {
            lab.out.rec("latency-refused", json!({"code": r.code, "message": r.message}));
            return;
        }
        let mut n = 0;
        let mut got = None;
        while t.elapsed() < Duration::from_secs(1) {
            let cap = need(c.call("screen.capture", json!({"format": "png", "region": region})));
            n += 1;
            let (_, _, now) = decode_png(cap.blob.as_ref().unwrap());
            if diff_px(&before, &now) > 40 {
                got = Some(t.elapsed().as_secs_f64() * 1e3);
                break;
            }
        }
        match got {
            Some(ms) => {
                lat.push(ms);
                polls.push(n as f64);
            }
            None => timeouts += 1,
        }
    }
    lab.out.rec("latency", json!({"window": t, "region": region, "actionToScreenMs": stats(&lat), "capturesPerSample": stats(&polls), "timeouts": timeouts, "raw": lat}));
}

const PAGE: &str = r##"<!doctype html><html><head><meta charset="utf-8"><title>lab051</title>
<style>body{font:20px sans-serif;margin:40px}input{font-size:24px;width:500px}button{font-size:24px;margin:10px}#tall{height:4000px}</style></head>
<body><input id="f" placeholder="type here"> <button id="b">Press</button> <a href="#x">A link</a><div id="tall"></div>
<script>let n=0;const f=document.getElementById('f');function upd(){document.title='v='+f.value+';n='+n+';y='+Math.round(scrollY)+';'}
f.addEventListener('input',upd);document.getElementById('b').addEventListener('click',()=>{n++;upd()});addEventListener('scroll',upd);upd()</script></body></html>"##;

fn tree_stats(lab: &mut Lab, c: &mut Conn, app: &str) {
    let mut ms = vec![];
    let mut host = vec![];
    let mut first = Value::Null;
    for i in 0..6 {
        let r = need(c.call("ui.tree", json!({})));
        if !r.ok {
            lab.out.rec("ui.tree-error", json!({"app": app, "code": r.code, "message": r.message}));
            return;
        }
        if i == 0 {
            first = json!({"ms": r.result["ms"], "nodes": r.result["nodes"].as_array().map(|a| a.len()), "total": r.result["total"], "queries": r.result["queries"], "window": r.result["window"]});
        } else {
            ms.push(r.result["ms"].as_f64().unwrap_or(0.0));
            host.push(r.ms);
        }
    }
    let unfiltered = need(c.call("ui.tree", json!({"visibleOnly": false, "interactiveOnly": false, "maxNodes": 1000})));
    lab.out.rec("ui.tree", json!({"app": app, "first": first, "warmGuestMs": stats(&ms), "warmHostMs": stats(&host),
        "allNodes": unfiltered.result["nodes"].as_array().map(|a| a.len()), "truncated": unfiltered.result["truncated"]}));
}

fn sc_uia(lab: &mut Lab, c: &mut Conn) {
    // Notepad
    if open_notepad(c).is_some() {
        tree_stats(lab, c, "notepad");
    }
    let _ = exec(c, "cmd.exe", &["/c", "taskkill", "/im", "notepad.exe", "/f"], 5000);
    // Explorer
    let _ = exec(c, "explorer.exe", &["C:\\Windows"], 10000);
    if wait_title(c, |t| t == "Windows", 15).is_some() {
        tree_stats(lab, c, "explorer");
        let _ = need(c.call("input.act", json!({"actions": [{"type": "key", "keys": "alt+f4"}]})));
    }
    // Settings
    let _ = exec(c, "cmd.exe", &["/c", "start", "", "ms-settings:display"], 10000);
    let t = Instant::now();
    while t.elapsed() < Duration::from_secs(20) {
        let s = need(c.call("screen.state", json!({})));
        if s.result["foreground"]["process"].as_str().unwrap_or("").eq_ignore_ascii_case("ApplicationFrameHost.exe") {
            std::thread::sleep(Duration::from_secs(2));
            tree_stats(lab, c, "settings");
            let _ = need(c.call("input.act", json!({"actions": [{"type": "key", "keys": "alt+f4"}]})));
            break;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    // Edge with a local page: functional checks of input and ui.invoke, read back through the page title
    let w = need(c.call_blob("files.write", json!({"path": "Desktop\\Received\\lab051.html"}), Some(PAGE.as_bytes())));
    lab.out.rec("files.write-page", json!({"ok": w.ok, "message": w.message}));
    let _ = exec(c, "cmd.exe", &["/c", "start", "", "msedge", "--no-first-run", "file:///C:/Users/agent/Desktop/Received/lab051.html"], 10000);
    let Some(t0) = wait_title(c, |t| t.contains("n=0"), 40) else {
        let shot = need(c.call("screen.capture", json!({})));
        if let Some(b) = shot.blob {
            let _ = std::fs::write(lab.out.dir.join("edge-missing.webp"), b);
        }
        lab.out.rec("edge", json!({"error": "page title never showed", "title": title_of(c)}));
        return;
    };
    std::thread::sleep(Duration::from_secs(1));
    let first = need(c.call("ui.tree", json!({})));
    lab.out.rec("edge-first-tree", json!({"title": t0, "ms": first.result["ms"], "nodes": first.result["nodes"].as_array().map(|a| a.len()), "queries": first.result["queries"], "chromium": first.result["chromium"]}));
    tree_stats(lab, c, "edge");
    let tree = need(c.call("ui.tree", json!({})));
    let edit = find_node(&tree.result, |n| n["role"] == "edit" && !n["name"].as_str().unwrap_or("").contains("dirección") && !n["name"].as_str().unwrap_or("").to_lowercase().contains("address")).cloned();
    let button = find_node(&tree.result, |n| n["role"] == "button" && n["name"] == "Press").cloned();
    let mut checks = serde_json::Map::new();
    if let (Some(edit), Some(button)) = (edit, button) {
        let (ex, ey) = center(&edit);
        let r = need(c.call("input.act", json!({"actions": [{"type": "click", "x": ex, "y": ey}, {"type": "type", "text": "hola GpuVM ñ"}]})));
        checks.insert("click+type".into(), json!({"ok": r.ok, "title": wait_title(c, |t| t.contains("v=hola GpuVM ñ;"), 3)}));
        let r = need(c.call("input.act", json!({"actions": [{"type": "key", "keys": "backspace", "repeat": 6}]})));
        checks.insert("key-repeat".into(), json!({"ok": r.ok, "title": wait_title(c, |t| t.contains("v=hola G;"), 3)}));
        let r = need(c.call("input.act", json!({"actions": [{"type": "key", "keys": "ctrl+a"}, {"type": "key", "keys": "delete"}]})));
        checks.insert("ctrl+a,delete".into(), json!({"ok": r.ok, "title": wait_title(c, |t| t.contains("v=;"), 3)}));
        let bid = button["id"].clone();
        let r = need(c.call("ui.invoke", json!({"id": bid, "action": "invoke"})));
        checks.insert("ui.invoke".into(), json!({"ok": r.ok, "ms": r.ms, "code": r.code, "title": wait_title(c, |t| t.contains("n=1;"), 3)}));
        let (bx, by) = center(&button);
        let r = need(c.call("input.act", json!({"actions": [{"type": "click", "x": bx, "y": by}]})));
        checks.insert("click-button".into(), json!({"ok": r.ok, "title": wait_title(c, |t| t.contains("n=2;"), 3)}));
        let eid = edit["id"].clone();
        let r = need(c.call("ui.invoke", json!({"id": eid, "action": "setValue", "value": "uia"})));
        checks.insert("ui.setValue".into(), json!({"ok": r.ok, "code": r.code, "message": r.message, "title": wait_title(c, |t| t.contains("v=uia;"), 3)}));
        let r = need(c.call("input.act", json!({"actions": [{"type": "scroll", "x": ex, "y": ey + 300.0, "dy": 5}]})));
        checks.insert("scroll".into(), json!({"ok": r.ok, "title": wait_title(c, |t| !t.contains("y=0;") && t.contains("y="), 3)}));
        let r = need(c.call("input.act", json!({"actions": [{"type": "drag", "x": ex - 200.0, "y": ey, "toX": ex + 200.0, "toY": ey}]})));
        checks.insert("drag".into(), json!({"ok": r.ok, "code": r.code}));
    } else {
        checks.insert("error".into(), json!({"tree": tree.result}));
    }
    lab.out.rec("edge-checks", Value::Object(checks));
    let _ = exec(c, "cmd.exe", &["/c", "taskkill", "/im", "msedge.exe", "/f"], 5000);
}

fn sc_exec(lab: &mut Lab, c: &mut Conn) {
    let mut ms = vec![];
    for _ in 0..40 {
        let r = exec(c, "cmd.exe", &["/c", "echo", "hi"], 5000);
        ms.push(r.ms);
    }
    let who = exec(c, "whoami.exe", &["/groups", "/fo", "csv"], 5000);
    let user = exec(c, "whoami.exe", &[], 5000);
    let stdin = need(c.call("exec.run", json!({"file": "findstr.exe", "args": ["x"], "stdin": "a\nxyz\nb\n", "timeoutMs": 5000})));
    let t = Instant::now();
    let to = exec(c, "ping.exe", &["-n", "30", "127.0.0.1"], 1500);
    let to_ms = t.elapsed().as_secs_f64() * 1e3;
    let big = exec(c, "cmd.exe", &["/c", "dir", "/s", "C:\\Windows\\System32"], 60000);
    let missing = exec(c, "no-such-program.exe", &[], 5000);
    let groups = who.result["stdout"].as_str().unwrap_or("");
    lab.out.rec("exec", json!({
        "echoMs": stats(&ms),
        "whoami": user.result["stdout"],
        "highOrAdmin": groups.contains("S-1-16-12288") || groups.contains("S-1-5-32-544\",\"Grupo") && groups.contains("habilitado"),
        "integrityLine": groups.lines().find(|l| l.contains("S-1-16-")),
        "stdin": stdin.result["stdout"],
        "timeout": {"result": to.result, "ms": to_ms},
        "big": {"ok": big.ok, "truncated": big.result["truncated"], "inBlob": big.result["outputInBlob"], "stdoutBytes": big.result["stdoutBytes"], "blob": big.blob.as_ref().map(|b| b.len()), "ms": big.ms},
        "missing": {"code": missing.code, "message": missing.message},
    }));
}

fn sc_files(lab: &mut Lab, c: &mut Conn) {
    let mut data = vec![0u8; 1 << 20];
    for (i, b) in data.iter_mut().enumerate() {
        *b = (i * 7 % 251) as u8;
    }
    let mut rows = serde_json::Map::new();
    for (name, size) in [("1MiB", 1usize << 20), ("10MiB", 10 << 20)] {
        let payload: Vec<u8> = data.iter().cycle().take(size).cloned().collect();
        let w = need(c.call_blob("files.write", json!({"path": format!("Desktop\\Received\\{name}.bin")}), Some(&payload)));
        let r = need(c.call("files.read", json!({"path": format!("C:\\Users\\agent\\Desktop\\Received\\{name}.bin")})));
        let same = r.blob.as_deref() == Some(&payload[..]);
        rows.insert(name.into(), json!({"writeMs": w.ms, "readMs": r.ms, "same": same, "writeOk": w.ok, "readOk": r.ok}));
    }
    let list = need(c.call("files.list", json!({"path": "Desktop"})));
    rows.insert("list".into(), json!({"ok": list.ok, "ms": list.ms, "entries": list.result["entries"].as_array().map(|a| a.iter().map(|e| e["name"].clone()).collect::<Vec<_>>())}));
    // escapes
    let _ = exec(c, "cmd.exe", &["/c", "mklink", "/J", "C:\\Users\\agent\\j", "C:\\Users\\gpuvm"], 5000);
    let _ = exec(c, "cmd.exe", &["/c", "echo", "x", ">", "C:\\Users\\agent\\own.txt"], 5000);
    let hl_own = exec(c, "cmd.exe", &["/c", "mklink", "/H", "C:\\Users\\agent\\own-hl.txt", "C:\\Users\\agent\\own.txt"], 5000);
    let hl_win = exec(c, "cmd.exe", &["/c", "mklink", "/H", "C:\\Users\\agent\\win-hl.ini", "C:\\Windows\\win.ini"], 5000);
    rows.insert("mklink".into(), json!({"hardlinkOwn": hl_own.result["stdout"], "hardlinkWinIni": [hl_win.result["exitCode"], hl_win.result["stdout"], hl_win.result["stderr"]]}));
    let mut esc = serde_json::Map::new();
    for (label, method, path) in [
        ("dotdot", "files.read", "..\\gpuvm\\NTUSER.DAT"),
        ("dotdot-abs", "files.read", "C:\\Users\\agent\\..\\gpuvm\\NTUSER.DAT"),
        ("outside", "files.read", "C:\\Windows\\win.ini"),
        ("device-path", "files.read", "\\\\?\\C:\\Windows\\win.ini"),
        ("unc", "files.list", "\\\\localhost\\c$"),
        ("junction-list", "files.list", "j"),
        ("junction-read", "files.read", "j\\NTUSER.DAT"),
        ("hardlink-own", "files.read", "own-hl.txt"),
        ("hardlink-winini", "files.read", "win-hl.ini"),
        ("ads", "files.read", "own.txt:secret"),
        ("device-name", "files.read", "Desktop\\CON"),
        ("forward-slash-dotdot", "files.read", "Desktop/../../gpuvm/x"),
        ("kelvin-case-trick", "files.read", "C:\\Users\\a\u{212A}ent\\own.txt"),
        ("ok-plain", "files.read", "own.txt"),
    ] {
        let r = need(c.call(method, json!({"path": path})));
        esc.insert(label.into(), json!({"ok": r.ok, "code": r.code, "message": r.message}));
    }
    let wr = need(c.call_blob("files.write", json!({"path": "j\\evil.txt"}), Some(b"x")));
    esc.insert("junction-write".into(), json!({"ok": wr.ok, "code": wr.code, "message": wr.message}));
    rows.insert("escapes".into(), Value::Object(esc));
    // outbox
    let _ = need(c.call_blob("files.write", json!({"path": "Desktop\\Outbox\\report.txt"}), Some(b"lab 051 report")));
    let o = need(c.call("outbox.offer", json!({"path": "Desktop\\Outbox\\report.txt", "note": "test"})));
    let o2 = need(c.call("outbox.offer", json!({"path": "Desktop\\Received\\1MiB.bin", "note": "not in outbox"})));
    rows.insert("outbox".into(), json!({"inOutbox": {"ok": o.ok, "result": o.result}, "outside": {"code": o2.code, "message": o2.message}}));
    let _ = exec(c, "cmd.exe", &["/c", "rmdir", "C:\\Users\\agent\\j"], 5000);
    let _ = exec(c, "cmd.exe", &["/c", "del", "/q", "C:\\Users\\agent\\own.txt", "C:\\Users\\agent\\own-hl.txt", "C:\\Users\\agent\\win-hl.ini"], 5000);
    lab.out.rec("files", Value::Object(rows));
}

fn refusal_probe(c: &mut Conn, x: f64, y: f64) -> Value {
    let cap = need(c.call("screen.capture", json!({})));
    let click = need(c.call("input.act", json!({"actions": [{"type": "click", "x": x, "y": y}]})));
    let typ = need(c.call("input.act", json!({"actions": [{"type": "type", "text": "x"}]})));
    let tree = need(c.call("ui.tree", json!({})));
    let st = need(c.call("screen.state", json!({})));
    json!({"capture": [cap.ok, cap.code], "click": [click.ok, click.code, click.message], "type": [typ.ok, typ.code, typ.message],
           "ui.tree": [tree.ok, tree.code], "state": st.result})
}

fn sc_secure(lab: &mut Lab, c: &mut Conn) {
    // a UAC prompt from the standard user: credentials on the secure desktop
    let since = Instant::now();
    let r = exec(c, "powershell.exe", &["-NoProfile", "-Command", "Start-Process cmd.exe -Verb RunAs"], 3000);
    let on = c.wait_event(since, Duration::from_secs(10), |v| v["event"] == "secure_desktop" && v["data"]["on"] == true);
    let probe = refusal_probe(c, 100.0, 100.0);
    let since2 = Instant::now();
    let kill = lab.psd("Stop-Process -Name consent -Force -ErrorAction SilentlyContinue; 'killed'");
    let off = c.wait_event(since2, Duration::from_secs(30), |v| v["event"] == "secure_desktop" && v["data"]["on"] == false);
    let events: Vec<Value> = c.events.iter().filter(|(t, _)| *t >= since).map(|(t, v)| json!({"ms": (*t - since).as_millis() as u64, "evt": v["event"], "data": v["data"]})).collect();
    let after = need(c.call("screen.capture", json!({})));
    lab.out.rec("secure-desktop", json!({"exec": r.result, "eventOnMs": on.map(|x| x.0), "probe": probe, "psd": kill, "eventOffMs": off.map(|x| x.0), "captureAfter": after.ok, "events": events}));
}

fn sc_elevated(lab: &mut Lab, c: &mut Conn) {
    let cmd = r#"$a = New-ScheduledTaskAction -Execute 'C:\ProgramData\GpuVMLab051\harness.exe' -Argument 'guest-system-window C:\Windows\System32\notepad.exe'
Register-ScheduledTask -TaskName GpuVMLab051Sys -Action $a -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
Remove-Item C:\ProgramData\GpuVMLab051\syswin.json -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName GpuVMLab051Sys
$t = 0; while (-not (Test-Path C:\ProgramData\GpuVMLab051\syswin.json) -and $t -lt 50) { Start-Sleep -Milliseconds 200; $t++ }
Unregister-ScheduledTask -TaskName GpuVMLab051Sys -Confirm:$false
Get-Content C:\ProgramData\GpuVMLab051\syswin.json"#;
    let out = lab.psd(cmd);
    let info: Value = serde_json::from_str(out.lines().last().unwrap_or("{}")).unwrap_or(json!({"raw": out}));
    let r = &info["rect"];
    let (x, y) = if r.is_array() { ((r[0].as_f64().unwrap() + r[2].as_f64().unwrap()) / 2.0, (r[1].as_f64().unwrap() + r[3].as_f64().unwrap()) / 2.0) } else { (500.0, 400.0) };
    std::thread::sleep(Duration::from_millis(800));
    let state = need(c.call("screen.state", json!({})));
    // under the pointer (not necessarily in front)
    let click = need(c.call("input.act", json!({"actions": [{"type": "click", "x": x, "y": y}]})));
    // bring it to the front the way a person would (Alt+Tab goes to the shell, allowed)
    let alt = need(c.call("input.act", json!({"actions": [{"type": "key", "keys": "alt+tab"}, {"type": "wait", "ms": 600}]})));
    let probe = refusal_probe(c, x, y);
    let pid = info["pid"].as_u64().unwrap_or(0);
    let kill = lab.psd(&format!("Stop-Process -Id {pid} -Force -ErrorAction SilentlyContinue; 'killed'"));
    lab.out.rec("elevated-window", json!({"window": info, "stateBefore": state.result["foreground"], "clickUnderPointer": [click.ok, click.code, click.message], "altTab": [alt.ok, alt.code], "probe": probe, "cleanup": kill}));
}

fn sc_errorbox(lab: &mut Lab, c: &mut Conn) {
    let since = Instant::now();
    let r = exec(c, "C:\\ProgramData\\GpuVMLab051\\harness.exe", &["guest-errorbox"], 3000);
    let ev = c.wait_event(since, Duration::from_secs(10), |v| v["event"] == "error_box");
    if let Some(b) = need(c.call("screen.capture", json!({}))).blob {
        let _ = std::fs::write(lab.out.dir.join("errorbox.webp"), b);
    }
    let probe = refusal_probe(c, 960.0, 540.0);
    std::thread::sleep(Duration::from_secs(2));
    let still = need(c.call("screen.state", json!({})));
    lab.out.rec("error-box", json!({"exec": r.result, "event": ev, "probe": probe, "boxesAfterKill": still.result["errorBoxes"]}));
}

fn sc_abuse(lab: &mut Lab) {
    let mut rows = serde_json::Map::new();
    // 1. wrong challenge MAC: the guest must not answer with a proof
    let r = accept(&lab.l, &lab.secret, &lab.vm, Hs::WrongChallengeMac, 15000).err().unwrap_or_default();
    rows.insert("wrongChallengeMac".into(), json!(r));
    // the guest waits 1 s after a failed handshake
    let cases: Vec<(&str, Box<dyn Fn(&mut Conn) -> Result<(), String>>)> = vec![
        ("wrongFrameMac", Box::new(|c: &mut Conn| {
            let mut f = c.sealer.lock().unwrap().seal(json!({"t": "ping"}));
            let n = f.len();
            f[n - 5] = if f[n - 5] == b'0' { b'1' } else { b'0' };
            let mut b = vec![];
            write_frame(&mut b, KIND_JSON, &f).unwrap();
            c.raw(&b)
        })),
        ("replayedSeq", Box::new(|c: &mut Conn| {
            let f = c.sealer.lock().unwrap().seal(json!({"t": "ping"}));
            let mut b = vec![];
            write_frame(&mut b, KIND_JSON, &f).unwrap();
            write_frame(&mut b, KIND_JSON, &f).unwrap();
            c.raw(&b)
        })),
        ("noMac", Box::new(|c: &mut Conn| {
            let mut b = vec![];
            write_frame(&mut b, KIND_JSON, br#"{"t":"req","id":1,"method":"agent.info","seq":1}"#).unwrap();
            c.raw(&b)
        })),
        ("jsonOver64KiB", Box::new(|c: &mut Conn| {
            let mut h = ((MAX_JSON as u32) + 1).to_le_bytes().to_vec();
            h.push(KIND_JSON);
            c.raw(&h)
        })),
        ("blobOver16MiB", Box::new(|c: &mut Conn| {
            let mut h = ((MAX_BLOB as u32) + 1).to_le_bytes().to_vec();
            h.push(KIND_BLOB);
            c.raw(&h)
        })),
        ("unknownKind", Box::new(|c: &mut Conn| c.raw(&[1, 0, 0, 0, 7, 0]))),
        ("unannouncedBlob", Box::new(|c: &mut Conn| {
            let mut b = vec![];
            write_frame(&mut b, KIND_BLOB, b"hello").unwrap();
            c.raw(&b)
        })),
        ("blobHashMismatch", Box::new(|c: &mut Conn| {
            let f = c.sealer.lock().unwrap().seal(json!({"t": "req", "id": 1, "method": "files.write", "params": {"path": "x.txt"}, "blob": true, "blobLen": 5, "blobSha256": hex(&sha256(b"other"))}));
            let mut b = vec![];
            write_frame(&mut b, KIND_JSON, &f).unwrap();
            write_frame(&mut b, KIND_BLOB, b"hello").unwrap();
            c.raw(&b)
        })),
        ("silence", Box::new(|c: &mut Conn| {
            c.stop.store(true, Ordering::SeqCst); // stop our heartbeat: the guest must drop us after 6 s
            Ok(())
        })),
    ];
    for (name, f) in cases {
        match lab.connect(20000) {
            Ok(mut c) => {
                let _ = need(c.call("agent.info", json!({})));
                let sent = f(&mut c);
                let wait = if name == "silence" { 9000 } else { 3000 };
                let (closed, ms, why) = c.closed_within(wait);
                rows.insert(name.into(), json!({"sent": sent.is_ok(), "guestClosed": closed, "ms": (ms * 10.0).round() / 10.0, "why": why}));
            }
            Err(e) => {
                rows.insert(name.into(), json!({"error": e}));
            }
        }
    }
    // soft refusals (connection stays)
    if let Ok(mut c) = lab.connect(20000) {
        let a = need(c.call("no.such", json!({})));
        let b = need(c.call("screen.capture", json!([1, 2])));
        let d = need(c.call("input.act", json!({"actions": [{"type": "click", "x": 99999, "y": 5}]})));
        rows.insert("soft".into(), json!({"unknownMethod": a.code, "paramsNotObject": b.code, "clickOutside": [d.code, d.message], "stillConnected": c.call("agent.info", json!({})).is_ok()}));
    }
    lab.out.rec("abuse", Value::Object(rows));
}

fn sc_acl(lab: &mut Lab) {
    let out = lab.psd(r"icacls C:\ProgramData\GpuVM\Agent\secret /grant *S-1-5-32-545:R | Out-Null; Restart-Service GpuVMAgent; 'granted Users read'");
    let r = accept(&lab.l, &lab.secret, &lab.vm, Hs::Good, 15000).map(|_| "CONNECTED (bad)").unwrap_or_else(|_| "no connection (good)");
    let log = lab.psd(r"Get-Content C:\ProgramData\GpuVM\Agent\logs\agent.log -Tail 3");
    let t = Instant::now();
    let fix = lab.psd(r"icacls C:\ProgramData\GpuVM\Agent\secret /remove:g *S-1-5-32-545 | Out-Null; Restart-Service GpuVMAgent; 'reverted'");
    let back = accept(&lab.l, &lab.secret, &lab.vm, Hs::Good, 30000).map(|(_, ms)| ms).ok();
    lab.out.rec("acl-refusal", json!({"psd": out, "with15s": r, "guestLog": log, "revert": fix, "reconnectAfterRevertMs": back.map(|_| t.elapsed().as_secs_f64() * 1e3)}));
}

fn sc_reboot(lab: &mut Lab, c: Conn) {
    let t = Instant::now();
    let mut c = c;
    let psd = lab.psd("Restart-Computer -Force; 'restarting'");
    let (closed, drop_ms, why) = c.closed_within(60000);
    drop(c);
    let reconnect = accept(&lab.l, &lab.secret, &lab.vm, Hs::Good, 240000);
    match reconnect {
        Ok((mut c, _)) => {
            let conn_ms = t.elapsed().as_secs_f64() * 1e3;
            let first = need(c.call("agent.info", json!({})));
            let signed = c.wait_event(t, Duration::from_secs(180), |v| v["event"] == "signed_in" && v["data"]["user"].is_string());
            let signed_ms = signed.as_ref().map(|_| t.elapsed().as_secs_f64() * 1e3);
            let seen: Vec<Value> = c.events.iter().map(|(_, v)| json!([v["event"], v["data"]])).collect();
            lab.out.rec("reboot-events", json!(seen));
            let mut cap_ms = None;
            let tc = Instant::now();
            while tc.elapsed() < Duration::from_secs(120) {
                if c.call("screen.capture", json!({})).map(|r| r.ok).unwrap_or(false) {
                    cap_ms = Some(t.elapsed().as_secs_f64() * 1e3);
                    break;
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            lab.out.rec("reboot", json!({"psd": psd, "dropNoticed": closed, "dropMs": drop_ms, "dropWhy": why, "reconnectedMs": conn_ms,
                "firstInfo": first.result, "signedInEventMs": signed_ms, "signedIn": signed.map(|s| s.1), "firstCaptureMs": cap_ms}));
        }
        Err(e) => lab.out.rec("reboot", json!({"psd": psd, "dropMs": drop_ms, "error": e})),
    }
}

fn serve(a: &[String]) {
    let secret_path = arg(a, "--secret").expect("--secret");
    let raw = std::fs::read(&secret_path).expect("secret");
    let mut secret = [0u8; 32];
    secret.copy_from_slice(&raw[..32]);
    let vm = arg(a, "--vm").unwrap_or_default().to_lowercase().trim_matches(|c| c == '{' || c == '}').to_string();
    let name = arg(a, "--name").unwrap_or_else(|| "agent051".into());
    let dir = std::path::PathBuf::from(arg(a, "--out").expect("--out"));
    std::fs::create_dir_all(&dir).unwrap();
    let psd = arg(a, "--psd").unwrap_or_default();
    let scen = arg(a, "--scenarios").unwrap_or_else(|| "info,capture,latency,uia,exec,files,secure,elevated,abuse,acl,errorbox,reboot".into());
    // bound to this VM's id (not HV_GUID_CHILDREN) so a broker listening for all VMs can run at the same time
    let bind_vm = if vm.is_empty() { HV_GUID_CHILDREN } else { guid_u128(&parse_guid(&vm).expect("--vm")) };
    // the name may be held by a broker under test: retry for --wait-bind seconds
    let wait_bind: u64 = arg(a, "--wait-bind").and_then(|v| v.parse().ok()).unwrap_or(0);
    let tb = Instant::now();
    let l = loop {
        match HvListener::bind(bind_vm, SERVICE_ID) {
            Ok(l) => break l,
            Err(e) if tb.elapsed() < Duration::from_secs(wait_bind) => {
                let _ = e;
                std::thread::sleep(Duration::from_millis(100));
            }
            Err(e) => {
                eprintln!("can't listen on the agent service id ({e}): is GpuVM's broker (or another harness) holding it?");
                std::process::exit(3);
            }
        }
    };
    println!("listening after {:.1} s", tb.elapsed().as_secs_f64());
    let file = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("results.jsonl")).unwrap();
    let mut lab = Lab { l, secret, vm, name, psd, out: Out { dir, file, t0: Instant::now() } };
    lab.out.rec("start", json!({"scenarios": scen}));
    let list: Vec<&str> = scen.split(',').collect();
    let mut conn: Option<Conn> = None;
    for s in list {
        let needs_conn = !matches!(s, "abuse" | "acl");
        if needs_conn && conn.is_none() {
            match lab.connect(120000) {
                Ok(c) => conn = Some(c),
                Err(e) => {
                    lab.out.rec("error", json!({"scenario": s, "connect": e}));
                    continue;
                }
            }
        }
        if !needs_conn {
            conn = None;
        }
        let t = Instant::now();
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match s {
            "info" => sc_info(&mut lab, conn.as_mut().unwrap()),
            "capture" => sc_capture(&mut lab, conn.as_mut().unwrap()),
            "latency" => sc_latency(&mut lab, conn.as_mut().unwrap()),
            "uia" => sc_uia(&mut lab, conn.as_mut().unwrap()),
            "exec" => sc_exec(&mut lab, conn.as_mut().unwrap()),
            "files" => sc_files(&mut lab, conn.as_mut().unwrap()),
            "secure" => sc_secure(&mut lab, conn.as_mut().unwrap()),
            "elevated" => sc_elevated(&mut lab, conn.as_mut().unwrap()),
            "errorbox" => sc_errorbox(&mut lab, conn.as_mut().unwrap()),
            "abuse" => sc_abuse(&mut lab),
            "acl" => sc_acl(&mut lab),
            "reboot" => sc_reboot(&mut lab, conn.take().unwrap()),
            x => lab.out.rec("error", json!({"unknown scenario": x})),
        }));
        if r.is_err() {
            lab.out.rec("error", json!({"scenario": s, "panic": true}));
            conn = None;
        }
        lab.out.rec("scenario-done", json!({"scenario": s, "s": t.elapsed().as_secs_f64()}));
    }
    lab.out.rec("end", json!({}));
}

fn main() {
    let a: Vec<String> = std::env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("serve") => serve(&a),
        Some("guest-system-window") => guestside::system_window(a.get(2).map(String::as_str).unwrap_or("C:\\Windows\\System32\\notepad.exe")),
        Some("guest-errorbox") => guestside::errorbox(),
        Some("guest-open-helper") => guestside::open_helper(),
        _ => eprintln!("harness serve | guest-system-window <exe> | guest-errorbox"),
    }
}
