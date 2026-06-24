//! Launch-at-login, toggled through the per-user `Run` registry key. The macOS
//! app uses `SMAppService`; the Windows equivalent is a value under
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
//!
//! We drive it with `reg.exe` rather than the Win32 registry API — it keeps the
//! code tiny and needs no extra bindings, consistent with how the session
//! detector shells out to `git`.

use std::path::{Path, PathBuf};

use crate::util::command;

const RUN_KEY: &str = r"HKCU\Software\Microsoft\Windows\CurrentVersion\Run";
const VALUE_NAME: &str = "AgentCord";

/// The command the Run key should launch: this executable, quoted. With no
/// arguments it starts in tray mode.
fn exe_command() -> String {
    let exe = std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(str::to_string))
        .unwrap_or_default();
    format!("\"{exe}\"")
}

fn current_exe_path() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

/// True when the Run value exists and points at this executable.
pub fn is_enabled() -> bool {
    let Some(stored) = read_run_value() else {
        return false;
    };
    let Some(expected) = current_exe_path() else {
        return false;
    };
    paths_match(&stored, &expected)
}

fn read_run_value() -> Option<String> {
    let output = command("reg")
        .args(["query", RUN_KEY, "/v", VALUE_NAME])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        let line = line.trim();
        if !line.starts_with(VALUE_NAME) {
            continue;
        }
        let (_, rest) = line.split_once("REG_SZ")?;
        return Some(rest.trim().trim_matches('"').to_string());
    }
    None
}

fn paths_match(stored: &str, expected: &Path) -> bool {
    let stored_path = Path::new(stored.trim().trim_matches('"'));
    if stored_path == expected {
        return true;
    }
    match (stored_path.canonicalize(), expected.canonicalize()) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

/// Add or remove the Run value. Returns whether the change succeeded.
pub fn set_enabled(enabled: bool) -> bool {
    let result = if enabled {
        command("reg")
            .args(["add", RUN_KEY, "/v", VALUE_NAME, "/t", "REG_SZ", "/d", &exe_command(), "/f"])
            .output()
    } else {
        command("reg")
            .args(["delete", RUN_KEY, "/v", VALUE_NAME, "/f"])
            .output()
    };
    result.map(|o| o.status.success()).unwrap_or(false)
}
