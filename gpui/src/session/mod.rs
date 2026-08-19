//! Session scans and Discord activity. Cheap: stat/read only the files
//! needed for the current decision.
//!
//! Agents live in `claude` / `codex` / `cursor` / `grok`.

use crate::settings::Settings;

mod claude;
mod codex;
mod cursor;
mod grok;
pub mod hooks;

pub use claude::{claude_linked, pretty_claude_model, scan_claude};
pub use codex::{codex_linked, pretty_codex_model, scan_codex};
pub use cursor::{cursor_linked, pretty_cursor_model, scan_cursor};
pub use grok::{grok_linked, pretty_grok_model, scan_grok};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

pub const DISCORD_CLIENT_ID: &str = "1517099756063686677";
pub const IDLE_WINDOW_SECS: f64 = 300.0;
pub(super) const GAP_TOLERANCE_MS: i64 = 5 * 60 * 1000;
pub(super) const LOOKBACK_MS: i64 = 24 * 60 * 60 * 1000;
pub(super) const TREE_WALK_MS: i64 = 30_000;
// ponytail: 30m cap; abandoned last-user chats shouldn't stay live forever
pub(super) const CURSOR_THINK_MS: i64 = 30 * 60 * 1000;

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

#[derive(Clone, Copy)]
pub struct ScanWanted {
    pub idle_secs: f64,
    pub claude: bool,
    pub codex: bool,
    pub grok: bool,
    pub cursor: bool,
}

impl Default for ScanWanted {
    fn default() -> Self {
        Self {
            idle_secs: IDLE_WINDOW_SECS,
            claude: true,
            codex: true,
            grok: true,
            cursor: true,
        }
    }
}

impl ScanWanted {
    pub fn from_settings(s: &Settings) -> Self {
        Self {
            idle_secs: s.idle_window_seconds.max(60.0),
            claude: s.agent_claude_enabled,
            codex: s.agent_codex_enabled,
            grok: s.agent_grok_enabled,
            cursor: s.agent_cursor_enabled,
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct ScanSnapshot {
    pub sessions: LiveSessions,
    pub claude_linked: bool,
    pub codex_linked: bool,
    pub grok_linked: bool,
    pub cursor_linked: bool,
}

pub struct ScanHandle {
    inner: Arc<Mutex<(ScanWanted, ScanSnapshot)>>,
}

impl ScanHandle {
    pub fn spawn(wanted: ScanWanted) -> Self {
        let snap = scan_wanted(wanted);
        let inner = Arc::new(Mutex::new((wanted, snap)));
        let bg = inner.clone();
        thread::Builder::new()
            .name("agentcord-session".into())
            .spawn(move || loop {
                thread::sleep(Duration::from_secs(1));
                let wanted = bg.lock().ok().map(|g| g.0).unwrap_or_default();
                let snap = scan_wanted(wanted);
                if let Ok(mut g) = bg.lock() {
                    g.1 = snap;
                }
            })
            .ok();
        Self { inner }
    }

    pub fn set_wanted(&self, wanted: ScanWanted) {
        if let Ok(mut g) = self.inner.lock() {
            g.0 = wanted;
        }
    }

    pub fn snapshot(&self) -> ScanSnapshot {
        self.inner
            .lock()
            .ok()
            .map(|g| g.1.clone())
            .unwrap_or_default()
    }
}

pub(super) fn scan_wanted(w: ScanWanted) -> ScanSnapshot {
    ScanSnapshot {
        sessions: LiveSessions {
            claude: w.claude.then(|| scan_claude(w.idle_secs)).flatten(),
            codex: w.codex.then(|| scan_codex(w.idle_secs)).flatten(),
            grok: w.grok.then(|| scan_grok(w.idle_secs)).flatten(),
            cursor: w.cursor.then(|| scan_cursor(w.idle_secs)).flatten(),
        },
        claude_linked: claude_linked(),
        codex_linked: codex_linked(),
        grok_linked: grok_linked(),
        cursor_linked: cursor_linked(),
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Activity {
    pub name: String,
    pub details: Option<String>,
    pub state: Option<String>,
    pub start_ms: i64,
    pub large_image: &'static str,
    pub activity_type: i32,
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn within_idle(activity_ms: i64, now: i64, window_secs: f64) -> bool {
    window_secs > 0.0 && activity_ms > 0 && (now - activity_ms) as f64 / 1000.0 <= window_secs
}

pub fn normalize_ms(event_ms: Option<i64>, mtime_ms: i64) -> i64 {
    event_ms.filter(|e| *e > 0).unwrap_or(mtime_ms)
}

pub fn active_duration(
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
        let (Some(created), Some(updated)) = (created_at_ms, updated_at_ms) else {
            return (0, None);
        };
        let start = created.max(cutoff_ms);
        let end = updated.min(now_ms);
        return if end > start {
            (end - start, Some(end))
        } else {
            (0, None)
        };
    }
    let mut points: HashSet<i64> = in_window.into_iter().collect();
    if let Some(c) = created_at_ms {
        if c >= cutoff_ms && c <= now_ms {
            points.insert(c);
        }
    }
    if let (Some(created), Some(updated)) = (created_at_ms, updated_at_ms) {
        if created < cutoff_ms && updated >= cutoff_ms {
            points.insert(cutoff_ms);
        }
    }
    let mut unique: Vec<i64> = points.into_iter().collect();
    unique.sort_unstable();
    if unique.is_empty() {
        return (0, None);
    }
    let mut active = 0;
    for pair in unique.windows(2) {
        let delta = pair[1] - pair[0];
        if delta > 0 && delta <= GAP_TOLERANCE_MS {
            active += delta;
        }
    }
    (active, unique.last().copied())
}

pub fn elapsed_start_ms(total_active_ms: i64, last_ms: Option<i64>, now_ms: i64) -> i64 {
    let end = last_ms.filter(|l| *l > 0).unwrap_or(now_ms).min(now_ms);
    end - total_active_ms.max(0)
}

pub fn pick_winner(sessions: &LiveSessions) -> Option<&SessionInfo> {
    sessions.iter().max_by_key(|s| s.activity_ms)
}

pub fn build_activity(info: &SessionInfo, settings: &Settings) -> Activity {
    let details = if settings.show_model && !info.model.is_empty() {
        Some(info.model.clone())
    } else {
        None
    };
    let mut state_parts = Vec::new();
    if settings.show_project {
        state_parts.push(format!("Working on: {}", info.project));
    }
    if settings.show_tokens && info.tokens > 0 {
        state_parts.push(format!("{} tokens", format_tokens(info.tokens)));
    }
    Activity {
        name: info.agent.display_name().to_string(),
        details,
        state: (!state_parts.is_empty()).then(|| state_parts.join(" · ")),
        start_ms: info.start_epoch_ms,
        large_image: info.agent.large_image(),
        activity_type: settings.activity_type(),
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


pub fn repo_name_from_remote(remote: &str) -> String {
    let base = remote.rsplit(['/', '\\', ':']).next().unwrap_or(remote);
    base.strip_suffix(".git")
        .or_else(|| base.strip_suffix(".GIT"))
        .unwrap_or(base)
        .to_string()
}

pub fn repo_from_cwd(cwd: &str) -> String {
    let fallback = basename(cwd).filter(|s| !s.is_empty()).unwrap_or_else(|| cwd.to_string());
    if cwd.is_empty() {
        return fallback;
    }
    {
        let cache = REPO_CACHE.lock().unwrap();
        if let Some(name) = cache.get(cwd) {
            return name.clone();
        }
    }
    let mut name = fallback.clone();
    if let Some(git_dir) = find_git_dir(Path::new(cwd)) {
        if let Some(url) = read_origin_url(&git_dir) {
            let from_remote = repo_name_from_remote(&url);
            if !from_remote.is_empty() {
                name = from_remote;
            }
        } else if let Some(top) = find_working_tree_root(Path::new(cwd)) {
            if let Some(base) = top.file_name().and_then(|s| s.to_str()) {
                if !base.is_empty() {
                    name = base.to_string();
                }
            }
        }
    }
    REPO_CACHE.lock().unwrap().insert(cwd.to_string(), name.clone());
    name
}

pub(super) fn find_working_tree_root(start: &Path) -> Option<PathBuf> {
    let mut dir = Some(start);
    while let Some(d) = dir {
        let git = d.join(".git");
        if git.is_dir() || git.is_file() {
            return Some(d.to_path_buf());
        }
        dir = d.parent();
    }
    None
}

pub(super) fn find_git_dir(start: &Path) -> Option<PathBuf> {
    let mut dir = Some(start);
    while let Some(d) = dir {
        let git = d.join(".git");
        if git.is_dir() {
            return Some(git);
        }
        if git.is_file() {
            if let Some(text) = read_to_string(&git) {
                for line in text.lines() {
                    let line = line.trim();
                    let Some(rest) = line
                        .strip_prefix("gitdir:")
                        .or_else(|| line.strip_prefix("GITDIR:"))
                    else {
                        continue;
                    };
                    let pointed = rest.trim();
                    if pointed.is_empty() {
                        continue;
                    }
                    let pointed = if Path::new(pointed).is_absolute() {
                        PathBuf::from(pointed)
                    } else {
                        d.join(pointed)
                    };
                    let common = pointed.join("commondir");
                    if let Some(rel) = read_to_string(&common) {
                        let rel = rel.trim();
                        if !rel.is_empty() {
                            return Some(pointed.join(rel));
                        }
                    }
                    return Some(pointed);
                }
            }
        }
        dir = d.parent();
    }
    None
}

pub(super) fn read_origin_url(git_dir: &Path) -> Option<String> {
    let text = read_to_string(&git_dir.join("config"))?;
    let mut in_origin = false;
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            in_origin = line.eq_ignore_ascii_case("[remote \"origin\"]");
            continue;
        }
        if !in_origin {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim().eq_ignore_ascii_case("url") {
            let url = value.trim();
            if !url.is_empty() {
                return Some(url.to_string());
            }
        }
    }
    None
}

pub(super) struct TreeSnap {
    files: Vec<(PathBuf, i64)>,
    walked_at: i64,
}

#[derive(Default, Clone)]
pub(super) struct JsonlAgg {
    offset: u64,
    leftover: String,
    stamps: Vec<i64>,
    cwd: Option<String>,
    model: Option<String>,
    tokens: i64,
    first_event_ms: Option<i64>,
    last_event_ms: Option<i64>,
    created_at_ms: Option<i64>,
    updated_at_ms: Option<i64>,
}

pub(super) static TREES: LazyLock<Mutex<HashMap<String, TreeSnap>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
pub(super) static JSONL_CACHE: LazyLock<Mutex<HashMap<PathBuf, JsonlAgg>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
pub(super) static REPO_CACHE: LazyLock<Mutex<HashMap<String, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(super) fn note_stamp(agg: &mut JsonlAgg, ms: i64) {
    if ms <= 0 {
        return;
    }
    agg.stamps.push(ms);
    agg.first_event_ms = Some(agg.first_event_ms.map_or(ms, |f| f.min(ms)));
    agg.last_event_ms = Some(agg.last_event_ms.map_or(ms, |l| l.max(ms)));
}

// ponytail: 30s tree walk, watcher if new sessions lag
pub(super) fn tree_snapshot(
    root: &Path,
    tag: &str,
    max_depth: usize,
    keep: impl Fn(&Path) -> bool,
) -> Vec<(PathBuf, i64)> {
    let key = format!("{}\0{tag}", root.to_string_lossy());
    let now = now_ms();
    let mut trees = TREES.lock().unwrap();
    let snap = trees.entry(key).or_insert(TreeSnap {
        files: Vec::new(),
        walked_at: 0,
    });
    if now.saturating_sub(snap.walked_at) >= TREE_WALK_MS {
        let mut files = Vec::new();
        walk_files(root, max_depth, &mut |path| {
            if keep(path) {
                if let Some(m) = file_mtime_ms(path) {
                    files.push((path.to_path_buf(), m));
                }
            }
        });
        snap.files = files;
        snap.walked_at = now;
    } else {
        let mut i = 0;
        while i < snap.files.len() {
            match file_mtime_ms(&snap.files[i].0) {
                Some(m) => {
                    snap.files[i].1 = m;
                    i += 1;
                }
                None => {
                    snap.files.swap_remove(i);
                }
            }
        }
    }
    snap.files.clone()
}

pub(super) fn jsonl_cached(path: &Path, parse: impl Fn(&str, &mut JsonlAgg)) -> JsonlAgg {
    let key = path.to_path_buf();
    let mut cache = JSONL_CACHE.lock().unwrap();
    let mut agg = cache.remove(&key).unwrap_or_default();
    pull_jsonl(path, &mut agg, parse);
    cache.insert(key, agg.clone());
    agg
}

pub(super) fn pull_jsonl(path: &Path, agg: &mut JsonlAgg, parse: impl Fn(&str, &mut JsonlAgg)) {
    let Some(mut file) = open_shared(path) else {
        return;
    };
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return;
    };
    if len < agg.offset {
        *agg = JsonlAgg::default();
    }
    if len <= agg.offset {
        return;
    }
    if file.seek(SeekFrom::Start(agg.offset)).is_err() {
        return;
    }
    let mut buf = [0u8; 8192];
    let mut carry = std::mem::take(&mut agg.leftover);
    loop {
        let n = match file.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        carry.push_str(&String::from_utf8_lossy(&buf[..n]));
        while let Some(pos) = carry.find('\n') {
            let mut line = carry[..pos].to_string();
            carry = carry[pos + 1..].to_string();
            if line.ends_with('\r') {
                line.pop();
            }
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                parse(trimmed, agg);
            }
        }
    }
    agg.leftover = carry;
    agg.offset = len;
}

pub(super) fn rolling_start(files: &[(PathBuf, i64)], parse: impl Fn(&str, &mut JsonlAgg) + Copy) -> i64 {
    let now = now_ms();
    let cutoff = now - LOOKBACK_MS;
    let mut total = 0;
    let mut newest_last = None;
    for (path, _) in files {
        let agg = jsonl_cached(path, parse);
        let (active, last) = active_duration(
            &agg.stamps,
            agg.created_at_ms,
            agg.updated_at_ms,
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



pub(super) fn env_home(key: &str) -> Option<PathBuf> {
    std::env::var(key)
        .ok()
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
}

pub(super) fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
}


pub(super) fn read_tail(path: &Path, max: u64) -> Option<String> {
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


pub(super) fn message_texts(message: &Value) -> Vec<String> {
    let Some(content) = message.get("content") else {
        return Vec::new();
    };
    if let Some(s) = content.as_str().filter(|s| !s.is_empty()) {
        return vec![s.to_string()];
    }
    let Some(arr) = content.as_array() else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|part| str_field(part, "text").filter(|s| !s.is_empty()))
        .collect()
}

pub(super) fn parse_embedded_timestamp(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    let utc_at = trimmed.rfind("(UTC")?;
    if !trimmed.ends_with(')') {
        return None;
    }
    let offset_secs = parse_utc_offset_secs(&trimmed[utc_at + 4..trimmed.len() - 1])?;
    let body = trimmed[..utc_at].trim();
    let parts: Vec<&str> = body.split(',').map(str::trim).collect();
    if parts.len() != 4 {
        return None;
    }
    let (month, day) = parse_mon_day(parts[1])?;
    let year: i32 = parts[2].parse().ok()?;
    let (hour, minute) = parse_ampm(parts[3])?;
    let days = days_from_civil(year, month, day)?;
    let local = days * 86_400 + hour as i64 * 3600 + minute as i64 * 60;
    Some((local - offset_secs) * 1000)
}

pub(super) fn parse_utc_offset_secs(raw: &str) -> Option<i64> {
    let trimmed = raw.trim();
    let (sign, body) = match trimmed.as_bytes().first()? {
        b'+' => (1i64, &trimmed[1..]),
        b'-' => (-1, &trimmed[1..]),
        _ => return None,
    };
    let (hours, minutes): (u32, u32) = match body.split_once(':') {
        Some((h, m)) => (h.parse().ok()?, m.parse().ok()?),
        None => (body.parse().ok()?, 0),
    };
    if hours > 18 || minutes > 59 {
        return None;
    }
    Some(sign * (hours as i64 * 3600 + minutes as i64 * 60))
}

pub(super) fn parse_mon_day(s: &str) -> Option<(u32, u32)> {
    let (mon, day) = s.rsplit_once(' ')?;
    const SHORT: [&str; 12] = [
        "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec",
    ];
    const LONG: [&str; 12] = [
        "january",
        "february",
        "march",
        "april",
        "may",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
    ];
    let lower = mon.to_ascii_lowercase();
    let idx = SHORT
        .iter()
        .position(|m| *m == lower)
        .or_else(|| LONG.iter().position(|m| *m == lower))?;
    let day: u32 = day.parse().ok()?;
    if !(1..=31).contains(&day) {
        return None;
    }
    Some((idx as u32 + 1, day))
}

pub(super) fn parse_ampm(s: &str) -> Option<(u32, u32)> {
    let (time, mer) = s.rsplit_once(' ')?;
    let (h, m) = time.split_once(':')?;
    let mut hour: u32 = h.parse().ok()?;
    let minute: u32 = m.parse().ok()?;
    if hour > 12 || minute > 59 {
        return None;
    }
    match mer.to_ascii_uppercase().as_str() {
        "PM" if hour != 12 => hour += 12,
        "AM" if hour == 12 => hour = 0,
        "AM" | "PM" => {}
        _ => return None,
    }
    Some((hour, minute))
}


pub(super) fn project_from_transcript(path: &Path) -> Option<String> {
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

pub(super) fn walk_files(root: &Path, max_depth: usize, visit: &mut dyn FnMut(&Path)) {
    fn rec(dir: &Path, depth: usize, max_depth: usize, visit: &mut dyn FnMut(&Path)) {
        if depth > max_depth {
            return;
        }
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
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

pub(super) fn percent_encode(s: &str) -> String {
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

pub fn parse_iso_ms(iso: &str) -> Option<i64> {
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

pub(super) fn days_from_civil(mut year: i32, month: u32, day: u32) -> Option<i64> {
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

pub(super) fn str_field(v: &Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().map(str::to_string)
}

pub(super) fn json_i64(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
}

pub(super) fn json_time(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    if let Some(s) = v.as_str() {
        return parse_iso_ms(s);
    }
    let n = json_i64(v)?;
    Some(if n.abs() < 1_000_000_000_000 { n * 1000 } else { n })
}

pub(super) fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (from_hex(bytes[i + 1]), from_hex(bytes[i + 2])) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub(super) fn from_hex(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

pub(super) fn basename(path: &str) -> Option<String> {
    Path::new(path)
        .file_name()
        .and_then(|s| s.to_str())
        .map(str::to_string)
}

pub(super) fn file_mtime_ms(path: &Path) -> Option<i64> {
    let meta = fs::metadata(path).ok()?;
    let d = meta.modified().ok()?.duration_since(UNIX_EPOCH).ok()?;
    Some(d.as_millis() as i64)
}

pub(super) fn read_to_string(path: &Path) -> Option<String> {
    let mut file = open_shared(path)?;
    let mut s = String::new();
    file.read_to_string(&mut s).ok()?;
    Some(s)
}

pub(super) fn open_shared(path: &Path) -> Option<File> {
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
pub(super) fn process_is_alive(pid: u32) -> bool {
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
pub(super) fn process_is_alive(_pid: u32) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use super::claude::scan_claude_from;
    use super::codex::scan_codex_from;
    use super::cursor::{cursor_hook_duration, cursor_session_span, scan_cursor_from};
    use super::grok::{grok_rolling_start, scan_grok_from};

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
        let act = build_activity(&info, &crate::settings::Settings::default());
        assert_eq!(act.name, "Grok");
        assert_eq!(act.details.as_deref(), Some("Grok 4.5"));
        assert_eq!(
            act.state.as_deref(),
            Some("Working on: agentcord · 81.2K tokens")
        );
        assert_eq!(act.large_image, "logo-grok");
        let mut hidden = crate::settings::Settings::default();
        hidden.show_model = false;
        hidden.show_project = false;
        hidden.show_tokens = false;
        hidden.activity_type = 2;
        let quiet = build_activity(&info, &hidden);
        assert!(quiet.details.is_none());
        assert!(quiet.state.is_none());
        assert_eq!(quiet.activity_type, 2);
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
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":5}}}\n",
        )
        .unwrap();
        let info = scan_claude_from(&dir, 300.0).unwrap();
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
{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":42}}}}
"#,
        )
        .unwrap();
        let info = scan_codex_from(&dir, 300.0).unwrap();
        assert_eq!(info.agent, AgentKind::Codex);
        assert_eq!(info.project, "agentcord");
        assert_eq!(info.model, "GPT-5.2");
        assert_eq!(info.tokens, 42);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn duration_drops_idle_gaps() {
        let now = 10_000_000i64;
        let cutoff = now - LOOKBACK_MS;
        let morning: Vec<i64> = (0..=15)
            .map(|i| now - 6 * 3600_000 + i * 4 * 60_000)
            .collect();
        let evening: Vec<i64> = (0..=15)
            .map(|i| now - 3600_000 + i * 4 * 60_000)
            .collect();
        let mut stamps = morning;
        stamps.extend(evening);
        let last = *stamps.last().unwrap();
        let (active, got_last) = active_duration(&stamps, None, None, cutoff, now);
        assert!((2 * 3600_000 - 30_000..=2 * 3600_000 + 5_000).contains(&active));
        assert_eq!(got_last, Some(last));
    }

    #[test]
    fn elapsed_adds_live_tail() {
        let now = 2_000_000i64;
        assert_eq!(
            elapsed_start_ms(3_600_000, Some(now - 4_000), now),
            now - 3_604_000
        );
    }

    #[test]
    fn elapsed_start_does_not_crawl_forward() {
        let last = 1_000_000i64;
        let total = 60_000;
        let a = elapsed_start_ms(total, Some(last), last + 10_000);
        let b = elapsed_start_ms(total, Some(last), last + 120_000);
        assert_eq!(a, b);
        assert_eq!(a, last - total);
    }

    #[test]
    fn updated_at_does_not_snap_elapsed_back() {
        let now = 10_000_000i64;
        let last_stamp = now - 5 * 60_000;
        let created = now - 57 * 60_000;
        let (active, last) = active_duration(
            &[last_stamp],
            Some(created),
            Some(now),
            now - LOOKBACK_MS,
            now,
        );
        assert_eq!(last, Some(last_stamp));
        let shown = now - elapsed_start_ms(active, last, now);
        assert_eq!(shown, active + 5 * 60_000);
    }

    #[test]
    fn cursor_span_keeps_elapsed_across_sparse_turns() {
        let now = 10_000_000i64;
        let first = now - 60 * 60_000;
        let last = now - 8_000;
        let (active, got_last) = cursor_session_span(&[first, last], None, Some(now), 0, now);
        assert_eq!(got_last, Some(now));
        assert!((55 * 60_000..=65 * 60_000).contains(&active), "active={active}");
    }

    #[test]
    fn cursor_hook_turns_sum_without_gap_fill() {
        let path = std::env::temp_dir().join(format!(
            "agentcord-turns-{}-{}.jsonl",
            std::process::id(),
            now_ms()
        ));
        fs::write(
            &path,
            "{ \"e\":\"start\",\"ms\":1000,\"id\":\"a\" }\n\
             { \"e\":\"end\",\"ms\":1801000,\"id\":\"a\" }\n\
             { \"e\":\"start\",\"ms\":2401000,\"id\":\"a\" }\n\
             { \"e\":\"end\",\"ms\":3601000,\"id\":\"a\" }\n",
        )
        .unwrap();
        std::env::set_var("AGENTCORD_CURSOR_TURNS", &path);
        let (total, last) = cursor_hook_duration(0, 3601000).unwrap();
        std::env::remove_var("AGENTCORD_CURSOR_TURNS");
        let _ = fs::remove_file(&path);
        assert_eq!(total, 30 * 60_000 + 20 * 60_000);
        assert_eq!(last, Some(3601000));
    }

    #[test]
    fn repo_from_origin_url() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-git-{}-{}",
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(dir.join(".git")).unwrap();
        fs::write(
            dir.join(".git").join("config"),
            "[remote \"origin\"]\n\turl = git@github.com:preschian/fidelity-repo.git\n",
        )
        .unwrap();
        assert_eq!(repo_from_cwd(dir.to_str().unwrap()), "fidelity-repo");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn claude_picks_event_time_over_mtime() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-claude-event-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let stale = dir.join("C-Users-test-stale");
        let live = dir.join("C-Users-test-live");
        fs::create_dir_all(&stale).unwrap();
        fs::create_dir_all(&live).unwrap();
        let now = now_ms();
        fs::write(
            live.join("session.jsonl"),
            format!(
                r#"{{"cwd":"D:\\Workspace\\live-repo","timestamp":{},"message":{{"model":"claude-opus-4-5","usage":{{"input_tokens":1,"output_tokens":1}}}}}}
"#,
                now - 10_000
            ),
        )
        .unwrap();
        fs::write(
            stale.join("session.jsonl"),
            format!(
                r#"{{"cwd":"D:\\Workspace\\stale-repo","timestamp":{},"message":{{"model":"claude-sonnet-4","usage":{{"input_tokens":9,"output_tokens":9}}}}}}
"#,
                now - 2 * 3600_000
            ),
        )
        .unwrap();
        let info = scan_claude_from(&dir, 300.0).unwrap();
        assert_eq!(info.project, "live-repo");
        assert_eq!(info.model, "Opus 4.5");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn cursor_embedded_stamp_matches_iso() {
        let iso = parse_iso_ms("2026-08-18T04:00:00Z").unwrap();
        assert_eq!(
            parse_embedded_timestamp("Tuesday, Aug 18, 2026, 11:00 AM (UTC+7)"),
            Some(iso)
        );
        assert_eq!(
            parse_embedded_timestamp("Tuesday, August 18, 2026, 11:00 AM (UTC+07:00)"),
            Some(iso)
        );
    }

    #[test]
    fn cursor_scan_uses_meta_updated_at() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-cursor-meta-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let sid = "df06561a-03f1-49bd-ae64-2ede2bd21bfc";
        let transcripts = home
            .join("projects")
            .join("D-Workspace-agentcord")
            .join("agent-transcripts")
            .join(sid);
        fs::create_dir_all(&transcripts).unwrap();
        let path = transcripts.join(format!("{sid}.jsonl"));
        fs::write(&path, "{}\n").unwrap();
        let file = std::fs::File::options().write(true).open(&path).unwrap();
        file.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(7200))
            .unwrap();
        drop(file);
        let now = now_ms();
        let chat = home.join("chats").join("workspace").join(sid);
        fs::create_dir_all(&chat).unwrap();
        fs::write(
            chat.join("meta.json"),
            format!(
                r#"{{"cwd":"D:\\Workspace\\agentcord","createdAtMs":{},"updatedAtMs":{}}}"#,
                now - 60_000,
                now - 5_000
            ),
        )
        .unwrap();
        let info = scan_cursor_from(&home, 180.0).unwrap();
        assert_eq!(info.agent, AgentKind::Cursor);
        assert_eq!(info.project, "agentcord");
        assert!(within_idle(info.activity_ms, now_ms(), 180.0));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn cursor_scan_ignores_stale_user_stamps() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-cursor-stamp-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let transcripts = home
            .join("projects")
            .join("D-Workspace-agentcord")
            .join("agent-transcripts");
        fs::create_dir_all(&transcripts).unwrap();
        let path = transcripts.join("abc123.jsonl");
        let stamp = cursor_stamp_near(now_ms(), 7 * 3600);
        fs::write(
            &path,
            format!(
                r#"{{"role":"user","message":{{"content":[{{"type":"text","text":"hi <timestamp>{stamp} (UTC+7)</timestamp>"}}]}}}}
"#
            ),
        )
        .unwrap();
        let file = std::fs::File::options().write(true).open(&path).unwrap();
        file.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(7200))
            .unwrap();
        drop(file);
        assert!(scan_cursor_from(&home, 180.0).is_none());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn cursor_scan_uses_jsonl_mtime() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-cursor-mtime-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let transcripts = home
            .join("projects")
            .join("D-Workspace-agentcord")
            .join("agent-transcripts");
        fs::create_dir_all(&transcripts).unwrap();
        fs::write(transcripts.join("live.jsonl"), "{}\n").unwrap();
        let info = scan_cursor_from(&home, 180.0).unwrap();
        assert_eq!(info.agent, AgentKind::Cursor);
        assert!(within_idle(info.activity_ms, now_ms(), 180.0));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn cursor_open_user_turn_stays_live_while_thinking() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-cursor-think-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let transcripts = home
            .join("projects")
            .join("D-Workspace-agentcord")
            .join("agent-transcripts");
        fs::create_dir_all(&transcripts).unwrap();
        let path = transcripts.join("think.jsonl");
        fs::write(
            &path,
            r#"{"role":"user","message":{"content":[{"type":"text","text":"go"}]}}
"#,
        )
        .unwrap();
        let file = std::fs::File::options().write(true).open(&path).unwrap();
        file.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(90))
            .unwrap();
        drop(file);
        let info = scan_cursor_from(&home, 60.0).unwrap();
        assert!(within_idle(info.activity_ms, now_ms(), 60.0));
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn cursor_finished_assistant_text_can_go_idle() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-cursor-done-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let transcripts = home
            .join("projects")
            .join("D-Workspace-agentcord")
            .join("agent-transcripts");
        fs::create_dir_all(&transcripts).unwrap();
        let path = transcripts.join("done.jsonl");
        fs::write(
            &path,
            r#"{"role":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
"#,
        )
        .unwrap();
        let file = std::fs::File::options().write(true).open(&path).unwrap();
        file.set_modified(std::time::SystemTime::now() - std::time::Duration::from_secs(90))
            .unwrap();
        drop(file);
        assert!(scan_cursor_from(&home, 60.0).is_none());
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn zero_idle_window_is_not_live() {
        assert!(!within_idle(now_ms(), now_ms(), 0.0));
    }

    #[test]
    fn tree_snapshot_isolates_filters_on_same_root() {
        let dir = std::env::temp_dir().join(format!(
            "agentcord-tree-{}-{}",
            std::process::id(),
            now_ms()
        ));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("session.jsonl"), "{}\n").unwrap();
        fs::write(dir.join("summary.json"), "{}\n").unwrap();
        let jsonl = tree_snapshot(&dir, "jsonl", 2, |p| {
            p.extension().and_then(|e| e.to_str()) == Some("jsonl")
        });
        let summary = tree_snapshot(&dir, "summary", 2, |p| {
            p.file_name().and_then(|n| n.to_str()) == Some("summary.json")
        });
        assert_eq!(jsonl.len(), 1);
        assert_eq!(summary.len(), 1);
        assert!(jsonl[0].0.ends_with("session.jsonl"));
        assert!(summary[0].0.ends_with("summary.json"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn grok_elapsed_uses_events_after_summary_walk() {
        let home = std::env::temp_dir().join(format!(
            "agentcord-grok-elapsed-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let sess = home.join("sessions").join("proj").join("sid");
        fs::create_dir_all(&sess).unwrap();
        fs::write(sess.join("summary.json"), "{}\n").unwrap();
        let now = now_ms();
        fs::write(
            sess.join("events.jsonl"),
            format!("{{\"ts\":{}}}\n{{\"ts\":{}}}\n", now - 60_000, now - 5_000),
        )
        .unwrap();
        let sessions = home.join("sessions");
        let _ = tree_snapshot(&sessions, "grok-summary", 8, |p| {
            p.file_name().and_then(|n| n.to_str()) == Some("summary.json")
        });
        let start = grok_rolling_start(&home);
        let elapsed = now_ms() - start;
        assert!(
            elapsed >= 50_000 && elapsed < 90_000,
            "elapsed={elapsed}"
        );
        let _ = fs::remove_dir_all(&home);
    }

    #[test]
    fn grok_open_turn_without_live_pid_is_idle() {
        *grok::LAST_GROK.lock().unwrap() = None;
        let home = std::env::temp_dir().join(format!(
            "agentcord-grok-idle-{}-{}",
            std::process::id(),
            now_ms()
        ));
        let sess = home
            .join("sessions")
            .join("D%3A%5CWorkspace%5Chsr-companion")
            .join("sid");
        fs::create_dir_all(&sess).unwrap();
        fs::write(home.join("active_sessions.json"), "[]\n").unwrap();
        fs::write(
            sess.join("summary.json"),
            r#"{"info":{"cwd":"D:\\Workspace\\hsr-companion"},"last_active_at":"2026-01-01T00:00:00Z","created_at":"2026-01-01T00:00:00Z","current_model_id":"grok-4.6","git_remotes":["git@github.com:preschian/hsr-companion.git"]}"#,
        )
        .unwrap();
        fs::write(
            sess.join("events.jsonl"),
            "{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"mcp_init_completed\"}\n",
        )
        .unwrap();
        assert!(scan_grok_from(&home, 300.0).is_none());
        let _ = fs::remove_dir_all(&home);
    }

    fn cursor_stamp_near(now_ms: i64, offset_secs: i64) -> String {
        let local = now_ms / 1000 + offset_secs;
        let days = local.div_euclid(86_400);
        let sod = local.rem_euclid(86_400);
        let (year, month, day) = civil_from_days(days);
        let hour = (sod / 3600) as u32;
        let minute = (sod / 60 % 60) as u32;
        let (h12, mer) = match hour {
            0 => (12, "AM"),
            1..=11 => (hour, "AM"),
            12 => (12, "PM"),
            _ => (hour - 12, "PM"),
        };
        const MONTHS: [&str; 12] = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ];
        const DAYS: [&str; 7] = [
            "Sunday",
            "Monday",
            "Tuesday",
            "Wednesday",
            "Thursday",
            "Friday",
            "Saturday",
        ];
        let weekday = DAYS[((days + 4).rem_euclid(7)) as usize];
        format!(
            "{}, {} {}, {}, {h12}:{minute:02} {mer}",
            weekday,
            MONTHS[month as usize - 1],
            day,
            year
        )
    }

    fn civil_from_days(days: i64) -> (i32, u32, u32) {
        let z = days + 719468;
        let era = z.div_euclid(146097);
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let mut year = (yoe + era * 400) as i32;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
        let month = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
        if month <= 2 {
            year += 1;
        }
        (year, month, day)
    }
}
