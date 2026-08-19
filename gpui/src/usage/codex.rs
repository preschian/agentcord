//! Codex usage: app-server first, ChatGPT wham fallback.

use super::*;
use serde_json::Value;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::Instant;

pub(super) fn fetch(prev: &Option<Cached<CodexUsage>>) -> Option<Cached<CodexUsage>> {
    if let Some(mut info) = fetch_codex_appserver() {
        keep_identity(
            &mut info.email,
            &mut info.plan_name,
            prev.as_ref().map(|p| (p.info.email.clone(), p.info.plan_name.clone())),
        );
        return Some(Cached::fresh(info));
    }
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
        Some(mut info) => {
            keep_identity(
                &mut info.email,
                &mut info.plan_name,
                prev.as_ref().map(|p| (p.info.email.clone(), p.info.plan_name.clone())),
            );
            Some(Cached::fresh(info))
        }
        None => keep_stale(prev),
    }
}

pub fn parse_codex_wham(json: &str) -> Option<CodexUsage> {
    let root: Value = serde_json::from_str(json).ok()?;
    let v = root.get("result").unwrap_or(&root);
    let rate = v
        .get("rate_limit")
        .or_else(|| v.get("rateLimits"))
        .unwrap_or(v);
    let primary = rate.get("primary_window").or_else(|| rate.get("primary"))?;
    let primary_window = codex_window(primary)?;
    let secondary = rate
        .get("secondary_window")
        .or_else(|| rate.get("secondary"))
        .and_then(codex_window);
    let plan_name = json_str(root.get("plan_type"))
        .or_else(|| json_str(v.get("plan_type")))
        .or_else(|| json_str(rate.get("planType")))
        .map(str::to_string);
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
        plan_name,
        ..Default::default()
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

fn fetch_codex_appserver() -> Option<CodexUsage> {
    let exe = codex_exe()?;
    let mut cmd = Command::new(exe);
    cmd.arg("app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    if let Some(home) = std::env::var_os("CODEX_HOME") {
        cmd.env("CODEX_HOME", home);
    }
    let mut child = cmd.spawn().ok()?;
    {
        let stdin = child.stdin.as_mut()?;
        stdin
            .write_all(
                br#"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"agentcord","title":"AgentCord","version":"0.4.0"}}}
{"method":"account/read","id":1,"params":{"refreshToken":false}}
{"method":"account/rateLimits/read","id":2,"params":null}
"#,
            )
            .ok()?;
        stdin.flush().ok()?;
    }
    let mut stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            match stdout.read(&mut tmp) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    buf.extend_from_slice(&tmp[..n]);
                    while let Some(pos) = buf.iter().position(|&b| b == b'\n') {
                        let line = String::from_utf8_lossy(&buf[..=pos]).into_owned();
                        buf.drain(..=pos);
                        if tx.send(line).is_err() {
                            return;
                        }
                    }
                }
            }
        }
        if !buf.is_empty() {
            let _ = tx.send(String::from_utf8_lossy(&buf).into_owned());
        }
    });
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut usage = None;
    let mut email = None;
    while Instant::now() < deadline {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(line) => {
                if let Some(e) = parse_codex_account(&line) {
                    email = e;
                }
                if let Some(info) = parse_codex_wham(&line) {
                    usage = Some(info);
                    break;
                }
            }
            Err(_) => break,
        }
    }
    let _ = child.kill();
    let _ = child.wait();
    let mut info = usage?;
    if email.is_some() {
        info.email = email;
    }
    Some(info)
}

pub fn parse_codex_account(line: &str) -> Option<Option<String>> {
    let v: Value = serde_json::from_str(line).ok()?;
    if v.get("id").and_then(|x| x.as_i64()) != Some(1) {
        return None;
    }
    let account = v.get("result")?.get("account")?;
    Some(
        json_str(account.get("email"))
            .filter(|s| !s.is_empty())
            .map(str::to_string),
    )
}

fn codex_exe() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("CODEX_BINARY").map(PathBuf::from) {
        if p.is_file() {
            return Some(p);
        }
    }
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let exe = dir.join("codex.exe");
            if exe.is_file() {
                return Some(exe);
            }
        }
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let cand = PathBuf::from(local)
            .join("Programs")
            .join("OpenAI")
            .join("Codex")
            .join("bin")
            .join("codex.exe");
        if cand.is_file() {
            return Some(cand);
        }
    }
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"))?;
    let cand = PathBuf::from(home)
        .join(".local")
        .join("bin")
        .join("codex.exe");
    cand.is_file().then_some(cand)
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

