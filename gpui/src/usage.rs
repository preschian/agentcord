//! Cheap usage polls: Claude / Cursor / Grok HTTP + Codex ChatGPT wham.

use crate::session::AgentKind;
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct UsageBar {
    pub percent: i64,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct UsageSnapshot {
    pub claude: Option<UsageBar>,
    pub codex: Option<UsageBar>,
    pub cursor: Option<UsageBar>,
    pub grok: Option<UsageBar>,
}

impl UsageSnapshot {
    pub fn for_agent(&self, agent: AgentKind) -> Option<UsageBar> {
        match agent {
            AgentKind::Claude => self.claude,
            AgentKind::Codex => self.codex,
            AgentKind::Cursor => self.cursor,
            AgentKind::Grok => self.grok,
        }
    }
}

pub fn spawn() -> Arc<Mutex<UsageSnapshot>> {
    let snap = Arc::new(Mutex::new(UsageSnapshot::default()));
    let shared = snap.clone();
    thread::Builder::new()
        .name("agentcord-usage".into())
        .spawn(move || loop {
            let next = fetch_all();
            if let Ok(mut g) = shared.lock() {
                *g = next;
            }
            thread::sleep(Duration::from_secs(300));
        })
        .ok();
    snap
}

fn fetch_all() -> UsageSnapshot {
    UsageSnapshot {
        claude: fetch_claude(),
        codex: fetch_codex(),
        cursor: fetch_cursor(),
        grok: fetch_grok(),
    }
}

fn fetch_claude() -> Option<UsageBar> {
    let token = claude_token()?;
    let body = get(
        "https://api.anthropic.com/api/oauth/usage",
        &[
            ("Authorization", &format!("Bearer {token}")),
            ("anthropic-beta", "oauth-2025-04-20"),
            ("anthropic-version", "2023-06-01"),
        ],
    )?;
    parse_claude_usage(&body)
}

fn fetch_cursor() -> Option<UsageBar> {
    let token = cursor_token()?;
    let auth = format!("Bearer {token}");
    let body = post_json(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
        "{}",
        &[
            ("Authorization", auth.as_str()),
            ("Connect-Protocol-Version", "1"),
            ("User-Agent", "AgentCord"),
        ],
    )
    .or_else(|| {
        get(
            "https://api2.cursor.sh/auth/usage",
            &[("Authorization", auth.as_str()), ("User-Agent", "AgentCord")],
        )
    })?;
    parse_cursor_usage(&body)
}

fn fetch_grok() -> Option<UsageBar> {
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
            let access = grok_refresh(&auth)?;
            let bearer = format!("Bearer {access}");
            get(
                "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
                &[
                    ("Authorization", bearer.as_str()),
                    ("Accept", "application/json"),
                    ("X-XAI-Token-Auth", "xai-grok-cli"),
                    ("User-Agent", "GrokCLI"),
                ],
            )?
        }
        Some((200, body)) => body,
        _ => return None,
    };
    parse_grok_billing(&body)
}

fn fetch_codex() -> Option<UsageBar> {
    let auth = codex_auth()?;
    let bearer = format!("Bearer {}", auth.access);
    let mut headers: Vec<(&str, &str)> = vec![
        ("Authorization", bearer.as_str()),
        ("Accept", "application/json"),
    ];
    if !auth.account_id.is_empty() {
        headers.push(("ChatGPT-Account-ID", auth.account_id.as_str()));
    }
    let body = get("https://chatgpt.com/backend-api/wham/usage", &headers)?;
    parse_codex_wham(&body)
}

pub fn parse_claude_usage(json: &str) -> Option<UsageBar> {
    let v: Value = serde_json::from_str(json).ok()?;
    if let Some(limits) = v.get("limits").and_then(|l| l.as_array()) {
        for limit in limits {
            let kind = limit.get("kind").and_then(|x| x.as_str()).unwrap_or("");
            let group = limit.get("group").and_then(|x| x.as_str()).unwrap_or("");
            if kind == "session" || group == "session" {
                if let Some(p) = json_num(limit.get("percent")) {
                    return Some(UsageBar {
                        percent: clamp_pct(p),
                    });
                }
            }
        }
    }
    let p = json_num(v.get("five_hour").and_then(|x| x.get("utilization")))?;
    Some(UsageBar {
        percent: clamp_pct(p),
    })
}

pub fn parse_cursor_usage(json: &str) -> Option<UsageBar> {
    let v: Value = serde_json::from_str(json).ok()?;
    if let Some(plan) = v.get("planUsage") {
        if let Some(p) = json_num(plan.get("totalPercentUsed")) {
            return Some(UsageBar {
                percent: clamp_pct(p),
            });
        }
        if let Some(limit) = json_num(plan.get("limit")).filter(|n| *n > 0.0) {
            let used = json_num(plan.get("includedSpend")).or_else(|| json_num(plan.get("totalSpend")))?;
            return Some(UsageBar {
                percent: clamp_pct(used / limit * 100.0),
            });
        }
    }
    let mut best: Option<(f64, f64)> = None;
    if let Some(obj) = v.as_object() {
        for (k, val) in obj {
            if k == "startOfMonth" || !val.is_object() {
                continue;
            }
            let max = json_num(val.get("maxRequestUsage")).filter(|n| *n > 0.0);
            let Some(max) = max else { continue };
            let used = json_num(val.get("numRequests")).unwrap_or(0.0);
            if best.is_none_or(|(_, m)| max > m) {
                best = Some((used, max));
            }
        }
    }
    let (used, max) = best?;
    Some(UsageBar {
        percent: clamp_pct(used * 100.0 / max),
    })
}

pub fn parse_grok_billing(json: &str) -> Option<UsageBar> {
    let v: Value = serde_json::from_str(json).ok()?;
    let config = v.get("config");
    let has_period = config
        .and_then(|c| c.get("currentPeriod"))
        .is_some()
        || v.get("billingPeriodEnd").is_some()
        || config.and_then(|c| c.get("billingPeriodEnd")).is_some();
    let percent = json_num(config.and_then(|c| c.get("creditUsagePercent")))
        .or_else(|| json_num(v.get("creditUsagePercent")))
        .or_else(|| if has_period { Some(0.0) } else { None })?;
    Some(UsageBar {
        percent: clamp_pct(percent),
    })
}

pub fn parse_codex_wham(json: &str) -> Option<UsageBar> {
    let v: Value = serde_json::from_str(json).ok()?;
    let rate = v
        .get("rate_limit")
        .or_else(|| v.get("rateLimits"))
        .unwrap_or(&v);
    let primary = rate
        .get("primary_window")
        .or_else(|| rate.get("primary"))?;
    let p = json_num(primary.get("used_percent")).or_else(|| json_num(primary.get("usedPercent")))?;
    Some(UsageBar {
        percent: clamp_pct(p),
    })
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
    let resp = req.send_string(json).ok()?;
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
    let mut path = PathBuf::from(std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?);
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
    fn grok_billing_percent() {
        let json = r#"{"config":{"creditUsagePercent":42.4,"currentPeriod":{"end":"2026-07-22T00:00:00Z"}}}"#;
        assert_eq!(parse_grok_billing(json).unwrap().percent, 42);
    }

    #[test]
    fn grok_missing_percent_is_zero_when_period_present() {
        let json = r#"{"config":{"currentPeriod":{"end":"2026-07-22T00:00:00Z"}}}"#;
        assert_eq!(parse_grok_billing(json).unwrap().percent, 0);
    }

    #[test]
    fn claude_session_limit() {
        let json = r#"{"limits":[{"kind":"session","percent":22}]}"#;
        assert_eq!(parse_claude_usage(json).unwrap().percent, 22);
    }

    #[test]
    fn cursor_plan_usage() {
        let json = r#"{"planUsage":{"totalPercentUsed":61.2}}"#;
        assert_eq!(parse_cursor_usage(json).unwrap().percent, 61);
    }

    #[test]
    fn codex_wham_primary() {
        let json = r#"{"rate_limit":{"primary_window":{"used_percent":17}}}"#;
        assert_eq!(parse_codex_wham(json).unwrap().percent, 17);
    }
}
