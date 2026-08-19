//! Install Cursor user hooks once. Marker is `agentcord-cursor-turn.ps1`.

use serde_json::{json, Value};
use std::fs;
use std::path::{Path, PathBuf};

const MARKER: &str = "agentcord-cursor-turn.ps1";
const HOOK_CMD: &str =
    r#"powershell.exe -NoProfile -ExecutionPolicy Bypass -File "./hooks/agentcord-cursor-turn.ps1""#;
const SCRIPT: &str = include_str!("../../hooks/agentcord-cursor-turn.ps1");
const EVENTS: [&str; 2] = ["beforeSubmitPrompt", "stop"];

pub fn ensure() {
    let Some(home) = cursor_home() else {
        return;
    };
    let _ = ensure_in(&home);
}

fn cursor_home() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(|h| PathBuf::from(h).join(".cursor"))
}

fn ensure_in(cursor_home: &Path) -> bool {
    let hooks_dir = cursor_home.join("hooks");
    let _ = fs::create_dir_all(&hooks_dir);
    let script = hooks_dir.join(MARKER);
    if fs::read_to_string(&script).ok().as_deref() != Some(SCRIPT) {
        let _ = fs::write(&script, SCRIPT);
    }
    let path = cursor_home.join("hooks.json");
    let mut root: Value = fs::read_to_string(&path)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({ "version": 1, "hooks": {} }));
    if !root.get("hooks").map_or(false, |h| h.is_object()) {
        root["hooks"] = json!({});
    }
    if root.get("version").is_none() {
        root["version"] = json!(1);
    }
    let mut changed = false;
    for event in EVENTS {
        changed |= ensure_event(root["hooks"].as_object_mut().unwrap(), event);
    }
    if changed {
        if let Ok(text) = serde_json::to_string_pretty(&root) {
            let _ = fs::write(path, text);
        }
    }
    changed
}

fn is_ours(cmd: &str) -> bool {
    cmd.contains(MARKER)
}

fn ensure_event(hooks: &mut serde_json::Map<String, Value>, event: &str) -> bool {
    let mut arr = hooks
        .get(event)
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let before = arr.len();
    let mut kept = false;
    arr.retain(|item| {
        let cmd = item
            .get("command")
            .and_then(|c| c.as_str())
            .unwrap_or("");
        if !is_ours(cmd) {
            return true;
        }
        if kept {
            return false;
        }
        kept = true;
        true
    });
    let mut changed = arr.len() != before;
    if !kept {
        arr.push(json!({ "command": HOOK_CMD, "timeout": 5 }));
        changed = true;
    }
    if changed {
        hooks.insert(event.to_string(), Value::Array(arr));
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_once_does_not_duplicate() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-hooks-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("hooks.json"),
            r#"{"version":1,"hooks":{"stop":[{"command":"other"}]}}"#,
        )
        .unwrap();
        assert!(ensure_in(&dir));
        assert!(!ensure_in(&dir));
        let v: Value =
            serde_json::from_str(&fs::read_to_string(dir.join("hooks.json")).unwrap()).unwrap();
        let stop = v["hooks"]["stop"].as_array().unwrap();
        assert_eq!(stop.iter().filter(|x| is_ours(x["command"].as_str().unwrap_or(""))).count(), 1);
        assert_eq!(
            v["hooks"]["beforeSubmitPrompt"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|x| is_ours(x["command"].as_str().unwrap_or("")))
                .count(),
            1
        );
        assert!(dir.join("hooks").join(MARKER).is_file());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn dedupes_existing_copies() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-hooks-dup-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("hooks.json"),
            r#"{"version":1,"hooks":{"stop":[{"command":"agentcord-cursor-turn.ps1"},{"command":"agentcord-cursor-turn.ps1 extra"}]}}"#,
        )
        .unwrap();
        assert!(ensure_in(&dir));
        assert!(!ensure_in(&dir));
        let v: Value =
            serde_json::from_str(&fs::read_to_string(dir.join("hooks.json")).unwrap()).unwrap();
        assert_eq!(v["hooks"]["stop"].as_array().unwrap().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }
}
