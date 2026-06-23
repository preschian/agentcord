//! Launch-at-login, toggled through the per-user `Run` registry key. The macOS
//! app uses `SMAppService`; the Windows equivalent is a value under
//! `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.
//!
//! We drive it with `reg.exe` rather than the Win32 registry API — it keeps the
//! code tiny and needs no extra bindings, consistent with how the session
//! detector shells out to `git`.

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

/// True if the Run value currently exists.
pub fn is_enabled() -> bool {
    command("reg")
        .args(["query", RUN_KEY, "/v", VALUE_NAME])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
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
