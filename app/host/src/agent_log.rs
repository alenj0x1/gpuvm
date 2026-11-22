use serde_json::{json, Value};
use std::collections::VecDeque;
use std::io::Write;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

struct Feed {
    next: u64,
    list: VecDeque<Value>,
}

static FEED: Mutex<Feed> = Mutex::new(Feed { next: 1, list: VecDeque::new() });
static FEED_CHANGED: Condvar = Condvar::new();
const FEED_MAX: usize = 300;
pub const WAIT_MAX_MS: u64 = 15_000;

pub fn push(mut event: Value) {
    let mut feed = FEED.lock().unwrap_or_else(|e| e.into_inner());
    event["seq"] = json!(feed.next);
    feed.next += 1;
    feed.list.push_back(event);
    while feed.list.len() > FEED_MAX {
        feed.list.pop_front();
    }
    FEED_CHANGED.notify_all();
}

pub fn wait(after: u64, timeout: Duration) -> Value {
    let feed = FEED.lock().unwrap_or_else(|e| e.into_inner());
    let after = if after >= feed.next { 0 } else { after };
    let (feed, _) = FEED_CHANGED
        .wait_timeout_while(feed, timeout, |f| f.list.back().is_none_or(|e| e["seq"].as_u64().unwrap_or(0) <= after))
        .unwrap_or_else(|e| e.into_inner());
    let events: Vec<Value> = feed.list.iter().filter(|e| e["seq"].as_u64().unwrap_or(0) > after).cloned().collect();
    json!({ "last": feed.next - 1, "events": events })
}

const MAX_POINTS: usize = 400;

fn num(v: &Value, k: &str) -> Option<i64> {
    v.get(k).and_then(Value::as_f64).map(|f| f.round() as i64)
}

fn thin(points: &[(i64, i64)], max: usize) -> Vec<Value> {
    if points.len() <= max {
        return points.iter().map(|(x, y)| json!([x, y])).collect();
    }
    let step = (points.len() - 1) as f64 / (max - 1) as f64;
    (0..max).map(|i| points[((i as f64 * step).round() as usize).min(points.len() - 1)]).map(|(x, y)| json!([x, y])).collect()
}

// Never what was typed: only shapes.
fn shape(a: &Value) -> Option<Value> {
    let kind = a["type"].as_str()?;
    Some(match kind {
        "click" => json!({ "type": "click", "x": num(a, "x")?, "y": num(a, "y")?, "button": a["button"].as_str().unwrap_or("left"), "count": a["count"].as_u64().unwrap_or(1).min(3) }),
        "move" => json!({ "type": "move", "x": num(a, "x")?, "y": num(a, "y")? }),
        "scroll" => json!({ "type": "scroll", "x": num(a, "x")?, "y": num(a, "y")?, "dy": num(a, "dy").unwrap_or(0).clamp(-50, 50), "dx": num(a, "dx").unwrap_or(0).clamp(-50, 50) }),
        "type" => json!({ "type": "type", "chars": a["text"].as_str().map(|t| t.chars().count()).unwrap_or(0) }),
        "key" => json!({ "type": "key", "keys": a["keys"].as_str().map(|k| k.chars().filter(|c| c.is_ascii_alphanumeric() || "+-_ ".contains(*c)).take(40).collect::<String>()).unwrap_or_default() }),
        "wait" => json!({ "type": "wait", "ms": a["ms"].as_u64().unwrap_or(0).min(5000) }),
        "drag" => {
            let mut strokes: Vec<Vec<(i64, i64)>> = Vec::new();
            if let Some(list) = a["strokes"].as_array() {
                for s in list.iter().filter_map(Value::as_array) {
                    let flat: Vec<i64> = s.iter().filter_map(|v| v.as_f64().map(|f| f.round() as i64)).collect();
                    strokes.push(flat.chunks_exact(2).map(|p| (p[0], p[1])).collect());
                }
            } else {
                strokes.push(vec![(num(a, "x")?, num(a, "y")?), (num(a, "toX")?, num(a, "toY")?)]);
            }
            let total: usize = strokes.iter().map(Vec::len).sum::<usize>().max(1);
            let strokes: Vec<Value> = strokes.iter().filter(|s| !s.is_empty())
                .map(|s| Value::Array(thin(s, (s.len() * MAX_POINTS / total).max(2)))).collect();
            json!({ "type": "drag", "strokes": strokes, "ms": a["ms"].as_u64() })
        }
        _ => return None,
    })
}

pub fn shapes(method: &str, params: &Value) -> Option<Value> {
    match method {
        "input.act" => {
            let list: Vec<Value> = params["actions"].as_array()?.iter().take(50).filter_map(shape).collect();
            (!list.is_empty()).then(|| Value::Array(list))
        }
        "ui.invoke" => Some(json!([{ "type": "invoke", "action": params["action"].as_str().unwrap_or("invoke") }])),
        _ => None,
    }
}

fn history_path() -> std::path::PathBuf {
    crate::agent::agents_dir().join("history.jsonl")
}

static HISTORY_LOCK: Mutex<()> = Mutex::new(());
const HISTORY_MAX_BYTES: u64 = 2 << 20;

pub fn append(entry: &Value) {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let path = history_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    if std::fs::metadata(&path).is_ok_and(|m| m.len() > HISTORY_MAX_BYTES) {
        if let Ok(text) = std::fs::read_to_string(&path) {
            let lines: Vec<&str> = text.lines().collect();
            let keep = lines[lines.len() / 2..].join("\n") + "\n";
            let tmp = path.with_extension("jsonl.new");
            if std::fs::write(&tmp, keep).is_ok() {
                let _ = std::fs::rename(&tmp, &path);
            }
        }
    }
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{entry}");
    }
}

pub fn read(limit: usize) -> Value {
    let _guard = HISTORY_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let text = std::fs::read_to_string(history_path()).unwrap_or_default();
    Value::Array(text.lines().rev().filter_map(|l| serde_json::from_str::<Value>(l).ok()).filter(Value::is_object).take(limit).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shapes_never_carry_text() {
        let s = shapes("input.act", &json!({ "actions": [
            { "type": "type", "text": "my password" }, { "type": "click", "x": 10.4, "y": 20.6 },
            { "type": "key", "keys": "ctrl+shift+end" }, { "type": "drag", "strokes": [[0, 0, 10, 10, 20, 20]] } ] })).unwrap();
        assert!(!s.to_string().contains("password"));
        assert_eq!(s[0], json!({ "type": "type", "chars": 11 }));
        assert_eq!(s[1]["x"], 10);
        assert_eq!(s[1]["y"], 21);
        assert_eq!(s[2]["keys"], "ctrl+shift+end");
        assert_eq!(s[3]["strokes"][0].as_array().unwrap().len(), 3);
        assert!(shapes("exec.run", &json!({ "file": "x" })).is_none());
    }

    #[test]
    fn long_strokes_are_thinned() {
        let flat: Vec<i64> = (0..10_000).collect();
        let s = shapes("input.act", &json!({ "actions": [{ "type": "drag", "strokes": [flat] }] })).unwrap();
        assert!(s[0]["strokes"][0].as_array().unwrap().len() <= MAX_POINTS);
    }

    #[test]
    fn feed_waits_and_continues() {
        let mine = |v: &Value| v["events"].as_array().unwrap().iter().filter(|e| e["feedTest"].is_number()).cloned().collect::<Vec<_>>();
        push(json!({ "feedTest": 1 }));
        let first = wait(0, Duration::from_millis(10));
        let last = first["last"].as_u64().unwrap();
        assert_eq!(mine(&first).len(), 1);
        assert!(mine(&wait(last, Duration::from_millis(20))).is_empty());
        std::thread::spawn(|| { std::thread::sleep(Duration::from_millis(30)); push(json!({ "feedTest": 2 })); });
        let start = std::time::Instant::now();
        let mut got = Vec::new();
        let mut after = last;
        while got.is_empty() && start.elapsed() < Duration::from_secs(5) {
            let next = wait(after, Duration::from_secs(5));
            after = next["last"].as_u64().unwrap();
            got = mine(&next);
        }
        assert_eq!(got[0]["feedTest"], 2);
    }
}
