//! Grok / SuperGrok billing.

use super::*;
use serde_json::Value;

pub(super) fn fetch(prev: &Option<Cached<GrokUsage>>) -> Option<Cached<GrokUsage>> {
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
        Some(mut info) => {
            info.email = auth.email.clone().filter(|s| !s.is_empty());
            info.plan_name = grok_plan(&auth).or_else(|| {
                prev.as_ref()
                    .and_then(|p| p.info.plan_name.clone())
            });
            if info.email.is_none() {
                info.email = prev.as_ref().and_then(|p| p.info.email.clone());
            }
            Some(Cached::fresh(info))
        }
        None => keep_stale(prev),
    }
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
        ..Default::default()
    })
}

fn grok_plan(auth: &GrokAuth) -> Option<String> {
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
    let body = get("https://cli-chat-proxy.grok.com/v1/settings", &headers).or_else(|| {
        get(
            "https://cli-chat-proxy.grok.com/v1/user?include=subscription",
            &headers,
        )
    })?;
    parse_grok_plan(&body)
}

pub fn parse_grok_plan(json: &str) -> Option<String> {
    let v: Value = serde_json::from_str(json).ok()?;
    if let Some(display) = json_str(v.get("subscription_tier_display")).filter(|s| !s.is_empty()) {
        return Some(display.trim().to_string());
    }
    json_str(v.get("subscriptionTier")).map(map_grok_tier)
}

fn map_grok_tier(raw: &str) -> String {
    match raw.trim() {
        "SuperGrokPro" | "SuperGrokHeavy" | "GrokHeavy" => "SuperGrok Heavy".into(),
        "GrokPro" | "SuperGrok" => "SuperGrok".into(),
        "Free" | "GrokFree" => "Free".into(),
        other => other.to_string(),
    }
}

struct GrokAuth {
    access: String,
    refresh: String,
    client_id: String,
    issuer: String,
    user_id: String,
    email: Option<String>,
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
            email: json_str(val.get("email"))
                .filter(|s| !s.is_empty())
                .map(str::to_string),
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

