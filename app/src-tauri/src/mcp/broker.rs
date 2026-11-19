//! What the MCP server asks of GpuVM, as logical operations. The real broker lives in the elevated service
//! (module cmdlets reached over the `\\.\pipe\gpuvm` pipe); `fake.rs` implements the same operations in memory
//! for tests and for `gpuvm.exe --mcp --fake`. Changing a cmdlet's name only touches `CMDLETS` below.
//!
//! Policy (who owns a machine, pause, budgets, kill switch, approvals) is enforced by the service; the MCP side
//! checks too, but it works for a model, so it is never the only guard.

use serde_json::{json, Value};
use std::sync::Mutex;

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

/// Logical operations (`op`) and their arguments:
/// - `client.connect {client:{name,version,protocol,pid}}` → `{connection, settings:{elicitation,maxSteps,maxMinutes}}`
/// - `client.disconnect {connection}`
/// - `templates.list {}` → `{templates:[{name,description,os}], profiles:[{name,cpu,memoryGB}]}`
/// - `machine.create {connection, template, name?, cpu?, memoryGB?}` → `{name}` (disposable, started)
/// - `machines.list {connection}` → `[{name,state,disposable,template,screen,signedIn,takenBy,paused}]`
/// - `machine.take / machine.release {connection, name}`
/// - `agent.invoke {connection, name, method, params}` → guest result (+ blob)
/// - `file.send {connection, name, hostPath}` → `{path}` (in the VM's Received folder)
/// - `offer.create {connection, name, path, note}` → `{offerId}`; `offer.get {connection, offerId}` → `{state, hostPath?}`
/// - `restore.create {connection, name, label?}` → `{name}`; `restore.revert {connection, name, point}`
/// - `machine.destroy {connection, name}`
/// - `viewer.open {connection, name}`
/// - `human.request {connection, name, message}` → `{requestId}` (pauses the agent on that machine)
pub trait Broker: Send + Sync {
    fn call(&self, op: &str, args: Value) -> Result<Reply>;
    /// Operations that can take minutes (creating a machine) get their own connection where that matters.
    fn call_long(&self, op: &str, args: Value) -> Result<Reply> {
        self.call(op, args)
    }
}

/// Logical operation → module cmdlet (names agreed with the broker session; see side-session notes).
pub const CMDLETS: &[(&str, &str)] = &[
    ("client.connect", "Connect-GpuVMAgentClient"),
    ("client.disconnect", "Disconnect-GpuVMAgentClient"),
    ("templates.list", "Get-GpuVMAgentTemplate"),
    ("machine.create", "New-GpuVMAgentMachine"),
    ("machines.list", "Get-GpuVMAgent"),
    ("machine.take", "Request-GpuVMAgentMachine"),
    ("machine.release", "Release-GpuVMAgentMachine"),
    ("agent.invoke", "Invoke-GpuVMAgent"),
    ("file.send", "Send-GpuVMAgentFile"),
    ("offer.create", "New-GpuVMAgentOffer"),
    ("offer.get", "Get-GpuVMAgentOffer"),
    ("restore.create", "New-GpuVMAgentRestorePoint"),
    ("restore.revert", "Restore-GpuVMAgentRestorePoint"),
    ("machine.destroy", "Remove-GpuVMAgentMachine"),
    ("human.request", "Request-GpuVMAgentHuman"),
];

/// Logical argument name → cmdlet parameter name (PowerShell style; the bridge matches names exactly).
fn parameter(name: &str) -> String {
    match name {
        "hostPath" => "HostPath".into(),
        "memoryGB" => "MemoryGB".into(),
        "offerId" => "OfferId".into(),
        _ => {
            let mut c = name.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        }
    }
}

/// The GpuVM service over its pipe, as the installed gpuvm.exe (the only program it trusts).
pub struct PipeBroker {
    conn: Mutex<Option<crate::backend::Conn>>,
    next: std::sync::atomic::AtomicU64,
}

impl PipeBroker {
    pub fn new() -> Self {
        PipeBroker { conn: Mutex::new(None), next: std::sync::atomic::AtomicU64::new(1) }
    }

    fn request(&self, op: &str, args: Value) -> Result<Value> {
        let cmd = CMDLETS.iter().find(|(o, _)| *o == op).map(|(_, c)| *c)
            .ok_or_else(|| BrokerError::new("internal", format!("Unknown operation {op}.")))?;
        let mut cmd_args = serde_json::Map::new();
        if let Value::Object(map) = args {
            for (k, v) in map {
                if !v.is_null() {
                    cmd_args.insert(parameter(&k), v);
                }
            }
        }
        let id = format!("mcp-{}", self.next.fetch_add(1, std::sync::atomic::Ordering::Relaxed));
        Ok(json!({ "id": id, "cmd": cmd, "args": Value::Object(cmd_args) }))
    }

    fn run(conn: &mut crate::backend::Conn, request: &Value) -> Result<Reply> {
        let event = conn.call(request, |_| {}).map_err(|e| BrokerError::new("unavailable", e))?;
        if event["ok"] != true {
            return Err(parse_error(&event["error"]));
        }
        // The bridge sends a list of everything the cmdlet wrote; the broker's cmdlets write one object.
        let data = match &event["data"] {
            Value::Array(items) if items.len() == 1 => items[0].clone(),
            other => other.clone(),
        };
        unwrap_reply(data)
    }
}

impl Default for PipeBroker {
    fn default() -> Self {
        Self::new()
    }
}

impl Broker for PipeBroker {
    fn call(&self, op: &str, args: Value) -> Result<Reply> {
        if op == "viewer.open" {
            return open_viewer(args["name"].as_str().unwrap_or(""));
        }
        let request = self.request(op, args)?;
        let mut guard = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Some(crate::backend::connect().map_err(|e| BrokerError::new("unavailable", e))?);
        }
        let result = Self::run(guard.as_mut().unwrap(), &request);
        // A broken connection is opened again on the next call.
        if matches!(&result, Err(e) if e.code == "unavailable") {
            *guard = None;
        }
        result
    }

    fn call_long(&self, op: &str, args: Value) -> Result<Reply> {
        let request = self.request(op, args)?;
        let mut conn = crate::backend::connect().map_err(|e| BrokerError::new("unavailable", e))?;
        Self::run(&mut conn, &request)
    }
}

/// Shows the machine in GpuVM's viewer: `gpuvm.exe --view <name>`, which the running app receives (single
/// instance) or starts with. The app decides what to show; nothing here is trusted beyond a machine name.
fn open_viewer(name: &str) -> Result<Reply> {
    if name.is_empty() || name.len() > 64 || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ' ') {
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
                .map_err(|_| BrokerError::new("internal", "The picture from GpuVM was damaged."))?);
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
        let r = unwrap_reply(json!({"ok": true, "result": {"w": 2}, "blob": "AAEC"})).unwrap();
        assert_eq!(r.data["w"], 2);
        assert_eq!(r.blob.unwrap(), vec![0, 1, 2]);
        assert!(unwrap_reply(json!({"ok": false, "error": {"code": "timeout", "message": "t"}})).is_err());
    }

    #[test]
    fn requests_use_exact_parameter_names() {
        let b = PipeBroker::new();
        let r = b.request("agent.invoke", json!({"connection": "c1", "name": "vm", "method": "screen.capture", "params": {}, "skip": null})).unwrap();
        assert_eq!(r["cmd"], "Invoke-GpuVMAgent");
        assert_eq!(r["args"], json!({"Connection": "c1", "Name": "vm", "Method": "screen.capture", "Params": {}}));
        assert!(b.request("nope", json!({})).is_err());
        let s = b.request("file.send", json!({"hostPath": "C:\\x"})).unwrap();
        assert!(s["args"]["HostPath"].is_string());
    }
}
