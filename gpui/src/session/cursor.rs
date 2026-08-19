//! Cursor session scan (`~/.cursor` transcripts + optional turn hooks).

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

pub fn scan_cursor(idle_secs: f64) -> Option<SessionInfo> {
    scan_cursor_from(&dirs_home()?.join(".cursor"), idle_secs)
}

pub(super) fn scan_cursor_from(home: &Path, idle_secs: f64) -> Option<SessionInfo> {
    let now = now_ms();
    let chats = home.join("chats");
    let projects = home.join("projects");
    let metas = cursor_meta_files(home);
    let files = if projects.is_dir() {
        tree_snapshot(&projects, "cursor-jsonl", 12, |p| {
            let s = p.to_string_lossy();
            s.contains("agent-transcripts") && s.ends_with(".jsonl")
        })
    } else {
        Vec::new()
    };
    let mut cwd_by_sid: HashMap<String, String> = HashMap::new();
    let mut best_activity = 0i64;
    let mut best_cwd: Option<String> = None;
    let mut best_path: Option<PathBuf> = None;
    for (meta_path, meta_mtime) in &metas {
        let sid = meta_path
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let (cwd, _, updated) = read_cursor_meta(meta_path).unwrap_or((None, None, None));
        if let Some(c) = cwd.clone().filter(|s| !s.is_empty()) {
            cwd_by_sid.insert(sid.to_string(), c);
        }
        let activity = updated.unwrap_or(0).max(*meta_mtime);
        if activity >= best_activity {
            best_activity = activity;
            best_cwd = cwd;
            best_path = Some(meta_path.clone());
        }
    }
    for (path, mtime) in &files {
        let mut activity = *mtime;
        if now.saturating_sub(*mtime) <= CURSOR_THINK_MS && cursor_open_turn(path) {
            activity = now;
        }
        if activity >= best_activity {
            best_activity = activity;
            best_cwd = cwd_by_sid.get(&cursor_session_id(path)).cloned();
            best_path = Some(path.clone());
        }
    }
    if best_activity <= 0 || !within_idle(best_activity, now, idle_secs) {
        return None;
    }
    let project = best_cwd
        .as_deref()
        .map(repo_from_cwd)
        .filter(|s| !s.is_empty())
        .or_else(|| best_path.as_deref().and_then(project_from_transcript))
        .unwrap_or_else(|| "Cursor".into());
    Some(SessionInfo {
        agent: AgentKind::Cursor,
        project,
        model: String::new(),
        start_epoch_ms: cursor_rolling_start(&files, &chats),
        activity_ms: best_activity,
        tokens: 0,
    })
}

fn cursor_meta_files(home: &Path) -> Vec<(PathBuf, i64)> {
    let mut out = Vec::new();
    for (dir, tag) in [
        (home.join("chats"), "cursor-meta"),
        (home.join("acp-sessions"), "cursor-acp-meta"),
    ] {
        if dir.is_dir() {
            out.extend(tree_snapshot(&dir, tag, 8, |p| {
                p.file_name().and_then(|n| n.to_str()) == Some("meta.json")
            }));
        }
    }
    out
}

fn cursor_open_turn(path: &Path) -> bool {
    let Some(text) = read_tail(path, 8192) else {
        return false;
    };
    let Some(last) = text.lines().rev().find(|l| !l.trim().is_empty()) else {
        return false;
    };
    let Ok(v) = serde_json::from_str::<Value>(last.trim()) else {
        return false;
    };
    match str_field(&v, "role").as_deref() {
        Some("user") => true,
        Some("assistant") => v
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_array())
            .is_some_and(|arr| {
                arr.iter()
                    .any(|p| str_field(p, "type").as_deref() == Some("tool_use"))
            }),
        _ => false,
    }
}

fn cursor_session_id(transcript: &Path) -> String {
    let stem = transcript
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    let parent = transcript
        .parent()
        .and_then(|p| p.file_name())
        .and_then(|n| n.to_str())
        .unwrap_or_default();
    if parent == "agent-transcripts" {
        stem.to_string()
    } else {
        parent.to_string()
    }
}

fn cursor_turns_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("AGENTCORD_CURSOR_TURNS") {
        return Some(PathBuf::from(p));
    }
    let base = std::env::var_os("APPDATA").map(PathBuf::from)?;
    Some(base.join("AgentCord").join("cursor-turns.jsonl"))
}

pub(super) fn cursor_hook_duration(cutoff_ms: i64, now_ms: i64) -> Option<(i64, Option<i64>)> {
    let text = read_to_string(&cursor_turns_path()?)?;
    let mut open: HashMap<String, Vec<i64>> = HashMap::new();
    let mut total = 0i64;
    let mut last = None;
    for line in text.lines() {
        let line = line.trim();
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
        if kind == "start" {
            open.entry(id).or_default().push(ms);
        } else if kind == "end" {
            if let Some(stack) = open.get_mut(&id) {
                if let Some(start) = stack.pop() {
                    let a = start.max(cutoff_ms);
                    let b = ms.min(now_ms);
                    if b > a {
                        total += b - a;
                    }
                    last = Some(last.map_or(ms, |l: i64| l.max(ms)));
                }
            }
        }
    }
    for starts in open.values() {
        for start in starts {
            let a = (*start).max(cutoff_ms);
            if now_ms > a {
                total += now_ms - a;
            }
            last = Some(last.map_or(now_ms, |l| l.max(now_ms)));
        }
    }
    Some((total, last))
}

/// Cursor transcripts only stamp user turns. Span first→last (plus
/// created/updated) so a new message does not snap elapsed to 0.
pub(super) fn cursor_session_span(
    stamps: &[i64],
    created_at_ms: Option<i64>,
    updated_at_ms: Option<i64>,
    cutoff_ms: i64,
    now_ms: i64,
) -> (i64, Option<i64>) {
    let in_window: Vec<i64> = stamps
        .iter()
        .copied()
        .filter(|ms| *ms >= cutoff_ms && *ms <= now_ms)
        .collect();
    if in_window.is_empty() {
        return active_duration(stamps, created_at_ms, updated_at_ms, cutoff_ms, now_ms);
    }
    let mut start = *in_window.iter().min().unwrap();
    if let Some(c) = created_at_ms {
        if c >= cutoff_ms && c <= now_ms && c < start {
            start = c;
        }
    }
    let last_stamp = *in_window.iter().max().unwrap();
    let end = updated_at_ms
        .map(|u| last_stamp.max(u.min(now_ms)))
        .unwrap_or(last_stamp);
    if end > start {
        (end - start, Some(end))
    } else {
        (0, Some(end))
    }
}

fn cursor_rolling_start(files: &[(PathBuf, i64)], chats: &Path) -> i64 {
    let now = now_ms();
    let cutoff = now - LOOKBACK_MS;
    if let Some((total, _)) = cursor_hook_duration(cutoff, now) {
        if total > 0 {
            return now - total;
        }
    }
    let mut total = 0;
    let mut newest_last = None;
    for (path, _) in files {
        let agg = jsonl_cached(path, parse_cursor_line);
        let sid = cursor_session_id(path);
        let (created, updated) = find_cursor_meta(chats, &sid)
            .and_then(|p| read_cursor_meta(&p))
            .map(|(_, c, u)| (c, u))
            .unwrap_or((None, None));
        let (active, last) = cursor_session_span(
            &agg.stamps,
            created.or(agg.created_at_ms),
            updated.or(agg.updated_at_ms),
            cutoff,
            now,
        );
        total += active;
        if let Some(l) = last {
            newest_last = Some(newest_last.map_or(l, |n: i64| n.max(l)));
        }
    }
    elapsed_start_ms(total, newest_last, now)
}

fn parse_cursor_line(line: &str, agg: &mut JsonlAgg) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    let Some(message) = v.get("message") else {
        return;
    };
    for text in message_texts(message) {
        let mut rest = text.as_str();
        while let Some(start) = rest.find("<timestamp>") {
            rest = &rest[start + 11..];
            let Some(end) = rest.find("</timestamp>") else {
                break;
            };
            if let Some(ms) = parse_embedded_timestamp(&rest[..end]) {
                note_stamp(agg, ms);
            }
            rest = &rest[end + 12..];
        }
    }
}

fn find_cursor_meta(chats: &Path, session_id: &str) -> Option<PathBuf> {
    if !chats.is_dir() || session_id.is_empty() {
        return None;
    }
    tree_snapshot(chats, "cursor-meta", 8, |p| {
        p.file_name().and_then(|n| n.to_str()) == Some("meta.json")
    })
    .into_iter()
    .find(|(path, _)| {
        path.parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            == Some(session_id)
    })
    .map(|(path, _)| path)
}

fn read_cursor_meta(path: &Path) -> Option<(Option<String>, Option<i64>, Option<i64>)> {
    let v: Value = serde_json::from_str(&read_to_string(path)?).ok()?;
    let cwd = str_field(&v, "cwd").filter(|s| !s.is_empty());
    let created = v
        .get("createdAtMs")
        .and_then(json_i64)
        .filter(|n| *n > 0);
    let updated = v
        .get("updatedAtMs")
        .and_then(json_i64)
        .filter(|n| *n > 0);
    Some((cwd, created, updated))
}

