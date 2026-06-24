//! Observes the active Claude Code session, builds the Rich Presence from the
//! user's settings, debounces updates, and drives the Discord IPC connection.
//! Clears the presence when the session goes idle. Port of
//! `AgentCord/PresenceController.swift`.
//!
//! ## Why single-threaded (and not a reader thread like macOS)
//!
//! macOS uses a Unix socket with a dedicated read thread alongside writes. That
//! does not translate to a Windows named pipe opened in the default
//! *synchronous* mode: the kernel serializes all I/O on one file object, so a
//! write blocks behind any in-flight blocking read (even via a duplicated
//! handle) — an instant deadlock. Overlapped I/O would fix it but needs Win32
//! calls that drag in the MSVC import-lib tooling we are avoiding.
//!
//! So this controller does everything on one thread: connect, read frames until
//! READY (no writes are pending then, so blocking reads are safe), then enter a
//! write-only loop that pushes `SET_ACTIVITY` on a timer. A failed write means
//! Discord closed the pipe, which triggers a reconnect (re-handshake, re-READY,
//! re-send). We do not read PINGs after READY; if Discord drops us for that, the
//! next write fails and we reconnect within seconds — self-healing.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::sleep;
use std::time::Duration;

use crate::claude_session::ClaudeSession;
use crate::discord_ipc::{connect_handshake, write_activity};
use crate::models::{Assets, PresenceButton, RichPresence, SessionInfo, Timestamps, UsageInfo};
use crate::settings::{is_allowed_activity, Settings, DISCORD_CLIENT_ID};

/// Discord throttles rapid activity updates, so we never push more often than
/// this. The loop period also serves as the debounce interval.
const UPDATE_INTERVAL: Duration = Duration::from_secs(3);

/// What the tray popover should show for the active-session card. Kept separate
/// from [`RichPresence`] so the UI never parses Discord wire strings back out.
#[derive(Clone, Default, PartialEq, Eq, Debug)]
pub enum SessionDisplay {
    #[default]
    Idle,
    Active {
        model: String,
        project: String,
        tokens_line: Option<String>,
        start_ms: i64,
    },
}

impl SessionDisplay {
    pub fn headline(&self) -> String {
        match self {
            Self::Idle => "No active session".to_string(),
            Self::Active { model, project, .. } => match (model.is_empty(), project.is_empty()) {
                (false, false) => format!("{model} · {project}"),
                (false, true) => model.clone(),
                (true, false) => project.clone(),
                (true, true) => "Active session".to_string(),
            },
        }
    }

    pub fn tokens_line(&self) -> Option<&str> {
        match self {
            Self::Active { tokens_line, .. } => tokens_line.as_deref(),
            _ => None,
        }
    }

    pub fn start_ms(&self) -> Option<i64> {
        match self {
            Self::Active { start_ms, .. } => Some(*start_ms),
            _ => None,
        }
    }
}

/// Discord pipe state shown in the tray status pill.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub enum ConnectionStatus {
    #[default]
    Disconnected,
    Connected,
    Connecting,
    Off,
}

impl std::fmt::Display for ConnectionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Connected => write!(f, "Connected"),
            Self::Connecting => write!(f, "Connecting…"),
            Self::Disconnected => write!(f, "Disconnected"),
            Self::Off => write!(f, "Off"),
        }
    }
}

/// Tray-facing state published atomically each controller tick.
#[derive(Clone)]
pub struct UiSnapshot {
    pub connection: ConnectionStatus,
    /// Latest scan result; tray applies display settings when rendering.
    pub session_info: Option<SessionInfo>,
    pub usage: Option<UsageInfo>,
}

impl Default for UiSnapshot {
    fn default() -> Self {
        Self {
            connection: ConnectionStatus::Disconnected,
            session_info: None,
            usage: None,
        }
    }
}

/// State shared between the controller, usage worker, and tray UI.
pub struct SharedState {
    pub settings: Mutex<Settings>,
    pub ui: Mutex<UiSnapshot>,
    pub quit: AtomicBool,
    /// Set by the tray when the popover opens; consumed by the usage worker.
    pub usage_refresh: AtomicBool,
}

impl SharedState {
    pub fn new(settings: Settings) -> Self {
        Self {
            settings: Mutex::new(settings),
            ui: Mutex::new(UiSnapshot::default()),
            quit: AtomicBool::new(false),
            usage_refresh: AtomicBool::new(false),
        }
    }

    /// Single write path for the presence toggle (persists to settings file).
    pub fn set_presence_enabled(&self, on: bool) {
        {
            let mut settings = self.settings.lock().unwrap();
            settings.presence_enabled = on;
            let _ = settings.save();
        }
    }

    pub fn toggle_presence_enabled(&self) {
        let mut settings = self.settings.lock().unwrap();
        settings.presence_enabled = !settings.presence_enabled;
        let _ = settings.save();
    }

    pub fn publish_ui(&self, connection: ConnectionStatus, session_info: Option<SessionInfo>) {
        let mut ui = self.ui.lock().unwrap();
        if ui.connection == connection && ui.session_info == session_info {
            return;
        }
        ui.connection = connection;
        ui.session_info = session_info;
    }

    pub fn set_usage(&self, usage: Option<UsageInfo>) {
        self.ui.lock().unwrap().usage = usage;
    }

    pub fn request_usage_refresh(&self) {
        self.usage_refresh.store(true, Ordering::Relaxed);
    }
}

/// Visible session fields derived once from settings + session info.
struct SessionFields {
    /// Discord activity title; always non-empty.
    title: String,
    model_label: String,
    project: String,
    tokens_line: Option<String>,
    start_ms: i64,
}

/// Discord payload for one scan tick (`None` when presence is off or idle).
pub fn build_session_presence(settings: &Settings, session: Option<&SessionInfo>) -> Option<RichPresence> {
    match (settings.presence_enabled, session) {
        (true, Some(info)) => Some(build_presence_from_fields(settings, &session_fields(settings, info))),
        _ => None,
    }
}

pub fn build_session_display(settings: &Settings, session: Option<&SessionInfo>) -> SessionDisplay {
    let Some(info) = session else {
        return SessionDisplay::Idle;
    };
    let fields = session_fields(settings, info);
    SessionDisplay::Active {
        model: fields.model_label,
        project: fields.project,
        tokens_line: fields.tokens_line,
        start_ms: fields.start_ms,
    }
}

fn session_fields(settings: &Settings, info: &SessionInfo) -> SessionFields {
    let model_label = if settings.show_model {
        info.model.clone().unwrap_or_else(|| "agentcord".to_string())
    } else {
        String::new()
    };
    let title = if model_label.is_empty() {
        "agentcord".to_string()
    } else {
        model_label.clone()
    };
    let project = if settings.show_project {
        info.project_name.clone()
    } else {
        String::new()
    };
    let tokens_line = if settings.show_tokens && info.total_tokens > 0 {
        Some(format!("{} tokens", format_tokens(info.total_tokens)))
    } else {
        None
    };
    SessionFields {
        title,
        model_label,
        project,
        tokens_line,
        start_ms: info.start_epoch_ms,
    }
}

fn build_presence_from_fields(settings: &Settings, fields: &SessionFields) -> RichPresence {
    let details = if settings.show_project {
        Some(format!("Working on: {}", fields.project))
    } else {
        None
    };
    let state = fields.tokens_line.clone();
    let activity_type = if is_allowed_activity(settings.activity_type) {
        settings.activity_type
    } else {
        0
    };

    RichPresence {
        r#type: Some(activity_type),
        name: Some(fields.title.clone()),
        details,
        state,
        timestamps: Some(Timestamps {
            start: Some(fields.start_ms),
            end: None,
        }),
        assets: Some(Assets {
            large_image: non_empty(&settings.large_image_key),
            large_text: Some("agentcord".to_string()),
            small_image: non_empty(&settings.small_image_key),
            small_text: Some("Active session".to_string()),
        }),
        buttons: Some(vec![PresenceButton {
            label: "What is Claude Code".to_string(),
            url: "https://www.anthropic.com".to_string(),
        }]),
    }
}

/// Tracks the last payload written to Discord for deduplication.
enum LastPayload {
    /// Reconnect or first tick — send even if unchanged.
    Unsent,
    Cleared,
    Active(RichPresence),
}

impl LastPayload {
    fn needs_send(&self, presence: &Option<RichPresence>) -> bool {
        match (self, presence) {
            (LastPayload::Unsent, _) => true,
            (LastPayload::Cleared, None) => false,
            (LastPayload::Cleared, Some(_)) => true,
            (LastPayload::Active(p), Some(q)) => p != q,
            (LastPayload::Active(_), None) => true,
        }
    }

    fn mark_sent(&mut self, presence: &Option<RichPresence>) {
        *self = match presence {
            None => LastPayload::Cleared,
            Some(p) => LastPayload::Active(p.clone()),
        };
    }

    fn force_resend(&mut self) {
        *self = LastPayload::Unsent;
    }
}

pub struct PresenceController {
    shared: Arc<SharedState>,
    pid: u32,
    nonce: AtomicU64,
    session: ClaudeSession,
    last_sent: LastPayload,
    attempt: u32,
}

impl PresenceController {
    pub fn new(shared: Arc<SharedState>) -> Self {
        let settings = shared.settings.lock().unwrap().clone();
        let mut session = ClaudeSession::new();
        sync_session_window(&mut session, &settings);
        Self {
            shared,
            pid: std::process::id(),
            nonce: AtomicU64::new(0),
            session,
            last_sent: LastPayload::Unsent,
            attempt: 0,
        }
    }

    /// Run the controller. Blocks the calling thread until `quit` is set.
    pub fn run(mut self) {
        while !self.shared.quit.load(Ordering::Relaxed) {
            // `Off` when presence is disabled before connect; `ConnectionEnd::Disabled`
            // when the user toggles it off mid-connection inside `connect_and_serve`.
            if !self.shared.settings.lock().unwrap().presence_enabled {
                self.idle_tick(ConnectionStatus::Off);
                sleep(UPDATE_INTERVAL);
                continue;
            }

            match self.connect_and_serve() {
                ConnectionEnd::Quit => break,
                ConnectionEnd::Disabled => self.last_sent.force_resend(),
                ConnectionEnd::CouldNotConnect => {
                    self.idle_tick(ConnectionStatus::Disconnected);
                    self.backoff();
                }
                ConnectionEnd::Dropped => {
                    self.attempt = 0;
                    self.idle_tick(ConnectionStatus::Disconnected);
                    self.backoff();
                }
            }
        }
    }

    /// Scan session and publish tray state while Discord is disconnected.
    fn idle_tick(&mut self, connection: ConnectionStatus) {
        let settings = self.shared.settings.lock().unwrap().clone();
        sync_session_window(&mut self.session, &settings);
        let session_info = self.session.scan();
        self.shared.publish_ui(connection, session_info);
    }

    fn connect_and_serve(&mut self) -> ConnectionEnd {
        println!("[discord] connecting");
        self.idle_tick(ConnectionStatus::Connecting);

        let mut pipe = match connect_handshake(DISCORD_CLIENT_ID) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[discord] connect failed: {e}");
                return ConnectionEnd::CouldNotConnect;
            }
        };

        println!("[discord] connected");
        self.attempt = 0;
        self.last_sent.force_resend();

        loop {
            if self.shared.quit.load(Ordering::Relaxed) {
                let _ = write_activity(&mut pipe, self.pid, &self.nonce, None);
                return ConnectionEnd::Quit;
            }

            let settings = self.shared.settings.lock().unwrap().clone();
            if !settings.presence_enabled {
                let _ = write_activity(&mut pipe, self.pid, &self.nonce, None);
                self.last_sent.mark_sent(&None);
                return ConnectionEnd::Disabled;
            }

            sync_session_window(&mut self.session, &settings);
            let session_info = self.session.scan();
            let presence = build_session_presence(&settings, session_info.as_ref());
            self.shared.publish_ui(ConnectionStatus::Connected, session_info);
            if self.last_sent.needs_send(&presence) {
                match write_activity(&mut pipe, self.pid, &self.nonce, presence.clone()) {
                    Ok(()) => {
                        self.last_sent.mark_sent(&presence);
                        log_presence(&presence);
                    }
                    Err(e) => {
                        eprintln!("[discord] write_activity failed: {e}");
                        return ConnectionEnd::Dropped;
                    }
                }
            }

            sleep(UPDATE_INTERVAL);
        }
    }

    fn backoff(&mut self) {
        self.attempt += 1;
        let secs = 2u64.pow(self.attempt.min(5)).min(30);
        sleep(Duration::from_secs(secs));
    }
}

enum ConnectionEnd {
    CouldNotConnect,
    Dropped,
    Quit,
    Disabled,
}

fn sync_session_window(session: &mut ClaudeSession, settings: &Settings) {
    session.set_active_window(Duration::from_secs_f64(settings.idle_window_seconds.max(1.0)));
}

fn non_empty(s: &str) -> Option<String> {
    if s.is_empty() {
        None
    } else {
        Some(s.to_string())
    }
}

fn format_tokens(count: u64) -> String {
    if count >= 1_000_000 {
        format!("{:.1}M", count as f64 / 1_000_000.0)
    } else if count >= 1_000 {
        format!("{:.1}K", count as f64 / 1_000.0)
    } else {
        count.to_string()
    }
}

fn log_presence(presence: &Option<RichPresence>) {
    match presence {
        Some(p) => println!(
            "[presence] {} | {} | {}",
            p.name.as_deref().unwrap_or(""),
            p.details.as_deref().unwrap_or(""),
            p.state.as_deref().unwrap_or("")
        ),
        None => println!("[presence] cleared"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::SessionInfo;

    fn sample_info() -> SessionInfo {
        SessionInfo {
            project_name: "agentcord".to_string(),
            model: Some("Opus 4.5".to_string()),
            start_epoch_ms: 1_700_000_000_000,
            total_tokens: 42_000,
            last_modified_ms: 1_700_000_100_000,
        }
    }

    #[test]
    fn view_respects_display_toggles() {
        let mut s = Settings::default();
        s.show_model = false;
        s.show_project = true;
        s.show_tokens = false;
        let info = sample_info();
        match build_session_display(&s, Some(&info)) {
            SessionDisplay::Active { model, project, tokens_line, .. } => {
                assert!(model.is_empty());
                assert_eq!(project, "agentcord");
                assert!(tokens_line.is_none());
            }
            _ => panic!("expected active"),
        }
        let presence = build_session_presence(&s, Some(&info)).unwrap();
        assert_eq!(presence.name.as_deref(), Some("agentcord"));
        assert!(presence.state.is_none());
    }

    #[test]
    fn view_presence_off_still_shows_session() {
        let mut s = Settings::default();
        s.presence_enabled = false;
        let info = sample_info();
        match build_session_display(&s, Some(&info)) {
            SessionDisplay::Active { model, project, .. } => {
                assert_eq!(model, "Opus 4.5");
                assert_eq!(project, "agentcord");
            }
            _ => panic!("expected active session card"),
        }
        assert!(build_session_presence(&s, Some(&info)).is_none());
    }

    #[test]
    fn view_idle_without_session() {
        let s = Settings::default();
        assert_eq!(build_session_display(&s, None), SessionDisplay::Idle);
        assert!(build_session_presence(&s, None).is_none());
    }
}
