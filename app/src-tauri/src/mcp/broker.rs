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

    fn run(conn: &mut crate::backend::Conn, request: &Value) -> Result<Reply> {
        let event = conn.call(request, |_| {}).map_err(|e| BrokerError::new("unavailable", e))?;
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
        unwrap_reply(data)
    }

    /// One command on the shared connection (the service answers one request at a time per connection).
    fn cmd(&self, cmd: &str, args: Value) -> Result<Reply> {
        let request = self.request(cmd, args);
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

    /// One command on a connection of its own (minutes-long module work), so other calls go on meanwhile.
    fn cmd_long(&self, cmd: &str, args: Value) -> Result<Reply> {
        let request = self.request(cmd, args);
        let mut conn = crate::backend::connect().map_err(|e| BrokerError::new("unavailable", e))?;
        Self::run(&mut conn, &request)
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

    /// A disposable machine from a template: created and started, its agent installed (each machine gets its own
    /// secret, so a template's copy can't be used as is), and taken by this connection.
    fn create(&self, args: &Value) -> Result<Reply> {
        let mut new = json!({ "Template": s(args, "template"), "Name": s(args, "name"), "Profile": s(args, "profile"), "Disposable": true });
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
        let created = self.cmd_long("New-GpuVM", new)?;
        let name = created.data["name"].as_str().or(args["name"].as_str())
            .ok_or_else(|| BrokerError::new("internal", "GpuVM didn't say which machine it created."))?.to_string();
        // PowerShell Direct answers once Windows has started: retry the install for a few minutes.
        let end = Instant::now() + Duration::from_secs(300);
        loop {
            match self.cmd_long("Install-GpuVMAgent", json!({ "Name": name })) {
                Ok(_) => break,
                Err(e) if Instant::now() < end && e.code != "unavailable" => {
                    super::server::log(&format!("installing the agent in {name}: {} (retrying)", e.message));
                    std::thread::sleep(Duration::from_secs(10));
                }
                Err(e) => return Err(BrokerError::new(&e.code, format!("{name} was created but its agent couldn't be installed: {}", e.message))),
            }
        }
        self.cmd("Lock-GpuVMAgent", json!({ "Name": name, "Connection": s(args, "connection"), "Task": s(args, "task") }))?;
        Ok(Reply::of(json!({ "name": name })))
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
            "machine.create" => self.create(&args),
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
                // A disposable machine is deleted once it is off: turn it off, then sweep.
                self.cmd_long("Invoke-GpuVMPower", json!({ "Name": name, "Action": "TurnOff" }))?;
                let _ = self.cmd_long("Remove-GpuVMDisposable", json!({}));
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
