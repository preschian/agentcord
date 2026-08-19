//! Cursor usage + profile.

use super::*;
use serde_json::Value;
use std::path::PathBuf;

pub(super) fn fetch(prev: &Option<Cached<CursorUsage>>) -> Option<Cached<CursorUsage>> {
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
        Some(mut info) => {
            apply_cursor_profile(&auth, &mut info, prev);
            Some(Cached::fresh(info))
        }
        None => keep_stale(prev),
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
            ..Default::default()
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
        ..Default::default()
    })
}

fn apply_cursor_profile(
    auth: &str,
    info: &mut CursorUsage,
    prev: &Option<Cached<CursorUsage>>,
) {
    keep_identity(
        &mut info.email,
        &mut info.plan_name,
        prev.as_ref()
            .map(|p| (p.info.email.clone(), p.info.plan_name.clone())),
    );
    if let Some(body) = post_json(
        "https://api2.cursor.sh/aiserver.v1.AuthService/GetEmail",
        "{}",
        &[
            ("Authorization", auth),
            ("Content-Type", "application/json"),
            ("Connect-Protocol-Version", "1"),
            ("User-Agent", "AgentCord"),
        ],
    ) {
        if let Some(email) = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|v| json_str(v.get("email")).map(str::to_string))
            .filter(|s| !s.is_empty())
        {
            info.email = Some(email);
        }
    }
    if let Some(body) = get(
        "https://api2.cursor.sh/auth/full_stripe_profile",
        &[("Authorization", auth), ("User-Agent", "AgentCord")],
    ) {
        if let Some(plan) = serde_json::from_str::<Value>(&body)
            .ok()
            .and_then(|v| json_str(v.get("membershipType")).map(str::to_string))
            .filter(|s| !s.is_empty())
        {
            info.plan_name = Some(plan);
        }
    }
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

