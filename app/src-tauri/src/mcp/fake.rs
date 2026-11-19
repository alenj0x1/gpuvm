//! An in-memory GpuVM for tests and for `gpuvm.exe --mcp --fake`: machines, a 1920x1080 desktop drawn as a
//! grid, input that is recorded instead of injected, files, offers, pause and the kill switch. It follows the
//! broker contract in broker.rs and the guest protocol (docs/agents/protocol.md).

use super::broker::{Broker, BrokerError, Reply, Result};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;

#[derive(Clone, Debug)]
pub struct Machine {
    pub name: String,
    pub disposable: bool,
    pub template: String,
    pub screen: (u32, u32),
    pub taken_by: Option<String>,
    pub paused: bool,
    /// "person" (took control) or "agent" (request_human).
    pub paused_by: String,
    pub off: bool,
    pub elevated_foreground: bool,
    pub secure_desktop: bool,
    pub files: HashMap<String, Vec<u8>>,
    pub restore_points: Vec<String>,
    /// Every input action, in desktop pixels.
    pub actions: Vec<Value>,
}

#[derive(Default)]
pub struct State {
    pub machines: Vec<Machine>,
    pub connections: HashMap<String, Value>,
    pub killed: bool,
    pub elicitation: bool,
    pub max_steps: u64,
    pub offers: HashMap<String, (String, String)>,
    pub calls: Vec<String>,
    next: u32,
}

pub struct FakeBroker {
    pub state: Mutex<State>,
}

impl FakeBroker {
    pub fn new() -> Self {
        let mut state = State { max_steps: 500, ..Default::default() };
        state.machines.push(machine("work-pc", false, ""));
        FakeBroker { state: Mutex::new(state) }
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn with<R>(&self, f: impl FnOnce(&mut State) -> R) -> R {
        f(&mut self.state.lock().unwrap())
    }
}

impl Default for FakeBroker {
    fn default() -> Self {
        Self::new()
    }
}

fn machine(name: &str, disposable: bool, template: &str) -> Machine {
    Machine {
        name: name.into(),
        disposable,
        template: template.into(),
        screen: (1920, 1080),
        taken_by: None,
        paused: false,
        paused_by: "person".into(),
        off: false,
        elevated_foreground: false,
        secure_desktop: false,
        files: HashMap::new(),
        restore_points: Vec::new(),
        actions: Vec::new(),
    }
}

fn err(code: &str, message: &str) -> BrokerError {
    BrokerError::new(code, message)
}

fn s<'a>(args: &'a Value, key: &str) -> &'a str {
    args[key].as_str().unwrap_or("")
}

impl Broker for FakeBroker {
    fn call(&self, op: &str, args: Value) -> Result<Reply> {
        let mut st = self.state.lock().unwrap();
        st.calls.push(op.to_string());
        if st.killed && op != "client.disconnect" {
            return Err(err("killed", "The person stopped this connection."));
        }
        let conn = s(&args, "connection").to_string();
        match op {
            "client.connect" => {
                st.next += 1;
                let id = format!("c{}", st.next);
                st.connections.insert(id.clone(), args["client"].clone());
                return Ok(Reply::of(json!({ "connection": id,
                    "settings": { "elicitation": st.elicitation, "maxSteps": st.max_steps, "maxMinutes": 60 } })));
            }
            "client.disconnect" => {
                st.connections.remove(&conn);
                return Ok(Reply::default());
            }
            "templates.list" => {
                return Ok(Reply::of(json!({
                    "templates": [{ "name": "win11-agent", "description": "Windows 11 with the GpuVM agent", "os": "Windows 11 Pro" }],
                    "profiles": [{ "name": "small", "cpu": 2, "memoryGB": 4 }, { "name": "medium", "cpu": 4, "memoryGB": 8 }]
                })));
            }
            "machines.list" => {
                let list: Vec<Value> = st.machines.iter().map(|m| json!({
                    "name": m.name, "state": if m.off { "off" } else { "ready" }, "disposable": m.disposable, "template": m.template,
                    "agent": if m.off { Value::Null } else { json!({ "version": "fake", "screen": { "w": m.screen.0, "h": m.screen.1 }, "signedIn": true }) },
                    "desktop": if m.secure_desktop { "secure" } else { "default" },
                    "takenBy": m.taken_by.as_ref().map(|c| json!({ "connection": c, "client": "fake client" })),
                    "paused": if m.paused { json!({ "by": m.paused_by, "message": "" }) } else { Value::Null } })).collect();
                return Ok(Reply::of(Value::Array(list)));
            }
            "machine.create" => {
                let template = s(&args, "template");
                if template != "win11-agent" {
                    return Err(err("not_found", &format!("There is no template named {template}.")));
                }
                st.next += 1;
                let name = match s(&args, "name") { "" => format!("agent-{}", st.next), n => n.to_string() };
                if st.machines.iter().any(|m| m.name == name) {
                    return Err(err("exists", &format!("A machine named {name} already exists.")));
                }
                let mut m = machine(&name, true, template);
                m.taken_by = Some(conn.clone());
                st.machines.push(m);
                return Ok(Reply::of(json!({ "name": name })));
            }
            "offer.get" => {
                let id = s(&args, "offerId");
                return match st.offers.get(id) {
                    Some((_, state)) => Ok(Reply::of(json!({ "offerId": id, "state": state }))),
                    None => Err(err("not_found", "There is no such offer.")),
                };
            }
            _ => {}
        }
        // Everything else acts on one machine.
        let name = s(&args, "name").to_string();
        let idx = st.machines.iter().position(|m| m.name == name)
            .ok_or_else(|| err("not_found", &format!("There is no machine named {name}.")))?;
        let max_steps = st.max_steps;
        let steps = st.calls.iter().filter(|c| c.starts_with("agent.")).count() as u64;
        let m = &mut st.machines[idx];
        match op {
            "machine.take" => {
                match &m.taken_by {
                    Some(other) if *other != conn => return Err(err("taken", "Another agent is using it.")),
                    _ => m.taken_by = Some(conn),
                }
                return Ok(Reply::of(json!({ "name": name })));
            }
            "machine.release" => {
                m.taken_by = None;
                return Ok(Reply::default());
            }
            "viewer.open" => return Ok(Reply::of(json!({ "open": true }))),
            "machine.start" => {
                m.off = false;
                return Ok(Reply::default());
            }
            _ => {}
        }
        if m.taken_by.as_deref() != Some(conn.as_str()) {
            return Err(err("not_taken", "Take the machine first."));
        }
        if m.paused && op != "human.request" {
            return Err(err("paused", "The person took control."));
        }
        match op {
            "agent.invoke" => {
                if steps > max_steps {
                    return Err(err("budget", "Step budget used up."));
                }
                // The broker sends `blob` after the request; the fake hands it to the guest with the params.
                let mut params = args["params"].clone();
                if let Some(b) = args.get("blob") {
                    params["blob"] = b.clone();
                }
                guest(m, s(&args, "method"), &params)
            }
            "file.send" => {
                let host = s(&args, "hostPath");
                let file = host.rsplit(['\\', '/']).next().unwrap_or("file").to_string();
                let path = format!(r"C:\Users\agent\Desktop\Received\{file}");
                m.files.insert(path.clone(), b"from host".to_vec());
                Ok(Reply::of(json!({ "path": path })))
            }
            "offer.create" => {
                let path = s(&args, "path").to_string();
                if !path.to_ascii_lowercase().starts_with(r"c:\users\agent\desktop\outbox\") {
                    return Err(err("denied", "Only files in the Outbox folder can be offered."));
                }
                st.next += 1;
                let id = format!("o{}", st.next);
                st.offers.insert(id.clone(), (path, "pending".into()));
                Ok(Reply::of(json!({ "offerId": id })))
            }
            "restore.create" => {
                let label = match s(&args, "label") { "" => format!("point-{}", m.restore_points.len() + 1), l => l.to_string() };
                m.restore_points.push(label.clone());
                Ok(Reply::of(json!({ "name": label })))
            }
            "restore.revert" => {
                let point = s(&args, "point");
                if !m.restore_points.iter().any(|p| p == point) {
                    return Err(err("not_found", &format!("There is no restore point named {point}.")));
                }
                m.actions.clear();
                Ok(Reply::of(json!({ "point": point })))
            }
            "machine.destroy" => {
                if !m.disposable {
                    return Err(err("denied", "Only disposable machines can be destroyed by an agent."));
                }
                st.machines.remove(idx);
                Ok(Reply::default())
            }
            "human.request" => {
                m.paused = true;
                m.paused_by = "agent".into();
                Ok(Reply::of(json!({ "requestId": "h1" })))
            }
            _ => Err(err("internal", &format!("Unknown operation {op}."))),
        }
    }
}

fn guest(m: &mut Machine, method: &str, p: &Value) -> Result<Reply> {
    match method {
        "agent.info" => Ok(Reply::of(json!({ "version": "fake", "os": "Windows 11", "user": "agent", "session": 1,
            "screen": { "w": m.screen.0, "h": m.screen.1 }, "signedIn": true }))),
        "screen.capture" => {
            if m.secure_desktop {
                return Err(err("secure_desktop", "Secure desktop."));
            }
            let (fw, fh) = m.screen;
            let region = match p["region"].as_array() {
                Some(r) if r.len() == 4 => {
                    let v: Vec<u32> = r.iter().map(|x| x.as_u64().unwrap_or(0) as u32).collect();
                    if v[2] == 0 || v[3] == 0 || v[0] + v[2] > fw || v[1] + v[3] > fh {
                        return Err(err("bad_request", "Region outside the screen."));
                    }
                    [v[0], v[1], v[2], v[3]]
                }
                _ => [0, 0, fw, fh],
            };
            let max_w = p["maxW"].as_u64().unwrap_or(1280) as u32;
            let max_h = p["maxH"].as_u64().unwrap_or(800) as u32;
            let (w, h) = super::geometry::fit(region[2], region[3], max_w, max_h);
            let png = draw(region, (w, h));
            Ok(Reply { data: json!({ "w": w, "h": h, "scale": w as f64 / region[2] as f64, "format": "png",
                "screen": { "w": fw, "h": fh } }), blob: Some(png) })
        }
        "screen.state" => Ok(Reply::of(json!({ "desktop": if m.secure_desktop { "secure" } else { "default" },
            "foreground": { "title": "Untitled - Notepad", "process": "notepad.exe",
                "integrity": if m.elevated_foreground { "high" } else { "medium" }, "blocked": m.elevated_foreground } }))),
        "input.act" => {
            if m.elevated_foreground {
                return Err(err("blocked_elevated", "Elevated window in front."));
            }
            let actions = p["actions"].as_array().cloned().unwrap_or_default();
            for a in &actions {
                if let (Some(x), Some(_)) = (a["x"].as_i64(), a["y"].as_i64()) {
                    if x < 0 || x >= m.screen.0 as i64 {
                        return Err(err("bad_request", "Outside the screen."));
                    }
                }
                m.actions.push(a.clone());
            }
            Ok(Reply::of(json!({ "done": actions.len() })))
        }
        "ui.tree" => Ok(Reply::of(json!({ "nodes": [
            { "id": "n1", "role": "window", "name": "Untitled - Notepad", "bbox": [300, 150, 1200, 700], "enabled": true, "patterns": [] },
            { "id": "n2", "role": "edit", "name": "Text editor", "bbox": [310, 230, 1180, 600], "enabled": true, "patterns": ["value"] },
            { "id": "n3", "role": "button", "name": "Close", "bbox": [1440, 150, 60, 40], "enabled": true, "patterns": ["invoke"] },
            { "id": "n4", "role": "button", "name": "Off screen", "bbox": [5000, 5000, 10, 10], "enabled": true, "patterns": ["invoke"] }
        ] }))),
        "ui.invoke" => match p["id"].as_str() {
            Some("n1" | "n2" | "n3") => Ok(Reply::of(json!({}))),
            _ => Err(err("not_found", "No such element.")),
        },
        "exec.run" => {
            let file = p["file"].as_str().unwrap_or("");
            let args: Vec<String> = p["args"].as_array().map(|a| a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect()).unwrap_or_default();
            if file == "huge" {
                return Ok(Reply::of(json!({ "exitCode": 0, "stdout": "x".repeat(1 << 20), "stderr": "", "truncated": true })));
            }
            if file == "sleep" {
                return Err(err("timeout", "The command didn't finish in time."));
            }
            Ok(Reply::of(json!({ "exitCode": 0, "stdout": format!("{file} {}\r\n", args.join(" ")), "stderr": "", "truncated": false })))
        }
        "files.read" => {
            let path = p["path"].as_str().unwrap_or("");
            m.files.get(path).map(|b| Reply { data: json!({ "size": b.len() }), blob: Some(b.clone()) })
                .ok_or_else(|| err("not_found", "No such file."))
        }
        "files.write" => {
            let path = p["path"].as_str().unwrap_or("").to_string();
            if !path.to_ascii_lowercase().starts_with(r"c:\users\agent\") || path.contains("..") {
                return Err(err("denied", "Outside the agent's profile."));
            }
            use base64::Engine;
            let data = base64::engine::general_purpose::STANDARD.decode(p["blob"].as_str().unwrap_or("")).unwrap_or_default();
            m.files.insert(path, data);
            Ok(Reply::of(json!({})))
        }
        "files.list" => Ok(Reply::of(json!({ "entries": m.files.keys().collect::<Vec<_>>() }))),
        _ => Err(err("bad_request", &format!("Unknown method {method}."))),
    }
}

/// A picture of the desktop region: a light background with a line every 100 desktop pixels (so a zoom shows
/// where it is) and a dark block at the region's top-left corner.
fn draw(region: [u32; 4], sent: (u32, u32)) -> Vec<u8> {
    let (w, h) = sent;
    let mut rgb = vec![0u8; (w * h * 3) as usize];
    for y in 0..h {
        let fy = region[1] as u64 + y as u64 * region[3] as u64 / h as u64;
        for x in 0..w {
            let fx = region[0] as u64 + x as u64 * region[2] as u64 / w as u64;
            let line = fx.is_multiple_of(100) || fy.is_multiple_of(100);
            let i = ((y * w + x) * 3) as usize;
            let c = if line { [60, 60, 60] } else { [240, (fx * 255 / 1920) as u8, (fy * 255 / 1080) as u8] };
            rgb[i..i + 3].copy_from_slice(&c);
        }
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgb);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_compression(png::Compression::Fast);
        let mut writer = enc.write_header().expect("png header");
        writer.write_image_data(&rgb).expect("png data");
    }
    out
}
