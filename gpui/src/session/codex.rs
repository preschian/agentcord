//! Codex session scan (`~/.codex/sessions`).

use super::*;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub fn pretty_codex_model(raw: &str) -> String {
    let rest = match raw
        .strip_prefix("gpt-")
        .or_else(|| raw.strip_prefix("GPT-"))
    {
        Some(r) => r,
        None => return raw.to_string(),
    };
    let mut version = Vec::new();
    let mut suffix = Vec::new();
    for part in rest.split('-').filter(|p| !p.is_empty()) {
        if suffix.is_empty() && part.chars().all(|c| c.is_ascii_digit() || c == '.') {
            version.push(part);
        } else {
            let mut chars = part.chars();
            let pretty = match chars.next() {
                Some(c) => format!("{}{}", c.to_ascii_uppercase(), chars.as_str()),
                None => String::new(),
            };
            suffix.push(pretty);
        }
    }
    let ver = version.join(".");
    let suf = if suffix.is_empty() {
        String::new()
    } else {
        format!(" {}", suffix.join(" "))
    };
    if ver.is_empty() {
        format!("GPT{suf}")
    } else {
        format!("GPT-{ver}{suf}")
    }
}

pub fn codex_linked() -> bool {
    codex_home().is_some_and(|home| home.join("sessions").is_dir())
}


pub fn scan_codex() -> AgentScan {
    let Some(home) = codex_home() else {
        return AgentScan::default();
    };
    scan_codex_from(&home.join("sessions"), IDLE_WINDOW_SECS)
}

pub(super) fn scan_codex_from(sessions: &Path, idle_secs: f64) -> AgentScan {
    if !sessions.is_dir() {
        return AgentScan::default();
    }
    let now = now_ms();
    let files = tree_snapshot(sessions, "codex-jsonl", 8, |p| {
        p.extension().and_then(|e| e.to_str()) == Some("jsonl")
    });
    let mut best: Option<(PathBuf, i64, JsonlAgg)> = None;
    for (path, mtime) in &files {
        let agg = jsonl_cached(path, parse_codex_line);
        let activity = normalize_ms(agg.last_event_ms, *mtime);
        if best
            .as_ref()
            .is_none_or(|(_, a, _)| activity >= *a)
        {
            best = Some((path.clone(), activity, agg));
        }
    }
    let live = best
        .as_ref()
        .is_some_and(|(_, activity, _)| within_idle(*activity, now, idle_secs));
    let today_ms = day_uptime(&files, parse_codex_line, now, live);
    let session = match best {
        Some((_transcript, activity, tail)) if live => {
            let project = tail
                .cwd
                .as_deref()
                .map(repo_from_cwd)
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "Codex".into());
            Some(SessionInfo {
                agent: AgentKind::Codex,
                project,
                model: tail.model.unwrap_or_else(|| "Codex".into()),
                start_epoch_ms: now - today_ms,
                activity_ms: activity,
                tokens: tail.tokens,
            })
        }
        _ => None,
    };
    AgentScan { today_ms, session }
}

fn codex_home() -> Option<PathBuf> {
    env_home("CODEX_HOME").or_else(|| Some(dirs_home()?.join(".codex")))
}

fn parse_codex_line(line: &str, agg: &mut JsonlAgg) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    if let Some(ms) = json_time(v.get("timestamp")) {
        note_stamp(agg, ms);
    }
    let Some(ty) = str_field(&v, "type") else {
        return;
    };
    let Some(payload) = v.get("payload") else {
        return;
    };
    if ty == "session_meta" || ty == "turn_context" {
        if let Some(cwd) = str_field(payload, "cwd").filter(|s| !s.is_empty()) {
            agg.cwd = Some(cwd);
        }
        if ty == "turn_context" {
            if let Some(model) = str_field(payload, "model").filter(|s| !s.is_empty()) {
                agg.model = Some(pretty_codex_model(&model));
            }
        }
        if ty == "session_meta" {
            if let Some(ms) = json_time(payload.get("timestamp")) {
                note_stamp(agg, ms);
            }
        }
    }
    if ty == "event_msg" && str_field(payload, "type").as_deref() == Some("token_count") {
        if let Some(usage) = payload.get("info").and_then(|i| i.get("last_token_usage")) {
            let total = usage.get("total_tokens").and_then(json_i64).unwrap_or(0);
            agg.tokens = if total > 0 {
                total
            } else {
                usage.get("input_tokens").and_then(json_i64).unwrap_or(0)
                    + usage.get("output_tokens").and_then(json_i64).unwrap_or(0)
            };
        }
    }
}

