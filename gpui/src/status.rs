//! Anthropic public status page (https://status.claude.com).

use crate::session::now_ms;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

const PAGE_URL: &str = "https://status.claude.com";
const ENDPOINT: &str = "https://status.claude.com/api/v2/summary.json";
const MAX_STALE_MS: i64 = 30 * 60 * 1000;

#[derive(Clone, Debug, PartialEq)]
pub struct StatusComponent {
    pub name: String,
    pub status: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StatusIncident {
    pub name: String,
    pub status: String,
    pub impact: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct StatusInfo {
    pub indicator: String,
    pub summary_label: String,
    pub components: Vec<StatusComponent>,
    pub incidents: Vec<StatusIncident>,
    pub fetched_at_ms: i64,
}

impl StatusInfo {
    pub fn page_url() -> &'static str {
        PAGE_URL
    }

    pub fn degraded_count(&self) -> usize {
        self.components
            .iter()
            .filter(|c| c.status != "operational")
            .count()
    }

    pub fn pill_color(&self) -> (u32, u32) {
        match self.indicator.as_str() {
            "none" => (0x34c759, 0x1d8a3a),
            "minor" | "major" => (0xff9500, 0xc2660a),
            "critical" => (0xff3b30, 0xc0271f),
            "maintenance" => (0x007aff, 0x0057b6),
            _ => (0xd5d5d7, 0x6d6d73),
        }
    }

    pub fn footer(&self) -> String {
        let updated = ago(self.fetched_at_ms);
        if self.degraded_count() > 0 {
            format!(
                "{} of {} degraded · updated {updated}",
                self.degraded_count(),
                self.components.len()
            )
        } else {
            format!("All systems operational · updated {updated}")
        }
    }
}

pub fn spawn() -> Arc<Mutex<Option<StatusInfo>>> {
    let snap = Arc::new(Mutex::new(None));
    let shared = snap.clone();
    thread::Builder::new()
        .name("agentcord-status".into())
        .spawn(move || loop {
            match fetch() {
                Some(info) => {
                    if let Ok(mut g) = shared.lock() {
                        *g = Some(info);
                    }
                }
                None => {
                    if let Ok(mut g) = shared.lock() {
                        if g.as_ref()
                            .is_some_and(|s| now_ms().saturating_sub(s.fetched_at_ms) > MAX_STALE_MS)
                        {
                            *g = None;
                        }
                    }
                }
            }
            thread::sleep(Duration::from_secs(300));
        })
        .ok();
    snap
}

fn fetch() -> Option<StatusInfo> {
    let mut req = ureq::get(ENDPOINT);
    req = req.set("Accept", "application/json");
    let body = req.call().ok()?.into_string().ok()?;
    parse_summary(&body)
}

pub fn parse_summary(json: &str) -> Option<StatusInfo> {
    let v: Value = serde_json::from_str(json).ok()?;
    let indicator = v
        .get("status")
        .and_then(|s| s.get("indicator"))
        .and_then(|x| x.as_str())
        .unwrap_or("unknown")
        .to_string();
    let mut components = Vec::new();
    if let Some(arr) = v.get("components").and_then(|c| c.as_array()) {
        for c in arr {
            if c.get("group").and_then(|g| g.as_bool()) == Some(true) {
                continue;
            }
            let Some(name) = c.get("name").and_then(|x| x.as_str()).filter(|s| !s.is_empty()) else {
                continue;
            };
            components.push(StatusComponent {
                name: short_name(name),
                status: c
                    .get("status")
                    .and_then(|x| x.as_str())
                    .unwrap_or("unknown")
                    .to_string(),
            });
        }
    }
    let mut incidents = Vec::new();
    if let Some(arr) = v.get("incidents").and_then(|c| c.as_array()) {
        for i in arr {
            let Some(name) = i.get("name").and_then(|x| x.as_str()).filter(|s| !s.is_empty()) else {
                continue;
            };
            incidents.push(StatusIncident {
                name: name.to_string(),
                status: i
                    .get("status")
                    .and_then(|x| x.as_str())
                    .unwrap_or("investigating")
                    .to_string(),
                impact: i
                    .get("impact")
                    .and_then(|x| x.as_str())
                    .unwrap_or("none")
                    .to_string(),
            });
        }
    }
    Some(StatusInfo {
        summary_label: summary_label(&indicator),
        indicator,
        components,
        incidents,
        fetched_at_ms: now_ms(),
    })
}

fn short_name(name: &str) -> String {
    name.split('(').next().unwrap_or(name).trim().to_string()
}

fn summary_label(indicator: &str) -> String {
    match indicator {
        "none" => "Operational".into(),
        "minor" => "Degraded".into(),
        "major" => "Partial Outage".into(),
        "critical" => "Major Outage".into(),
        "maintenance" => "Maintenance".into(),
        _ => "Unknown".into(),
    }
}

fn ago(ms: i64) -> String {
    let secs = (now_ms().saturating_sub(ms) / 1000).max(0);
    if secs < 60 {
        "just now".into()
    } else if secs < 3600 {
        format!("{}m ago", secs / 60)
    } else if secs < 86400 {
        format!("{}h ago", secs / 3600)
    } else {
        format!("{}d ago", secs / 86400)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_operational_summary() {
        let json = r#"{"status":{"indicator":"none"},"components":[{"name":"Claude API (api.anthropic.com)","status":"operational","group":false},{"name":"Group","status":"operational","group":true}],"incidents":[]}"#;
        let info = parse_summary(json).unwrap();
        assert_eq!(info.summary_label, "Operational");
        assert_eq!(info.components.len(), 1);
        assert_eq!(info.components[0].name, "Claude API");
        assert_eq!(info.degraded_count(), 0);
        assert!(info.footer().contains("All systems operational"));
    }

    #[test]
    fn parses_incident() {
        let json = r#"{"status":{"indicator":"minor"},"components":[],"incidents":[{"name":"Elevated errors","status":"investigating","impact":"minor"}]}"#;
        let info = parse_summary(json).unwrap();
        assert_eq!(info.summary_label, "Degraded");
        assert_eq!(info.incidents[0].name, "Elevated errors");
    }
}
