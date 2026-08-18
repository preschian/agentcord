//! Cheap usage polls: Claude / Cursor / Grok HTTP + Codex ChatGPT wham.

use crate::session::{now_ms, parse_iso_ms, AgentKind};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const MAX_STALE_MS: i64 = 24 * 60 * 60 * 1000;

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
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CursorUsage {
    pub included: UsageWindow,
    pub auto: Option<UsageWindow>,
    pub api: Option<UsageWindow>,
    pub on_demand: Option<UsageWindow>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct GrokUsage {
    pub weekly: UsageWindow,
    pub on_demand: Option<UsageWindow>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CodexUsage {
    pub primary: UsageWindow,
    pub primary_label: String,
    pub secondary: Option<UsageWindow>,
    pub secondary_label: Option<String>,
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

pub fn format_window_value(window: &UsageWindow) -> String {
    match window.resets_at_ms {
        Some(ms) => {
            let left = format_reset_in_at(ms, now_ms());
            if left == "now" {
                format!("{}% · resets now", window.percent)
            } else {
                format!("{}% · resets in {left}", window.percent)
            }
        }
        None => format!("{}%", window.percent),
    }
}

fn fetch_all(prev: &UsageSnapshot) -> UsageSnapshot {
    UsageSnapshot {
        claude: fetch_claude(&prev.claude),
        codex: fetch_codex(&prev.codex),
        cursor: fetch_cursor(&prev.cursor),
        grok: fetch_grok(&prev.grok),
    }
}

fn keep_stale<T: Clone>(prev: &Option<Cached<T>>) -> Option<Cached<T>> {
    prev.clone()
        .filter(|c| now_ms().saturating_sub(c.fetched_at_ms) <= MAX_STALE_MS)
}

fn fetch_claude(prev: &Option<Cached<ClaudeUsage>>) -> Option<Cached<ClaudeUsage>> {
    let token = claude_token()?;
    let body = get(
        "https://api.anthropic.com/api/oauth/usage",
        &[
            ("Authorization", &format!("Bearer {token}")),
            ("anthropic-beta", "oauth-2025-04-20"),
            ("anthropic-version", "2023-06-01"),
        ],
    );
    match body.and_then(|b| parse_claude_usage(&b)) {
        Some(info) => Some(Cached::fresh(info)),
        None => keep_stale(prev),
    }
}

fn fetch_cursor(prev: &Option<Cached<CursorUsage>>) -> Option<Cached<CursorUsage>> {
    let token = cursor_token()?;
    let auth = format!("Bearer {token}");
    let body = post_json(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        "{}",
        &[
            ("Authorization", auth.as_str()),
            ("Content-Type", "application/json"),
            ("Connect-Protocol-Version", "1"),
            ("User-Agent", "AgentCord"),
        ],
    )
    .or_else(|| {
        get(
            "https://api2.cursor.sh/auth/usage",
            &[
                ("Authorization", auth.as_str()),
                ("User-Agent", "AgentCord"),
            ],
        )
    });
    match body.and_then(|b| parse_cursor_usage(&b)) {
        Some(info) => Some(Cached::fresh(info)),
        None => keep_stale(prev),
    }
}

fn fetch_grok(prev: &Option<Cached<GrokUsage>>) -> Option<Cached<GrokUsage>> {
    let auth = grok_auth()?;
    let bearer = format!("Bearer {}", auth.access);
    let mut headers: Vec<(&str, &str)> = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
        ("X-XAI-Token-Auth", "xai-grok-cli"),
        ("User-Agent", "GrokCLI"),
    ];
    if !auth.user_id.is_empty() {
        headers.push(("x-userid", auth.user_id.as_str()));
    }
    let body = match get_status(
        "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
        &headers,
    ) {
        Some((401, _)) if !auth.refresh.is_empty() && !auth.client_id.is_empty() => {
            grok_refresh(&auth).and_then(|access| {
                let bearer = format!("Bearer {access}");
                get(
                    "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                    &[
                        ("Authorization", bearer.as_str()),
                        ("Accept", "application/json"),
                        ("X-XAI-Token-Auth", "xai-grok-cli"),
                        ("User-Agent", "GrokCLI"),
                    ],
                )
            })
        }
        Some((200, body)) => Some(body),
        _ => None,
    };
    match body.and_then(|b| parse_grok_billing(&b)) {
        Some(info) => Some(Cached::fresh(info)),
        None => keep_stale(prev),
    }
}

fn fetch_codex(prev: &Option<Cached<CodexUsage>>) -> Option<Cached<CodexUsage>> {
    let auth = codex_auth()?;
    let bearer = format!("Bearer {}", auth.access);
    let mut headers: Vec<(&str, &str)> = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
    ];
    if !auth.account_id.is_empty() {
        headers.push(("ChatGPT-Account-ID", auth.account_id.as_str()));
    }
    let body = get("https://chatgpt.com/backend-api/wham/usage", &headers);
    match body.and_then(|b| parse_codex_wham(&b)) {
        Some(info) => Some(Cached::fresh(info)),
        None => keep_stale(prev),
    }
}

pub fn parse_claude_usage(json: &str) -> Option<ClaudeUsage> {
    let v: Value = serde_json::from_str(json).ok()?;
    let mut session = None;
    let mut weekly = None;
    let mut model_weekly = Vec::new();
    if let Some(limits) = v.get("limits").and_then(|l| l.as_array()) {
        for limit in limits {
            let kind = limit.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            let group = limit.get("group").and_then(|x| x.as_str()).unwrap_or("");
            let scope = limit.get("scope").filter(|s| s.is_object());
            if session.is_none() && (kind == "session" || group == "session") {
                session = Some(limit);
            }
            if weekly.is_none() && (kind == "weekly_all" || (group == "weekly" && scope.is_none()))
            {
                weekly = Some(limit);
            }
            if group == "weekly" {
                if let Some(name) = scope
                    .and_then(|s| s.get("model"))
                    .and_then(|m| m.get("display_name"))
                    .and_then(|x| x.as_str())
                    .filter(|s| !s.is_empty())
                {
                    model_weekly.push((name.to_string(), claude_window(Some(limit), None)));
                }
            }
        }
    }
    let five_hour = v.get("five_hour").filter(|x| x.is_object());
    let seven_day = v.get("seven_day").filter(|x| x.is_object());
    if session.is_none() && five_hour.is_none() && weekly.is_none() && seven_day.is_none() {
        return None;
    }
    Some(ClaudeUsage {
        five_hour: claude_window(session, five_hour),
        weekly: claude_window(weekly, seven_day),
        model_weekly,
    })
}

fn claude_window(limit: Option<&Value>, fallback: Option<&Value>) -> UsageWindow {
    let percent = json_num(limit.and_then(|l| l.get("percent")))
        .or_else(|| json_num(fallback.and_then(|f| f.get("utilization"))))
        .unwrap_or(0.0);
    let resets = json_str(limit.and_then(|l| l.get("resets_at")))
        .or_else(|| json_str(fallback.and_then(|f| f.get("resets_at"))))
        .and_then(parse_iso_ms);
    let severity = json_str(limit.and_then(|l| l.get("severity")))
        .map(Severity::from_api)
        .unwrap_or_else(|| Severity::from_percent(clamp_pct(percent)));
    UsageWindow {
        percent: clamp_pct(percent),
        resets_at_ms: resets,
        severity,
    }
}

pub fn parse_cursor_usage(json: &str) -> Option<CursorUsage> {
    let v: Value = serde_json::from_str(json).ok()?;
    if let Some(plan) = v.get("planUsage") {
        let total = json_num(plan.get("totalPercentUsed")).or_else(|| {
            let limit = json_num(plan.get("limit")).filter(|n| *n > 0.0)?;
            let used =
                json_num(plan.get("includedSpend")).or_else(|| json_num(plan.get("totalSpend")))?;
            Some(used / limit * 100.0)
        })?;
        let total_pct = clamp_pct(total);
        let resets = json_epoch_ms(v.get("billingCycleEnd"));
        let extra = |key: &str| {
            json_num(plan.get(key)).and_then(|p| {
                let pct = clamp_pct(p);
                (p > 0.0 && pct != total_pct).then_some(UsageWindow::new(pct, resets))
            })
        };
        let on_demand = v.get("spendLimitUsage").and_then(|spend| {
            let lim = json_num(spend.get("individualLimit")).filter(|n| *n > 0.0)?;
            let remaining = json_num(spend.get("individualRemaining")).unwrap_or(lim);
            Some(UsageWindow::new(
                clamp_pct((lim - remaining).max(0.0) / lim * 100.0),
                resets,
            ))
        });
        return Some(CursorUsage {
            included: UsageWindow::new(total_pct, resets),
            auto: extra("autoPercentUsed"),
            api: extra("apiPercentUsed"),
            on_demand,
        });
    }
    let mut best: Option<(f64, f64)> = None;
    let mut start_of_month = None;
    if let Some(obj) = v.as_object() {
        for (k, val) in obj {
            if k == "startOfMonth" {
                start_of_month = val.as_str();
                continue;
            }
            if !val.is_object() {
                continue;
            }
            let Some(max) = json_num(val.get("maxRequestUsage")).filter(|n| *n > 0.0) else {
                continue;
            };
            let used = json_num(val.get("numRequests")).unwrap_or(0.0);
            if best.is_none_or(|(_, m)| max > m) {
                best = Some((used, max));
            }
        }
    }
    let (used, max) = best?;
    let resets = start_of_month.and_then(parse_iso_ms).map(|ms| {
        // Legacy field is startOfMonth; quota resets at the next month boundary.
        ms + 30 * 24 * 60 * 60 * 1000
    });
    Some(CursorUsage {
        included: UsageWindow::new(clamp_pct(used * 100.0 / max), resets),
        auto: None,
        api: None,
        on_demand: None,
    })
}

pub fn parse_grok_billing(json: &str) -> Option<GrokUsage> {
    let v: Value = serde_json::from_str(json).ok()?;
    let config = v.get("config");
    let period_end = json_str(
        config
            .and_then(|c| c.get("currentPeriod"))
            .and_then(|p| p.get("end")),
    )
    .or_else(|| json_str(config.and_then(|c| c.get("billingPeriodEnd"))))
    .or_else(|| json_str(v.get("billingPeriodEnd")));
    let has_period = period_end.is_some();
    let percent = json_num(config.and_then(|c| c.get("creditUsagePercent")))
        .or_else(|| json_num(v.get("creditUsagePercent")))
        .or_else(|| if has_period { Some(0.0) } else { None })?;
    let resets = period_end.and_then(parse_iso_ms);
    let on_demand = config.and_then(|c| {
        let cap = money_val(c.get("onDemandCap")).filter(|n| *n > 0.0)?;
        let used = money_val(c.get("onDemandUsed")).unwrap_or(0.0);
        Some(UsageWindow::new(clamp_pct(used / cap * 100.0), resets))
    });
    Some(GrokUsage {
        weekly: UsageWindow::new(clamp_pct(percent), resets),
        on_demand,
    })
}

pub fn parse_codex_wham(json: &str) -> Option<CodexUsage> {
    let v: Value = serde_json::from_str(json).ok()?;
    let rate = v
        .get("rate_limit")
        .or_else(|| v.get("rateLimits"))
        .unwrap_or(&v);
    let primary = rate.get("primary_window").or_else(|| rate.get("primary"))?;
    let primary_window = codex_window(primary)?;
    let secondary = rate
        .get("secondary_window")
        .or_else(|| rate.get("secondary"))
        .and_then(codex_window);
    Some(CodexUsage {
        primary_label: window_label(primary, "Primary limit"),
        primary: primary_window,
        secondary_label: secondary.is_some().then(|| {
            window_label(
                rate.get("secondary_window")
                    .or_else(|| rate.get("secondary"))
                    .unwrap_or(primary),
                "Secondary limit",
            )
        }),
        secondary,
    })
}

fn codex_window(v: &Value) -> Option<UsageWindow> {
    let p = json_num(v.get("used_percent")).or_else(|| json_num(v.get("usedPercent")))?;
    let percent = clamp_pct(p);
    let resets = json_num(v.get("reset_at"))
        .or_else(|| json_num(v.get("resetsAt")))
        .map(epoch_to_ms);
    Some(UsageWindow {
        percent,
        resets_at_ms: resets,
        severity: Severity::from_percent(percent),
    })
}

fn window_label(v: &Value, fallback: &str) -> String {
    let minutes = json_num(v.get("windowDurationMins"))
        .or_else(|| json_num(v.get("limit_window_seconds")).map(|s| s / 60.0))
        .map(|n| n as i64)
        .unwrap_or(0);
    if minutes <= 0 {
        fallback.into()
    } else if minutes <= 6 * 60 {
        "5-hour session".into()
    } else if minutes <= 8 * 24 * 60 {
        "Weekly limit".into()
    } else if minutes <= 40 * 24 * 60 {
        "Monthly limit".into()
    } else {
        fallback.into()
    }
}

fn load_cache() -> UsageSnapshot {
    let Some(path) = cache_path() else {
        return UsageSnapshot::default();
    };
    fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_cache(snap: &UsageSnapshot) {
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

fn cache_path() -> Option<PathBuf> {
    let base = std::env::var_os("APPDATA").map(PathBuf::from)?;
    Some(base.join("AgentCord").join("gpui-usage-cache.json"))
}

fn clamp_pct(v: f64) -> i64 {
    if !v.is_finite() {
        return 0;
    }
    v.round().clamp(0.0, 100.0) as i64
}

fn json_num(v: Option<&Value>) -> Option<f64> {
    v.and_then(|x| x.as_f64().or_else(|| x.as_i64().map(|n| n as f64)))
}

fn json_str(v: Option<&Value>) -> Option<&str> {
    v.and_then(|x| x.as_str())
}

fn json_epoch_ms(v: Option<&Value>) -> Option<i64> {
    match v? {
        Value::Number(n) => n.as_f64().map(epoch_to_ms),
        Value::String(s) => s.parse::<f64>().ok().map(epoch_to_ms),
        _ => None,
    }
}

fn money_val(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::Number(_) => json_num(v),
        Value::Object(o) => json_num(o.get("val")),
        _ => None,
    }
}

fn epoch_to_ms(n: f64) -> i64 {
    if n > 1_000_000_000_000.0 {
        n as i64
    } else {
        (n * 1000.0) as i64
    }
}

fn format_reset_in_at(resets_at_ms: i64, now: i64) -> String {
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

fn get(url: &str, headers: &[(&str, &str)]) -> Option<String> {
    match get_status(url, headers) {
        Some((200, body)) => Some(body),
        _ => None,
    }
}

fn get_status(url: &str, headers: &[(&str, &str)]) -> Option<(u16, String)> {
    let mut req = ureq::get(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let resp = req.call().ok()?;
    let status = resp.status();
    let body = resp.into_string().ok()?;
    Some((status, body))
}

fn post_json(url: &str, json: &str, headers: &[(&str, &str)]) -> Option<String> {
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

fn claude_token() -> Option<String> {
    let v: Value = serde_json::from_str(&read_home(&[".claude", ".credentials.json"])?).ok()?;
    v.get("claudeAiOauth")
        .and_then(|o| o.get("accessToken"))
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

fn cursor_token() -> Option<String> {
    let appdata = std::env::var_os("APPDATA").map(PathBuf::from)?;
    let path = appdata.join("Cursor").join("auth.json");
    let v: Value = serde_json::from_str(&fs::read_to_string(path).ok()?).ok()?;
    v.get("accessToken")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

struct GrokAuth {
    access: String,
    refresh: String,
    client_id: String,
    issuer: String,
    user_id: String,
}

fn grok_auth() -> Option<GrokAuth> {
    let v: Value = serde_json::from_str(&read_home(&[".grok", "auth.json"])?).ok()?;
    let obj = v.as_object()?;
    for val in obj.values() {
        if !val.is_object() {
            continue;
        }
        let access = val
            .get("key")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        let refresh = val
            .get("refresh_token")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string();
        if access.is_empty() && refresh.is_empty() {
            continue;
        }
        return Some(GrokAuth {
            access,
            refresh,
            client_id: val
                .get("oidc_client_id")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
            issuer: val
                .get("oidc_issuer")
                .and_then(|x| x.as_str())
                .unwrap_or("https://auth.x.ai")
                .to_string(),
            user_id: val
                .get("user_id")
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string(),
        });
    }
    None
}

fn grok_refresh(auth: &GrokAuth) -> Option<String> {
    let issuer = auth.issuer.trim_end_matches('/');
    let url = format!("{issuer}/oauth2/token");
    let body = format!(
        "grant_type=refresh_token&refresh_token={}&client_id={}",
        urlencoding(&auth.refresh),
        urlencoding(&auth.client_id)
    );
    let resp = ureq::post(&url)
        .set("Content-Type", "application/x-www-form-urlencoded")
        .send_string(&body)
        .ok()?;
    let text = resp.into_string().ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("access_token")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

struct CodexAuth {
    access: String,
    account_id: String,
}

fn codex_auth() -> Option<CodexAuth> {
    let home = std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .filter(|p| !p.as_os_str().is_empty())
        .or_else(|| {
            std::env::var_os("USERPROFILE")
                .or_else(|| std::env::var_os("HOME"))
                .map(|h| PathBuf::from(h).join(".codex"))
        })?;
    let v: Value = serde_json::from_str(&fs::read_to_string(home.join("auth.json")).ok()?).ok()?;
    let access = v
        .get("access_token")
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())?
        .to_string();
    Some(CodexAuth {
        access,
        account_id: v
            .get("account_id")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
    })
}

fn read_home(parts: &[&str]) -> Option<String> {
    let mut path =
        PathBuf::from(std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?);
    for p in parts {
        path.push(p);
    }
    fs::read_to_string(path).ok()
}

fn urlencoding(s: &str) -> String {
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
}
