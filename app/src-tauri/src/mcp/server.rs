use super::broker::Broker;
use super::tools::{self, Ctx};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, Write};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const MODERN: &str = "2026-07-28";
pub const LEGACY: &[&str] = &["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];
pub const SERVER_NAME: &str = "gpuvm";

const META_VERSION: &str = "io.modelcontextprotocol/protocolVersion";
const META_CLIENT: &str = "io.modelcontextprotocol/clientInfo";
const META_CAPS: &str = "io.modelcontextprotocol/clientCapabilities";
const META_SERVER: &str = "io.modelcontextprotocol/serverInfo";

pub const INSTRUCTIONS: &str = "GpuVM runs Windows virtual machines on this PC for you to use while the person \
watches and can take over. Flow: list_templates → create_disposable (or list_machines → take_machine) → \
screenshot → click/type/key/act → screenshot again to check. Coordinates are pixels of the screenshot you \
looked at (each screenshot has an id; actions use the latest one unless you pass `screenshot`). Prefer \
ui_tree + ui_invoke for standard controls and `run` for commands. UAC prompts, the lock screen, passwords and \
payments are human-only: use request_human. Files go in with send_file/write_file and leave only through \
offer_file, which the person approves in GpuVM. open_viewer answers once the person sees the picture. If a \
call says the person took control, call wait_for_person (don't ask in the chat or retry): it answers when they \
hand the machine back. Give each action a short `intent` (\"Drawing the moon\", \"Installing Blender\"): \
the person sees it live over the machine.";

pub fn server_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn server_info() -> Value {
    json!({ "name": SERVER_NAME, "title": "GpuVM", "version": server_version() })
}

pub type Out = Arc<Mutex<Box<dyn Write + Send>>>;

pub fn send(out: &Out, message: &Value) {
    // One write per message, so a line is never split between writers.
    let line = format!("{message}\n");
    let mut w = out.lock().unwrap_or_else(|e| e.into_inner());
    let _ = w.write_all(line.as_bytes());
    let _ = w.flush();
}

pub fn log(line: &str) {
    eprintln!("[gpuvm-mcp] {line}");
}

#[derive(Default, Clone, Debug)]
pub struct Client {
    pub name: String,
    pub version: String,
    pub protocol: String,
    pub legacy: bool,
    pub elicitation: bool,
}

pub struct Server {
    pub ctx: Arc<Ctx>,
    out: Out,
    legacy: Mutex<Option<Client>>,
    waiting: Mutex<HashMap<String, mpsc::Sender<Value>>>,
    pub cancelled: Arc<Mutex<HashSet<String>>>,
    next_id: std::sync::atomic::AtomicU64,
    threads: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl Server {
    pub fn new(broker: Arc<dyn Broker>, out: Out) -> Arc<Self> {
        Arc::new(Server {
            ctx: Arc::new(Ctx::new(broker)),
            out,
            legacy: Mutex::new(None),
            waiting: Mutex::new(HashMap::new()),
            cancelled: Arc::new(Mutex::new(HashSet::new())),
            next_id: std::sync::atomic::AtomicU64::new(1),
            threads: Mutex::new(Vec::new()),
        })
    }

    pub fn serve(self: &Arc<Self>, input: impl BufRead) {
        // A client that writes another encoding gets its bad bytes replaced, not a server that hangs up.
        for line in input.split(b'\n') {
            let Ok(line) = line else { break };
            let line = String::from_utf8_lossy(&line);
            let line = line.trim_end_matches('\r');
            if line.trim().is_empty() {
                continue;
            }
            self.handle_line(line);
        }
        self.finish();
    }

    pub fn finish(&self) {
        self.ctx.shutting_down.store(true, std::sync::atomic::Ordering::Relaxed);
        self.ctx.disconnect();
        self.join();
    }

    pub fn join(&self) {
        let handles: Vec<_> = std::mem::take(&mut *self.threads.lock().unwrap());
        for h in handles {
            let _ = h.join();
        }
    }

    pub fn handle_line(self: &Arc<Self>, line: &str) {
        let message: Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(_) => return send(&self.out, &rpc_error(Value::Null, -32700, "Parse error: send one JSON-RPC message per line.", None)),
        };
        if message.is_array() {
            return send(&self.out, &rpc_error(Value::Null, -32600, "Batches aren't supported; send one message per line.", None));
        }
        let id = message.get("id").cloned();
        if message.get("method").is_none() {
            if let Some(id) = id {
                let key = id.to_string();
                if let Some(tx) = self.waiting.lock().unwrap().remove(&key) {
                    let _ = tx.send(message);
                }
            }
            return;
        }
        let method = message["method"].as_str().unwrap_or("").to_string();
        let params = message.get("params").cloned().unwrap_or(json!({}));
        let Some(id) = id else {
            if method == "notifications/cancelled" {
                if let Some(rid) = params.get("requestId") {
                    self.cancelled.lock().unwrap().insert(rid.to_string());
                }
            }
            return;
        };

        let meta = params.get("_meta").cloned().unwrap_or(Value::Null);
        let client = if let Some(version) = meta.get(META_VERSION).and_then(Value::as_str) {
            if version != MODERN {
                return send(&self.out, &rpc_error(id, -32022, "Unsupported protocol version",
                    Some(json!({ "supported": supported(), "requested": version }))));
            }
            let info = meta.get(META_CLIENT).cloned().unwrap_or(Value::Null);
            let caps = meta.get(META_CAPS).cloned().unwrap_or(Value::Null);
            Client {
                name: info["name"].as_str().unwrap_or("unknown").into(),
                version: info["version"].as_str().unwrap_or("").into(),
                protocol: MODERN.into(),
                legacy: false,
                elicitation: caps.get("elicitation").is_some(),
            }
        } else if method == "initialize" {
            let asked = params["protocolVersion"].as_str().unwrap_or("");
            let chosen = if LEGACY.contains(&asked) { asked } else { LEGACY[0] };
            let client = Client {
                name: params["clientInfo"]["name"].as_str().unwrap_or("unknown").into(),
                version: params["clientInfo"]["version"].as_str().unwrap_or("").into(),
                protocol: chosen.into(),
                legacy: true,
                elicitation: params["capabilities"].get("elicitation").is_some(),
            };
            log(&format!("initialize from {} {} ({chosen})", client.name, client.version));
            *self.legacy.lock().unwrap() = Some(client.clone());
            self.ctx.identify(&client);
            return send(&self.out, &json!({ "jsonrpc": "2.0", "id": id, "result": {
                "protocolVersion": chosen,
                "capabilities": { "tools": { "listChanged": false } },
                "serverInfo": server_info(),
                "instructions": INSTRUCTIONS,
            } }));
        } else if method == "server/discover" {
            // A probe without a version: answer it the modern way so dual-era clients pick it.
            Client { name: "unknown".into(), protocol: MODERN.into(), ..Default::default() }
        } else if let Some(c) = self.legacy.lock().unwrap().clone() {
            c
        } else {
            return send(&self.out, &rpc_error(id, -32600,
                &format!("Send `initialize` first, or put the protocol version in _meta ({MODERN}; also {}).", LEGACY.join(", ")),
                Some(json!({ "supported": supported() }))));
        };
        if !client.legacy && client.name != "unknown" {
            self.ctx.identify(&client);
        }

        match method.as_str() {
            "server/discover" => self.reply(&client, id, json!({
                "supportedVersions": supported(),
                "capabilities": { "tools": {} },
                "instructions": INSTRUCTIONS,
                "ttlMs": 3_600_000,
                "cacheScope": "private",
            })),
            "ping" => self.reply(&client, id, json!({})),
            "tools/list" => {
                let mut result = json!({ "tools": tools::definitions() });
                if !client.legacy {
                    result["ttlMs"] = json!(3_600_000);
                    result["cacheScope"] = json!("private");
                }
                self.reply(&client, id, result)
            }
            "tools/call" => {
                let server = Arc::clone(self);
                // Input calls on one machine keep the order they were read in (each runs on its own thread).
                let ticket = tools::input_ticket(&self.ctx, &params);
                let handle = std::thread::spawn(move || {
                    let _turn = ticket.as_ref().map(|(machine, t)| server.ctx.input.wait_turn(machine, *t));
                    let result = server.call_tool(&client, &id, &params);
                    server.cancelled.lock().unwrap().remove(&id.to_string());
                    server.reply(&client, id, result);
                });
                let mut threads = self.threads.lock().unwrap();
                threads.retain(|h| !h.is_finished());
                threads.push(handle);
            }
            "resources/list" | "resources/templates/list" | "prompts/list" if client.legacy => {
                let key = method.split('/').next().unwrap_or("resources");
                let key = if method == "resources/templates/list" { "resourceTemplates" } else { key };
                self.reply(&client, id, json!({ key: [] }))
            }
            _ => send(&self.out, &rpc_error(id, -32601, &format!("Method not found: {method}"), None)),
        }
    }

    fn reply(&self, client: &Client, id: Value, mut result: Value) {
        if !client.legacy {
            if result.get("resultType").is_none() {
                result["resultType"] = json!("complete");
            }
            let meta = result.as_object_mut().unwrap().entry("_meta").or_insert(json!({}));
            meta[META_SERVER] = server_info();
        }
        send(&self.out, &json!({ "jsonrpc": "2.0", "id": id, "result": result }));
    }

    fn call_tool(self: &Arc<Self>, client: &Client, id: &Value, params: &Value) -> Value {
        let name = params["name"].as_str().unwrap_or("");
        let args = params.get("arguments").cloned().unwrap_or(json!({}));
        let cancelled = {
            let set = Arc::clone(&self.cancelled);
            let key = id.to_string();
            move || set.lock().unwrap().contains(&key)
        };
        let server = Arc::clone(self);
        let client2 = client.clone();
        let ask = move |message: &str| -> Option<bool> { server.ask(&client2, message) };
        let call = tools::Call {
            client,
            args: &args,
            input_responses: params.get("inputResponses"),
            request_state: params.get("requestState").and_then(Value::as_str),
            cancelled: &cancelled,
            ask_legacy: &ask,
        };
        let started = std::time::Instant::now();
        let result = tools::call(&self.ctx, name, &call);
        if result["isError"] == true {
            log(&format!("{name} failed after {} ms: {}", started.elapsed().as_millis(), result["content"][0]["text"].as_str().unwrap_or("")));
        } else if std::env::var_os("GPUVM_MCP_LOG").is_some() {
            log(&format!("{name} {} ms", started.elapsed().as_millis()));
        }
        result
    }

    fn ask(&self, client: &Client, message: &str) -> Option<bool> {
        if !client.legacy || !client.elicitation {
            return None;
        }
        let n = self.next_id.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let id = json!(format!("gpuvm-ask-{n}"));
        let (tx, rx) = mpsc::channel();
        self.waiting.lock().unwrap().insert(id.to_string(), tx);
        send(&self.out, &json!({ "jsonrpc": "2.0", "id": id, "method": "elicitation/create", "params": {
            "mode": "form", "message": message,
            "requestedSchema": { "type": "object", "properties": {} } } }));
        let answer = rx.recv_timeout(Duration::from_secs(300)).ok();
        self.waiting.lock().unwrap().remove(&id.to_string());
        Some(answer.is_some_and(|a| a["result"]["action"] == "accept"))
    }
}

pub fn supported() -> Vec<&'static str> {
    std::iter::once(MODERN).chain(LEGACY.iter().copied()).collect()
}

pub fn rpc_error(id: Value, code: i64, message: &str, data: Option<Value>) -> Value {
    let mut error = Map::new();
    error.insert("code".into(), json!(code));
    error.insert("message".into(), json!(message));
    if let Some(d) = data {
        error.insert("data".into(), d);
    }
    json!({ "jsonrpc": "2.0", "id": id, "error": Value::Object(error) })
}

pub fn run(fake: bool) -> i32 {
    let broker: Arc<dyn Broker> = if fake {
        Arc::new(super::fake::FakeBroker::new())
    } else {
        Arc::new(super::broker::PipeBroker::new())
    };
    let out: Out = Arc::new(Mutex::new(Box::new(std::io::stdout())));
    let server = Server::new(broker, out);
    log(&format!("GpuVM MCP server {} ({}) ready", server_version(), if fake { "fake broker" } else { "GpuVM service" }));
    server.serve(std::io::stdin().lock());
    0
}
