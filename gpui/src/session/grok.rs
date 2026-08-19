//! Grok CLI session scan (`~/.grok`).

use super::*;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

pub(super) static LAST_GROK: Mutex<Option<SessionInfo>> = Mutex::new(None);

pub fn pretty_grok_model(raw: &str) -> String {
    if let Some(rest) = raw
        .strip_prefix("grok-")
        .or_else(|| raw.strip_prefix("Grok-"))
    {
        if rest.is_empty() {
            "Grok".into()
        } else {
            format!("Grok {rest}")
        }
    } else if raw.is_empty() {
        "Grok".into()
    } else {
        raw.to_string()
    }
}

pub fn grok_linked() -> bool {
    grok_home().is_some_and(|home| {
        home.join("auth.json").is_file() || home.join("active_sessions.json").is_file()
    })
}

pub fn scan_grok(idle_secs: f64) -> Option<SessionInfo> {
    scan_grok_from(&grok_home()?, idle_secs)
}

pub(super) fn scan_grok_from(home: &Path, idle_secs: f64) -> Option<SessionInfo> {
    let now = now_ms();
    let mut best: Option<SessionInfo> = None;
    if let Some(json) = read_to_string(&home.join("active_sessions.json")) {
        if let Ok(Value::Array(items)) = serde_json::from_str::<Value>(&json) {
            for item in items {
                let Some(info) = grok_live_item(home, &item, now, idle_secs) else {
                    continue;
                };
                if best
                    .as_ref()
                    .is_none_or(|b| info.activity_ms >= b.activity_ms)
                {
                    best = Some(info);
                }
            }
        }
    }
    if best.is_none() {
        if let Ok(g) = LAST_GROK.lock() {
            if let Some(prev) = g.as_ref() {
                if within_idle(prev.activity_ms, now, idle_secs) {
                    best = Some(prev.clone());
                }
            }
        }
    }
    if best.is_none() {
        best = grok_newest_recent(home, idle_secs, now);
    }
    let mut info = best?;
    info.start_epoch_ms = grok_rolling_start(home);
    if let Ok(mut g) = LAST_GROK.lock() {
        *g = Some(info.clone());
    }
    Some(info)
}

fn grok_live_item(home: &Path, item: &Value, now: i64, idle_secs: f64) -> Option<SessionInfo> {
    let sid = item.get("session_id")?.as_str()?;
    let cwd = item.get("cwd")?.as_str()?;
    let pid = item.get("pid")?.as_i64()?;
    if pid <= 0 || !process_is_alive(pid as u32) {
        return None;
    }
    let opened = item
        .get("opened_at")
        .and_then(|v| v.as_str())
        .and_then(parse_iso_ms)
        .unwrap_or(now);
    grok_info_from(home, sid, cwd, Some(opened), now, idle_secs, true)
}

fn grok_newest_recent(home: &Path, idle_secs: f64, now: i64) -> Option<SessionInfo> {
    let sessions = home.join("sessions");
    if !sessions.is_dir() {
        return None;
    }
    let files = tree_snapshot(&sessions, "grok-summary", 8, |p| {
        p.file_name().and_then(|n| n.to_str()) == Some("summary.json")
    });
    let mut best: Option<SessionInfo> = None;
    for (path, _) in files {
        let Some(dir) = path.parent() else {
            continue;
        };
        let sid = dir.file_name().and_then(|n| n.to_str()).unwrap_or("");
        let encoded = dir
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let cwd = percent_decode(encoded);
        let Some(info) = grok_info_from(home, sid, &cwd, None, now, idle_secs, false) else {
            continue;
        };
        if best
            .as_ref()
            .is_none_or(|b| info.activity_ms >= b.activity_ms)
        {
            best = Some(info);
        }
    }
    best
}

fn grok_info_from(
    home: &Path,
    sid: &str,
    cwd: &str,
    opened: Option<i64>,
    now: i64,
    idle_secs: f64,
    live: bool,
) -> Option<SessionInfo> {
    let summary_path = find_grok_summary(home, cwd, sid);
    let (model, remotes, last_active, created) = summary_path
        .as_ref()
        .and_then(|p| read_grok_summary(p))
        .unwrap_or_default();
    let (tokens, signal_model) = summary_path
        .as_ref()
        .and_then(|p| p.parent().map(|d| d.join("signals.json")))
        .and_then(|p| read_grok_signals(&p))
        .unwrap_or((0, None));
    let mut activity = last_active.or(opened).unwrap_or(0);
    if let Some(path) = &summary_path {
        if live {
            activity = activity.max(file_mtime_ms(path).unwrap_or(0));
            if let Some(dir) = path.parent() {
                for name in [
                    "events.jsonl",
                    "updates.jsonl",
                    "chat_history.jsonl",
                    "signals.json",
                    "hunk_records.jsonl",
                ] {
                    activity = activity.max(file_mtime_ms(&dir.join(name)).unwrap_or(0));
                }
                // ponytail: mid-turn think can pause writes; last event != turn_ended still counts.
                if !within_idle(activity, now, idle_secs) && is_open_turn(dir) {
                    activity = now;
                }
            }
        } else if activity == 0 {
            activity = file_mtime_ms(path).unwrap_or(0);
        }
    }
    if !within_idle(activity, now, idle_secs) {
        return None;
    }
    let project = remotes
        .first()
        .map(|r| repo_name_from_remote(r))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| {
            let from_git = repo_from_cwd(cwd);
            if from_git.is_empty() {
                "Grok".into()
            } else {
                from_git
            }
        });
    let model = model
        .or(signal_model)
        .map(|m| pretty_grok_model(&m))
        .unwrap_or_else(|| "Grok".into());
    Some(SessionInfo {
        agent: AgentKind::Grok,
        project,
        model,
        start_epoch_ms: created.or(opened).unwrap_or(activity),
        activity_ms: activity,
        tokens,
    })
}

pub(super) fn grok_rolling_start(home: &Path) -> i64 {
    let sessions = home.join("sessions");
    if !sessions.is_dir() {
        return now_ms();
    }
    let files = tree_snapshot(&sessions, "grok-events", 8, |p| {
        p.file_name().and_then(|n| n.to_str()) == Some("events.jsonl")
    });
    rolling_start(&files, parse_grok_event_line)
}

fn parse_grok_event_line(line: &str, agg: &mut JsonlAgg) {
    let Ok(v) = serde_json::from_str::<Value>(line) else {
        return;
    };
    if let Some(ms) = json_time(v.get("timestamp")).or_else(|| json_time(v.get("ts"))) {
        note_stamp(agg, ms);
    }
}

fn grok_home() -> Option<PathBuf> {
    env_home("GROK_HOME").or_else(|| Some(dirs_home()?.join(".grok")))
}

fn find_grok_summary(home: &Path, cwd: &str, sid: &str) -> Option<PathBuf> {
    let direct = home
        .join("sessions")
        .join(percent_encode(cwd))
        .join(sid)
        .join("summary.json");
    if direct.is_file() {
        return Some(direct);
    }
    let sessions = home.join("sessions");
    let groups = fs::read_dir(sessions).ok()?;
    for group in groups.flatten() {
        let session = group.path().join(sid).join("summary.json");
        if session.is_file() {
            return Some(session);
        }
    }
    None
}

fn read_grok_summary(
    path: &Path,
) -> Option<(Option<String>, Vec<String>, Option<i64>, Option<i64>)> {
    let v: Value = serde_json::from_str(&read_to_string(path)?).ok()?;
    let model = str_field(&v, "current_model_id");
    let last = str_field(&v, "last_active_at")
        .or_else(|| str_field(&v, "updated_at"))
        .and_then(|s| parse_iso_ms(&s));
    let created = str_field(&v, "created_at").and_then(|s| parse_iso_ms(&s));
    let remotes = v
        .get("git_remotes")
        .and_then(|r| r.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default();
    Some((model, remotes, last, created))
}

fn read_grok_signals(path: &Path) -> Option<(i64, Option<String>)> {
    let v: Value = serde_json::from_str(&read_to_string(path)?).ok()?;
    let tokens = v.get("contextTokensUsed").and_then(json_i64).unwrap_or(0);
    let model = str_field(&v, "primaryModelId");
    Some((tokens, model))
}

fn is_open_turn(session_dir: &Path) -> bool {
    let path = session_dir.join("events.jsonl");
    let ty = last_jsonl_type(&path).unwrap_or_default();
    !ty.is_empty()
        && !ty.eq_ignore_ascii_case("turn_ended")
        && !ty.eq_ignore_ascii_case("session_end")
        && !ty.eq_ignore_ascii_case("session_ended")
}

fn last_jsonl_type(path: &Path) -> Option<String> {
    let text = read_tail(path, 8192)?;
    let last = text.lines().rev().find(|l| !l.trim().is_empty())?;
    let v: Value = serde_json::from_str(last.trim()).ok()?;
    str_field(&v, "type")
}

