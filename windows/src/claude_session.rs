//! Detects the currently active Claude Code session by scanning
//! `%USERPROFILE%\.claude\projects` and parsing the most recently modified
//! `.jsonl` transcript. The transcript schema is undocumented, so all parsing
//! is defensive: malformed or unexpected lines are skipped, never fatal.
//!
//! Port of `AgentCord/ClaudeSession.swift`. Two differences from the macOS
//! original, both deliberate:
//!
//!   * No live filesystem watcher yet. macOS uses `FSEvents`; here we rely on
//!     the periodic re-scan the Swift app also runs (it's what catches the
//!     active→idle transition, which fires no file event). A `notify`-based
//!     watcher can be layered on later for instant updates.
//!   * `Calendar`/`ISO8601DateFormatter` become `chrono`.
//!
//! The parsing semantics — daily token totals, the "active work" timer that
//! excludes idle gaps, repo-name resolution via git — match the Swift version.

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::models::SessionInfo;
use crate::util::command;

/// When summing the day's working time, a gap between two consecutive messages
/// longer than this is treated as a break (idle), not work, so a session left
/// open does not inflate the total. Also excludes the gaps between sessions.
const ACTIVE_GAP_TOLERANCE_MS: i64 = 5 * 60 * 1000;

pub struct ClaudeSession {
    pub(crate) projects_dir: PathBuf,
    /// A transcript counts as active if it was modified within this window.
    active_window: Duration,
    /// Memoized per-file aggregates, reused while the file is unmodified and we
    /// are still on the same calendar day. See [`Self::aggregate`].
    cache: HashMap<PathBuf, CacheEntry>,
    repo_name_cache: HashMap<String, String>,
    /// When the transcript tree is unchanged, reuse the last result and only
    /// refresh the elapsed timer (avoids re-walking aggregates every tick).
    last_scan: Option<ScanSnapshot>,
}

struct ScanSnapshot {
    files_sig: u64,
    day_start_ms: i64,
    total_active_ms: i64,
    newest: (PathBuf, i64),
    active_last_today_ms: Option<i64>,
    session: SessionInfo,
}

impl ClaudeSession {
    pub fn new() -> Self {
        let projects_dir = home_dir().join(".claude").join("projects");
        Self {
            projects_dir,
            active_window: Duration::from_secs(5 * 60),
            cache: HashMap::new(),
            repo_name_cache: HashMap::new(),
            last_scan: None,
        }
    }

    pub fn set_active_window(&mut self, window: Duration) {
        self.active_window = window;
    }

    pub fn with_active_window(mut self, window: Duration) -> Self {
        self.active_window = window;
        self
    }

    pub fn projects_dir(&self) -> &Path {
        &self.projects_dir
    }

    /// Scan the projects tree and return the current session, or `None` when no
    /// transcript has been touched within the active window.
    pub fn scan(&mut self) -> Option<SessionInfo> {
        let mut files: Vec<(PathBuf, i64)> = Vec::new();
        collect_jsonl(&self.projects_dir, &mut files);
        if files.is_empty() {
            self.last_scan = None;
            return None;
        }

        let newest = files
            .iter()
            .max_by_key(|(_, mtime)| *mtime)
            .cloned()
            .expect("non-empty");

        let now_ms = now_ms();
        if now_ms - newest.1 > self.active_window.as_millis() as i64 {
            self.last_scan = None;
            return None;
        }

        let day_start_ms = local_day_start_ms();
        let files_sig = files_signature(&files);

        if let Some(prev) = &self.last_scan {
            if prev.files_sig == files_sig
                && prev.day_start_ms == day_start_ms
                && prev.newest == newest
            {
                return Some(self.refresh_elapsed(prev, now_ms));
            }
        }

        let mut total_tokens_today: i64 = 0;
        let mut total_active_ms: i64 = 0;
        for (path, mtime) in &files {
            let agg = self.aggregate(path, *mtime, day_start_ms);
            total_tokens_today += agg.tokens_today;
            total_active_ms += agg.active_ms_today;
        }
        let active_agg = self.aggregate(&newest.0, newest.1, day_start_ms);

        self.cache.retain(|k, _| files.iter().any(|(p, _)| p == k));

        let session =
            self.make_session_info(&newest, &active_agg, total_tokens_today, total_active_ms, now_ms);
        self.last_scan = Some(ScanSnapshot {
            files_sig,
            day_start_ms,
            total_active_ms,
            newest: newest.clone(),
            active_last_today_ms: active_agg.last_today_ms,
            session: session.clone(),
        });
        Some(session)
    }

    fn refresh_elapsed(&self, prev: &ScanSnapshot, now_ms: i64) -> SessionInfo {
        let mut elapsed_ms = prev.total_active_ms;
        if let Some(last) = prev.active_last_today_ms {
            let tail = now_ms - last;
            if tail > 0 && tail <= ACTIVE_GAP_TOLERANCE_MS {
                elapsed_ms += tail;
            }
        }
        SessionInfo {
            start_epoch_ms: now_ms - elapsed_ms,
            last_modified_ms: prev.newest.1,
            ..prev.session.clone()
        }
    }

    fn aggregate(&mut self, path: &Path, mtime: i64, day_start_ms: i64) -> DayAggregate {
        if let Some(entry) = self.cache.get(path) {
            if entry.mtime == mtime && entry.day_start_ms == day_start_ms {
                return entry.aggregate.clone();
            }
        }

        let mut agg = DayAggregate::default();
        let mut prev_today_ms: Option<i64> = None;

        if let Ok(content) = fs::read_to_string(path) {
            for line in content.lines() {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                let obj = match serde_json::from_str::<serde_json::Value>(trimmed) {
                    Ok(v) if v.is_object() => v,
                    _ => continue,
                };

                if agg.cwd.is_none() {
                    if let Some(c) = obj.get("cwd").and_then(|v| v.as_str()) {
                        if !c.is_empty() {
                            agg.cwd = Some(c.to_string());
                        }
                    }
                }

                let line_ms = obj
                    .get("timestamp")
                    .and_then(|v| v.as_str())
                    .and_then(epoch_ms_from_iso);
                let is_today = line_ms.is_some_and(|ms| ms >= day_start_ms);

                if let Some(message) = obj.get("message").filter(|m| m.is_object()) {
                    if let Some(m) = message.get("model").and_then(|v| v.as_str()) {
                        if !m.is_empty() && m != "<synthetic>" {
                            agg.model = Some(m.to_string());
                        }
                    }
                    if is_today {
                        if let Some(usage) = message.get("usage").filter(|u| u.is_object()) {
                            agg.tokens_today +=
                                usage.get("input_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                            agg.tokens_today +=
                                usage.get("output_tokens").and_then(|v| v.as_i64()).unwrap_or(0);
                        }
                    }
                }

                if is_today {
                    if let Some(ms) = line_ms {
                        if let Some(prev) = prev_today_ms {
                            let delta = ms - prev;
                            if delta > 0 && delta <= ACTIVE_GAP_TOLERANCE_MS {
                                agg.active_ms_today += delta;
                            }
                        }
                        prev_today_ms = Some(ms);
                        agg.last_today_ms = Some(ms);
                    }
                }
            }
        }

        self.cache.insert(
            path.to_path_buf(),
            CacheEntry { mtime, day_start_ms, aggregate: agg.clone() },
        );
        agg
    }

    fn make_session_info(
        &mut self,
        newest: &(PathBuf, i64),
        active: &DayAggregate,
        total_tokens_today: i64,
        total_active_ms: i64,
        now_ms: i64,
    ) -> SessionInfo {
        let dir_name = newest
            .0
            .parent()
            .and_then(|p| p.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let mut project_name = derive_project_name(dir_name);
        if let Some(cwd) = &active.cwd {
            project_name = self.repo_name(cwd);
        }

        let mut elapsed_ms = total_active_ms;
        if let Some(last) = active.last_today_ms {
            let tail = now_ms - last;
            if tail > 0 && tail <= ACTIVE_GAP_TOLERANCE_MS {
                elapsed_ms += tail;
            }
        }
        let start_ms = now_ms - elapsed_ms;

        SessionInfo {
            project_name: if project_name.is_empty() {
                "Claude Code".to_string()
            } else {
                project_name
            },
            model: active.model.as_deref().map(pretty_model),
            start_epoch_ms: start_ms,
            total_tokens: total_tokens_today.max(0) as u64,
            last_modified_ms: newest.1,
        }
    }

    fn repo_name(&mut self, cwd: &str) -> String {
        if let Some(cached) = self.repo_name_cache.get(cwd) {
            return cached.clone();
        }

        let mut name = last_path_component(cwd);
        if let Some(remote) = run_git(&["-C", cwd, "config", "--get", "remote.origin.url"]) {
            let mut base = last_path_component(&remote);
            if let Some(stripped) = base.strip_suffix(".git") {
                base = stripped.to_string();
            }
            if !base.is_empty() {
                name = base;
            }
        } else if let Some(top) = run_git(&["-C", cwd, "rev-parse", "--show-toplevel"]) {
            let base = last_path_component(&top);
            if !base.is_empty() {
                name = base;
            }
        }

        self.repo_name_cache.insert(cwd.to_string(), name.clone());
        name
    }
}

#[derive(Default, Clone)]
struct DayAggregate {
    cwd: Option<String>,
    model: Option<String>,
    last_today_ms: Option<i64>,
    active_ms_today: i64,
    tokens_today: i64,
}

struct CacheEntry {
    mtime: i64,
    day_start_ms: i64,
    aggregate: DayAggregate,
}

fn files_signature(files: &[(PathBuf, i64)]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for (path, mtime) in files {
        path.hash(&mut hasher);
        mtime.hash(&mut hasher);
    }
    hasher.finish()
}

fn collect_jsonl(dir: &Path, out: &mut Vec<(PathBuf, i64)>) {
    let entries = match fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let file_type = match entry.file_type() {
            Ok(t) => t,
            Err(_) => continue,
        };
        let path = entry.path();
        if file_type.is_dir() {
            collect_jsonl(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            let mtime = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            out.push((path, mtime));
        }
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn local_day_start_ms() -> i64 {
    chrono::Local::now()
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|midnight| midnight.and_local_timezone(chrono::Local).single())
        .map(|dt| dt.timestamp_millis())
        .unwrap_or_else(now_ms)
}

pub fn epoch_ms_from_iso(s: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.timestamp_millis())
}

fn derive_project_name(dir: &str) -> String {
    dir.rsplit('-')
        .find(|s| !s.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| dir.to_string())
}

fn last_path_component(p: &str) -> String {
    p.rsplit(['/', '\\'])
        .find(|s| !s.is_empty())
        .unwrap_or("")
        .to_string()
}

fn run_git(args: &[&str]) -> Option<String> {
    let output = command("git").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

pub fn pretty_model(raw: &str) -> String {
    let lower = raw.to_lowercase();
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

    match extract_version(raw) {
        Some(v) => format!("{family} {v}"),
        None => family.to_string(),
    }
}

fn extract_version(raw: &str) -> Option<String> {
    let b = raw.as_bytes();
    let start = b.iter().position(u8::is_ascii_digit)?;
    let mut end = start;
    while end < b.len() && b[end].is_ascii_digit() {
        end += 1;
    }
    if end + 1 < b.len() && (b[end] == b'.' || b[end] == b'-') && b[end + 1].is_ascii_digit() {
        end += 1;
        while end < b.len() && b[end].is_ascii_digit() {
            end += 1;
        }
    }
    Some(raw[start..end].replace('-', "."))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn pretty_model_formats_opus() {
        assert_eq!(pretty_model("claude-opus-4-5-20260101"), "Opus 4.5");
    }

    #[test]
    fn extract_version_normalizes_dash() {
        assert_eq!(extract_version("claude-sonnet-4-6"), Some("4.6".to_string()));
    }

    #[test]
    fn epoch_ms_from_iso_parses_zulu() {
        let ms = epoch_ms_from_iso("2026-01-15T12:00:00Z").unwrap();
        assert!(ms > 0);
    }

    #[test]
    fn aggregate_sums_tokens_and_active_gaps() {
        let dir = std::env::temp_dir().join("agentcord_test_projects");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("session.jsonl");
        let day = local_day_start_ms();
        let t0 = day + 60_000;
        let t1 = t0 + 30_000;
        let mut file = fs::File::create(&path).unwrap();
        writeln!(
            file,
            r#"{{"timestamp":"{}","message":{{"model":"claude-opus-4-5","usage":{{"input_tokens":10,"output_tokens":5}}}}}}"#,
            chrono::DateTime::from_timestamp_millis(t0).unwrap().to_rfc3339()
        )
        .unwrap();
        writeln!(
            file,
            r#"{{"timestamp":"{}","message":{{"usage":{{"input_tokens":2,"output_tokens":3}}}}}}"#,
            chrono::DateTime::from_timestamp_millis(t1).unwrap().to_rfc3339()
        )
        .unwrap();

        let mut session = ClaudeSession::new().with_active_window(Duration::from_secs(3600));
        session.projects_dir = dir.clone();
        let mtime = fs::metadata(&path).unwrap().modified().unwrap();
        let mtime_ms = mtime
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let agg = session.aggregate(&path, mtime_ms, day);
        assert_eq!(agg.tokens_today, 20);
        assert_eq!(agg.active_ms_today, 30_000);

        let _ = fs::remove_dir_all(&dir);
    }
}
