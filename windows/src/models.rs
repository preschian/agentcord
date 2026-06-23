//! Codable payload structs for the Discord Rich Presence IPC protocol, plus the
//! value type that describes a detected Claude Code session.
//!
//! Direct port of `AgentCord/Models.swift`. The wire shapes are identical to
//! the macOS app — only the (de)serialization machinery differs (serde here,
//! Codable there).

use serde::Serialize;

// MARK: - Rich Presence payload

/// A Discord activity (Rich Presence). Every field is optional so we only
/// encode what we actually want to display; `skip_serializing_if` drops the
/// `None` fields rather than emitting `null` for them.
#[derive(Serialize, Clone, PartialEq, Debug, Default)]
pub struct RichPresence {
    /// Activity type. 0 Playing, 2 Listening, 3 Watching, 5 Competing.
    /// Types 1 (Streaming) and 4 (Custom) are not allowed for RPC updates.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub r#type: Option<i32>,
    /// The bold title line. Discord honors this for the activity header.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub timestamps: Option<Timestamps>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub assets: Option<Assets>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub buttons: Option<Vec<PresenceButton>>,
}

#[derive(Serialize, Clone, PartialEq, Debug, Default)]
pub struct Timestamps {
    /// Epoch milliseconds. Setting `start` makes Discord show an elapsed counter.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub start: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub end: Option<i64>,
}

#[derive(Serialize, Clone, PartialEq, Debug, Default)]
pub struct Assets {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub large_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub large_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub small_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub small_text: Option<String>,
}

#[derive(Serialize, Clone, PartialEq, Debug)]
pub struct PresenceButton {
    pub label: String,
    pub url: String,
}

// MARK: - IPC command payloads

/// Sent as opcode 0 immediately after connecting.
#[derive(Serialize)]
pub struct HandshakePayload<'a> {
    pub v: i32,
    pub client_id: &'a str,
}

/// Sent as opcode 1 to set (or clear) the presence.
///
/// `activity` is intentionally *not* `skip_serializing_if`: when it is `None`
/// we must encode an explicit JSON `null` to clear the presence, which is what
/// serde does for an unskipped `Option::None`.
#[derive(Serialize)]
pub struct SetActivityCommand {
    pub cmd: &'static str,
    pub nonce: String,
    pub args: SetActivityArgs,
}

#[derive(Serialize)]
pub struct SetActivityArgs {
    pub pid: u32,
    pub activity: Option<RichPresence>,
}

impl SetActivityCommand {
    pub fn new(nonce: String, pid: u32, activity: Option<RichPresence>) -> Self {
        Self {
            cmd: "SET_ACTIVITY",
            nonce,
            args: SetActivityArgs { pid, activity },
        }
    }
}

// MARK: - Claude Code session

// MARK: - Claude subscription usage

/// One rate-limit window: how much is used and when it resets. Port of
/// `UsageInfo.Window` from the macOS app.
#[derive(Clone, PartialEq, Debug)]
pub struct UsageWindow {
    pub percent: u32,
    /// Raw severity from the API ("normal", "warning", ...).
    pub severity: String,
    /// Reset time as epoch milliseconds, if known.
    pub resets_at_ms: Option<i64>,
}

impl UsageWindow {
    /// True once the window is past "normal", so the UI can highlight it.
    pub fn is_elevated(&self) -> bool {
        self.severity.to_lowercase() != "normal"
    }
}

/// The user's current subscription usage, as shown by Claude Code's `/usage`.
#[derive(Clone, PartialEq, Debug)]
pub struct UsageInfo {
    /// The rolling 5-hour session limit.
    pub five_hour: UsageWindow,
    /// The weekly (all-models) limit.
    pub weekly: UsageWindow,
}

/// A snapshot of the currently active Claude Code session.
#[derive(Clone, PartialEq, Debug)]
pub struct SessionInfo {
    pub project_name: String,
    pub model: Option<String>,
    pub start_epoch_ms: i64,
    pub total_tokens: u64,
    /// Last-modified time of the active transcript, as epoch milliseconds.
    pub last_modified_ms: i64,
}
