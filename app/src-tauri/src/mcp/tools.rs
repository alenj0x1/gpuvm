//! The tools, in the four planes of Windows 365 for Agents: create (templates, disposable machines), get
//! (machines to take and release), do (screen, input, UI Automation, commands, files, restore points) and
//! see/take control (viewer, asking the person). Errors are tool results with `isError` and a plain English
//! sentence the model can act on.

use super::broker::{Broker, BrokerError, Reply};
use super::geometry::{self, Shot};
use super::server::Client;
use base64::Engine;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Text sent back in one result (Claude Code warns at 10k tokens and stops at 25k by default).
pub const MAX_TEXT: usize = 20_000;
const MAX_TYPE: usize = 5_000;
const MAX_WRITE: usize = 10 << 20;
/// Bytes asked for by read_file (text beyond what a model can use is cut anyway).
const READ_MAX: u64 = 4 << 20;
const PROFILE: &str = r"C:\Users\agent\";
/// The Outbox, relative to the agent's home (lowercase, for comparisons).
const OUTBOX: &str = r"desktop\outbox\";
const APPROVAL_TTL: Duration = Duration::from_secs(600);
/// Tools that ask the person through the client first when the connection's "approvals" setting is on.
const CONFIRM: &[&str] = &["run", "write_file", "send_file"];

#[derive(Clone, Debug)]
pub struct Settings {
    pub elicitation: bool,
    pub max_steps: u64,
    pub max_minutes: u64,
    /// How long a request to the person (approval) stays open.
    pub approval_timeout: u64,
}

#[derive(Default)]
struct MachineUse {
    steps: u64,
    since: Option<Instant>,
}

struct Pending {
    tool: String,
    args: String,
    created: Instant,
}

/// Everything one MCP connection remembers.
pub struct Ctx {
    broker: Arc<dyn Broker>,
    connection: Mutex<Option<(String, Settings)>>,
    client: Mutex<Option<Client>>,
    killed: std::sync::atomic::AtomicBool,
    shots: Mutex<Vec<Shot>>,
    next_shot: std::sync::atomic::AtomicU32,
    screens: Mutex<HashMap<String, (u32, u32)>>,
    uses: Mutex<HashMap<String, MachineUse>>,
    pending: Mutex<HashMap<String, Pending>>,
    /// This connection's pending request_human per machine (lowercase name → request id), for cancel_request.
    human_requests: Mutex<HashMap<String, String>>,
    /// Poll interval while waiting (machine ready, person, offers); short in tests.
    pub poll_ms: std::sync::atomic::AtomicU64,
}

impl Ctx {
    pub fn new(broker: Arc<dyn Broker>) -> Self {
        Ctx {
            broker,
            connection: Mutex::new(None),
            client: Mutex::new(None),
            killed: Default::default(),
            shots: Mutex::new(Vec::new()),
            next_shot: std::sync::atomic::AtomicU32::new(1),
            screens: Mutex::new(HashMap::new()),
            uses: Mutex::new(HashMap::new()),
            pending: Mutex::new(HashMap::new()),
            human_requests: Mutex::new(HashMap::new()),
            poll_ms: std::sync::atomic::AtomicU64::new(1000),
        }
    }

    /// Registers the client with GpuVM (shown in the app) the first time it is known.
    pub fn identify(&self, client: &Client) {
        let mut c = self.client.lock().unwrap();
        if c.is_none() {
            *c = Some(client.clone());
            drop(c);
            let _ = self.connection();
        }
    }

    fn connection(&self) -> Result<(String, Settings), String> {
        let mut guard = self.connection.lock().unwrap();
        if let Some(c) = guard.as_ref() {
            return Ok(c.clone());
        }
        let client = self.client.lock().unwrap().clone().unwrap_or_default();
        let reply = self.broker.call("client.connect", json!({ "client": {
            "name": client.name, "version": client.version, "protocol": client.protocol, "pid": std::process::id() } }))
            .map_err(|e| explain("", &e))?;
        let s = &reply.data["settings"];
        let settings = Settings {
            elicitation: s["elicitation"].as_bool().unwrap_or(false),
            max_steps: s["maxSteps"].as_u64().unwrap_or(500),
            max_minutes: s["maxMinutes"].as_u64().unwrap_or(60),
            approval_timeout: s["approvalTimeoutSec"].as_u64().unwrap_or(300),
        };
        let id = reply.data["connection"].as_str().unwrap_or("").to_string();
        if id.is_empty() {
            return Err("GpuVM didn't accept the connection.".into());
        }
        super::server::log(&format!("connected to GpuVM as {id} ({} {})", client.name, client.version));
        *guard = Some((id.clone(), settings.clone()));
        Ok((id, settings))
    }

    pub fn disconnect(&self) {
        if let Some((id, _)) = self.connection.lock().unwrap().take() {
            let _ = self.broker.call("client.disconnect", json!({ "connection": id }));
        }
    }

    fn latest_shot(&self, machine: &str, id: Option<u32>) -> Option<Shot> {
        let shots = self.shots.lock().unwrap();
        match id {
            Some(id) => shots.iter().rev().find(|s| s.id == id && s.machine == machine).cloned(),
            None => shots.iter().rev().find(|s| s.machine == machine && !s.zoom).cloned(),
        }
    }

    fn add_shot(&self, mut shot: Shot) -> Shot {
        shot.id = self.next_shot.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut shots = self.shots.lock().unwrap();
        shots.push(shot.clone());
        // Keep the last few per connection: older ids stop working, with a clear message.
        if shots.len() > 64 {
            shots.remove(0);
        }
        shot
    }

    fn forget_machine(&self, machine: &str) {
        self.shots.lock().unwrap().retain(|s| s.machine != machine);
        self.screens.lock().unwrap().remove(machine);
        self.uses.lock().unwrap().remove(machine);
    }
}

/// One tool call: arguments plus what the server can do for it.
pub struct Call<'a> {
    pub client: &'a Client,
    pub args: &'a Value,
    pub input_responses: Option<&'a Value>,
    pub request_state: Option<&'a str>,
    pub cancelled: &'a dyn Fn() -> bool,
    /// Legacy elicitation (asks the client); None when it can't.
    pub ask_legacy: &'a dyn Fn(&str) -> Option<bool>,
}

type Out = Result<Value, String>;

fn text(t: impl Into<String>) -> Value {
    json!({ "content": [{ "type": "text", "text": cap(t.into()) }] })
}

fn tool_error(message: impl Into<String>) -> Value {
    json!({ "content": [{ "type": "text", "text": message.into() }], "isError": true })
}

/// Keeps the beginning and the end of a long text.
pub fn cap(t: String) -> String {
    cap_to(t, MAX_TEXT)
}

fn cap_to(t: String, max: usize) -> String {
    if t.chars().count() <= max {
        return t;
    }
    let head: String = t.chars().take(max * 3 / 4).collect();
    let total = t.chars().count();
    let tail: String = t.chars().skip(total - max / 4).collect();
    format!("{head}\n… [{} characters cut] …\n{tail}", total - head.chars().count() - tail.chars().count())
}

/// A broker or guest error as a sentence the model can act on.
pub fn explain(machine: &str, e: &BrokerError) -> String {
    let m = if machine.is_empty() { "the machine".to_string() } else { machine.to_string() };
    match e.code.as_str() {
        "blocked_elevated" => "An administrator window is in front; ask the person with request_human.".into(),
        "secure_desktop" => format!("{m} is showing a secure screen (a UAC prompt or the lock screen) that only the person can use; ask them with request_human."),
        "no_foreground" => "No window has the focus; click the window you want first, then try again.".into(),
        "not_signed_in" => format!("Nobody is signed in to {m} yet; wait a moment (take_machine waits for it) and try again."),
        "too_large" => "That is too large to send; ask for less (a smaller region, fewer nodes, a shorter output).".into(),
        "timeout" => "It didn't finish in time; try again, or with a longer timeout.".into(),
        "cancelled" => "The request was cancelled.".into(),
        "busy" => format!("{m} is busy with other requests; try again in a moment."),
        "not_found" => if e.message.is_empty() { "Not found.".into() } else { e.message.clone() },
        "denied" => format!("Not allowed: {}", if e.message.is_empty() { "the agent can only use its own home folder." } else { &e.message }),
        "bad_request" => format!("GpuVM refused the request: {}", e.message),
        "paused" => format!("The person took control of {m}. Wait until they hand it back (\"Return to agent\" in GpuVM), then take a fresh screenshot before acting."),
        "killed" => "The person stopped this agent connection from GpuVM. Stop working and tell the user.".into(),
        "budget" => format!("The step or time budget for {m} is used up. Ask the person to raise it in GpuVM's Agents settings, or stop."),
        "not_taken" => format!("Take {m} first with take_machine."),
        "taken" => format!("{m} is being used by another agent connection."),
        "off" => format!("{m} is off; take_machine starts it."),
        "no_agent" => format!("{m} has no GpuVM agent installed; only machines with the agent can be used (create one from a template)."),
        "needs_approval" => format!("Waiting for the person to approve this in GpuVM: {}", e.message),
        "unavailable" => format!("GpuVM isn't reachable: {} Ask the person to open GpuVM.", e.message),
        _ => if e.message.is_empty() { format!("GpuVM error ({}).", e.code) } else { e.message.clone() },
    }
}

// ---------------------------------------------------------------- definitions

fn schema(props: Value, required: &[&str]) -> Value {
    json!({ "type": "object", "properties": props, "required": required, "additionalProperties": false })
}

fn machine_prop() -> Value {
    json!({ "type": "string", "description": "Machine name (from list_machines or create_disposable)." })
}

fn coord(desc: &str) -> Value {
    json!({ "type": "number", "minimum": 0, "description": desc })
}

fn shot_prop() -> Value {
    json!({ "type": "integer", "description": "Screenshot id whose pixels the coordinates refer to (default: the latest full screenshot of this machine)." })
}

fn after_prop() -> Value {
    json!({ "type": "boolean", "description": "Return a fresh screenshot after the action (saves a call)." })
}

fn ann(title: &str, read_only: bool, destructive: bool, idempotent: bool, open_world: bool) -> Value {
    json!({ "title": title, "readOnlyHint": read_only, "destructiveHint": destructive, "idempotentHint": idempotent, "openWorldHint": open_world })
}

fn tool(name: &str, description: &str, input: Value, annotations: Value) -> Value {
    json!({ "name": name, "description": description, "inputSchema": input, "annotations": annotations })
}

/// The tool list, in a fixed order (clients cache it).
pub fn definitions() -> Vec<Value> {
    let m = machine_prop;
    let action_item = json!({ "type": "object", "description": "One action: {type:'click',x,y,button?,count?,modifiers?} | {type:'move',x,y} | {type:'drag',x,y,toX,toY} | {type:'scroll',x,y,dx?,dy?} | {type:'type',text} | {type:'key',keys,repeat?} | {type:'wait',ms}",
        "properties": { "type": { "type": "string", "enum": ["click", "move", "drag", "scroll", "type", "key", "wait"] } }, "required": ["type"] });
    vec![
        // create
        tool("list_templates", "List the templates (ready Windows images with the GpuVM agent) and size profiles a disposable machine can be created from.",
            schema(json!({}), &[]), ann("List templates", true, false, true, false)),
        tool("create_disposable", "Create a disposable Windows machine from a template, start it and take it (it is deleted when it shuts down). Waits until the agent inside is ready. Takes a few minutes.",
            schema(json!({ "template": { "type": "string" }, "name": { "type": "string", "description": "Optional name (letters, digits, -)." },
                "profile": { "type": "string", "description": "Size profile from list_templates." },
                "cpu": { "type": "integer", "minimum": 1, "maximum": 16 }, "memoryGB": { "type": "integer", "minimum": 2, "maximum": 64 }, "task": { "type": "string", "description": "What you are going to do with it, in a few words (shown to the person in GpuVM)." } }), &["template"]),
            ann("Create disposable machine", false, false, false, false)),
        // get
        tool("list_machines", "List GpuVM machines with their state, whether an agent can use them, who has them and whether the person paused the agent.",
            schema(json!({}), &[]), ann("List machines", true, false, true, false)),
        tool("take_machine", "Take a machine for this connection (one connection per machine), starting it if needed, and wait until its agent is ready.",
            schema(json!({ "machine": m(), "waitSeconds": { "type": "integer", "minimum": 0, "maximum": 900, "description": "Default 180." }, "task": { "type": "string", "description": "What you are going to do with it, in a few words (shown to the person in GpuVM)." } }), &["machine"]),
            ann("Take machine", false, false, true, false)),
        tool("release_machine", "Release a machine you took so the person or another agent can use it.",
            schema(json!({ "machine": m() }), &["machine"]), ann("Release machine", false, false, true, false)),
        // do: screen
        tool("screenshot", "Capture the machine's screen as an image. Use the returned image's pixels for every action. `zoom` = [x, y, width, height] in the pixels of a previous screenshot shows that part at higher detail (zoom images are for looking; actions still use the latest full screenshot unless you pass its id).",
            schema(json!({ "machine": m(), "maxWidth": { "type": "integer", "minimum": 64, "maximum": 2576, "description": "Default 1280." },
                "maxHeight": { "type": "integer", "minimum": 64, "maximum": 2576, "description": "Default 800." },
                "zoom": { "type": "array", "items": { "type": "number" }, "minItems": 4, "maxItems": 4 },
                "screenshot": shot_prop(), "format": { "type": "string", "enum": ["webp", "png"] } }), &["machine"]),
            ann("Screenshot", true, false, false, false)),
        // do: input
        tool("click", "Click at (x, y) in screenshot pixels.",
            schema(json!({ "machine": m(), "x": coord("X in screenshot pixels."), "y": coord("Y in screenshot pixels."),
                "button": { "type": "string", "enum": ["left", "right", "middle"] }, "count": { "type": "integer", "minimum": 1, "maximum": 3 },
                "modifiers": { "type": "string", "description": "e.g. 'ctrl' or 'shift+alt'." }, "screenshot": shot_prop(), "screenshotAfter": after_prop() }), &["machine", "x", "y"]),
            ann("Click", false, false, false, false)),
        tool("type", "Type text into the focused window (as keystrokes, any characters).",
            schema(json!({ "machine": m(), "text": { "type": "string", "maxLength": MAX_TYPE }, "screenshotAfter": after_prop() }), &["machine", "text"]),
            ann("Type text", false, false, false, false)),
        tool("key", "Press a key or combination, e.g. 'enter', 'ctrl+s', 'alt+f4', 'win+r', 'ctrl+shift+end'.",
            schema(json!({ "machine": m(), "keys": { "type": "string" }, "repeat": { "type": "integer", "minimum": 1, "maximum": 50 }, "screenshotAfter": after_prop() }), &["machine", "keys"]),
            ann("Press keys", false, false, false, false)),
        tool("scroll", "Scroll at (x, y): dy > 0 scrolls down, dx > 0 right, in wheel notches.",
            schema(json!({ "machine": m(), "x": coord("X in screenshot pixels."), "y": coord("Y in screenshot pixels."),
                "dx": { "type": "integer", "minimum": -50, "maximum": 50 }, "dy": { "type": "integer", "minimum": -50, "maximum": 50 },
                "screenshot": shot_prop(), "screenshotAfter": after_prop() }), &["machine", "x", "y"]),
            ann("Scroll", false, false, false, false)),
        tool("drag", "Drag with the left button from (x, y) to (toX, toY), in screenshot pixels.",
            schema(json!({ "machine": m(), "x": coord("Start X."), "y": coord("Start Y."), "toX": coord("End X."), "toY": coord("End Y."),
                "screenshot": shot_prop(), "screenshotAfter": after_prop() }), &["machine", "x", "y", "toX", "toY"]),
            ann("Drag", false, false, false, false)),
        tool("act", "Run several input actions in order, stopping at the first error (coordinates in screenshot pixels).",
            schema(json!({ "machine": m(), "actions": { "type": "array", "items": action_item, "minItems": 1, "maxItems": 50 },
                "screenshot": shot_prop(), "screenshotAfter": after_prop() }), &["machine", "actions"]),
            ann("Act", false, false, false, false)),
        // do: UI Automation
        tool("ui_tree", "List the controls of the window in front (UI Automation): id, role, name, box and centre in the pixels of the latest screenshot. Faster and more exact than reading the picture for standard controls.",
            schema(json!({ "machine": m(), "maxNodes": { "type": "integer", "minimum": 1, "maximum": 1000, "description": "Default 150." },
                "interactiveOnly": { "type": "boolean", "description": "Default true." } }), &["machine"]),
            ann("UI tree", true, false, true, false)),
        tool("ui_invoke", "Act on a control from ui_tree by id: invoke (press), toggle, select, expand, or setValue (with value).",
            schema(json!({ "machine": m(), "id": { "type": "string" }, "action": { "type": "string", "enum": ["invoke", "toggle", "select", "expand", "setValue"] },
                "value": { "type": "string" } }), &["machine", "id", "action"]),
            ann("UI invoke", false, false, false, false)),
        // do: commands and files
        tool("run", "Run a command in the machine as the standard user `agent` (never administrator) and return its exit code and output. By default `command` is a PowerShell command line; with shell 'none' it is a program and `args` its arguments.",
            schema(json!({ "machine": m(), "command": { "type": "string" }, "shell": { "type": "string", "enum": ["powershell", "cmd", "none"] },
                "args": { "type": "array", "items": { "type": "string" } }, "cwd": { "type": "string" },
                "timeoutSeconds": { "type": "integer", "minimum": 1, "maximum": 600, "description": "Default 60." }, "stdin": { "type": "string" } }), &["machine", "command"]),
            ann("Run command", false, true, false, true)),
        tool("read_file", "Read a file in the agent's home folder in the machine (a path relative to it, like Desktop\\Received\\x.txt, or a full one): text comes back as text, images as an image.",
            schema(json!({ "machine": m(), "path": { "type": "string" } }), &["machine", "path"]),
            ann("Read file", true, false, true, false)),
        tool("write_file", "Write a file in the agent's home folder in the machine (a path relative to it, like Desktop\\Outbox\\report.md, or a full one; replaces it if it exists).",
            schema(json!({ "machine": m(), "path": { "type": "string" }, "content": { "type": "string" },
                "encoding": { "type": "string", "enum": ["utf8", "base64"], "description": "Default utf8." } }), &["machine", "path", "content"]),
            ann("Write file", false, true, true, false)),
        tool("send_file", "Copy a file from this PC into the machine's Desktop\\Received folder.",
            schema(json!({ "machine": m(), "hostPath": { "type": "string", "description": "Full path of a file on this PC." } }), &["machine", "hostPath"]),
            ann("Send file to machine", false, false, true, false)),
        tool("offer_file", "Offer a file from the machine's Desktop\\Outbox folder to the person; it reaches this PC only if they approve it in GpuVM. Optionally wait for their answer.",
            schema(json!({ "machine": m(), "path": { "type": "string", "description": "A file directly in Desktop\\Outbox, e.g. Desktop\\Outbox\\report.md." },
                "note": { "type": "string", "description": "What it is and why, shown to the person." },
                "waitSeconds": { "type": "integer", "minimum": 0, "maximum": 900, "description": "Default 0 (don't wait)." } }), &["machine", "path", "note"]),
            ann("Offer file", false, false, false, false)),
        tool("offer_status", "Whether the person approved or declined an offered file, and where it is on this PC if approved.",
            schema(json!({ "machine": m(), "offerId": { "type": "string" } }), &["machine", "offerId"]),
            ann("Offer status", true, false, true, false)),
        // do: restore points and lifetime
        tool("restore_point_create", "Save a restore point of a normal (not disposable) machine you took, to go back to later. The machine restarts for it.",
            schema(json!({ "machine": m(), "label": { "type": "string" } }), &["machine"]),
            ann("Create restore point", false, false, false, false)),
        tool("restore_point_revert", "Return a normal machine you took to a restore point (by id or label). The person must allow it in GpuVM first (this waits for them); how it is now is kept as a new restore point. The machine restarts.",
            schema(json!({ "machine": m(), "point": { "type": "string" }, "reason": { "type": "string", "description": "Why, shown to the person." } }), &["machine", "point"]),
            ann("Revert to restore point", false, true, false, false)),
        tool("destroy", "Shut down and delete a disposable machine you created; everything in it is lost. Other machines can't be destroyed by an agent.",
            schema(json!({ "machine": m(), "force": { "type": "boolean", "description": "Destroy even if an offered file is still waiting for the person (it is lost)." } }), &["machine"]),
            ann("Destroy disposable machine", false, true, true, false)),
        // see / take control
        tool("open_viewer", "Open the machine in GpuVM's viewer on this PC so the person can watch and take over.",
            schema(json!({ "machine": m() }), &["machine"]), ann("Open viewer", false, false, true, false)),
        tool("request_approval", "Ask the person, in GpuVM (not in this chat), to allow something high-risk in a machine you took: administrator rights, network access, or something else. Waits for their answer. Restore point reverts ask on their own.",
            schema(json!({ "machine": m(), "kind": { "type": "string", "enum": ["admin", "network", "other"] },
                "title": { "type": "string", "description": "Short title, e.g. 'Install GpuVM as administrator'." },
                "reason": { "type": "string", "description": "Why, in one or two sentences." },
                "waitSeconds": { "type": "integer", "minimum": 0, "maximum": 1800, "description": "Default: the person's approval timeout." } }), &["machine", "kind", "title", "reason"]),
            ann("Ask for approval", false, false, false, false)),
        tool("request_human", "Pause and ask the person to do something only a human may do in the machine (a UAC prompt, the lock screen, a password, a payment, a CAPTCHA). The agent stays paused until they press \"Return to agent\"; optionally wait for that.",
            schema(json!({ "machine": m(), "message": { "type": "string", "description": "What you need them to do, in one or two sentences." },
                "waitSeconds": { "type": "integer", "minimum": 0, "maximum": 1800, "description": "Default 0 (return at once)." } }), &["machine", "message"]),
            ann("Ask the person", false, false, false, false)),
        tool("cancel_request", "Withdraw your pending request_human on a machine when you give up waiting: the pause it caused ends and the machine is yours again (to write a report or destroy it). It can't end a pause the person started themselves.",
            schema(json!({ "machine": m() }), &["machine"]),
            ann("Withdraw request to the person", false, false, true, false)),
    ]
}

// ---------------------------------------------------------------- calls

fn arg_str<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    match args.get(key) {
        Some(Value::String(s)) if !s.trim().is_empty() => Ok(s),
        Some(Value::String(_)) | None | Some(Value::Null) => Err(format!("`{key}` is required.")),
        _ => Err(format!("`{key}` must be a string.")),
    }
}

fn opt_str<'a>(args: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s)),
        _ => Err(format!("`{key}` must be a string.")),
    }
}

fn num(args: &Value, key: &str) -> Result<f64, String> {
    args.get(key).and_then(Value::as_f64).ok_or_else(|| format!("`{key}` must be a number."))
}

fn opt_int(args: &Value, key: &str, min: i64, max: i64) -> Result<Option<i64>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_f64() {
            Some(f) if f.fract() == 0.0 && f >= min as f64 && f <= max as f64 => Ok(Some(f as i64)),
            _ => Err(format!("`{key}` must be a whole number from {min} to {max}.")),
        },
    }
}

fn opt_bool(args: &Value, key: &str) -> Result<Option<bool>, String> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        _ => Err(format!("`{key}` must be true or false.")),
    }
}

/// Runs one tool and always returns a CallToolResult (or an `input_required` result).
pub fn call(ctx: &Ctx, name: &str, call: &Call) -> Value {
    if !call.args.is_object() {
        return tool_error("Arguments must be a JSON object.");
    }
    if !definitions().iter().any(|d| d["name"] == name) {
        return tool_error(format!("There is no tool named {name}."));
    }
    if ctx.killed.load(std::sync::atomic::Ordering::Relaxed) {
        return tool_error(explain("", &BrokerError::new("killed", "")));
    }
    let (connection, settings) = match ctx.connection() {
        Ok(c) => c,
        Err(e) => return tool_error(e),
    };
    // Approvals through the client, when the person turned them on for this connection.
    if settings.elicitation && CONFIRM.contains(&name) {
        match approve(ctx, name, call) {
            Approval::Go => {}
            Approval::Reply(v) => return v,
        }
    }
    let t = Tool { ctx, name, connection: &connection, settings: &settings, args: call.args, cancelled: call.cancelled };
    let result = match name {
        "list_templates" => t.list_templates(),
        "create_disposable" => t.create_disposable(),
        "list_machines" => t.list_machines(),
        "take_machine" => t.take_machine(),
        "release_machine" => t.release_machine(),
        "screenshot" => t.screenshot_tool(),
        "click" | "type" | "key" | "scroll" | "drag" | "act" => t.input(name),
        "ui_tree" => t.ui_tree(),
        "ui_invoke" => t.ui_invoke(),
        "run" => t.run(),
        "read_file" => t.read_file(),
        "write_file" => t.write_file(),
        "send_file" => t.send_file(),
        "offer_file" => t.offer_file(),
        "offer_status" => t.offer_status(),
        "restore_point_create" => t.restore_create(),
        "restore_point_revert" => t.restore_revert(),
        "destroy" => t.destroy(),
        "open_viewer" => t.open_viewer(),
        "request_human" => t.request_human(),
        "request_approval" => t.request_approval(),
        "cancel_request" => t.cancel_request(),
        _ => Err(format!("There is no tool named {name}.")),
    };
    result.unwrap_or_else(tool_error)
}

enum Approval {
    Go,
    Reply(Value),
}

fn random_hex() -> String {
    let mut bytes = [0u8; 16];
    // SAFETY: a valid buffer of the given size; the system RNG needs no algorithm handle.
    unsafe {
        windows_sys::Win32::Security::Cryptography::BCryptGenRandom(std::ptr::null_mut(), bytes.as_mut_ptr(), 16,
            windows_sys::Win32::Security::Cryptography::BCRYPT_USE_SYSTEM_PREFERRED_RNG);
    }
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn approve(ctx: &Ctx, name: &str, call: &Call) -> Approval {
    let machine = call.args["machine"].as_str().unwrap_or("the machine");
    let what = match name {
        "run" => format!("run `{}` in {machine}", call.args["command"].as_str().unwrap_or("")),
        "write_file" => format!("write {} in {machine}", call.args["path"].as_str().unwrap_or("")),
        "send_file" => format!("copy {} from this PC into {machine}", call.args["hostPath"].as_str().unwrap_or("")),
        _ => name.to_string(),
    };
    let message = format!("Allow the agent to {}?", cap_to(what, 400));
    if call.client.legacy {
        return match (call.ask_legacy)(&message) {
            Some(false) => Approval::Reply(tool_error("The person declined this. Don't retry it; ask them what to do instead.")),
            _ => Approval::Go,
        };
    }
    if !call.client.elicitation {
        return Approval::Go;
    }
    let args = call.args.to_string();
    if let Some(state) = call.request_state {
        let mut pending = ctx.pending.lock().unwrap();
        pending.retain(|_, p| p.created.elapsed() < APPROVAL_TTL);
        let valid = matches!(pending.get(state), Some(p) if p.tool == name && p.args == args);
        if !valid {
            return Approval::Reply(tool_error("That approval doesn't match this call or expired; call the tool again."));
        }
        pending.remove(state);
        let action = call.input_responses.and_then(|r| r["confirm"]["action"].as_str()).unwrap_or("");
        return if action == "accept" {
            Approval::Go
        } else {
            Approval::Reply(tool_error("The person declined this. Don't retry it; ask them what to do instead."))
        };
    }
    let nonce = random_hex();
    ctx.pending.lock().unwrap().insert(nonce.clone(), Pending { tool: name.into(), args, created: Instant::now() });
    Approval::Reply(json!({
        "resultType": "input_required",
        "inputRequests": { "confirm": { "method": "elicitation/create", "params": {
            "mode": "form", "message": message, "requestedSchema": { "type": "object", "properties": {} } } } },
        "requestState": nonce,
    }))
}

struct Tool<'a> {
    ctx: &'a Ctx,
    name: &'a str,
    connection: &'a str,
    settings: &'a Settings,
    args: &'a Value,
    cancelled: &'a dyn Fn() -> bool,
}

impl Tool<'_> {
    fn broker(&self, op: &str, machine: &str, mut args: Value) -> Result<Reply, String> {
        args["connection"] = json!(self.connection);
        if !machine.is_empty() {
            args["name"] = json!(machine);
        }
        let long = matches!(op, "machine.create" | "restore.create" | "restore.revert" | "machine.destroy");
        let r = if long { self.ctx.broker.call_long(op, args) } else { self.ctx.broker.call(op, args) };
        r.map_err(|e| self.fail(machine, e))
    }

    fn fail(&self, machine: &str, e: BrokerError) -> String {
        if e.code == "killed" {
            self.ctx.killed.store(true, std::sync::atomic::Ordering::Relaxed);
        }
        // The service drops a client when its pipe closes: register again on the next call (machines must be
        // taken again, which the error says).
        if e.code == "unavailable" {
            self.ctx.connection.lock().unwrap().take();
            self.ctx.shots.lock().unwrap().clear();
        }
        // Paused because the agent itself asked the person (request_human), not because they took over (lab 053: the
        // model was told "the person took control" while it was the one waiting for them).
        if e.code == "paused" && !machine.is_empty() {
            if let Ok(Some(m)) = self.find(machine) {
                if paused_by(&m) == Some("human") {
                    return format!("{machine} is waiting for the person to do what you asked with request_human; nothing can be done in it until they press \"Return to agent\". If you give up waiting, use cancel_request to get it back.");
                }
            }
        }
        explain(machine, &e)
    }

    fn machine(&self) -> Result<&str, String> {
        arg_str(self.args, "machine")
    }

    /// One step on a machine: counts against its budget first.
    fn step(&self, machine: &str) -> Result<(), String> {
        let mut uses = self.ctx.uses.lock().unwrap();
        let u = uses.entry(machine.to_string()).or_default();
        let since = *u.since.get_or_insert_with(Instant::now);
        if u.steps >= self.settings.max_steps {
            return Err(explain(machine, &BrokerError::new("budget", "")) + &format!(" ({} steps)", self.settings.max_steps));
        }
        if since.elapsed() > Duration::from_secs(self.settings.max_minutes * 60) {
            return Err(explain(machine, &BrokerError::new("budget", "")) + &format!(" ({} minutes)", self.settings.max_minutes));
        }
        u.steps += 1;
        Ok(())
    }

    fn invoke(&self, machine: &str, method: &str, params: Value) -> Result<Reply, String> {
        self.invoke_with(machine, method, params, json!({}))
    }

    /// `extra`: `timeoutSec` (the broker's wait, default 30 s) and `blob` (base64 sent after the request).
    fn invoke_with(&self, machine: &str, method: &str, params: Value, mut extra: Value) -> Result<Reply, String> {
        self.step(machine)?;
        extra["method"] = json!(method);
        extra["params"] = params;
        extra["note"] = json!(self.note());
        self.broker("agent.invoke", machine, extra)
    }

    /// What this step does, for the person's view of the session in GpuVM: the tool and its arguments.
    fn note(&self) -> String {
        let mut args = self.args.clone();
        if let Some(map) = args.as_object_mut() {
            map.remove("machine");
            if let Some(Value::String(c)) = map.get_mut("content") {
                *c = format!("({} characters)", c.chars().count());
            }
        }
        let text = if args.as_object().is_some_and(|m| m.is_empty()) { self.name.to_string() } else { format!("{} {args}", self.name) };
        cap_to(text, 160)
    }

    /// The machine as the broker lists it, which must be taken by this connection.
    fn mine(&self, machine: &str) -> Result<Value, String> {
        let m = self.find(machine)?.ok_or_else(|| format!("There is no machine named {machine}."))?;
        if taken_by(&m) != Some(self.connection) {
            return Err(explain(machine, &BrokerError::new("not_taken", "")));
        }
        Ok(m)
    }

    fn wait(&self, seconds: u64, mut done: impl FnMut() -> Result<bool, String>) -> Result<bool, String> {
        let end = Instant::now() + Duration::from_secs(seconds);
        loop {
            if done()? {
                return Ok(true);
            }
            if Instant::now() >= end || (self.cancelled)() {
                return Ok(false);
            }
            let poll = Duration::from_millis(self.ctx.poll_ms.load(std::sync::atomic::Ordering::Relaxed));
            std::thread::sleep(poll.min(end.saturating_duration_since(Instant::now())).max(Duration::from_millis(1)));
        }
    }

    fn machines(&self) -> Result<Vec<Value>, String> {
        let r = self.broker("machines.list", "", json!({}))?;
        Ok(match r.data {
            Value::Array(a) => a,
            Value::Null => Vec::new(),
            other => vec![other],
        })
    }

    fn find(&self, machine: &str) -> Result<Option<Value>, String> {
        Ok(self.machines()?.into_iter().find(|m| m["name"].as_str().is_some_and(|n| n.eq_ignore_ascii_case(machine))))
    }

    // -------- create

    fn list_templates(&self) -> Out {
        let r = self.broker("templates.list", "", json!({}))?;
        let mut lines = vec!["Templates:".to_string()];
        for t in r.data["templates"].as_array().into_iter().flatten() {
            lines.push(format!("- {} — {}", t["name"].as_str().unwrap_or("?"), t["description"].as_str().unwrap_or("")));
        }
        if lines.len() == 1 {
            lines.push("(none: the person has to make a template with the GpuVM agent first)".into());
        }
        let profiles: Vec<String> = r.data["profiles"].as_array().into_iter().flatten()
            .map(|p| format!("- {} ({} CPU, {} GB)", p["name"].as_str().unwrap_or("?"), p["cpu"], p["memoryGB"])).collect();
        if !profiles.is_empty() {
            lines.push("Profiles:".into());
            lines.extend(profiles);
        }
        Ok(text(lines.join("\n")))
    }

    fn create_disposable(&self) -> Out {
        let template = arg_str(self.args, "template")?;
        let name = opt_str(self.args, "name")?;
        if let Some(n) = name {
            if n.len() > 40 || !n.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
                return Err("`name` may only have letters, digits and '-' (up to 40).".into());
            }
        }
        let cpu = opt_int(self.args, "cpu", 1, 16)?;
        let mem = opt_int(self.args, "memoryGB", 2, 64)?;
        let r = self.broker("machine.create", "", json!({ "template": template, "name": name,
            "profile": opt_str(self.args, "profile")?, "cpu": cpu, "memoryGB": mem, "task": self.task()? }))?;
        let created = r.data["name"].as_str().ok_or("GpuVM didn't say which machine it created.")?.to_string();
        let ready = self.wait_ready(&created, 600)?;
        Ok(text(format!("Created disposable machine {created} from {template}; {ready}")))
    }

    // -------- get

    fn list_machines(&self) -> Out {
        let list = self.machines()?;
        if list.is_empty() {
            return Ok(text("No machines. Create one with create_disposable."));
        }
        let lines: Vec<String> = list.iter().map(|m| {
            let mut flags = vec![m["state"].as_str().unwrap_or("?").to_string()];
            if m["disposable"] == true { flags.push("disposable".into()); }
            match paused_by(m) {
                Some("human") => flags.push("paused: waiting for the person (request_human)".into()),
                Some("control") => flags.push("paused: the person took control".into()),
                Some(_) => flags.push("paused by the person".into()),
                None => {}
            }
            match taken_by(m) {
                Some(c) if c == self.connection => flags.push("taken by you".into()),
                Some(_) => flags.push(format!("taken by another agent ({})", m["takenBy"]["client"]["name"].as_str().unwrap_or("?"))),
                None => {}
            }
            if let Some(d) = m["desktop"].as_str().filter(|d| *d != "default") {
                flags.push(format!("{d} screen"));
            }
            let size = screen(m).map(|(w, h)| format!(" {w}x{h}")).unwrap_or_default();
            format!("- {}: {}{size}", m["name"].as_str().unwrap_or("?"), flags.join(", "))
        }).collect();
        Ok(text(lines.join("\n")))
    }

    fn wait_ready(&self, machine: &str, seconds: u64) -> Result<String, String> {
        let mut last = Value::Null;
        let ready = self.wait(seconds, || {
            last = self.find(machine)?.unwrap_or(Value::Null);
            if last["state"] == "no-agent" {
                return Err(explain(machine, &BrokerError::new("no_agent", "")));
            }
            Ok(last["state"] == "ready" && last["agent"]["signedIn"] != false)
        })?;
        if !ready {
            return Ok(format!("not ready yet (state: {}); call take_machine again to keep waiting.", last["state"].as_str().unwrap_or("unknown")));
        }
        let size = screen(&last);
        if let Some(s) = size {
            self.ctx.screens.lock().unwrap().insert(machine.to_string(), s);
        }
        self.ctx.uses.lock().unwrap().entry(machine.to_string()).or_default().since.get_or_insert_with(Instant::now);
        Ok(format!("its agent is ready{}. Next: screenshot.", size.map(|(w, h)| format!(" (screen {w}x{h})")).unwrap_or_default()))
    }

    fn task(&self) -> Result<Option<String>, String> {
        Ok(opt_str(self.args, "task")?.map(|t| cap_to(t.to_string(), 200)))
    }

    fn take_machine(&self) -> Out {
        let machine = self.machine()?;
        let wait = opt_int(self.args, "waitSeconds", 0, 900)?.unwrap_or(180) as u64;
        let m = self.find(machine)?.ok_or_else(|| format!("There is no machine named {machine}."))?;
        if m["state"] == "no-agent" {
            return Err(explain(machine, &BrokerError::new("no_agent", "")));
        }
        self.broker("machine.take", machine, json!({ "task": self.task()? }))?;
        if m["state"] == "off" {
            self.broker("machine.start", machine, json!({}))?;
        }
        let ready = self.wait_ready(machine, wait)?;
        Ok(text(format!("You have {machine}; {ready}")))
    }

    fn release_machine(&self) -> Out {
        let machine = self.machine()?;
        self.broker("machine.release", machine, json!({}))?;
        self.ctx.forget_machine(machine);
        Ok(text(format!("Released {machine}.")))
    }

    // -------- screen

    fn screen_size(&self, machine: &str) -> Result<(u32, u32), String> {
        if let Some(s) = self.ctx.screens.lock().unwrap().get(machine) {
            return Ok(*s);
        }
        let info = self.invoke(machine, "agent.info", json!({}))?;
        let w = info.data["screen"]["w"].as_u64().ok_or("The machine didn't report its screen size.")? as u32;
        let h = info.data["screen"]["h"].as_u64().ok_or("The machine didn't report its screen size.")? as u32;
        self.ctx.screens.lock().unwrap().insert(machine.to_string(), (w, h));
        Ok((w, h))
    }

    fn screenshot_tool(&self) -> Out {
        let machine = self.machine()?;
        let max_w = opt_int(self.args, "maxWidth", 64, geometry::MAX_EDGE as i64)?.map(|v| v as u32);
        let max_h = opt_int(self.args, "maxHeight", 64, geometry::MAX_EDGE as i64)?.map(|v| v as u32);
        let zoom = match self.args.get("zoom") {
            None | Some(Value::Null) => None,
            Some(Value::Array(a)) if a.len() == 4 && a.iter().all(Value::is_number) => {
                Some([a[0].as_f64().unwrap(), a[1].as_f64().unwrap(), a[2].as_f64().unwrap(), a[3].as_f64().unwrap()])
            }
            _ => return Err("`zoom` must be [x, y, width, height] in screenshot pixels.".into()),
        };
        let format = opt_str(self.args, "format")?.unwrap_or("webp");
        if format != "webp" && format != "png" {
            return Err("`format` must be webp or png.".into());
        }
        let reference = opt_int(self.args, "screenshot", 0, u32::MAX as i64)?.map(|v| v as u32);
        let (shot, image) = self.capture(machine, max_w, max_h, zoom, reference, format)?;
        let mut content = vec![image];
        content.push(json!({ "type": "text", "text": describe(&shot) }));
        Ok(json!({ "content": content }))
    }

    /// Captures and registers a screenshot; returns its mapping and the MCP image content.
    fn capture(&self, machine: &str, max_w: Option<u32>, max_h: Option<u32>, zoom: Option<[f64; 4]>, reference: Option<u32>, format: &str) -> Result<(Shot, Value), String> {
        let screen = self.screen_size(machine)?;
        let (mut origin, mut region) = ((0u32, 0u32), screen);
        if let Some([x, y, w, h]) = zoom {
            let base = self.ctx.latest_shot(machine, reference).ok_or(match reference {
                Some(id) => format!("Screenshot {id} isn't known for {machine} (too old, or of another machine); take a new one."),
                None => "Take a full screenshot first; zoom uses its pixels.".to_string(),
            })?;
            let r = base.rect_to_full(x, y, w, h)?;
            origin = (r[0], r[1]);
            region = (r[2], r[3]);
        }
        let (bw, bh) = (max_w.unwrap_or(geometry::DEFAULT_MAX.0), max_h.unwrap_or(geometry::DEFAULT_MAX.1));
        let (sw, sh) = geometry::fit(region.0, region.1, bw, bh);
        let mut params = json!({ "maxW": sw, "maxH": sh, "format": format });
        if zoom.is_some() {
            params["region"] = json!([origin.0, origin.1, region.0, region.1]);
        }
        let reply = self.invoke(machine, "screen.capture", params)?;
        let blob = reply.blob.ok_or("The machine sent no picture.")?;
        let w = reply.data["w"].as_u64().unwrap_or(0) as u32;
        let h = reply.data["h"].as_u64().unwrap_or(0) as u32;
        if w == 0 || h == 0 || w > geometry::MAX_EDGE || h > geometry::MAX_EDGE || (w as u64 * h as u64) > geometry::MAX_PIXELS {
            return Err(format!("The machine sent a picture of an unexpected size ({w}x{h})."));
        }
        // The desktop may have changed size (resolution change): use what the capture reports.
        if let (Some(fw), Some(fh)) = (reply.data["screen"]["w"].as_u64(), reply.data["screen"]["h"].as_u64()) {
            let now = (fw as u32, fh as u32);
            if now != screen && zoom.is_none() {
                region = now;
            }
            self.ctx.screens.lock().unwrap().insert(machine.to_string(), now);
        }
        let shot = self.ctx.add_shot(Shot { id: 0, machine: machine.into(), screen, origin, region, sent: (w, h), zoom: zoom.is_some() });
        let mime = match reply.data["format"].as_str().unwrap_or(format) { "png" => "image/png", _ => "image/webp" };
        let image = json!({ "type": "image", "data": base64::engine::general_purpose::STANDARD.encode(&blob), "mimeType": mime });
        Ok((shot, image))
    }

    // -------- input

    fn reference(&self, machine: &str) -> Result<Shot, String> {
        let id = opt_int(self.args, "screenshot", 0, u32::MAX as i64)?.map(|v| v as u32);
        self.ctx.latest_shot(machine, id).ok_or_else(|| match id {
            Some(id) => format!("Screenshot {id} isn't known for {machine} (too old, or of another machine); take a new one."),
            None => format!("Take a screenshot of {machine} first; coordinates are in its pixels."),
        })
    }

    fn point(shot: &Shot, a: &Value, kx: &str, ky: &str) -> Result<(i32, i32), String> {
        shot.to_full(num(a, kx)?, num(a, ky)?)
    }

    /// One action from the model → the guest's action, in desktop pixels.
    fn convert(&self, shot: Option<&Shot>, a: &Value, machine: &str) -> Result<Value, String> {
        let kind = a["type"].as_str().ok_or("Each action needs a `type`.")?;
        let need = || shot.ok_or_else(|| format!("Take a screenshot of {machine} first; coordinates are in its pixels."));
        Ok(match kind {
            "click" => {
                let (x, y) = Self::point(need()?, a, "x", "y")?;
                let button = opt_str(a, "button")?.unwrap_or("left");
                if !["left", "right", "middle"].contains(&button) {
                    return Err("`button` must be left, right or middle.".into());
                }
                let mut v = json!({ "type": "click", "x": x, "y": y, "button": button, "count": opt_int(a, "count", 1, 3)?.unwrap_or(1) });
                if let Some(m) = opt_str(a, "modifiers")? {
                    v["mods"] = json!(m);
                }
                v
            }
            "move" => {
                let (x, y) = Self::point(need()?, a, "x", "y")?;
                json!({ "type": "move", "x": x, "y": y })
            }
            "drag" => {
                let s = need()?;
                let (x, y) = Self::point(s, a, "x", "y")?;
                let (tx, ty) = Self::point(s, a, "toX", "toY")?;
                json!({ "type": "drag", "x": x, "y": y, "toX": tx, "toY": ty })
            }
            "scroll" => {
                let (x, y) = Self::point(need()?, a, "x", "y")?;
                let dx = opt_int(a, "dx", -50, 50)?.unwrap_or(0);
                let dy = opt_int(a, "dy", -50, 50)?.unwrap_or(0);
                if dx == 0 && dy == 0 {
                    return Err("Give `dx` or `dy` (wheel notches) to scroll.".into());
                }
                json!({ "type": "scroll", "x": x, "y": y, "dx": dx, "dy": dy })
            }
            "type" => {
                let t = a["text"].as_str().ok_or("`text` must be a string.")?;
                if t.chars().count() > MAX_TYPE {
                    return Err(format!("Type at most {MAX_TYPE} characters at a time (use write_file for long text)."));
                }
                json!({ "type": "type", "text": t })
            }
            "key" => {
                let k = arg_str(a, "keys")?;
                json!({ "type": "key", "keys": k.to_ascii_lowercase(), "repeat": opt_int(a, "repeat", 1, 50)?.unwrap_or(1) })
            }
            "wait" => json!({ "type": "wait", "ms": opt_int(a, "ms", 0, 5000)?.unwrap_or(500) }),
            other => return Err(format!("Unknown action type {other}.")),
        })
    }

    fn input(&self, name: &str) -> Out {
        let machine = self.machine()?;
        let actions: Vec<Value> = if name == "act" {
            match self.args.get("actions") {
                Some(Value::Array(a)) if !a.is_empty() && a.len() <= 50 => a.clone(),
                _ => return Err("`actions` must be a list of 1 to 50 actions.".into()),
            }
        } else {
            let mut a = self.args.clone();
            a["type"] = json!(name);
            vec![a]
        };
        let needs_shot = actions.iter().any(|a| matches!(a["type"].as_str(), Some("click" | "move" | "drag" | "scroll")));
        let shot = if needs_shot { Some(self.reference(machine)?) } else { None };
        let converted = actions.iter().enumerate()
            .map(|(i, a)| self.convert(shot.as_ref(), a, machine).map_err(|e| if name == "act" { format!("Action {}: {e}", i + 1) } else { e }))
            .collect::<Result<Vec<_>, _>>()?;
        let reply = self.invoke(machine, "input.act", json!({ "actions": converted, "stopOnError": true }))?;
        let done = reply.data["done"].as_u64().unwrap_or(converted.len() as u64);
        let mut summary = if name == "act" { format!("Done {done} of {} actions.", converted.len()) } else { "Done.".to_string() };
        if let Some(s) = &shot {
            summary += &format!(" (coordinates from screenshot {})", s.id);
        }
        if opt_bool(self.args, "screenshotAfter")? == Some(true) {
            let last = self.ctx.latest_shot(machine, None);
            let (mw, mh) = last.as_ref().map(|s| (Some(s.sent.0.max(s.sent.1)), Some(s.sent.0.max(s.sent.1)))).unwrap_or((None, None));
            let (shot, image) = self.capture(machine, mw, mh, None, None, "webp")?;
            return Ok(json!({ "content": [{ "type": "text", "text": summary }, image, { "type": "text", "text": describe(&shot) }] }));
        }
        Ok(text(summary))
    }

    // -------- UI Automation

    fn ui_tree(&self) -> Out {
        let machine = self.machine()?;
        let max = opt_int(self.args, "maxNodes", 1, 1000)?.unwrap_or(150);
        let interactive = opt_bool(self.args, "interactiveOnly")?.unwrap_or(true);
        let shot = match self.ctx.latest_shot(machine, None) {
            Some(s) => s,
            None => {
                // No screenshot yet: use the space a default screenshot would have, so later ones match.
                let screen = self.screen_size(machine)?;
                let sent = geometry::fit(screen.0, screen.1, geometry::DEFAULT_MAX.0, geometry::DEFAULT_MAX.1);
                self.ctx.add_shot(Shot { id: 0, machine: machine.into(), screen, origin: (0, 0), region: screen, sent, zoom: false })
            }
        };
        let reply = self.invoke(machine, "ui.tree", json!({ "scope": "foreground", "maxNodes": max, "visibleOnly": true, "interactiveOnly": interactive }))?;
        let nodes = reply.data["nodes"].as_array().cloned().unwrap_or_default();
        let mut lines = vec![format!("Controls of the window in front ({} nodes; boxes [x, y, w, h] in the pixels of screenshot {}, {}x{}):", nodes.len(), shot.id, shot.sent.0, shot.sent.1)];
        for n in &nodes {
            let b: Vec<i64> = n["bbox"].as_array().map(|a| a.iter().map(|v| v.as_i64().unwrap_or(0)).collect()).unwrap_or_default();
            let place = if b.len() == 4 {
                match shot.rect_to_shot([b[0], b[1], b[2], b[3]]) {
                    Some(r) => {
                        let centre = shot.to_shot(b[0] + b[2] / 2, b[1] + b[3] / 2).map(|(x, y)| format!(" centre ({x}, {y})")).unwrap_or_default();
                        format!(" [{}, {}, {}, {}]{centre}", r[0], r[1], r[2], r[3])
                    }
                    None => " (not visible)".into(),
                }
            } else { String::new() };
            let patterns: Vec<&str> = n["patterns"].as_array().map(|p| p.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
            lines.push(format!("{} {} \"{}\"{place}{}{}",
                n["id"].as_str().unwrap_or("?"), n["role"].as_str().unwrap_or("?"), n["name"].as_str().unwrap_or("").replace('"', "'"),
                if n["enabled"] == false { " disabled" } else { "" },
                if patterns.is_empty() { String::new() } else { format!(" ({})", patterns.join(", ")) }));
        }
        Ok(text(lines.join("\n")))
    }

    fn ui_invoke(&self) -> Out {
        let machine = self.machine()?;
        let id = arg_str(self.args, "id")?;
        let action = arg_str(self.args, "action")?;
        if !["invoke", "toggle", "select", "expand", "setValue"].contains(&action) {
            return Err("`action` must be invoke, toggle, select, expand or setValue.".into());
        }
        let value = opt_str(self.args, "value")?;
        if action == "setValue" && value.is_none() {
            return Err("setValue needs `value`.".into());
        }
        self.invoke(machine, "ui.invoke", json!({ "id": id, "action": action, "value": value }))?;
        Ok(text("Done."))
    }

    // -------- commands and files

    fn run(&self) -> Out {
        let machine = self.machine()?;
        let command = arg_str(self.args, "command")?;
        let shell = opt_str(self.args, "shell")?.unwrap_or("powershell");
        let extra: Vec<String> = match self.args.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(a)) if a.iter().all(Value::is_string) => a.iter().map(|v| v.as_str().unwrap().to_string()).collect(),
            _ => return Err("`args` must be a list of strings.".into()),
        };
        let (file, args) = match shell {
            "powershell" => ("powershell.exe".to_string(), vec!["-NoProfile".into(), "-NonInteractive".into(), "-Command".into(), command.to_string()]),
            "cmd" => ("cmd.exe".to_string(), vec!["/d".into(), "/s".into(), "/c".into(), command.to_string()]),
            "none" => (command.to_string(), extra.clone()),
            _ => return Err("`shell` must be powershell, cmd or none.".into()),
        };
        if shell != "none" && !extra.is_empty() {
            return Err("`args` only goes with shell 'none'; put everything in `command` otherwise.".into());
        }
        let timeout = opt_int(self.args, "timeoutSeconds", 1, 600)?.unwrap_or(60);
        let reply = self.invoke_with(machine, "exec.run", json!({ "file": file, "args": args, "cwd": opt_str(self.args, "cwd")?,
            "timeoutMs": timeout * 1000, "stdin": opt_str(self.args, "stdin")? }), json!({ "timeoutSec": (timeout + 10).min(600) }))?;
        let d = &reply.data;
        let (out, err) = run_output(d, reply.blob.as_deref());
        let mut t = if d["timedOut"] == true {
            format!("Timed out after {timeout} s (the command was stopped); partial output below.")
        } else {
            format!("Exit code {}", d["exitCode"])
        };
        if d["truncated"] == true {
            t += " (the machine cut the output at 1 MiB)";
        }
        if !out.is_empty() {
            t += &format!("\n--- stdout ---\n{}", cap_to(out, MAX_TEXT * 3 / 4));
        }
        if !err.is_empty() {
            t += &format!("\n--- stderr ---\n{}", cap_to(err, MAX_TEXT / 4));
        }
        Ok(text(t))
    }

    /// The agent's home in the machine (`agent.info` home; the default user's profile otherwise), ending in `\`.
    fn home(&self, machine: &str) -> String {
        let home = self.find(machine).ok().flatten()
            .and_then(|m| m["agent"]["home"].as_str().map(str::to_string))
            .unwrap_or_else(|| PROFILE.trim_end_matches('\\').to_string());
        format!("{}\\", home.trim_end_matches('\\'))
    }

    /// A path for files.*: relative to the agent's home (passed as is; the guest resolves it) or a full path inside
    /// it. Never `..`, `.`, another drive, a UNC path or a stream (`:`).
    fn home_path(&self, machine: &str, key: &str) -> Result<String, String> {
        let path = arg_str(self.args, key)?.replace('/', "\\");
        let bad = || Err("Use a path inside the agent's home folder, relative (like Desktop\\Outbox\\report.md) or full; no '..'.".to_string());
        if path.split('\\').any(|p| p == ".." || p == ".") || path.starts_with('\\') {
            return bad();
        }
        let colon = path.find(':');
        if colon.is_none() {
            return Ok(path);
        }
        let home = self.home(machine);
        if colon != Some(1) || !path.to_ascii_lowercase().starts_with(&home.to_ascii_lowercase()) || path[2..].contains(':') {
            return bad();
        }
        Ok(path)
    }

    fn profile_path(&self) -> Result<String, String> {
        let machine = self.machine()?;
        self.home_path(machine, "path")
    }

    fn read_file(&self) -> Out {
        let machine = self.machine()?;
        let path = self.profile_path()?;
        let reply = self.invoke(machine, "files.read", json!({ "path": path, "offset": 0, "length": READ_MAX }))?;
        let size = reply.data["size"].as_u64();
        let bytes = reply.blob.unwrap_or_default();
        let partial = size.is_some_and(|s| s > bytes.len() as u64);
        let lower = path.to_ascii_lowercase();
        let image = [(".png", "image/png"), (".jpg", "image/jpeg"), (".jpeg", "image/jpeg"), (".webp", "image/webp"), (".gif", "image/gif")]
            .iter().find(|(ext, _)| lower.ends_with(ext)).map(|(_, m)| *m);
        if let Some(mime) = image {
            if bytes.len() > 5 << 20 {
                return Err("That image is over 5 MB; take a screenshot of it instead.".into());
            }
            return Ok(json!({ "content": [{ "type": "image", "data": base64::engine::general_purpose::STANDARD.encode(&bytes), "mimeType": mime },
                { "type": "text", "text": format!("{path} ({} bytes)", bytes.len()) }] }));
        }
        let decoded = if bytes.starts_with(&[0xFF, 0xFE]) {
            let units: Vec<u16> = bytes[2..].as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).collect();
            String::from_utf16(&units).ok()
        } else {
            std::str::from_utf8(bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes)).ok().map(str::to_string)
        };
        match decoded {
            Some(t) if !t.contains('\0') => Ok(text(format!("{path} ({} bytes{}):\n{t}", size.unwrap_or(bytes.len() as u64),
                if partial { format!(", first {} shown", bytes.len()) } else { String::new() }))),
            _ => Ok(text(format!("{path} is a binary file ({} bytes). Put it in Desktop\\Outbox and use offer_file to get it to this PC.", bytes.len()))),
        }
    }

    fn write_file(&self) -> Out {
        let machine = self.machine()?;
        let path = self.profile_path()?;
        let content = self.args.get("content").and_then(Value::as_str).ok_or("`content` must be a string.")?;
        let bytes = match opt_str(self.args, "encoding")?.unwrap_or("utf8") {
            "utf8" => content.as_bytes().to_vec(),
            "base64" => base64::engine::general_purpose::STANDARD.decode(content.trim()).map_err(|_| "`content` isn't valid base64.")?,
            _ => return Err("`encoding` must be utf8 or base64.".into()),
        };
        if bytes.len() > MAX_WRITE {
            return Err("Write at most 10 MB at a time (use send_file for big files).".into());
        }
        self.invoke_with(machine, "files.write", json!({ "path": path, "blob": true }),
            json!({ "blob": base64::engine::general_purpose::STANDARD.encode(&bytes), "timeoutSec": 60 }))?;
        Ok(text(format!("Wrote {} bytes to {path}.", bytes.len())))
    }

    fn send_file(&self) -> Out {
        let machine = self.machine()?;
        let host = arg_str(self.args, "hostPath")?;
        let p = std::path::Path::new(host);
        if !p.is_absolute() {
            return Err("`hostPath` must be a full path on this PC.".into());
        }
        self.step(machine)?;
        self.broker("file.send", machine, json!({ "hostPath": host }))?;
        // Check it arrived instead of trusting the copy's "done" (lab 053: a 106 MB installer was reported copied
        // and never reached the machine). Folders are only checked for existence.
        let name = p.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let inside = format!("Desktop\\Received\\{name}");
        let expected = std::fs::metadata(p).ok().filter(|m| m.is_file()).map(|m| m.len());
        if expected.is_some() {
            let missing = || format!("GpuVM reported the copy as done, but {inside} isn't in {machine}: the file wasn't delivered. Don't retry in a loop; tell the person.");
            self.step(machine)?;
            let check = self.ctx.broker.call("agent.invoke", json!({ "connection": self.connection, "name": machine, "method": "files.read",
                "params": { "path": inside, "offset": 0, "length": 1 }, "note": format!("check {inside} arrived") }));
            let got = match check {
                Ok(r) => r.data["size"].as_u64(),
                Err(e) if e.code == "not_found" => return Err(missing()),
                Err(e) => return Err(self.fail(machine, e)),
            };
            if got != expected {
                return Err(format!("{inside} reached {machine} incomplete ({} of {} bytes). Don't run it; tell the person.",
                    got.map(|g| g.to_string()).unwrap_or("?".into()), expected.unwrap_or(0)));
            }
        }
        Ok(text(format!("Copied to {inside} in {machine}{}.", expected.map(|n| format!(" ({n} bytes, checked)")).unwrap_or_default())))
    }

    fn offer_file(&self) -> Out {
        let machine = self.machine()?;
        let path = self.home_path(machine, "path")?;
        // Relative to the home: Desktop\Outbox\<file>, nothing deeper.
        let home = self.home(machine).to_ascii_lowercase();
        let lower = path.to_ascii_lowercase();
        let relative = lower.strip_prefix(&home).unwrap_or(&lower);
        let file = relative.strip_prefix(OUTBOX).unwrap_or("");
        if file.is_empty() || file.contains('\\') {
            return Err("Only files directly inside Desktop\\Outbox (in the agent's home) can be offered; write or copy the file there first.".into());
        }
        let note = arg_str(self.args, "note")?;
        let wait = opt_int(self.args, "waitSeconds", 0, 900)?.unwrap_or(0) as u64;
        self.step(machine)?;
        let r = self.broker("offer.create", machine, json!({ "path": path, "note": cap_to(note.to_string(), 500) }))?;
        let id = r.data["offerId"].as_str().ok_or("GpuVM didn't return an offer id.")?.to_string();
        if wait == 0 {
            return Ok(text(format!("Offered {path} to the person (offer {id}). They approve it in GpuVM; check with offer_status.")));
        }
        let mut last = Value::Null;
        self.wait(wait, || {
            last = self.broker("offer.get", machine, json!({ "offerId": id }))?.data;
            Ok(!matches!(last["state"].as_str(), Some("pending" | "copying")))
        })?;
        Ok(text(offer_text(&id, &last)))
    }

    fn offer_status(&self) -> Out {
        let machine = self.machine()?;
        let id = arg_str(self.args, "offerId")?;
        let r = self.broker("offer.get", machine, json!({ "offerId": id }))?;
        Ok(text(offer_text(id, &r.data)))
    }

    // -------- restore points and lifetime

    /// Asks the person in GpuVM (never through the client) and waits for their answer; the allowed request's id.
    fn approval(&self, machine: &str, kind: &str, title: &str, reason: &str, wait: u64) -> Result<String, String> {
        let r = self.broker("approval.request", machine, json!({ "kind": kind, "title": cap_to(title.to_string(), 120),
            "reason": cap_to(reason.to_string(), 500), "timeoutSec": wait.max(30) }))?;
        let id = r.data["requestId"].as_str().ok_or("GpuVM didn't return a request id.")?.to_string();
        let mut state = String::from("pending");
        self.wait(wait, || {
            state = self.broker("approval.get", machine, json!({ "requestId": id }))?.data["state"].as_str().unwrap_or("pending").to_string();
            Ok(state != "pending")
        })?;
        match state.as_str() {
            "allowed" => Ok(id),
            "denied" => Err("The person said no in GpuVM. Don't try again; ask them what to do instead.".into()),
            "pending" => {
                // Withdrawn so the person isn't asked later about something nobody waits for; a request answered in
                // the meantime keeps its answer (the broker refuses to withdraw it).
                match self.broker("request.revoke", machine, json!({ "requestId": id })) {
                    Ok(_) => Err(format!("The person didn't answer in GpuVM in time, so the request ({id}) was withdrawn. Ask again later if you still need it, or tell the user.")),
                    Err(_) => Err(format!("The person hasn't answered in GpuVM yet (request {id}); try again later.")),
                }
            }
            _ => Err("The request expired without an answer.".into()),
        }
    }

    fn request_approval(&self) -> Out {
        let machine = self.machine()?;
        let kind = arg_str(self.args, "kind")?;
        if !["admin", "network", "other"].contains(&kind) {
            return Err("`kind` must be admin, network or other.".into());
        }
        let title = arg_str(self.args, "title")?;
        let reason = arg_str(self.args, "reason")?;
        let wait = opt_int(self.args, "waitSeconds", 0, 1800)?.map(|w| w as u64).unwrap_or(self.settings.approval_timeout);
        self.mine(machine)?;
        let id = self.approval(machine, kind, title, reason, wait)?;
        Ok(text(format!("The person allowed it (request {id}).")))
    }

    /// Restore points need the machine off for a moment, which deletes a disposable machine: refused for those.
    fn restorable(&self, machine: &str) -> Result<(), String> {
        if self.mine(machine)?["disposable"] == true {
            return Err(format!("{machine} is disposable: turning it off (which restore points need) deletes it. Use a normal machine the person gave you for restore points."));
        }
        Ok(())
    }

    fn restore_create(&self) -> Out {
        let machine = self.machine()?;
        let label = opt_str(self.args, "label")?;
        if label.is_some_and(|l| l.chars().count() > 60) {
            return Err("`label` is 60 characters at most.".into());
        }
        self.restorable(machine)?;
        self.step(machine)?;
        let r = self.broker("restore.create", machine, json!({ "label": label }))?;
        self.ctx.shots.lock().unwrap().retain(|s| s.machine != machine);
        let ready = self.wait_ready(machine, 300)?;
        Ok(text(format!("Restore point {} saved (the machine restarted for it); {ready}", r.data["name"].as_str().unwrap_or("?"))))
    }

    fn restore_revert(&self) -> Out {
        let machine = self.machine()?;
        let point = arg_str(self.args, "point")?;
        self.restorable(machine)?;
        self.step(machine)?;
        let approval = self.approval(machine, "revert", &format!("Go back to restore point {point}"),
            opt_str(self.args, "reason")?.unwrap_or("The agent wants to return the machine to an earlier state."), self.settings.approval_timeout)?;
        self.broker("restore.revert", machine, json!({ "point": point, "approval": approval }))?;
        self.ctx.shots.lock().unwrap().retain(|s| s.machine != machine);
        let ready = self.wait_ready(machine, 300)?;
        Ok(text(format!("{machine} is back at {point} (how it was before is kept as a new restore point); {ready}")))
    }

    fn destroy(&self) -> Out {
        let machine = self.machine()?;
        if self.mine(machine)?["disposable"] != true {
            return Err(format!("{machine} isn't disposable; only the person can delete it. Use release_machine when you're done."));
        }
        // A file offered to the person is still read from the machine when they accept it (lab 053: the report
        // was lost because the machine was destroyed while its offer waited).
        if opt_bool(self.args, "force")? != Some(true) {
            let offers = self.broker("offers.list", machine, json!({}))?.data;
            let waiting: Vec<String> = offers.as_array().into_iter().flatten()
                .filter(|o| matches!(o["state"].as_str(), Some("pending" | "copying")))
                .map(|o| o["id"].as_str().unwrap_or("?").to_string()).collect();
            if !waiting.is_empty() {
                return Err(format!("Offer {} is still waiting for the person; destroying {machine} would lose that file. Wait with offer_status (waitSeconds), or call destroy again with force: true.", waiting.join(", ")));
            }
        }
        self.broker("machine.destroy", machine, json!({}))?;
        self.ctx.forget_machine(machine);
        Ok(text(format!("{machine} is being shut down and deleted.")))
    }

    // -------- see / take control

    fn open_viewer(&self) -> Out {
        let machine = self.machine()?;
        self.broker("viewer.open", machine, json!({}))?;
        Ok(text(format!("GpuVM's viewer shows {machine} to the person now.")))
    }

    fn request_human(&self) -> Out {
        let machine = self.machine()?;
        let message = arg_str(self.args, "message")?;
        let wait = opt_int(self.args, "waitSeconds", 0, 1800)?.unwrap_or(0) as u64;
        let r = self.broker("human.request", machine, json!({ "message": cap_to(message.to_string(), 500) }))?;
        if let Some(id) = r.data["requestId"].as_str() {
            self.ctx.human_requests.lock().unwrap().insert(machine.to_ascii_lowercase(), id.to_string());
        }
        if wait == 0 {
            return Ok(text(format!("Asked the person. The agent on {machine} is paused until they press \"Return to agent\"; calls will say so meanwhile.")));
        }
        let back = self.wait(wait, || Ok(self.find(machine)?.is_some_and(|m| paused_by(&m).is_none())))?;
        if back {
            self.ctx.human_requests.lock().unwrap().remove(&machine.to_ascii_lowercase());
            Ok(text(format!("The person handed {machine} back. Take a fresh screenshot before acting: the screen may have changed.")))
        } else {
            // Not withdrawn here: the person may be in the middle of it (a UAC prompt). The model decides.
            Ok(text(format!("The person hasn't handed {machine} back yet. Wait more with request_human, or give up with cancel_request (it gets the machine back so you can write your report or destroy it).")))
        }
    }

    /// Withdraws this connection's pending request_human on a machine: the pause it caused ends. Never a pause or
    /// take-control by the person (the broker refuses those).
    fn cancel_request(&self) -> Out {
        let machine = self.machine()?;
        let key = machine.to_ascii_lowercase();
        let Some(id) = self.ctx.human_requests.lock().unwrap().get(&key).cloned() else {
            return Err(format!("You have no request to the person pending on {machine}."));
        };
        match self.ctx.broker.call("request.revoke", json!({ "connection": self.connection, "name": machine, "requestId": id })) {
            Ok(r) => {
                self.ctx.human_requests.lock().unwrap().remove(&key);
                self.ctx.shots.lock().unwrap().retain(|s| s.machine != machine);
                if r.data["resumed"] == false {
                    Ok(text(format!("Withdrew your request on {machine}; it is still paused for another reason.")))
                } else {
                    Ok(text(format!("Withdrew your request; {machine} is yours again. Take a fresh screenshot before acting: the person may have done part of it.")))
                }
            }
            Err(e) => {
                let answered = e.code == "bad_request";
                if answered || e.code == "not_found" {
                    self.ctx.human_requests.lock().unwrap().remove(&key);
                }
                Err(match e.code.as_str() {
                    // Gone from the broker: the person answered it (handed the machine back) or replaced it with a
                    // pause of their own. Which one is in the machine's state now (lab 053: an answered request came
                    // back not_found and was reported as "took control").
                    "not_found" => match self.find(machine).ok().flatten().as_ref().and_then(paused_by) {
                        None => format!("The person already answered your request and handed {machine} back; take a fresh screenshot before acting."),
                        Some("human") => format!("{machine} is paused by another request to the person; wait for them."),
                        Some(_) => format!("The person took control of {machine} themselves, so the pause is theirs now; wait until they press \"Return to agent\"."),
                    },
                    "bad_request" => format!("The person already answered your request on {machine}; check with list_machines or take a screenshot."),
                    _ => self.fail(machine, e),
                })
            }
        }
    }
}

/// Fields of a machine as the broker lists it.
fn screen(m: &Value) -> Option<(u32, u32)> {
    let s = &m["agent"]["screen"];
    Some((s["w"].as_u64()? as u32, s["h"].as_u64()? as u32))
}

/// Why the machine is paused: "human" (request_human), "control" (the person took over) or "person".
fn paused_by(m: &Value) -> Option<&str> {
    m["paused"].is_object().then(|| m["paused"]["reason"].as_str().unwrap_or("person"))
}

fn taken_by(m: &Value) -> Option<&str> {
    m["takenBy"]["connection"].as_str()
}

/// exec.run's output: in the JSON, or (when it didn't fit a frame) in the blob, stdout then stderr.
fn run_output(d: &Value, blob: Option<&[u8]>) -> (String, String) {
    let fix = |s: &str| s.replace("\r\n", "\n");
    if d["outputInBlob"] == true {
        let b = blob.unwrap_or_default();
        let n = (d["stdoutBytes"].as_u64().unwrap_or(b.len() as u64) as usize).min(b.len());
        let m = (d["stderrBytes"].as_u64().unwrap_or(0) as usize).min(b.len() - n);
        return (fix(&String::from_utf8_lossy(&b[..n])), fix(&String::from_utf8_lossy(&b[n..n + m])));
    }
    (fix(d["stdout"].as_str().unwrap_or("")), fix(d["stderr"].as_str().unwrap_or("")))
}

fn offer_text(id: &str, d: &Value) -> String {
    match d["state"].as_str() {
        Some("accepted") => format!("The person accepted offer {id}{}.", d["savedTo"].as_str().map(|p| format!("; the file is at {p} on this PC")).unwrap_or_default()),
        Some("refused") => format!("The person refused offer {id}."),
        Some("pending") => format!("Offer {id} is still waiting for the person."),
        Some("copying") => format!("Offer {id} was accepted and is being copied."),
        Some("expired") => format!("Offer {id} expired without an answer."),
        Some("failed") => format!("Offer {id} failed: {}", d["error"].as_str().unwrap_or("unknown error")),
        other => format!("Offer {id}: {}", other.unwrap_or("unknown")),
    }
}

fn describe(shot: &Shot) -> String {
    let scale = shot.sent.0 as f64 / shot.region.0 as f64;
    if shot.zoom {
        format!("Screenshot {} of {}: zoom of desktop [{}, {}, {}, {}] at {}x{} (scale {:.3}). For looking only; act with the full screenshot's pixels.",
            shot.id, shot.machine, shot.origin.0, shot.origin.1, shot.region.0, shot.region.1, shot.sent.0, shot.sent.1, scale)
    } else {
        format!("Screenshot {} of {}: {}x{} (desktop {}x{}, scale {:.3}). Actions use these pixels.",
            shot.id, shot.machine, shot.sent.0, shot.sent.1, shot.region.0, shot.region.1, scale)
    }
}
