//! Claude Code session scan (`~/.claude/projects`).

use super::*;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub fn pretty_claude_model(raw: &str) -> String {
    let lower = raw.to_ascii_lowercase();
    let family = if lower.contains("opus") {
        "Opus"
    } else if lower.contains("sonnet") {
        "Sonnet"
    } else if lower.contains("haiku") {
        "Haiku"
    } else if lower.contains("fable") {
        "Fable"
    } else {
        return raw.to_string();
    };
    match claude_version(raw) {
        Some(ver) => format!("{family} {ver}"),
        None => family.into(),
    }
}

fn claude_version(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    let mut i = 0;
    while i < bytes.len() && !bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i == bytes.len() {
        return None;
    }
    let start = i;
    i += 1;
    while i < bytes.len() && bytes[i].is_ascii_digit() {
        i += 1;
    }
    if i + 1 < bytes.len()
        && (bytes[i] == b'.' || bytes[i] == b'-')
        && bytes[i + 1].is_ascii_digit()
    {
        i += 2;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            i += 1;
        }
        return Some(raw[start..i].replace('-', "."));
    }
    Some(raw[start..i].to_string())
}

pub fn claude_linked() -> bool {
    claude_home().is_some_and(|home| home.join("projects").is_dir())
}

pub fn scan_claude(idle_secs: f64) -> AgentScan {
    let Some(home) = claude_home() else {
        return AgentScan::default();
    };
    scan_claude_from(&home.join("projects"), idle_secs)
}

pub(super) fn scan_claude_from(projects: &Path, idle_secs: f64) -> AgentScan {
    if !projects.is_dir() {
        return AgentScan::default();
    }
    let now = now_ms();
    let files = tree_snapshot(projects, "claude-jsonl", 8, |p| {
        p.extension().and_then(|e| e.to_str()) == Some("jsonl")
    });
    let mut best: Option<(PathBuf, i64, JsonlAgg)> = None;
    for (path, mtime) in &files {
        let agg = jsonl_cached(path, parse_claude_line);
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
    let today_ms = day_uptime(&files, parse_claude_line, now, live);
    let session = match best {
        Some((transcript, activity, tail)) if live => {
            let project = tail
                .cwd
                .as_deref()
                .map(repo_from_cwd)
                .filter(|s| !s.is_empty())
                .or_else(|| claude_project_from_dir(&transcript))
                .unwrap_or_else(|| "Claude".into());
            Some(SessionInfo {
                agent: AgentKind::Claude,
                project,
                model: tail.model.unwrap_or_default(),
                start_epoch_ms: now - today_ms,
                activity_ms: activity,
                tokens: tail.tokens,
            })
        }
        _ => None,
    };
    AgentScan { today_ms, session }
}

fn claude_home() -> Option<PathBuf> {
    env_home("CLAUDE_HOME").or_else(|| Some(dirs_home()?.join(".claude")))
}

fn parse_claude_line(line: &str, agg: &mut JsonlAgg) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    if agg.cwd.is_none() {
        if let Some(cwd) = str_field(&v, "cwd").filter(|s| !s.is_empty()) {
            agg.cwd = Some(cwd);
        }
    }
    if let Some(ms) = json_time(v.get("timestamp")) {
        note_stamp(agg, ms);
    }
    let Some(message) = v.get("message") else {
        return;
    };
    if let Some(model) =
        str_field(message, "model").filter(|m| m != "<synthetic>" && !m.is_empty())
    {
        agg.model = Some(pretty_claude_model(&model));
    }
    if let Some(usage) = message.get("usage") {
        agg.tokens += usage.get("input_tokens").and_then(json_i64).unwrap_or(0)
            + usage.get("output_tokens").and_then(json_i64).unwrap_or(0);
    }
}

fn claude_project_from_dir(transcript: &Path) -> Option<String> {
    let dir = transcript.parent()?.file_name()?.to_str()?;
    dir.rsplit_once('-')
        .map(|(_, tail)| tail)
        .filter(|t| !t.is_empty())
        .or(Some(dir))
        .map(str::to_string)
}

