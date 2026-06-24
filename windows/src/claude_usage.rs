//! Polls the user's Claude subscription usage limits — the rolling 5-hour
//! "session" quota and the weekly quota shown by Claude Code's `/usage`.
//! Port of `AgentCord/ClaudeUsage.swift`.
//!
//! These numbers are not in the local transcripts; they come from an
//! undocumented OAuth endpoint that Claude Code itself calls. We reuse Claude
//! Code's own access token and hit the same endpoint. Two differences from
//! macOS, both forced by the platform:
//!
//!   * The token lives in the macOS keychain there; on Windows Claude Code
//!     stores it in `%USERPROFILE%\.claude\.credentials.json`, so we read that.
//!   * Rather than an HTTPS client crate (and its TLS stack), we shell out to
//!     the `curl.exe` bundled with Windows — consistent with how we already
//!     call `git`/`reg`.
//!
//! Everything is best-effort: any failure (no token, expired token, endpoint
//! changed, offline) yields `None` and the popover shows a dash.

use std::time::Duration;

use serde::Deserialize;

use crate::models::{UsageInfo, UsageWindow};
use crate::util;

const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";

/// Fetch the current usage, or `None` on any failure.
pub fn fetch() -> Option<UsageInfo> {
    let token = read_access_token()?;
    let output = util::command("curl")
        .args(["-s", "--max-time", "15"])
        .arg("-H")
        .arg(format!("Authorization: Bearer {token}"))
        .args([
            "-H",
            "anthropic-beta: oauth-2025-04-20",
            "-H",
            "anthropic-version: 2023-06-01",
            "-H",
            "Content-Type: application/json",
            ENDPOINT,
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }
    let resp: UsageResponse = serde_json::from_slice(&output.stdout).ok()?;
    Some(resp.into_usage_info())
}

/// Reads Claude Code's OAuth access token from
/// `%USERPROFILE%\.claude\.credentials.json`.
fn read_access_token() -> Option<String> {
    let path = crate::claude_session::home_dir()
        .join(".claude")
        .join(".credentials.json");
    let contents = std::fs::read_to_string(path).ok()?;
    let creds: CredentialsFile = serde_json::from_str(&contents).ok()?;
    let token = creds.claude_ai_oauth?.access_token;
    (!token.is_empty()).then_some(token)
}

#[derive(Deserialize)]
struct CredentialsFile {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<OAuthCredentials>,
}

#[derive(Deserialize)]
struct OAuthCredentials {
    #[serde(rename = "accessToken")]
    access_token: String,
}

/// The poll interval the macOS app uses (the numbers move slowly and the
/// endpoint rate-limits aggressively).
pub const POLL_INTERVAL: Duration = Duration::from_secs(300);

// MARK: - Wire format

/// The subset of the `/api/oauth/usage` response we care about. Every field is
/// optional so decoding never throws on a missing or renamed key.
#[derive(Deserialize)]
struct UsageResponse {
    five_hour: Option<RespWindow>,
    seven_day: Option<RespWindow>,
    limits: Option<Vec<RespLimit>>,
}

#[derive(Deserialize)]
struct RespWindow {
    utilization: Option<f64>,
    resets_at: Option<String>,
}

#[derive(Deserialize)]
struct RespLimit {
    kind: Option<String>,
    group: Option<String>,
    percent: Option<f64>,
    severity: Option<String>,
    resets_at: Option<String>,
}

impl UsageResponse {
    fn into_usage_info(self) -> UsageInfo {
        let limits = self.limits.unwrap_or_default();
        // Prefer the structured `limits` array (it carries severity); fall back
        // to the flat top-level windows for the raw percentage and reset time.
        let session = limits
            .iter()
            .find(|l| l.kind.as_deref() == Some("session") || l.group.as_deref() == Some("session"));
        let weekly = limits
            .iter()
            .find(|l| l.kind.as_deref() == Some("weekly_all"))
            .or_else(|| limits.iter().find(|l| l.group.as_deref() == Some("weekly")));

        UsageInfo {
            five_hour: UsageWindow {
                percent: percent(session.and_then(|l| l.percent), self.five_hour.as_ref().and_then(|w| w.utilization)),
                severity: session.and_then(|l| l.severity.clone()).unwrap_or_else(|| "normal".to_string()),
                resets_at_ms: parse_date(
                    session
                        .and_then(|l| l.resets_at.as_deref())
                        .or_else(|| self.five_hour.as_ref().and_then(|w| w.resets_at.as_deref())),
                ),
            },
            weekly: UsageWindow {
                percent: percent(weekly.and_then(|l| l.percent), self.seven_day.as_ref().and_then(|w| w.utilization)),
                severity: weekly.and_then(|l| l.severity.clone()).unwrap_or_else(|| "normal".to_string()),
                resets_at_ms: parse_date(
                    weekly
                        .and_then(|l| l.resets_at.as_deref())
                        .or_else(|| self.seven_day.as_ref().and_then(|w| w.resets_at.as_deref())),
                ),
            },
        }
    }
}

fn percent(primary: Option<f64>, fallback: Option<f64>) -> u32 {
    primary.or(fallback).unwrap_or(0.0).round().max(0.0) as u32
}

/// Parse timestamps like "2026-06-26T04:59:59.083560+00:00" to epoch ms.
fn parse_date(s: Option<&str>) -> Option<i64> {
    let s = s.filter(|x| !x.is_empty())?;
    crate::claude_session::epoch_ms_from_iso(s)
}
