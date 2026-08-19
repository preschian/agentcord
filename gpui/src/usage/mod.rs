//! Cheap usage polls. Agent fetchers live in `claude` / `codex` / `cursor` / `grok`.

use crate::session::{format_tokens, now_ms, parse_iso_ms, AgentKind, SessionInfo};
use crate::settings::Settings;

mod claude;
mod codex;
mod cursor;
mod grok;

pub use claude::{parse_claude_profile, parse_claude_usage};
pub use codex::{parse_codex_wham, parse_codex_account};
pub use cursor::parse_cursor_usage;
pub use grok::{parse_grok_billing, parse_grok_plan};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub(super) const MAX_STALE_MS: i64 = 24 * 60 * 60 * 1000;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    #[default]
    Normal,
    Warning,
    Critical,
}

impl Severity {
    fn from_api(raw: &str) -> Self {
        match raw.to_ascii_lowercase().as_str() {
            "normal" | "info" | "" => Self::Normal,
            "warning" | "warn" | "low" => Self::Warning,
            _ => Self::Critical,
        }
    }

    fn from_percent(percent: i64) -> Self {
        if percent >= 95 {
            Self::Critical
        } else if percent >= 80 {
            Self::Warning
        } else {
            Self::Normal
        }
    }

    pub fn color(self) -> u32 {
        match self {
            Self::Normal => 0x007aff,
            Self::Warning => 0xff9500,
            Self::Critical => 0xff3b30,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct UsageWindow {
    pub percent: i64,
    #[serde(default)]
    pub resets_at_ms: Option<i64>,
    #[serde(default)]
    pub severity: Severity,
}

impl UsageWindow {
    fn new(percent: i64, resets_at_ms: Option<i64>) -> Self {
        Self {
            percent,
            resets_at_ms,
            severity: Severity::from_percent(percent),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Cached<T> {
    pub fetched_at_ms: i64,
    pub info: T,
}

impl<T> Cached<T> {
    fn fresh(info: T) -> Self {
        Self {
            fetched_at_ms: now_ms(),
            info,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ClaudeUsage {
    pub five_hour: UsageWindow,
    pub weekly: UsageWindow,
    #[serde(default)]
    pub model_weekly: Vec<(String, UsageWindow)>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub plan_name: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CursorUsage {
    pub included: UsageWindow,
    pub auto: Option<UsageWindow>,
    pub api: Option<UsageWindow>,
    pub on_demand: Option<UsageWindow>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub plan_name: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GrokUsage {
    pub weekly: UsageWindow,
    pub on_demand: Option<UsageWindow>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub plan_name: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CodexUsage {
    pub primary: UsageWindow,
    pub primary_label: String,
    pub secondary: Option<UsageWindow>,
    pub secondary_label: Option<String>,
    #[serde(default)]
    pub email: Option<String>,
    #[serde(default)]
    pub plan_name: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct UsageSnapshot {
    pub claude: Option<Cached<ClaudeUsage>>,
    pub codex: Option<Cached<CodexUsage>>,
    pub cursor: Option<Cached<CursorUsage>>,
    pub grok: Option<Cached<GrokUsage>>,
}

impl UsageSnapshot {
    pub fn primary(&self, agent: AgentKind) -> Option<UsageWindow> {
        match agent {
            AgentKind::Claude => self.claude.as_ref().map(|c| c.info.five_hour),
            AgentKind::Codex => self.codex.as_ref().map(|c| c.info.primary),
            AgentKind::Cursor => self.cursor.as_ref().map(|c| c.info.included),
            AgentKind::Grok => self.grok.as_ref().map(|c| c.info.weekly),
        }
    }

    pub fn identity(&self, agent: AgentKind) -> (Option<String>, Option<String>) {
        match agent {
            AgentKind::Claude => self
                .claude
                .as_ref()
                .map(|c| (c.info.email.clone(), c.info.plan_name.clone()))
                .unwrap_or((None, None)),
            AgentKind::Codex => self
                .codex
                .as_ref()
                .map(|c| (c.info.email.clone(), c.info.plan_name.clone()))
                .unwrap_or((None, None)),
            AgentKind::Cursor => self
                .cursor
                .as_ref()
                .map(|c| (c.info.email.clone(), c.info.plan_name.clone()))
                .unwrap_or((None, None)),
            AgentKind::Grok => self
                .grok
                .as_ref()
                .map(|c| (c.info.email.clone(), c.info.plan_name.clone()))
                .unwrap_or((None, None)),
        }
    }

    pub fn rows(&self, agent: AgentKind) -> Vec<(String, Option<UsageWindow>)> {
        match agent {
            AgentKind::Claude => {
                let Some(c) = &self.claude else {
                    return Vec::new();
                };
                let mut rows = vec![
                    ("Current session".into(), Some(c.info.five_hour)),
                    ("All models".into(), Some(c.info.weekly)),
                ];
                rows.extend(
                    c.info
                        .model_weekly
                        .iter()
                        .map(|(name, w)| (name.clone(), Some(*w))),
                );
                rows
            }
            AgentKind::Codex => {
                let Some(c) = &self.codex else {
                    return Vec::new();
                };
                let mut rows = vec![(c.info.primary_label.clone(), Some(c.info.primary))];
                if let (Some(w), label) = (c.info.secondary, c.info.secondary_label.as_deref()) {
                    rows.push((label.unwrap_or("Secondary limit").into(), Some(w)));
                }
                rows
            }
            AgentKind::Cursor => {
                let Some(c) = &self.cursor else {
                    return Vec::new();
                };
                let mut rows = vec![("Included usage".into(), Some(c.info.included))];
                if let Some(w) = c.info.auto {
                    rows.push(("Auto + Composer".into(), Some(w)));
                }
                if let Some(w) = c.info.api {
                    rows.push(("API models".into(), Some(w)));
                }
                if let Some(w) = c.info.on_demand {
                    rows.push(("On-demand".into(), Some(w)));
                }
                rows
            }
            AgentKind::Grok => {
                let Some(c) = &self.grok else {
                    return Vec::new();
                };
                let mut rows = vec![("Weekly credits".into(), Some(c.info.weekly))];
                if let Some(w) = c.info.on_demand {
                    rows.push(("On-demand".into(), Some(w)));
                }
                rows
            }
        }
    }
}

pub fn spawn() -> Arc<Mutex<UsageSnapshot>> {
    let snap = Arc::new(Mutex::new(load_cache()));
    let shared = snap.clone();
    thread::Builder::new()
        .name("agentcord-usage".into())
        .spawn(move || loop {
            let prev = shared.lock().ok().map(|g| g.clone()).unwrap_or_default();
            let next = fetch_all(&prev);
            save_cache(&next);
            if let Ok(mut g) = shared.lock() {
                *g = next;
            }
            thread::sleep(Duration::from_secs(300));
        })
        .ok();
    snap
}

pub const TRAY_TIP_MAX: usize = 63;

pub fn tray_tip(
    session: Option<&SessionInfo>,
    discord: &str,
    last_error: Option<&str>,
    snap: &UsageSnapshot,
    enabled: &[AgentKind],
    settings: &Settings,
    now: i64,
) -> String {
    let session_line = match session {
        Some(s) => {
            let mut parts = vec![s.agent.display_name().to_string()];
            if settings.show_project {
                parts.push(s.project.clone());
            }
            if settings.show_model && !s.model.is_empty() {
                parts.push(s.model.clone());
            }
            parts.push(elapsed_compact(now.saturating_sub(s.start_epoch_ms)));
            if settings.show_tokens && s.tokens > 0 {
                parts.push(format!("{} tokens", format_tokens(s.tokens)));
            }
            parts.join(" · ")
        }
        None => match last_error.filter(|e| !e.is_empty()) {
            Some(err) => format!("AgentCord — {err}"),
            None => format!("AgentCord — Idle · {discord}"),
        },
    };
    let text = match usage_tip(snap, enabled, now) {
        Some(usage) => format!("{session_line}\n{usage}"),
        None => session_line,
    };
    fit_tip(&text)
}

pub fn masked_email(email: &str) -> String {
    let Some(at) = email.find('@') else {
        return "•".repeat(email.len().max(4));
    };
    let local = &email[..at];
    let domain = &email[at + 1..];
    let masked_local = if local.is_empty() {
        "•••".into()
    } else {
        format!(
            "{}{}",
            local.chars().next().unwrap(),
            "•".repeat((local.len() - 1).max(3))
        )
    };
    let masked_domain = match domain.rfind('.') {
        None => "•".repeat(domain.len().max(3)),
        Some(dot) => {
            let name = &domain[..dot];
            let tld = &domain[dot..];
            if name.is_empty() {
                format!("••{tld}")
            } else {
                format!(
                    "{}{}{tld}",
                    name.chars().next().unwrap(),
                    "•".repeat((name.len() - 1).max(2))
                )
            }
        }
    };
    format!("{masked_local}@{masked_domain}")
}

pub fn capitalize_plan(value: &str) -> String {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

pub(super) fn usage_tip(snap: &UsageSnapshot, enabled: &[AgentKind], now: i64) -> Option<String> {
    let rows: Vec<_> = enabled
        .iter()
        .copied()
        .filter_map(|agent| snap.primary(agent).map(|window| (agent, window)))
        .collect();
    if rows.is_empty() {
        return None;
    }
    let labeled = rows.len() > 1;
    let codex_label = snap.codex.as_ref().map(|c| c.info.primary_label.as_str());
    Some(
        rows.into_iter()
            .map(|(agent, window)| compact_usage(agent, &window, labeled, codex_label, now))
            .collect::<Vec<_>>()
            .join(" · "),
    )
}

pub(super) fn compact_usage(
    agent: AgentKind,
    window: &UsageWindow,
    labeled: bool,
    codex_label: Option<&str>,
    now: i64,
) -> String {
    let text = if labeled {
        format!("{} {}%", agent.display_name(), window.percent)
    } else {
        match agent {
            AgentKind::Claude => format!("5h {}%", window.percent),
            AgentKind::Codex
                if codex_label.is_some_and(|s| s.to_ascii_lowercase().contains("5-hour")) =>
            {
                format!("Codex 5h {}%", window.percent)
            }
            AgentKind::Codex => format!("Codex {}%", window.percent),
            AgentKind::Cursor => format!("Cursor {}%", window.percent),
            AgentKind::Grok => format!("Grok {}%", window.percent),
        }
    };
    if !labeled {
        if let Some(ms) = window.resets_at_ms {
            return format!("{text} ({})", format_reset_in_at(ms, now));
        }
    }
    text
}

pub(super) fn elapsed_compact(ms: i64) -> String {
    let total_minutes = (ms / 60_000).max(0);
    let h = total_minutes / 60;
    let m = total_minutes % 60;
    if h > 0 {
        format!("{h}h {m:02}m")
    } else {
        format!("{m}m")
    }
}

pub(super) fn fit_tip(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= TRAY_TIP_MAX {
        return text.to_string();
    }
    chars[..TRAY_TIP_MAX - 1].iter().collect::<String>() + "…"
}

pub fn format_window_value(window: &UsageWindow) -> String {
    match window.resets_at_ms {
        Some(ms) => {
            let left = format_reset_in_at(ms, now_ms());
            if left == "now" {
                format!("{}% · resets now", window.percent)
            } else {
                format!("{}% · {left}", window.percent)
            }
        }
        None => format!("{}%", window.percent),
    }
}

pub(super) fn fetch_all(prev: &UsageSnapshot) -> UsageSnapshot {
    UsageSnapshot {
        claude: claude::fetch(&prev.claude),
        codex: codex::fetch(&prev.codex),
        cursor: cursor::fetch(&prev.cursor),
        grok: grok::fetch(&prev.grok),
    }
}

pub(super) fn keep_stale<T: Clone>(prev: &Option<Cached<T>>) -> Option<Cached<T>> {
    prev.clone()
        .filter(|c| now_ms().saturating_sub(c.fetched_at_ms) <= MAX_STALE_MS)
}

pub(super) fn keep_identity(
    email: &mut Option<String>,
    plan: &mut Option<String>,
    prev: Option<(Option<String>, Option<String>)>,
) {
    let Some((prev_email, prev_plan)) = prev else {
        return;
    };
    if email.is_none() {
        *email = prev_email;
    }
    if plan.is_none() {
        *plan = prev_plan;
    }
}


pub(super) fn load_cache() -> UsageSnapshot {
    let Some(path) = cache_path() else {
        return UsageSnapshot::default();
    };
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

pub(super) fn save_cache(snap: &UsageSnapshot) {
    let Some(path) = cache_path() else {
        return;
    };
    if let Some(dir) = path.parent() {
        let _ = fs::create_dir_all(dir);
    }
    let Ok(text) = serde_json::to_string(snap) else {
        return;
    };
    let tmp = path.with_extension("json.tmp");
    if fs::write(&tmp, text).is_ok() {
        let _ = fs::rename(&tmp, path);
    }
}

pub(super) fn cache_path() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA").map(PathBuf::from)?;
    Some(base.join("AgentCord").join("gpui-usage-cache.json"))
}

pub(super) fn clamp_pct(v: f64) -> i64 {
    if !v.is_finite() {
        return 0;
    }
    v.round().clamp(0.0, 100.0) as i64
}

pub(super) fn json_num(v: Option<&Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64().or_else(|| x.as_i64().map(|n| n as f64)))
}

pub(super) fn json_str(v: Option<&Value>) -> Option<&str> {
    v.and_then(|x| x.as_str())
}

pub(super) fn json_epoch_ms(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_f64().map(epoch_to_ms),
        Value::String(s) => s.parse::<f64>().ok().map(epoch_to_ms),
        _ => None,
    }
}

pub(super) fn money_val(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(_) => json_num(v),
        Value::Object(o) => json_num(o.get("val")),
        _ => None,
    }
}

pub(super) fn epoch_to_ms(n: f64) -> i64 {
    if n > 1_000_000_000_000.0 {
        n as i64
    } else {
        (n * 1000.0) as i64
    }
}

pub(super) fn format_reset_in_at(resets_at_ms: i64, now: i64) -> String {
    let remaining = resets_at_ms - now;
    let total_minutes = remaining / 60_000;
    if total_minutes <= 0 {
        return if remaining > 0 {
            "<1m".into()
        } else {
            "now".into()
        };
    }
    let days = total_minutes / (24 * 60);
    let hours = total_minutes / 60 % 24;
    let minutes = total_minutes % 60;
    if days > 0 {
        format!("{days}d {hours}h")
    } else if hours > 0 {
        format!("{hours}h {minutes}m")
    } else {
        format!("{minutes}m")
    }
}

pub(super) fn get(url: &str, headers: &[(&str, &str)]) -> Option<String> {
    match get_status(url, headers) {
        Some((200, body)) => Some(body),
        _ => None,
    }
}

pub(super) fn get_status(url: &str, headers: &[(&str, &str)]) -> Option<(u16, String)> {
    let mut req = ureq::get(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let resp = req.call().ok()?;
    let status = resp.status();
    let body = resp.into_string().ok()?;
    Some((status, body))
}

pub(super) fn post_json(url: &str, json: &str, headers: &[(&str, &str)]) -> Option<String> {
    let mut req = ureq::post(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    if req.header("Content-Type").is_none() {
        req = req.set("Content-Type", "application/json");
    }
    let resp = req.send_bytes(json.as_bytes()).ok()?;
    if resp.status() != 200 {
        return None;
    }
    resp.into_string().ok()
}


pub(super) fn read_home(parts: &[&str]) -> Option<String> {
    let mut path =
        PathBuf::from(std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?);
    for p in parts {
        path.push(p);
    }
    fs::read_to_string(path).ok()
}

pub(super) fn urlencoding(s: &str) -> String {
    let mut out = String::new();
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grok_billing_percent_and_on_demand() {
        let json = r#"{"config":{"creditUsagePercent":42.4,"currentPeriod":{"end":"2026-07-22T00:00:00Z"},"onDemandCap":{"val":20},"onDemandUsed":{"val":5}}}"#;
        let info = parse_grok_billing(json).unwrap();
        assert_eq!(info.weekly.percent, 42);
        assert_eq!(info.weekly.resets_at_ms, Some(1_784_678_400_000));
        assert_eq!(info.on_demand.unwrap().percent, 25);
    }

    #[test]
    fn grok_missing_percent_is_zero_when_period_present() {
        let json = r#"{"config":{"currentPeriod":{"end":"2026-07-22T00:00:00Z"}}}"#;
        let info = parse_grok_billing(json).unwrap();
        assert_eq!(info.weekly.percent, 0);
        assert!(info.on_demand.is_none());
    }

    #[test]
    fn claude_session_and_weekly() {
        let json = r#"{"limits":[{"kind":"session","percent":22,"resets_at":"2026-08-18T12:00:00Z","severity":"normal"},{"kind":"weekly_all","percent":40,"severity":"warning"}]}"#;
        let info = parse_claude_usage(json).unwrap();
        assert_eq!(info.five_hour.percent, 22);
        assert_eq!(info.five_hour.resets_at_ms, Some(1_787_054_400_000));
        assert_eq!(info.weekly.percent, 40);
        assert_eq!(info.weekly.severity, Severity::Warning);
    }

    #[test]
    fn claude_model_weekly() {
        let json = r#"{"limits":[{"kind":"session","percent":10},{"group":"weekly","percent":50,"scope":{"model":{"display_name":"Fable"}}}]}"#;
        let info = parse_claude_usage(json).unwrap();
        assert_eq!(info.model_weekly[0].0, "Fable");
        assert_eq!(info.model_weekly[0].1.percent, 50);
    }

    #[test]
    fn cursor_plan_usage_extras() {
        let json = r#"{"billingCycleEnd":1785000000,"planUsage":{"totalPercentUsed":61.2,"autoPercentUsed":12},"spendLimitUsage":{"individualLimit":10,"individualRemaining":7.5}}"#;
        let info = parse_cursor_usage(json).unwrap();
        assert_eq!(info.included.percent, 61);
        assert_eq!(info.included.resets_at_ms, Some(1_785_000_000_000));
        assert_eq!(info.auto.unwrap().percent, 12);
        assert_eq!(info.on_demand.unwrap().percent, 25);
    }

    #[test]
    fn codex_wham_primary_and_secondary() {
        let json = r#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":48,"limit_window_seconds":18000,"reset_at":1785000000},"secondary_window":{"used_percent":19,"limit_window_seconds":604800,"reset_at":1785600000}}}"#;
        let info = parse_codex_wham(json).unwrap();
        assert_eq!(info.primary.percent, 48);
        assert_eq!(info.primary_label, "5-hour session");
        assert_eq!(info.secondary.unwrap().percent, 19);
        assert_eq!(info.secondary_label.as_deref(), Some("Weekly limit"));
    }

    #[test]
    fn reset_countdown() {
        let now = 1_000_000_000_000;
        assert_eq!(format_reset_in_at(now, now), "now");
        assert_eq!(format_reset_in_at(now + 45_000, now), "<1m");
        assert_eq!(format_reset_in_at(now + 45 * 60_000, now), "45m");
        assert_eq!(
            format_reset_in_at(now + (2 * 60 + 17) * 60_000, now),
            "2h 17m"
        );
        assert_eq!(
            format_reset_in_at(now + (6 * 24 * 60 + 22 * 60) * 60_000, now),
            "6d 22h"
        );
    }

    #[test]
    fn usage_value_omits_resets_in() {
        let now = now_ms();
        let pending = UsageWindow::new(46, Some(now + (6 * 24 * 60 + 22 * 60) * 60_000));
        let text = format_window_value(&pending);
        assert_eq!(text, "46% · 6d 22h");
        assert!(!text.contains("resets in"));

        let due = UsageWindow::new(46, Some(now - 1_000));
        assert_eq!(format_window_value(&due), "46% · resets now");
        assert_eq!(format_window_value(&UsageWindow::new(10, None)), "10%");
    }

    #[test]
    fn claude_profile_plan_and_email() {
        let json = r#"{"account":{"email":"a@b.com","has_claude_max":true},"organization":{"organization_type":"claude_pro"}}"#;
        let (email, plan) = parse_claude_profile(json).unwrap();
        assert_eq!(email.as_deref(), Some("a@b.com"));
        assert_eq!(plan.as_deref(), Some("Pro"));
    }

    #[test]
    fn grok_plan_display_and_tier() {
        assert_eq!(
            parse_grok_plan(r#"{"subscription_tier_display":"SuperGrok"}"#).as_deref(),
            Some("SuperGrok")
        );
        assert_eq!(
            parse_grok_plan(r#"{"subscriptionTier":"GrokPro"}"#).as_deref(),
            Some("SuperGrok")
        );
    }

    #[test]
    fn codex_appserver_rate_limits() {
        let json = r#"{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42.4,"windowDurationMins":300,"resetsAt":1785000000},"secondary":{"usedPercent":12,"windowDurationMins":10080,"resetsAt":1785600000},"planType":"pro"}}}"#;
        let info = parse_codex_wham(json).unwrap();
        assert_eq!(info.primary.percent, 42);
        assert_eq!(info.primary_label, "5-hour session");
        assert_eq!(info.secondary.unwrap().percent, 12);
        assert_eq!(info.plan_name.as_deref(), Some("pro"));
        assert_eq!(
            parse_codex_account(
                r#"{"id":1,"result":{"account":{"email":"dev@openai.com","type":"chatgpt"}}}"#
            ),
            Some(Some("dev@openai.com".into()))
        );
    }

    #[test]
    fn masked_email_keeps_first_chars() {
        assert_eq!(masked_email("pres@example.com"), "p•••@e••••••.com");
        assert_eq!(masked_email("ab@x.io"), "a•••@x••.io");
    }

    #[test]
    fn tray_tip_idle_and_usage_fit() {
        let snap = UsageSnapshot {
            claude: Some(Cached {
                fetched_at_ms: 0,
                info: ClaudeUsage {
                    five_hour: UsageWindow::new(45, Some(1_000_000_000_000 + 2 * 3600 * 1000)),
                    ..Default::default()
                },
            }),
            ..Default::default()
        };
        let idle = tray_tip(
            None,
            "Connected",
            None,
            &UsageSnapshot::default(),
            &[],
            &crate::settings::Settings::default(),
            1_000_000_000_000,
        );
        assert_eq!(idle, "AgentCord — Idle · Connected");
        let one = tray_tip(
            None,
            "Connected",
            None,
            &snap,
            &[AgentKind::Claude],
            &crate::settings::Settings::default(),
            1_000_000_000_000,
        );
        assert!(one.contains("5h 45%"));
        assert!(one.contains("2h 0m"));
        assert!(one.chars().count() <= TRAY_TIP_MAX);
        let session = SessionInfo {
            agent: AgentKind::Claude,
            project: "a-very-long-project-name-that-would-exceed-the-limit-if-not-truncated"
                .into(),
            model: "Opus".into(),
            start_epoch_ms: 1_000_000_000_000,
            activity_ms: 1_000_000_000_000,
            tokens: 12_000,
        };
        let long = tray_tip(
            Some(&session),
            "Connected",
            None,
            &snap,
            &[AgentKind::Claude],
            &crate::settings::Settings::default(),
            1_000_000_000_000,
        );
        assert_eq!(long.chars().count(), TRAY_TIP_MAX);
        assert!(long.ends_with('…'));
    }
}
