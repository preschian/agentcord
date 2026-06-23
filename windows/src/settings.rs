//! User-configurable settings. Port of `AgentCord/Settings.swift`.
//!
//! macOS persists these in `UserDefaults`; here they live in a JSON file at
//! `%APPDATA%\AgentCord\settings.json`. Menu-bar-only options
//! (`showMenuBarStatus`, `showUsageInMenuBar`) are omitted until there's a UI.
//! `#[serde(default)]` fills any missing field from `Default`, so old config
//! files keep loading as new fields are added.

use std::fs;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, PartialEq)]
#[serde(default)]
pub struct Settings {
    /// The Discord Application ID this app reports as. Not a secret; safe to
    /// ship. Same default as the macOS app.
    pub client_id: String,
    pub presence_enabled: bool,
    pub show_model: bool,
    pub show_tokens: bool,
    pub show_project: bool,
    pub do_not_disturb: bool,
    pub large_image_key: String,
    pub small_image_key: String,
    /// Discord activity type: 0 Playing, 2 Listening, 3 Watching, 5 Competing.
    pub activity_type: i32,
    /// A transcript counts as active if touched within this many seconds.
    pub idle_window_seconds: f64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            client_id: "1517099756063686677".to_string(),
            presence_enabled: true,
            show_model: true,
            show_tokens: true,
            show_project: true,
            do_not_disturb: false,
            large_image_key: "claude-color".to_string(),
            small_image_key: "discord-presence-icon".to_string(),
            activity_type: 0,
            idle_window_seconds: 300.0,
        }
    }
}

/// Activity types Discord permits for RPC updates. Streaming (1) and Custom (4)
/// are intentionally excluded.
pub const ALLOWED_ACTIVITY_TYPES: [i32; 4] = [0, 2, 3, 5];

impl Settings {
    pub fn config_path() -> PathBuf {
        let base = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        base.join("AgentCord").join("settings.json")
    }

    /// Load from disk, falling back to defaults on any error (missing file,
    /// malformed JSON). Writes nothing.
    pub fn load() -> Self {
        match fs::read_to_string(Self::config_path()) {
            Ok(s) => serde_json::from_str(&s).unwrap_or_default(),
            Err(_) => Self::default(),
        }
    }

    pub fn save(&self) -> std::io::Result<()> {
        let path = Self::config_path();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        let json = serde_json::to_string_pretty(self)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        fs::write(path, json)
    }
}
