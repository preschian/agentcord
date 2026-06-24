//! Small shared helpers.

use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

/// Build a `Command` that won't flash a console window when spawned from the
/// GUI (release) build. `CREATE_NO_WINDOW` only suppresses console allocation,
/// so GUI children (e.g. notepad) still show their own windows.
pub fn command(program: &str) -> Command {
    let mut c = Command::new(program);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .or_else(|| std::env::var_os("HOME"))
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn claude_dir() -> PathBuf {
    home_dir().join(".claude")
}

pub fn credentials_path() -> PathBuf {
    claude_dir().join(".credentials.json")
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn epoch_ms_from_iso(s: &str) -> Option<i64> {
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return Some(dt.timestamp_millis());
    }
    // API timestamps may include microseconds; strip the fractional part and retry (macOS parity).
    if let Some(dot) = s.find('.') {
        let suffix = &s[dot..];
        if let Some(tz_rel) = suffix.find(|c| c == '+' || c == '-' || c == 'Z') {
            let stripped = format!("{}{}", &s[..dot], &s[dot + tz_rel..]);
            if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(&stripped) {
                return Some(dt.timestamp_millis());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epoch_ms_from_iso_parses_zulu() {
        let ms = epoch_ms_from_iso("2026-01-15T12:00:00Z").unwrap();
        assert!(ms > 0);
    }

    #[test]
    fn epoch_ms_from_iso_parses_fractional_timestamps() {
        assert!(epoch_ms_from_iso("2026-06-26T04:59:59.083560+00:00").is_some());
    }
}
