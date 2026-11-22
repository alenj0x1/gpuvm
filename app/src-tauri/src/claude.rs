// Allowing all mcp__gpuvm tools is safe: GpuVM's own gate asks the person for anything risky, whatever the client allows.

use serde_json::{json, Value};
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const RULE: &str = "mcp__gpuvm";

fn home() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE").map(PathBuf::from)
}

// Only absolute PATH entries: a relative or empty one would resolve against GpuVM's working folder.
fn cli() -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(h) = home() {
        candidates.push(h.join(".local").join("bin").join("claude.exe"));
    }
    if let Some(appdata) = std::env::var_os("APPDATA") {
        candidates.push(PathBuf::from(appdata).join("npm").join("claude.cmd"));
    }
    let path: Vec<PathBuf> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).filter(|d| d.is_absolute()).collect()).unwrap_or_default();
    candidates.extend(path.iter().flat_map(|d| ["claude.exe", "claude.cmd"].map(|n| d.join(n))));
    candidates.into_iter().find(|p| p.is_file())
}

fn read_json(path: &PathBuf) -> Result<Option<Value>, String> {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(text.trim_start_matches('\u{feff}')).map(Some).map_err(|_| format!("{} isn't valid JSON.", path.display())),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

fn settings_path() -> Option<PathBuf> {
    home().map(|h| h.join(".claude").join("settings.json"))
}

fn allowed(settings: &Value) -> bool {
    settings["permissions"]["allow"].as_array().is_some_and(|a| a.iter().any(|r| r == RULE))
}

fn added() -> Option<Value> {
    let config = read_json(&home()?.join(".claude.json")).ok()??;
    let server = config["mcpServers"]["gpuvm"].clone();
    (!server.is_null()).then_some(server)
}

#[tauri::command]
pub fn claude_code_state() -> Value {
    let exe = std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default();
    let server = added();
    let current = server.as_ref().is_some_and(|s| s["command"].as_str().is_some_and(|c| c.eq_ignore_ascii_case(&exe)));
    let allowed = settings_path().and_then(|p| read_json(&p).ok().flatten()).is_some_and(|s| allowed(&s));
    json!({ "cli": cli().is_some(), "added": server.is_some(), "current": current, "allowed": allowed })
}

fn after_key(text: &str, from: usize, key: &str, open: char) -> Option<usize> {
    let k = text[from..].find(&format!("\"{key}\""))? + from;
    let rest = &text[k + key.len() + 2..];
    let colon = rest.find(':')?;
    let value = rest[colon + 1..].trim_start();
    value.starts_with(open).then(|| text.len() - value.len() + 1)
}

fn allow_tools() -> Result<(), String> {
    let path = settings_path().ok_or("No user profile.")?;
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e.to_string()),
    };
    let bom = text.starts_with('\u{feff}');
    let body = text.trim_start_matches('\u{feff}');
    let after = if body.trim().is_empty() {
        serde_json::to_string_pretty(&json!({ "permissions": { "allow": [RULE] } })).map_err(|e| e.to_string())? + "\n"
    } else {
        let before: Value = serde_json::from_str(body).map_err(|_| format!("{} isn't valid JSON: it was left as it is.", path.display()))?;
        if !before.is_object() {
            return Err(format!("{} isn't a JSON object: it was left as it is.", path.display()));
        }
        if allowed(&before) {
            return Ok(());
        }
        let mut expected = before.clone();
        let edited = if before["permissions"]["allow"].is_array() {
            expected["permissions"]["allow"].as_array_mut().map(|a| a.insert(0, json!(RULE)));
            let p = body.find("\"permissions\"").ok_or("permissions")?;
            let at = after_key(body, p, "allow", '[').ok_or("allow")?;
            let empty = body[at..].trim_start().starts_with(']');
            format!("{}\"{RULE}\"{}{}", &body[..at], if empty { "" } else { ", " }, &body[at..])
        } else if before["permissions"].is_object() {
            expected["permissions"]["allow"] = json!([RULE]);
            let at = after_key(body, 0, "permissions", '{').ok_or("permissions")?;
            let empty = body[at..].trim_start().starts_with('}');
            format!("{}\"allow\": [\"{RULE}\"]{}{}", &body[..at], if empty { "" } else { ", " }, &body[at..])
        } else if before.get("permissions").is_none() {
            expected["permissions"] = json!({ "allow": [RULE] });
            let at = body.find('{').ok_or("{")? + 1;
            let empty = body[at..].trim_start().starts_with('}');
            format!("{}\n  \"permissions\": {{ \"allow\": [\"{RULE}\"] }}{}{}", &body[..at], if empty { "\n" } else { "," }, &body[at..])
        } else {
            return Err(format!("{}: \"permissions\" isn't an object, it was left as it is.", path.display()));
        };
        if serde_json::from_str::<Value>(&edited).ok().as_ref() != Some(&expected) {
            return Err(format!("Couldn't add GpuVM's permission to {} without changing anything else: it was left as it is.", path.display()));
        }
        if bom { format!("\u{feff}{edited}") } else { edited }
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("json.gpuvm-new");
    std::fs::write(&tmp, after).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &path).map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn connect_claude_code() -> Result<Value, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let claude = cli().ok_or("Claude Code isn't installed on this PC.")?;
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let run = |args: &[&std::ffi::OsStr]| Command::new(&claude).args(args).creation_flags(CREATE_NO_WINDOW).output().map_err(|e| e.to_string());
        if !claude_code_state()["current"].as_bool().unwrap_or(false) {
            let old = added();
            if old.is_some() {
                let _ = run(&["mcp".as_ref(), "remove".as_ref(), "gpuvm".as_ref(), "-s".as_ref(), "user".as_ref()]);
            }
            let out = run(&["mcp".as_ref(), "add".as_ref(), "-s".as_ref(), "user".as_ref(), "gpuvm".as_ref(), "--".as_ref(), exe.as_os_str(), "--mcp".as_ref()])?;
            if !out.status.success() {
                if let Some(cmd) = old.as_ref().and_then(|o| o["command"].as_str()) {
                    let args: Vec<String> = old.as_ref().and_then(|o| o["args"].as_array()).map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_string)).collect()).unwrap_or_default();
                    let mut back: Vec<&std::ffi::OsStr> = vec!["mcp".as_ref(), "add".as_ref(), "-s".as_ref(), "user".as_ref(), "gpuvm".as_ref(), "--".as_ref(), cmd.as_ref()];
                    back.extend(args.iter().map(|a| std::ffi::OsStr::new(a.as_str())));
                    let _ = run(&back);
                }
                let msg = String::from_utf8_lossy(&out.stderr).trim().to_string();
                return Err(if msg.is_empty() { "Claude Code couldn't add GpuVM.".into() } else { msg });
            }
        }
        allow_tools()?;
        Ok(claude_code_state())
    }).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_allow_inside_permissions_only() {
        let text = r#"{ "note": { "allow": ["x"] }, "permissions": { "deny": [], "allow": [ "a" ] } }"#;
        let p = text.find("\"permissions\"").unwrap();
        let at = after_key(text, p, "allow", '[').unwrap();
        assert_eq!(&text[at..at + 5], " \"a\" ");
    }
}
