//! Session scans and Discord activity. Cheap: stat/read only the files
//! needed for the current decision. Agents: Claude, Codex, Cursor, Grok.

use serde_json::Value;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub const DISCORD_CLIENT_ID: &str = "1517099756063686677";
pub const IDLE_WINDOW_SECS: f64 = 300.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AgentKind {
    Claude,
    Codex,
    Cursor,
    Grok,
}

impl AgentKind {
    pub fn display_name(self) -> &'static str {
        match self {
            Self::Claude => "Claude",
            Self::Codex => "Codex",
            Self::Cursor => "Cursor",
            Self::Grok => "Grok",
        }
    }

    pub fn provider_name(self) -> &'static str {
        match self {
            Self::Claude => "Anthropic",
            Self::Codex => "OpenAI",
            Self::Cursor => "Cursor",
            Self::Grok => "xAI",
        }
    }

    pub fn large_image(self) -> &'static str {
        match self {
            Self::Claude => "logo-claude",
            Self::Codex => "logo-chatgpt",
            Self::Cursor => "logo-cursor",
            Self::Grok => "logo-grok",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct SessionInfo {
    pub agent: AgentKind,
    pub project: String,
    pub model: String,
    pub start_epoch_ms: i64,
    pub activity_ms: i64,
    pub tokens: i64,
}

#[derive(Clone, Debug, Default)]
pub struct LiveSessions {
    pub claude: Option<SessionInfo>,
    pub codex: Option<SessionInfo>,
    pub cursor: Option<SessionInfo>,
    pub grok: Option<SessionInfo>,
}

impl LiveSessions {
    fn iter(&self) -> impl Iterator<Item = &SessionInfo> {
        [
            self.claude.as_ref(),
            self.codex.as_ref(),
            self.cursor.as_ref(),
            self.grok.as_ref(),
        ]
        .into_iter()
        .flatten()
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Activity {
    pub name: String,
    pub details: Option<String>,
    pub state: Option<String>,
    pub start_ms: i64,
    pub large_image: &'static str,
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn within_idle(activity_ms: i64, now: i64) -> bool {
    activity_ms > 0 && (now - activity_ms) as f64 / 1000.0 <= IDLE_WINDOW_SECS
}

pub fn pick_winner(sessions: &LiveSessions) -> Option<&SessionInfo> {
    sessions.iter().max_by_key(|s| s.activity_ms)
}

pub fn build_activity(info: &SessionInfo) -> Activity {
    let details = if info.model.is_empty() {
        None
    } else {
        Some(info.model.clone())
    };
    let mut state_parts = vec![format!("Working on: {}", info.project)];
    if info.tokens > 0 {
        state_parts.push(format!("{} tokens", format_tokens(info.tokens)));
    }
    Activity {
        name: info.agent.display_name().to_string(),
        details,
        state: Some(state_parts.join(" · ")),
        start_ms: info.start_epoch_ms,
        large_image: info.agent.large_image(),
    }
}

pub fn format_tokens(count: i64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1_000 {
        format!("{:.1}K", count as f64 / 1_000.0)
    } else {
        count.to_string()
    }
}

pub fn pretty_grok_model(raw: &str) -> String {
    if let Some(rest) = raw.strip_prefix("grok-").or_else(|| raw.strip_prefix("Grok-")) {
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

pub fn pretty_codex_model(raw: &str) -> String {
    let rest = match raw.strip_prefix("gpt-").or_else(|| raw.strip_prefix("GPT-")) {
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

pub fn repo_name_from_remote(remote: &str) -> String {
    let base = remote
        .rsplit(['/', '\\', ':'])
        .next()
        .unwrap_or(remote);
    base.strip_suffix(".git")
        .or_else(|| base.strip_suffix(".GIT"))
        .unwrap_or(base)
        .to_string()
}

pub fn scan_all() -> LiveSessions {
    LiveSessions {
        claude: scan_claude(),
        codex: scan_codex(),
        grok: scan_grok(),
        cursor: scan_cursor(),
    }
}

pub fn grok_linked() -> bool {
    grok_home().is_some_and(|home| {
        home.join("auth.json").is_file() || home.join("active_sessions.json").is_file()
    })
}

pub fn cursor_linked() -> bool {
    dirs_home().is_some_and(|home| home.join(".cursor").join("projects").is_dir())
}

pub fn claude_linked() -> bool {
    claude_home().is_some_and(|home| home.join("projects").is_dir())
}

pub fn codex_linked() -> bool {
    codex_home().is_some_and(|home| home.join("sessions").is_dir())
}

/// Ticking clock like the production popover: "1:02:03" / "2:03".
pub fn format_clock(ms: i64) -> String {
    let total = (ms / 1000).max(0);
    let h = total / 3600;
    let m = total / 60 % 60;
    let s = total % 60;
    if h > 0 {
        format!("{h}:{m:02}:{s:02}")
    } else {
        format!("{m}:{s:02}")
    }
}

pub fn scan_grok() -> Option<SessionInfo> {
    let home = grok_home()?;
    let now = now_ms();
    let active_path = home.join("active_sessions.json");
    let json = read_to_string(&active_path)?;
    let arr = serde_json::from_str::<Value>(&json).ok()?;
    let items = arr.as_array()?;

    let mut best: Option<SessionInfo> = None;
    for item in items {
        let sid = item.get("session_id")?.as_str()?;
        let cwd = item.get("cwd")?.as_str()?;
        let pid = item.get("pid")?.as_i64()?;
        if pid <= 0 || !process_is_alive(pid as u32) {
            continue;
        }
        let opened = item
            .get("opened_at")
            .and_then(|v| v.as_str())
            .and_then(parse_iso_ms)
            .unwrap_or(now);

        let summary_path = find_grok_summary(&home, cwd, sid);
        let (model, remotes, last_active, created) = summary_path
            .as_ref()
            .and_then(|p| read_grok_summary(p))
            .unwrap_or_default();
        let (tokens, signal_model) = summary_path
            .as_ref()
            .and_then(|p| p.parent().map(|d| d.join("signals.json")))
            .and_then(|p| read_grok_signals(&p))
            .unwrap_or((0, None));

        let mut activity = last_active.unwrap_or(opened);
        if let Some(path) = &summary_path {
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
                if !within_idle(activity, now) && is_open_turn(dir) {
                    activity = now;
                }
            }
        }
        if !within_idle(activity, now) {
            continue;
        }

        let project = remotes
            .first()
            .map(|r| repo_name_from_remote(r))
            .filter(|s| !s.is_empty())
            .or_else(|| basename(cwd).filter(|s| !s.is_empty()))
            .unwrap_or_else(|| "Grok".into());
        let model = model
            .or(signal_model)
            .map(|m| pretty_grok_model(&m))
            .unwrap_or_else(|| "Grok".into());

        let info = SessionInfo {
            agent: AgentKind::Grok,
            project,
            model,
            start_epoch_ms: created.unwrap_or(opened),
            activity_ms: activity,
            tokens,
        };
        if best.as_ref().is_none_or(|b| info.activity_ms >= b.activity_ms) {
            best = Some(info);
        }
    }
    best
}

pub fn scan_claude() -> Option<SessionInfo> {
    scan_claude_from(&claude_home()?.join("projects"))
}

pub fn scan_codex() -> Option<SessionInfo> {
    scan_codex_from(&codex_home()?.join("sessions"))
}

fn scan_claude_from(projects: &Path) -> Option<SessionInfo> {
    if !projects.is_dir() {
        return None;
    }
    let now = now_ms();
    let (transcript, mtime) = newest_jsonl(projects, 8, None)?;
    let tail = parse_claude_tail(&transcript);
    let activity = tail.last_event_ms.unwrap_or(mtime);
    if !within_idle(activity, now) {
        return None;
    }
    let project = tail
        .cwd
        .as_deref()
        .and_then(basename)
        .filter(|s| !s.is_empty())
        .or_else(|| claude_project_from_dir(&transcript))
        .unwrap_or_else(|| "Claude".into());
    Some(SessionInfo {
        agent: AgentKind::Claude,
        project,
        model: tail.model.unwrap_or_default(),
        start_epoch_ms: tail.first_event_ms.unwrap_or(mtime),
        activity_ms: activity,
        tokens: tail.tokens,
    })
}

fn scan_codex_from(sessions: &Path) -> Option<SessionInfo> {
    if !sessions.is_dir() {
        return None;
    }
    let now = now_ms();
    let (transcript, mtime) = newest_jsonl(sessions, 8, None)?;
    let tail = parse_codex_tail(&transcript);
    let activity = tail.last_event_ms.unwrap_or(mtime);
    if !within_idle(activity, now) {
        return None;
    }
    let project = tail
        .cwd
        .as_deref()
        .and_then(basename)
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Codex".into());
    Some(SessionInfo {
        agent: AgentKind::Codex,
        project,
        model: tail.model.unwrap_or_else(|| "Codex".into()),
        start_epoch_ms: tail.first_event_ms.unwrap_or(mtime),
        activity_ms: activity,
        tokens: tail.tokens,
    })
}

pub fn scan_cursor() -> Option<SessionInfo> {
    let home = dirs_home()?.join(".cursor");
    let projects = home.join("projects");
    if !projects.is_dir() {
        return None;
    }
    let now = now_ms();
    let mut newest: Option<(PathBuf, i64)> = None;
    walk_files(&projects, 12, &mut |path| {
        let p = path.to_string_lossy();
        if !p.contains("agent-transcripts") || !p.ends_with(".jsonl") {
            return;
        }
        let Some(mtime) = file_mtime_ms(path) else { return };
        if newest.as_ref().is_none_or(|(_, t)| mtime > *t) {
            newest = Some((path.to_path_buf(), mtime));
        }
    });
    let (transcript, mtime) = newest?;
    if !within_idle(mtime, now) {
        return None;
    }
    let session_id = transcript
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_string();
    if session_id.is_empty() {
        return None;
    }

    let mut info = SessionInfo {
        agent: AgentKind::Cursor,
        project: project_from_transcript(&transcript).unwrap_or_else(|| "Cursor".into()),
        model: String::new(),
        start_epoch_ms: mtime,
        activity_ms: mtime,
        tokens: 0,
    };

    if let Some(meta) = find_cursor_meta(&home.join("chats"), &session_id) {
        apply_cursor_meta(&meta, &mut info, mtime);
    }
    if info.project.is_empty() {
        info.project = "Cursor".into();
    }
    Some(info)
}

fn grok_home() -> Option<PathBuf> {
    env_home("GROK_HOME").or_else(|| Some(dirs_home()?.join(".grok")))
}

fn claude_home() -> Option<PathBuf> {
    env_home("CLAUDE_HOME").or_else(|| Some(dirs_home()?.join(".claude")))
}

fn codex_home() -> Option<PathBuf> {
    env_home("CODEX_HOME").or_else(|| Some(dirs_home()?.join(".codex")))
}

fn env_home(key: &str) -> Option<PathBuf> {
    std::env::var(key).ok().filter(|s| !s.is_empty()).map(PathBuf::from)
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
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

fn read_grok_summary(path: &Path) -> Option<(Option<String>, Vec<String>, Option<i64>, Option<i64>)> {
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

fn read_tail(path: &Path, max: u64) -> Option<String> {
    let mut file = open_shared(path)?;
    let len = file.metadata().ok()?.len();
    if len == 0 {
        return None;
    }
    let take = len.min(max);
    file.seek(SeekFrom::End(-(take as i64))).ok()?;
    let mut buf = vec![0u8; take as usize];
    let n = file.read(&mut buf).ok()?;
    let mut text = String::from_utf8_lossy(&buf[..n]).into_owned();
    if len > take {
        if let Some(cut) = text.find('\n') {
            text = text[cut + 1..].to_string();
        }
    }
    Some(text)
}

#[derive(Default)]
struct TailMeta {
    cwd: Option<String>,
    model: Option<String>,
    first_event_ms: Option<i64>,
    last_event_ms: Option<i64>,
    tokens: i64,
}

fn note_event(meta: &mut TailMeta, ms: i64) {
    meta.first_event_ms = Some(meta.first_event_ms.map_or(ms, |f| f.min(ms)));
    meta.last_event_ms = Some(meta.last_event_ms.map_or(ms, |l| l.max(ms)));
}

fn parse_claude_tail(path: &Path) -> TailMeta {
    let mut meta = TailMeta::default();
    let Some(text) = read_tail(path, 256 * 1024) else {
        return meta;
    };
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        if meta.cwd.is_none() {
            if let Some(cwd) = str_field(&v, "cwd").filter(|s| !s.is_empty()) {
                meta.cwd = Some(cwd);
            }
        }
        if let Some(ms) = str_field(&v, "timestamp").as_deref().and_then(parse_iso_ms) {
            note_event(&mut meta, ms);
        }
        let Some(message) = v.get("message") else {
            continue;
        };
        if let Some(model) = str_field(message, "model").filter(|m| m != "<synthetic>" && !m.is_empty()) {
            meta.model = Some(pretty_claude_model(&model));
        }
        if let Some(usage) = message.get("usage") {
            meta.tokens += usage.get("input_tokens").and_then(json_i64).unwrap_or(0)
                + usage.get("output_tokens").and_then(json_i64).unwrap_or(0);
        }
    }
    meta
}

fn parse_codex_tail(path: &Path) -> TailMeta {
    let mut meta = TailMeta::default();
    let Some(text) = read_tail(path, 256 * 1024) else {
        return meta;
    };
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        if let Some(ms) = str_field(&v, "timestamp").as_deref().and_then(parse_iso_ms) {
            note_event(&mut meta, ms);
        }
        let Some(ty) = str_field(&v, "type") else {
            continue;
        };
        let Some(payload) = v.get("payload") else {
            continue;
        };
        if ty == "session_meta" || ty == "turn_context" {
            if let Some(cwd) = str_field(payload, "cwd").filter(|s| !s.is_empty()) {
                meta.cwd = Some(cwd);
            }
            if ty == "turn_context" {
                if let Some(model) = str_field(payload, "model").filter(|s| !s.is_empty()) {
                    meta.model = Some(pretty_codex_model(&model));
                }
            }
            if ty == "session_meta" {
                if let Some(ms) = str_field(payload, "timestamp")
                    .as_deref()
                    .and_then(parse_iso_ms)
                {
                    meta.first_event_ms = Some(meta.first_event_ms.map_or(ms, |f| f.min(ms)));
                }
            }
        }
        if ty == "event_msg"
            && str_field(payload, "type").as_deref() == Some("token_count")
        {
            if let Some(usage) = payload.get("info").and_then(|i| i.get("last_token_usage")) {
                let total = usage.get("total_tokens").and_then(json_i64).unwrap_or(0);
                meta.tokens = if total > 0 {
                    total
                } else {
                    usage.get("input_tokens").and_then(json_i64).unwrap_or(0)
                        + usage.get("output_tokens").and_then(json_i64).unwrap_or(0)
                };
            }
        }
    }
    meta
}

fn newest_jsonl(root: &Path, max_depth: usize, must_contain: Option<&str>) -> Option<(PathBuf, i64)> {
    let mut newest: Option<(PathBuf, i64)> = None;
    walk_files(root, max_depth, &mut |path| {
        let p = path.to_string_lossy();
        if !p.ends_with(".jsonl") {
            return;
        }
        if let Some(needle) = must_contain {
            if !p.contains(needle) {
                return;
            }
        }
        let Some(mtime) = file_mtime_ms(path) else { return };
        if newest.as_ref().is_none_or(|(_, t)| mtime > *t) {
            newest = Some((path.to_path_buf(), mtime));
        }
    });
    newest
}

fn claude_project_from_dir(transcript: &Path) -> Option<String> {
    let dir = transcript.parent()?.file_name()?.to_str()?;
    dir.rsplit_once('-')
        .map(|(_, tail)| tail)
        .filter(|t| !t.is_empty())
        .or(Some(dir))
        .map(str::to_string)
}

fn find_cursor_meta(chats: &Path, session_id: &str) -> Option<PathBuf> {
    if !chats.is_dir() {
        return None;
    }
    let mut found = None;
    walk_files(chats, 8, &mut |path| {
        if found.is_some() {
            return;
        }
        if path.file_name().and_then(|n| n.to_str()) != Some("meta.json") {
            return;
        }
        let parent = path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str());
        if parent == Some(session_id) {
            found = Some(path.to_path_buf());
        }
    });
    found
}

fn apply_cursor_meta(path: &Path, info: &mut SessionInfo, transcript_mtime: i64) {
    let Some(text) = read_to_string(path) else { return };
    let Ok(v) = serde_json::from_str::<Value>(&text) else { return };
    if let Some(cwd) = str_field(&v, "cwd") {
        if let Some(base) = basename(&cwd) {
            if !base.is_empty() {
                info.project = base;
            }
        }
    }
    if let Some(created) = v.get("createdAtMs").and_then(json_i64) {
        if created > 0 {
            info.start_epoch_ms = created;
        }
    }
    let mut activity = transcript_mtime;
    if let Some(updated) = v.get("updatedAtMs").and_then(json_i64) {
        if updated > activity {
            activity = updated;
        }
    }
    info.activity_ms = activity;
}

fn project_from_transcript(path: &Path) -> Option<String> {
    let text = path.to_string_lossy();
    let marker = if text.contains("\\projects\\") {
        "\\projects\\"
    } else {
        "/projects/"
    };
    let rest = text.split_once(marker)?.1;
    let encoded = rest.split(['\\', '/']).next()?;
    encoded
        .rsplit_once('-')
        .map(|(_, tail)| tail)
        .filter(|t| !t.is_empty())
        .or(Some(encoded))
        .map(str::to_string)
}

fn walk_files(root: &Path, max_depth: usize, visit: &mut dyn FnMut(&Path)) {
    fn rec(dir: &Path, depth: usize, max_depth: usize, visit: &mut dyn FnMut(&Path)) {
        if depth > max_depth {
            return;
        }
        let Ok(entries) = fs::read_dir(dir) else { return };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(ft) = entry.file_type() else { continue };
            if ft.is_dir() {
                rec(&path, depth + 1, max_depth, visit);
            } else if ft.is_file() {
                visit(&path);
            }
        }
    }
    rec(root, 0, max_depth, visit);
}

fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn parse_iso_ms(iso: &str) -> Option<i64> {
    // 2026-07-22T04:20:53.376422Z or with offset. Seconds precision is enough.
    if iso.len() < 19 {
        return None;
    }
    let year: i32 = iso.get(0..4)?.parse().ok()?;
    let month: u32 = iso.get(5..7)?.parse().ok()?;
    let day: u32 = iso.get(8..10)?.parse().ok()?;
    let hour: u32 = iso.get(11..13)?.parse().ok()?;
    let minute: u32 = iso.get(14..16)?.parse().ok()?;
    let second: u32 = iso.get(17..19)?.parse().ok()?;
    let days = days_from_civil(year, month, day)?;
    Some((days * 86_400 + hour as i64 * 3600 + minute as i64 * 60 + second as i64) * 1000)
}

fn days_from_civil(mut year: i32, month: u32, day: u32) -> Option<i64> {
    if !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    if month <= 2 {
        year -= 1;
    }
    let era = year.div_euclid(400) as i64;
    let yoe = (year - era as i32 * 400) as i64;
    let m = month as i64;
    let mp = if m > 2 { m - 3 } else { m + 9 };
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().map(str::to_string)
}

fn json_i64(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
}

fn basename(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .map(str::to_string)
}

fn file_mtime_ms(path: &Path) -> Option<i64> {
    let meta = fs::metadata(path).ok()?;
    let d = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(d.as_millis() as i64)
}

fn read_to_string(path: &Path) -> Option<String> {
    let mut file = open_shared(path)?;
    let mut s = String::new();
    file.read_to_string(&mut s).ok()?;
    Some(s)
}

fn open_shared(path: &Path) -> Option<File> {
    let mut opts = fs::OpenOptions::new();
    opts.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        opts.share_mode(0x00000007); // FILE_SHARE_READ|WRITE|DELETE
    }
    opts.open(path).ok()
}

#[cfg(windows)]
fn process_is_alive(pid: u32) -> bool {
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const STILL_ACTIVE: u32 = 259;
    extern "system" {
        fn OpenProcess(access: u32, inherit: i32, pid: u32) -> isize;
        fn GetExitCodeProcess(handle: isize, code: *mut u32) -> i32;
        fn CloseHandle(handle: isize) -> i32;
    }
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if handle == 0 || handle == -1 {
            return false;
        }
        let mut code = 0u32;
        let ok = GetExitCodeProcess(handle, &mut code) != 0;
        CloseHandle(handle);
        ok && code == STILL_ACTIVE
    }
}

#[cfg(not(windows))]
fn process_is_alive(_pid: u32) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pretty_claude_formats_id() {
        assert_eq!(pretty_claude_model("claude-opus-4-5-20260101"), "Opus 4.5");
        assert_eq!(pretty_claude_model("claude-sonnet-4"), "Sonnet 4");
        assert_eq!(pretty_claude_model("claude-fable-5"), "Fable 5");
    }

    #[test]
    fn pretty_codex_formats_id() {
        assert_eq!(pretty_codex_model("gpt-5.2"), "GPT-5.2");
        assert_eq!(pretty_codex_model("gpt-5-2-codex"), "GPT-5.2 Codex");
    }

    #[test]
    fn pretty_grok_formats_id() {
        assert_eq!(pretty_grok_model("grok-4.5"), "Grok 4.5");
        assert_eq!(pretty_grok_model("grok-"), "Grok");
    }

    #[test]
    fn pretty_cursor_formats_id() {
        assert_eq!(pretty_cursor_model("default"), "Auto");
        assert_eq!(pretty_cursor_model("cursor-gpt-5"), "GPT 5");
    }

    #[test]
    fn tokens_short() {
        assert_eq!(format_tokens(153055), "153.1K");
        assert_eq!(format_tokens(42), "42");
    }

    #[test]
    fn clock_format() {
        assert_eq!(format_clock(123_000), "2:03");
        assert_eq!(format_clock(3_723_000), "1:02:03");
    }

    #[test]
    fn remote_repo() {
        assert_eq!(
            repo_name_from_remote("git@github.com:preschian/agentcord.git"),
            "agentcord"
        );
        assert_eq!(
            repo_name_from_remote("https://github.com/preschian/agentcord.git"),
            "agentcord"
        );
    }

    #[test]
    fn iso_to_epoch() {
        let ms = parse_iso_ms("2026-07-22T04:20:53.376422Z").unwrap();
        assert!(ms > 1_700_000_000_000);
        assert_eq!(ms % 60_000, 53_000);
    }

    #[test]
    fn percent_encodes_windows_cwd() {
        assert_eq!(
            percent_encode(r"D:\Workspace\agentcord"),
            "D%3A%5CWorkspace%5Cagentcord"
        );
    }

    #[test]
    fn winner_prefers_newer_cursor() {
        let grok = SessionInfo {
            agent: AgentKind::Grok,
            project: "old".into(),
            model: "Grok 4.5".into(),
            start_epoch_ms: 1000,
            activity_ms: 1000,
            tokens: 0,
        };
        let cursor = SessionInfo {
            agent: AgentKind::Cursor,
            project: "agentcord".into(),
            model: String::new(),
            start_epoch_ms: 4000,
            activity_ms: 5000,
            tokens: 0,
        };
        let sessions = LiveSessions {
            grok: Some(grok),
            cursor: Some(cursor.clone()),
            ..Default::default()
        };
        assert_eq!(pick_winner(&sessions).unwrap().agent, AgentKind::Cursor);
    }

    #[test]
    fn winner_prefers_newer_grok() {
        let grok = SessionInfo {
            agent: AgentKind::Grok,
            project: "agentcord".into(),
            model: "Grok 4.5".into(),
            start_epoch_ms: 1000,
            activity_ms: 9000,
            tokens: 0,
        };
        let cursor = SessionInfo {
            agent: AgentKind::Cursor,
            project: "other".into(),
            model: String::new(),
            start_epoch_ms: 4000,
            activity_ms: 5000,
            tokens: 0,
        };
        let sessions = LiveSessions {
            grok: Some(grok),
            cursor: Some(cursor),
            ..Default::default()
        };
        assert_eq!(pick_winner(&sessions).unwrap().agent, AgentKind::Grok);
    }

    #[test]
    fn activity_payload() {
        let info = SessionInfo {
            agent: AgentKind::Grok,
            project: "agentcord".into(),
            model: "Grok 4.5".into(),
            start_epoch_ms: 1000,
            activity_ms: 2000,
            tokens: 81200,
        };
        let act = build_activity(&info);
        assert_eq!(act.name, "Grok");
        assert_eq!(act.details.as_deref(), Some("Grok 4.5"));
        assert_eq!(
            act.state.as_deref(),
            Some("Working on: agentcord · 81.2K tokens")
        );
        assert_eq!(act.large_image, "logo-grok");
    }

    #[test]
    fn project_from_encoded_transcript() {
        let p = PathBuf::from(
            r"C:\Users\p\.cursor\projects\D-Workspace-agentcord\agent-transcripts\a\a.jsonl",
        );
        assert_eq!(project_from_transcript(&p).as_deref(), Some("agentcord"));
    }

    #[test]
    fn scan_claude_from_newest_jsonl() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-claude-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let project = dir.join("C-Users-test-agentcord");
        fs::create_dir_all(&project).unwrap();
        fs::write(
            project.join("session.jsonl"),
            r#"{"cwd":"D:\\Workspace\\agentcord","message":{"model":"claude-opus-4-5","usage":{"input_tokens":3,"output_tokens":5}}}"#,
        )
        .unwrap();
        let info = scan_claude_from(&dir).unwrap();
        assert_eq!(info.agent, AgentKind::Claude);
        assert_eq!(info.project, "agentcord");
        assert_eq!(info.model, "Opus 4.5");
        assert_eq!(info.tokens, 8);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn scan_codex_from_newest_jsonl() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-codex-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let day = dir.join("2026").join("08").join("18");
        fs::create_dir_all(&day).unwrap();
        fs::write(
            day.join("rollout.jsonl"),
            r#"{"type":"session_meta","payload":{"cwd":"D:\\Workspace\\agentcord"}}
{"type":"turn_context","payload":{"cwd":"D:\\Workspace\\agentcord","model":"gpt-5.2"}}
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}}}}"#,
        )
        .unwrap();
        let info = scan_codex_from(&dir).unwrap();
        assert_eq!(info.agent, AgentKind::Codex);
        assert_eq!(info.project, "agentcord");
        assert_eq!(info.model, "GPT-5.2");
        assert_eq!(info.tokens, 42);
        let _ = fs::remove_dir_all(&dir);
    }
}
