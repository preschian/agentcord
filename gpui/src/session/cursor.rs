//! Cursor session from today's hook file (`%TEMP%\AgentCord\yyyy-MM-dd-uptime.json`).

use super::*;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub fn pretty_cursor_model(raw: &str) -> String {
    if raw.eq_ignore_ascii_case("default") {
        return "Auto".into();
    }
    let value = raw
        .strip_prefix("cursor-")
        .or_else(|| raw.strip_prefix("Cursor-"))
        .unwrap_or(raw);
    value
        .split('-')
        .filter(|p| !p.is_empty())
        .map(|part| {
            if part.chars().next().is_some_and(|c| c.is_ascii_digit()) {
                part.to_string()
            } else if part.eq_ignore_ascii_case("gpt") {
                "GPT".into()
            } else {
                let mut chars = part.chars();
                match chars.next() {
                    Some(c) => format!("{}{}", c.to_ascii_uppercase(), chars.as_str()),
                    None => String::new(),
                }
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn cursor_linked() -> bool {
    dirs_home().is_some_and(|home| {
        let c = home.join(".cursor");
        c.join("projects").is_dir() || c.join("chats").is_dir()
    })
}

pub fn scan_cursor(_idle_secs: f64) -> AgentScan {
    scan_cursor_at(&cursor_uptime_path(), now_ms())
}

pub(super) fn scan_cursor_at(path: &Path, now_ms: i64) -> AgentScan {
    let day = cursor_day_uptime_from(path, now_ms);
    let session = day.open.then(|| {
        let project = if day.project.is_empty() {
            "Cursor".into()
        } else {
            day.project
        };
        SessionInfo {
            agent: AgentKind::Cursor,
            project,
            model: String::new(),
            start_epoch_ms: now_ms - day.total_ms,
            activity_ms: now_ms,
            tokens: 0,
        }
    });
    AgentScan {
        today_ms: day.total_ms,
        session,
    }
}

pub(super) struct CursorDay {
    pub total_ms: i64,
    pub open: bool,
    pub project: String,
}

pub(super) fn cursor_day_uptime_from(path: &Path, now_ms: i64) -> CursorDay {
    let Some(text) = read_to_string(path) else {
        return CursorDay {
            total_ms: 0,
            open: false,
            project: String::new(),
        };
    };
    let mut open: HashMap<String, Vec<i64>> = HashMap::new();
    let mut total = 0i64;
    let mut project = String::new();
    for line in text.lines() {
        let line = line.trim().trim_start_matches('\u{feff}');
        if line.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(kind) = str_field(&v, "e") else {
            continue;
        };
        let Some(ms) = v.get("ms").and_then(json_i64) else {
            continue;
        };
        let id = str_field(&v, "id").unwrap_or_default();
        if let Some(cwd) = str_field(&v, "cwd").filter(|s| !s.is_empty()) {
            project = repo_from_cwd(&cwd);
        }
        if kind == "start" {
            open.entry(id).or_default().push(ms);
        } else if kind == "end" {
            if let Some(stack) = open.get_mut(&id) {
                if let Some(start) = stack.pop() {
                    if ms > start {
                        total += ms - start;
                    }
                }
            }
        }
    }
    let mut live = false;
    for starts in open.values() {
        for start in starts {
            live = true;
            if now_ms > *start {
                total += now_ms - *start;
            }
        }
    }
    CursorDay {
        total_ms: total.max(0),
        open: live,
        project,
    }
}

pub(super) fn cursor_uptime_path() -> PathBuf {
    cursor_uptime_dir().join(format!("{}-uptime.json", local_ymd()))
}

pub(super) fn cursor_uptime_dir() -> PathBuf {
    if let Some(p) = std::env::var_os("AGENTCORD_CURSOR_UPTIME_DIR") {
        return PathBuf::from(p);
    }
    std::env::temp_dir().join("AgentCord")
}
