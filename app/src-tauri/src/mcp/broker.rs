//! What the MCP server asks of GpuVM, as logical operations. The real broker lives in the elevated service
//! (`app/host/src/agent.rs`, commands on the `\\.\pipe\gpuvm` pipe answered in-process) and the module (cmdlets
//! through the service's PowerShell bridge); `fake.rs` implements the same operations in memory for tests and for
//! `gpuvm.exe --mcp --fake`.
//!
//! Policy (who has a machine, pause, budgets, kill switch, offers) is enforced by the service; the MCP side checks
//! too, but it works for a model, so it is never the only guard.

use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// A failed operation: a short machine code (protocol.md's guest codes plus the broker's) and its message.
#[derive(Debug, Clone, PartialEq)]
pub struct BrokerError {
    pub code: String,
    pub message: String,
}

impl BrokerError {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        BrokerError { code: code.into(), message: message.into() }
    }
}

/// A reply: JSON data, and the binary blob that came with it (screenshots, file contents).
#[derive(Debug, Default, Clone)]
pub struct Reply {
    pub data: Value,
    pub blob: Option<Vec<u8>>,
}

impl Reply {
    pub fn of(data: Value) -> Self {
        Reply { data, blob: None }
    }
}

pub type Result<T> = std::result::Result<T, BrokerError>;

/// Logical operations (`op`) and their arguments (data shapes are the broker's, see agent-broker's notes):
/// - `client.connect {client:{name,version,protocol,pid}}` → `{connection, settings:{elicitation,maxSteps,maxMinutes}}`
/// - `client.disconnect {connection}`
/// - `templates.list {}` → `{templates:[{name,description}], profiles:[{name,cpu,memoryGB}]}`
/// - `machine.create {connection, template, name?, profile?, cpu?, memoryGB?}` → `{name}` (disposable, started,
///   agent installed, taken by `connection`)
/// - `machines.list {connection}` → `[{name, state, agent:{screen:{w,h}, signedIn}|null, paused:{by,message}|null,
///   takenBy:{connection,client}|null, disposable, template, desktop}]`
/// - `machine.take / machine.release / machine.start {connection, name}`
/// - `agent.invoke {connection, name, method, params, timeoutSec?, blob?}` → guest result (+ blob)
/// - `file.send {connection, name, hostPath}` → `{path}` (in the VM's Desktop\Received)
/// - `offer.create {connection, name, path, note}` → `{offerId}`; `offer.get {connection, offerId}` → `{state, hostPath?}`
/// - `restore.create {connection, name, label?}` → `{name}`; `restore.revert {connection, name, point}`
/// - `machine.destroy {connection, name}` (disposable: turned off, then deleted)
/// - `viewer.open {connection, name}`
/// - `human.request {connection, name, message}` → `{requestId}` (pauses the agent on that machine)
/// - `approval.request {connection, name, kind, title, reason, timeoutSec}` → `{requestId, expiresAt}`;
///   `approval.get {connection, name, requestId}` → `{state: pending|allowed|denied|expired}` (the person answers in GpuVM)
pub trait Broker: Send + Sync {
    fn call(&self, op: &str, args: Value) -> Result<Reply>;
    /// Operations that take minutes (creating a machine) run on their own pipe connection.
    fn call_long(&self, op: &str, args: Value) -> Result<Reply> {
        self.call(op, args)
    }
}

/// The GpuVM service over its pipe, as the installed gpuvm.exe (the only program it trusts).
pub struct PipeBroker {
    conn: Mutex<Option<crate::backend::Conn>>,
    next: std::sync::atomic::AtomicU64,
}

impl Default for PipeBroker {
    fn default() -> Self {
        Self::new()
    }
}

fn s(args: &Value, key: &str) -> Value {
    args.get(key).cloned().unwrap_or(Value::Null)
}

/// Drops null arguments: the bridge passes every key it gets to the cmdlet.
fn clean(args: Value) -> Value {
    match args {
        Value::Object(map) => Value::Object(map.into_iter().filter(|(_, v)| !v.is_null()).collect()),
        other => other,
    }
}

/// A command's data as a list (one object, a list, or nothing).
pub fn list(v: Value) -> Vec<Value> {
    match v {
        Value::Array(a) => a,
        Value::Null => Vec::new(),
        other => vec![other],
    }
}

impl PipeBroker {
    pub fn new() -> Self {
        PipeBroker { conn: Mutex::new(None), next: std::sync::atomic::AtomicU64::new(1) }
    }

    fn request(&self, cmd: &str, args: Value) -> Value {
        let id = format!("mcp-{}", self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        json!({ "id": id, "cmd": cmd, "args": clean(args) })
    }

    /// One request; also the warnings the command wrote (New-GpuVM reports "couldn't turn on" only as a warning).
    fn run(conn: &mut crate::backend::Conn, request: &Value) -> Result<(Reply, Vec<String>)> {
        let mut warnings = Vec::new();
        let event = conn.call(request, |e| {
            if e["type"] == "warning" {
                if let Some(m) = e["message"].as_str() {
                    warnings.push(m.to_string());
                }
            }
        }).map_err(|e| BrokerError::new("unavailable", e))?;
        if event["ok"] != true {
            // The service: {"ok":false,"error":"<English>","code":"<code>"}; older errors are text only.
            return Err(match event["code"].as_str() {
                Some(code) => BrokerError::new(code, event["error"].as_str().unwrap_or("")),
                None => parse_error(&event["error"]),
            });
        }
        // The service sends a list of what the command wrote; commands here write one object.
        let data = match &event["data"] {
            Value::Array(items) if items.len() == 1 => items[0].clone(),
            other => other.clone(),
        };
        Ok((unwrap_reply(data)?, warnings))
    }

    /// One command, with its warnings: on the shared connection (the service answers one request at a time per
    /// connection), or on a connection of its own for minutes-long module work (`long`).
    fn exec(&self, cmd: &str, args: Value, long: bool) -> Result<(Reply, Vec<String>)> {
        let request = self.request(cmd, args);
        if long {
            let mut conn = crate::backend::connect().map_err(|e| BrokerError::new("unavailable", e))?;
            return Self::run(&mut conn, &request);
        }
        let mut guard = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Some(crate::backend::connect().map_err(|e| BrokerError::new("unavailable", e))?);
        }
        let result = Self::run(guard.as_mut().unwrap(), &request);
        if matches!(&result, Err(e) if e.code == "unavailable") {
            *guard = None;
        }
        result
    }

    fn cmd(&self, cmd: &str, args: Value) -> Result<Reply> {
        self.exec(cmd, args, false).map(|r| r.0)
    }

    fn cmd_long(&self, cmd: &str, args: Value) -> Result<Reply> {
        self.exec(cmd, args, true).map(|r| r.0)
    }

    fn templates(&self) -> Result<Reply> {
        let templates: Vec<Value> = list(self.cmd("Get-GpuVMTemplate", json!({}))?.data).into_iter().map(|t| json!({
            "name": t["name"],
            "description": format!("{}, saved from {}{}", t["edition"].as_str().unwrap_or("Windows"),
                t["fromVM"].as_str().unwrap_or("a machine"), t["createdAt"].as_str().map(|d| format!(" on {}", &d[..d.len().min(10)])).unwrap_or_default()),
        })).collect();
        // Get-GpuVMProfile lists {Name, Description, Settings:{cpu, memoryGB, ...}}.
        let profiles: Vec<Value> = list(self.cmd("Get-GpuVMProfile", json!({}))?.data).into_iter().map(|p| json!({
            "name": p["Name"], "cpu": p["Settings"]["cpu"], "memoryGB": p["Settings"]["memoryGB"] })).collect();
        Ok(Reply::of(json!({ "templates": templates, "profiles": profiles })))
    }

    fn runner(&self) -> impl Fn(&str, Value, bool) -> Result<(Reply, Vec<String>)> + '_ {
        move |cmd: &str, args: Value, long: bool| self.exec(cmd, args, long)
    }

    fn revert(&self, args: &Value) -> Result<Reply> {
        let name = s(args, "name");
        let point = args["point"].as_str().unwrap_or("");
        let points = list(self.cmd("Get-GpuVMRestorePoint", json!({ "Name": name }))?.data);
        let found = points.iter().find(|p| p["id"].as_str() == Some(point))
            .or_else(|| points.iter().rev().find(|p| p["label"].as_str().is_some_and(|l| l.eq_ignore_ascii_case(point))))
            .ok_or_else(|| BrokerError::new("not_found", format!("There is no restore point {point}; points: {}.",
                points.iter().map(|p| format!("{} ({})", p["id"].as_str().unwrap_or("?"), p["label"].as_str().unwrap_or(""))).collect::<Vec<_>>().join(", "))))?;
        // -SaveCurrent: how the machine is now becomes a point first, so nothing is lost. `Approval`: the person's
        // allowed `revert` request (the service checks and strips it).
        self.cmd_long("Restore-GpuVMRestorePoint", json!({ "Name": name, "Id": found["id"], "SaveCurrent": true, "ShutdownIfRunning": true,
            "Approval": s(args, "approval") }))?;
        Ok(Reply::of(json!({ "point": found["id"] })))
    }
}

impl Broker for PipeBroker {
    fn call(&self, op: &str, args: Value) -> Result<Reply> {
        let name = s(&args, "name");
        let connection = s(&args, "connection");
        match op {
            "client.connect" => self.cmd("Connect-GpuVMAgentClient", json!({ "Client": s(&args, "client") })),
            "client.disconnect" => self.cmd("Disconnect-GpuVMAgentClient", json!({ "Connection": connection })),
            "templates.list" => self.templates(),
            "machine.create" => create_disposable(&self.runner(), &args, &std::thread::sleep),
            "machines.list" => self.cmd("Get-GpuVMAgent", json!({})).map(|r| Reply::of(Value::Array(list(r.data)))),
            "machine.take" => self.cmd("Lock-GpuVMAgent", json!({ "Name": name, "Connection": connection, "Task": s(&args, "task") })),
            "machine.start" => self.cmd_long("Invoke-GpuVMPower", json!({ "Name": name, "Action": "Start" })),
            "machine.release" =>self.cmd("Unlock-GpuVMAgent", json!({ "Name": name, "Connection": connection })),
            "agent.invoke" => self.cmd("Invoke-GpuVMAgent", json!({ "Name": name, "Method": s(&args, "method"), "Params": s(&args, "params"),
                "TimeoutSec": s(&args, "timeoutSec"), "Connection": connection, "Blob": s(&args, "blob"), "Note": s(&args, "note") })),
            "approval.request" => self.cmd("New-GpuVMAgentRequest", json!({ "Name": name, "Connection": connection, "Kind": s(&args, "kind"),
                "Title": s(&args, "title"), "Reason": s(&args, "reason"), "TimeoutSec": s(&args, "timeoutSec") })),
            "approval.get" => {
                let id = s(&args, "requestId");
                list(self.cmd("Get-GpuVMAgentRequest", json!({ "Id": id }))?.data).into_iter().find(|r| r["id"] == id).map(Reply::of)
                    .ok_or_else(|| BrokerError::new("not_found", "There is no such request."))
            }
            "file.send" => {
                let host = args["hostPath"].as_str().unwrap_or("");
                self.cmd_long("Send-GpuVMFile", json!({ "Name": name, "Path": [host] }))?;
                let file = host.rsplit(['\\', '/']).next().unwrap_or(host);
                Ok(Reply::of(json!({ "path": format!(r"C:\Users\agent\Desktop\Received\{file}") })))
            }
            "offer.create" => self.cmd("New-GpuVMAgentOffer", json!({ "Name": name, "Path": s(&args, "path"), "Note": s(&args, "note"), "Connection": connection })),
            "offers.list" => self.cmd("Get-GpuVMAgentOffer", json!({ "Name": name })).map(|r| Reply::of(Value::Array(list(r.data)))),
            "offer.get" => {
                let id = s(&args, "offerId");
                let offers = list(self.cmd("Get-GpuVMAgentOffer", json!({ "Id": id }))?.data);
                offers.into_iter().find(|o| o["id"] == id).map(Reply::of)
                    .ok_or_else(|| BrokerError::new("not_found", "There is no such offer."))
            }
            "restore.create" => self.cmd_long("New-GpuVMRestorePoint", json!({ "Name": name, "Label": s(&args, "label"), "ShutdownIfRunning": true }))
                .map(|r| Reply::of(json!({ "name": r.data["id"].as_str().or(r.data["label"].as_str()).unwrap_or("saved") }))),
            "restore.revert" => self.revert(&args),
            "machine.destroy" => {
                remove_disposable(&self.runner(), name.as_str().unwrap_or(""));
                Ok(Reply::default())
            }
            "human.request" => self.cmd("Request-GpuVMHuman", json!({ "Name": name, "Connection": connection, "Message": s(&args, "message") })),
            "viewer.open" => open_viewer(name.as_str().unwrap_or("")),
            _ => Err(BrokerError::new("internal", format!("Unknown operation {op}."))),
        }
    }

    fn call_long(&self, op: &str, args: Value) -> Result<Reply> {
        self.call(op, args)
    }
}

/// Runs one module command through the service: (command, arguments, long) → its reply and the warnings it wrote.
pub type Run<'a> = dyn Fn(&str, Value, bool) -> Result<(Reply, Vec<String>)> + 'a;

/// A name for a new disposable when the model gives none: `<template>-<6 hex>` (agent sessions must name it).
fn new_name(template: &str) -> String {
    let template: String = template.chars().take(30).collect();
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    format!("{template}-{:06x}", (nanos ^ std::process::id().rotate_left(12)) & 0xff_ffff)
}

/// A disposable machine from a template: created and started, its agent installed (each machine gets its own
/// secret, so a template's copy can't be used as is), and taken by this connection. Whatever this call created and
/// couldn't hand over is deleted again before the error is returned.
pub fn create_disposable(run: &Run, args: &Value, pause: &dyn Fn(Duration)) -> Result<Reply> {
    // `Connection` makes the service claim the new machine for this session (validated and stripped by it), so only
    // this session can install its agent and take it.
    let name = match args["name"].as_str() {
        Some(n) if !n.is_empty() => n.to_string(),
        _ => new_name(args["template"].as_str().unwrap_or("agent")),
    };
    let mut new = json!({ "Template": s(args, "template"), "Name": name, "Profile": s(args, "profile"), "Disposable": true,
        "Connection": s(args, "connection") });
    let mut vm = serde_json::Map::new();
    if let Some(cpu) = args["cpu"].as_u64() {
        vm.insert("cpu".into(), json!({ "count": cpu }));
    }
    if let Some(mem) = args["memoryGB"].as_u64() {
        vm.insert("memoryGB".into(), json!(mem));
    }
    if !vm.is_empty() {
        new["Override"] = json!({ "vm": Value::Object(vm) });
    }
    let (created, warnings) = run("New-GpuVM", new, true)?;
    let name = created.data["name"].as_str().unwrap_or(&name).to_string();
    // New-GpuVM keeps a machine it couldn't turn on (not enough memory, mostly) and says so in `started`/`startError`
    // with the figures: stop here instead of waiting for an agent that can't come.
    let d = &created.data;
    if d["started"] == false {
        remove_disposable(run, &name);
        let (needed, free) = (d["neededGB"].as_f64(), d["freeGB"].as_f64());
        let reason = match (needed, free) {
            (Some(n), Some(f)) => format!("it needs {n:.1} GB of memory free and there are {f:.1} GB"),
            _ => d["startError"].as_str().unwrap_or("Windows didn't start it").trim_end_matches('.').to_string(),
        };
        let memory = needed.is_some();
        return Err(BrokerError::new(if memory { "no_memory" } else { "failed" }, format!(
            "{name} couldn't start: {reason}. It was deleted again.{}",
            if memory { " Ask for less memoryGB (4 is enough for most tests), or ask the person to free memory." } else { "" })));
    }
    // Modules before `started` only warn.
    if let Some(w) = warnings.iter().find(|w| w.contains("couldn't turn on")) {
        remove_disposable(run, &name);
        let reason = w.split_once(": ").map(|(_, r)| r).unwrap_or(w).trim_end_matches('.');
        let memory = reason.contains("GB free");
        return Err(BrokerError::new(if memory { "no_memory" } else { "failed" }, format!(
            "{name} couldn't start: {reason}. It was deleted again.{}",
            if memory { " Ask for less memoryGB (4 is enough for most tests), or ask the person to free memory." } else { "" })));
    }
    finish_create(run, args, &name, pause).inspect_err(|_| remove_disposable(run, &name))
}

fn finish_create(run: &Run, args: &Value, name: &str, pause: &dyn Fn(Duration)) -> Result<Reply> {
    // Errors that retrying can't fix: someone else has it, the session ended, or it isn't allowed.
    let fatal = |e: &BrokerError| matches!(e.code.as_str(), "unavailable" | "taken" | "not_taken" | "killed" | "denied" | "bad_request");
    // PowerShell Direct answers once Windows has started: retry the install for a few minutes. The same failure three
    // times in a row won't change by waiting (lab 053: an access error repeated for 5 minutes).
    let end = Instant::now() + Duration::from_secs(300);
    let mut last = (String::new(), 0);
    loop {
        match run("Install-GpuVMAgent", json!({ "Name": name }), true) {
            Ok(_) => break,
            Err(e) if Instant::now() < end && !fatal(&e) && !(last.0 == e.message && last.1 >= 2) => {
                last = if last.0 == e.message { (last.0, last.1 + 1) } else { (e.message.clone(), 1) };
                super::server::log(&format!("installing the agent in {name}: {} (retrying)", e.message));
                pause(Duration::from_secs(10));
            }
            Err(e) => return Err(BrokerError::new(&e.code, format!("{name} was created but its agent couldn't be installed, so it was deleted again: {}", e.message))),
        }
    }
    // The claim becomes the lock once the agent inside has registered (it may restart Windows first).
    let end = Instant::now() + Duration::from_secs(300);
    loop {
        match run("Lock-GpuVMAgent", json!({ "Name": name, "Connection": s(args, "connection"), "Task": s(args, "task") }), false) {
            Ok(_) => break,
            Err(e) if Instant::now() < end && !fatal(&e) => pause(Duration::from_secs(3)),
            Err(e) => return Err(BrokerError::new(&e.code, format!("{name} was created but couldn't be taken, so it was deleted again: {}", e.message))),
        }
    }
    Ok(Reply::of(json!({ "name": name })))
}

/// Deletes one disposable machine now: turned off, then `Remove-GpuVMDisposable -Name` (that machine, without the
/// grace a never-started disposable gets). An older module without `-Name` gets the general sweep instead.
/// (`Remove-GpuVM -DeleteDisk` isn't used: for an agent session it needs a `delete` approval and a UAC prompt.)
pub fn remove_disposable(run: &Run, name: &str) {
    let _ = run("Invoke-GpuVMPower", json!({ "Name": name, "Action": "TurnOff" }), true);
    if let Err(e) = run("Remove-GpuVMDisposable", json!({ "Name": name }), true) {
        if e.message.contains("Argument not allowed") {
            super::server::log(&format!("this GpuVM has no Remove-GpuVMDisposable -Name: {name} goes with the next sweep"));
            let _ = run("Remove-GpuVMDisposable", json!({}), true);
        } else {
            super::server::log(&format!("couldn't delete the disposable {name}: {}", e.message));
        }
    }
}

/// Shows the machine in GpuVM's viewer: `gpuvm.exe --view <name>`, which the running app receives (single
/// instance) or starts with. The app decides what to show; nothing here is trusted beyond a machine name.
fn open_viewer(name: &str) -> Result<Reply> {
    if name.is_empty() || name.len() > 40 || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err(BrokerError::new("bad_request", "That isn't a machine name."));
    }
    let exe = std::env::current_exe().map_err(|e| BrokerError::new("internal", e.to_string()))?;
    std::process::Command::new(exe).args(["--view", name]).spawn()
        .map_err(|e| BrokerError::new("internal", format!("Couldn't open GpuVM: {e}")))?;
    Ok(Reply::of(json!({ "open": true })))
}

/// `{ok:false, error:{code,message}}` objects, or a thrown message: `"code: message"` or plain text.
pub fn parse_error(error: &Value) -> BrokerError {
    if let Some(code) = error["code"].as_str() {
        return BrokerError::new(code, error["message"].as_str().unwrap_or(""));
    }
    let text = error.as_str().unwrap_or("GpuVM didn't say why.");
    if let Some((code, message)) = text.split_once(": ") {
        if !code.is_empty() && code.len() <= 32 && code.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
            return BrokerError::new(code, message);
        }
    }
    BrokerError::new("failed", text)
}

/// A broker object may carry `{ok:false,error}` or a base64 `blob`; take them out of the data.
pub fn unwrap_reply(mut data: Value) -> Result<Reply> {
    if data["ok"] == false {
        return Err(parse_error(&data["error"]));
    }
    let mut blob = None;
    if let Some(map) = data.as_object_mut() {
        if let Some(Value::String(b64)) = map.remove("blob") {
            use base64::Engine;
            blob = Some(base64::engine::general_purpose::STANDARD.decode(b64.as_bytes())
                .map_err(|_| BrokerError::new("internal", "The data from GpuVM was damaged."))?);
            if let Some(Value::String(format)) = map.remove("blobFormat") {
                if let Some(Value::Object(result)) = map.get_mut("result") {
                    result.entry("format").or_insert(json!(format));
                }
            }
        }
        if map.contains_key("ok") && map.contains_key("result") {
            return Ok(Reply { data: map.remove("result").unwrap_or(Value::Null), blob });
        }
    }
    Ok(Reply { data, blob })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn errors_and_blobs_are_unwrapped() {
        assert_eq!(parse_error(&json!("paused: The person took control.")).code, "paused");
        assert_eq!(parse_error(&json!("Something: else")).code, "failed");
        assert_eq!(parse_error(&json!({"code": "blocked_elevated", "message": "x"})).code, "blocked_elevated");
        let r = unwrap_reply(json!({"ok": true, "result": {"w": 2}, "blob": "AAEC", "blobFormat": "webp", "ms": 3})).unwrap();
        assert_eq!(r.data["w"], 2);
        assert_eq!(r.data["format"], "webp");
        assert_eq!(r.blob.unwrap(), vec![0, 1, 2]);
        assert!(unwrap_reply(json!({"ok": false, "error": {"code": "timeout", "message": "t"}})).is_err());
    }

    /// A scripted service: answers per command, records every call.
    type Calls = std::sync::Arc<Mutex<Vec<(String, Value)>>>;
    type Answer = Result<(Reply, Vec<String>)>;

    fn script(answer: impl Fn(&str, &Value) -> Answer) -> (Calls, impl Fn(&str, Value, bool) -> Answer) {
        let calls = std::sync::Arc::new(Mutex::new(Vec::new()));
        let log = calls.clone();
        (calls, move |cmd: &str, args: Value, _long: bool| {
            log.lock().unwrap().push((cmd.to_string(), args.clone()));
            answer(cmd, &args)
        })
    }

    fn names(calls: &Mutex<Vec<(String, Value)>>) -> Vec<String> {
        calls.lock().unwrap().iter().map(|c| c.0.clone()).collect()
    }

    const NO_PAUSE: &dyn Fn(Duration) = &|_| {};

    #[test]
    fn create_stops_when_the_machine_cannot_turn_on() {
        let (calls, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"] })), vec![
                "The VM was created but couldn't turn on: The VM needs 8.3 GB free and there are 3.6 GB. Close programs or give it less memory.".into()])),
            _ => Ok((Reply::default(), vec![])),
        });
        let e = create_disposable(&run, &json!({ "template": "agent-tpl", "name": "x1", "connection": "c1" }), NO_PAUSE).unwrap_err();
        assert_eq!(e.code, "no_memory");
        assert!(e.message.contains("x1 couldn't start: The VM needs 8.3 GB free and there are 3.6 GB") && e.message.contains("deleted again"), "{}", e.message);
        assert_eq!(names(&calls), ["New-GpuVM", "Invoke-GpuVMPower", "Remove-GpuVMDisposable"]);
        assert_eq!(calls.lock().unwrap()[2].1, json!({ "Name": "x1" }));
        assert_eq!(calls.lock().unwrap()[0].1["Connection"], "c1");
    }

    #[test]
    fn create_reads_the_structured_start_state() {
        let (calls, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"], "started": false, "startError": "The VM needs 8.3 GB free and there are 3.6 GB.",
                "neededGB": 8.3, "freeGB": 3.6 })), vec![])),
            _ => Ok((Reply::default(), vec![])),
        });
        let e = create_disposable(&run, &json!({ "template": "agent-tpl", "name": "x2" }), NO_PAUSE).unwrap_err();
        assert_eq!(e.code, "no_memory");
        assert!(e.message.starts_with("x2 couldn't start: it needs 8.3 GB of memory free and there are 3.6 GB. It was deleted again."), "{}", e.message);
        assert_eq!(names(&calls), ["New-GpuVM", "Invoke-GpuVMPower", "Remove-GpuVMDisposable"]);
        assert_eq!(calls.lock().unwrap()[2].1, json!({ "Name": "x2" }));
        // Another reason, without figures.
        let (_, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"], "started": false, "startError": "Hyper-V refused." })), vec![])),
            _ => Ok((Reply::default(), vec![])),
        });
        let e = create_disposable(&run, &json!({ "template": "t", "name": "x3" }), NO_PAUSE).unwrap_err();
        assert_eq!((e.code.as_str(), e.message.as_str()), ("failed", "x3 couldn't start: Hyper-V refused. It was deleted again."));
        // Started: goes on to install and take.
        let (calls, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"], "started": true })), vec![])),
            _ => Ok((Reply::default(), vec![])),
        });
        create_disposable(&run, &json!({ "template": "t", "name": "x4" }), NO_PAUSE).unwrap();
        assert_eq!(names(&calls), ["New-GpuVM", "Install-GpuVMAgent", "Lock-GpuVMAgent"]);
    }

    #[test]
    fn create_gives_up_on_a_repeated_install_error_and_deletes() {
        let (calls, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"] })), vec![])),
            "Install-GpuVMAgent" => Err(BrokerError::new("failed", "Access to the path is denied.")),
            _ => Ok((Reply::default(), vec![])),
        });
        let e = create_disposable(&run, &json!({ "template": "agent-tpl" }), NO_PAUSE).unwrap_err();
        assert!(e.message.contains("couldn't be installed, so it was deleted again"));
        let n = names(&calls);
        assert_eq!(n.iter().filter(|c| *c == "Install-GpuVMAgent").count(), 3);
        assert_eq!(&n[n.len() - 2..], ["Invoke-GpuVMPower", "Remove-GpuVMDisposable"]);
        // A generated name: the template and 6 hex digits, valid for New-GpuVM.
        let name = calls.lock().unwrap()[0].1["Name"].as_str().unwrap().to_string();
        assert!(name.starts_with("agent-tpl-") && name.len() == 16, "{name}");
    }

    #[test]
    fn create_succeeds_and_removal_falls_back_on_old_modules() {
        let (calls, run) = script(|cmd, args| match cmd {
            "New-GpuVM" => Ok((Reply::of(json!({ "name": args["Name"] })), vec!["Couldn't remember the ISO: x".into()])),
            _ => Ok((Reply::default(), vec![])),
        });
        let r = create_disposable(&run, &json!({ "template": "t", "name": "ok1", "memoryGB": 4, "task": "test" }), NO_PAUSE).unwrap();
        assert_eq!(r.data["name"], "ok1");
        assert_eq!(names(&calls), ["New-GpuVM", "Install-GpuVMAgent", "Lock-GpuVMAgent"]);
        assert_eq!(calls.lock().unwrap()[0].1["Override"], json!({ "vm": { "memoryGB": 4 } }));
        assert_eq!(calls.lock().unwrap()[2].1["Task"], "test");

        let (calls, run) = script(|cmd, args| match cmd {
            "Remove-GpuVMDisposable" if args.get("Name").is_some() => Err(BrokerError::new("failed", "Argument not allowed: Name")),
            _ => Ok((Reply::default(), vec![])),
        });
        remove_disposable(&run, "old1");
        assert_eq!(names(&calls), ["Invoke-GpuVMPower", "Remove-GpuVMDisposable", "Remove-GpuVMDisposable"]);
        assert_eq!(calls.lock().unwrap()[2].1, json!({}));
    }

    #[test]
    fn requests_drop_nulls_and_lists_normalize() {
        let b = PipeBroker::new();
        let r = b.request("Invoke-GpuVMAgent", json!({"Name": "vm", "Blob": null, "Params": {}}));
        assert_eq!(r["args"], json!({"Name": "vm", "Params": {}}));
        assert_eq!(list(json!({"a": 1})).len(), 1);
        assert_eq!(list(Value::Null).len(), 0);
        assert!(open_viewer("bad name;").is_err());
    }
}
