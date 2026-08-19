//! Claude usage + profile (Anthropic OAuth).

use super::*;
use serde_json::Value;

pub(super) fn fetch(prev: &Option<Cached<ClaudeUsage>>) -> Option<Cached<ClaudeUsage>> {
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
        Some(mut info) => {
            apply_claude_profile(&token, &mut info, prev);
            Some(Cached::fresh(info))
        }
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
        ..Default::default()
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

fn apply_claude_profile(
    token: &str,
    info: &mut ClaudeUsage,
    prev: &Option<Cached<ClaudeUsage>>,
) {
    keep_identity(
        &mut info.email,
        &mut info.plan_name,
        prev.as_ref()
            .map(|p| (p.info.email.clone(), p.info.plan_name.clone())),
    );
    let body = get(
        "https://api.anthropic.com/api/oauth/profile",
        &[
            ("Authorization", &format!("Bearer {token}")),
            ("anthropic-beta", "oauth-2025-04-20"),
            ("anthropic-version", "2023-06-01"),
        ],
    );
    if let Some((email, plan)) = body.as_deref().and_then(parse_claude_profile) {
        if email.is_some() {
            info.email = email;
        }
        if plan.is_some() {
            info.plan_name = plan;
        }
    }
}

pub fn parse_claude_profile(json: &str) -> Option<(Option<String>, Option<String>)> {
    let v: Value = serde_json::from_str(json).ok()?;
    let email = json_str(v.get("account").and_then(|a| a.get("email")))
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let plan = json_str(
        v.get("organization")
            .and_then(|o| o.get("organization_type")),
    )
    .map(claude_plan_label)
    .or_else(|| {
        let account = v.get("account")?;
        if account.get("has_claude_max").and_then(|x| x.as_bool()) == Some(true) {
            Some("Max".into())
        } else if account.get("has_claude_pro").and_then(|x| x.as_bool()) == Some(true) {
            Some("Pro".into())
        } else {
            None
        }
    });
    Some((email, plan))
}

fn claude_plan_label(raw: &str) -> String {
    let stripped = raw.strip_prefix("claude_").unwrap_or(raw).replace('_', " ");
    stripped
        .split_whitespace()
        .map(|w| {
            let mut c = w.chars();
            match c.next() {
                Some(f) => f.to_uppercase().collect::<String>() + c.as_str(),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn claude_token() -> Option<String> {
    let v: Value = serde_json::from_str(&read_home(&[".claude", ".credentials.json"])?).ok()?;
    v.get("claudeAiOauth")
        .and_then(|o| o.get("accessToken"))
        .and_then(|x| x.as_str())
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}

