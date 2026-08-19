//! Cursor session from today's hook file (`%TEMP%\AgentCord\yyyy-MM-dd-uptime.json`).

use super::*;
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default)]
pub struct CursorScan {
    pub today_ms: i64,
    pub session: Option<SessionInfo>,
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

pub fn cursor_linked() -> bool {
    dirs_home().is_some_and(|home| {
        let c = home.join(".cursor");
        c.join("projects").is_dir() || c.join("chats").is_dir()
    })
}

pub fn scan_cursor(_idle_secs: f64) -> CursorScan {
    scan_cursor_at(&cursor_uptime_path(), now_ms())
}

pub(super) fn scan_cursor_at(path: &Path, now_ms: i64) -> CursorScan {
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
    CursorScan {
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

pub(super) fn local_ymd() -> String {
    #[cfg(windows)]
    {
        #[repr(C)]
        struct SystemTime {
            year: u16,
            month: u16,
            day_of_week: u16,
            day: u16,
            hour: u16,
            minute: u16,
            second: u16,
            milliseconds: u16,
        }
        extern "system" {
            fn GetLocalTime(st: *mut SystemTime);
        }
        let mut st = SystemTime {
            year: 0,
            month: 0,
            day_of_week: 0,
            day: 0,
            hour: 0,
            minute: 0,
            second: 0,
            milliseconds: 0,
        };
        unsafe { GetLocalTime(&mut st) };
        return format!("{:04}-{:02}-{:02}", st.year, st.month, st.day);
    }
    #[cfg(not(windows))]
    {
        let secs = now_ms() / 1000;
        let days = secs.div_euclid(86_400);
        let (year, month, day) = civil_ymd(days);
        format!("{year:04}-{month:02}-{day:02}")
    }
}

#[cfg(not(windows))]
fn civil_ymd(days: i64) -> (i32, u32, u32) {
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    (year as i32, m as u32, d as u32)
}
