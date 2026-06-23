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

use std::fs::File;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::sleep;
use std::time::Duration;

use crate::claude_session::ClaudeSession;
use crate::discord_ipc::{
    handshake_payload, handle_inbound_frame, open_pipe, opcode, read_frame, write_activity, write_frame,
    FrameAction,
};
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
    Disabled,
    DoNotDisturb,
    Active {
        model: String,
        project: String,
        tokens_line: Option<String>,
        start_ms: i64,
    },
}

/// A human-readable snapshot of what the controller is doing, for the tray
/// popover to display.
#[derive(Default, Clone)]
pub struct StatusSnapshot {
    /// "Connected", "Connecting…", or "Disconnected".
    pub connection: String,
    pub session: SessionDisplay,
}

/// State shared between the controller and the tray UI. The tray mutates
/// `settings` (toggles) and sets `quit`; the controller reads those and
/// publishes `status` each tick.
pub struct SharedState {
    pub settings: Mutex<Settings>,
    pub status: Mutex<StatusSnapshot>,
    /// Latest subscription usage (5-hour + weekly), polled by the usage thread.
    pub usage: Mutex<Option<UsageInfo>>,
    pub quit: AtomicBool,
}

impl SharedState {
    pub fn new(settings: Settings) -> Self {
        Self {
            settings: Mutex::new(settings),
            status: Mutex::new(StatusSnapshot::default()),
            usage: Mutex::new(None),
            quit: AtomicBool::new(false),
        }
    }

    fn set_connection(&self, value: &str) {
        self.status.lock().unwrap().connection = value.to_string();
    }

    fn set_session_display(&self, display: SessionDisplay) {
        self.status.lock().unwrap().session = display;
    }
}

pub struct PresenceController {
    shared: Arc<SharedState>,
    pid: u32,
    nonce: AtomicU64,
    session: ClaudeSession,
    /// Last payload we sent; lets us skip unchanged updates without re-serializing.
    last_sent: Option<Option<RichPresence>>,
    /// Reconnect attempt counter, for exponential backoff.
    attempt: u32,
}

impl PresenceController {
    pub fn new(shared: Arc<SharedState>) -> Self {
        let idle_window = shared.settings.lock().unwrap().idle_window_seconds.max(1.0);
        let session = ClaudeSession::new().with_active_window(Duration::from_secs_f64(idle_window));
        Self {
            shared,
            pid: std::process::id(),
            nonce: AtomicU64::new(0),
            session,
            last_sent: None,
            attempt: 0,
        }
    }

    /// Run the controller. Blocks the calling thread until `quit` is set.
    pub fn run(mut self) {
        while !self.shared.quit.load(Ordering::Relaxed) {
            let end = self.connect_and_serve();
            if matches!(end, ConnectionEnd::Quit) {
                break;
            }
            self.shared.set_connection("Disconnected");
            if matches!(end, ConnectionEnd::Dropped) {
                // A live connection dropped: reconnect promptly.
                self.attempt = 0;
            }
            self.backoff();
        }
    }

    /// Open the pipe, handshake, wait for READY, then push presence updates
    /// until the connection drops or quit is requested.
    fn connect_and_serve(&mut self) -> ConnectionEnd {
        println!("[discord] connecting");
        self.shared.set_connection("Connecting…");
        let mut pipe = match open_pipe() {
            Some(p) => p,
            None => return ConnectionEnd::CouldNotConnect,
        };
        if write_frame(&mut pipe, opcode::HANDSHAKE, &handshake_payload(DISCORD_CLIENT_ID)).is_err() {
            return ConnectionEnd::CouldNotConnect;
        }
        if !wait_for_ready(&mut pipe) {
            return ConnectionEnd::CouldNotConnect;
        }

        println!("[discord] connected");
        self.shared.set_connection("Connected");
        self.attempt = 0;
        // Force a send on (re)connect even if the content is unchanged.
        self.last_sent = None;

        loop {
            if self.shared.quit.load(Ordering::Relaxed) {
                let _ = write_activity(&mut pipe, self.pid, &self.nonce, None);
                return ConnectionEnd::Quit;
            }

            // Snapshot settings so we react to tray toggles within one tick.
            let settings = self.shared.settings.lock().unwrap().clone();
            self.session
                .set_active_window(Duration::from_secs_f64(settings.idle_window_seconds.max(1.0)));

            let session_info = self.session.scan();
            let presence = if settings.presence_enabled && !settings.do_not_disturb {
                session_info.as_ref().map(|info| build_presence(&settings, info))
            } else {
                None
            };
            self.shared
                .set_session_display(build_session_display(&settings, session_info.as_ref()));

            if self.last_sent.as_ref() != Some(&presence) {
                match write_activity(&mut pipe, self.pid, &self.nonce, presence.clone()) {
                    Ok(()) => {
                        self.last_sent = Some(presence.clone());
                        log_presence(&presence);
                    }
                    Err(_) => return ConnectionEnd::Dropped,
                }
            }

            sleep(UPDATE_INTERVAL);
        }
    }

    /// Sleep before the next connection attempt: exponential backoff capped at
    /// 30s, mirroring the macOS client.
    fn backoff(&mut self) {
        self.attempt += 1;
        let secs = 2u64.pow(self.attempt.min(5)).min(30);
        sleep(Duration::from_secs(secs));
    }
}

enum ConnectionEnd {
    /// Never reached READY (pipe missing, handshake/READY failed).
    CouldNotConnect,
    /// Was connected and READY, then the pipe dropped.
    Dropped,
    /// Quit was requested; the controller should stop.
    Quit,
}

/// Read frames until READY. Answers any PINGs along the way (safe here: no
/// write is racing a blocking read on this single thread). Returns false if the
/// connection closed or errored first.
fn wait_for_ready(pipe: &mut File) -> bool {
    loop {
        match read_frame(pipe) {
            Ok(Some((op, payload))) => match handle_inbound_frame(op, &payload, pipe) {
                FrameAction::Ready => return true,
                FrameAction::Error(msg) => {
                    eprintln!("[discord] error: {msg}");
                    return false;
                }
                FrameAction::Closed => return false,
                FrameAction::Continue => {}
            },
            Ok(None) | Err(_) => return false,
        }
    }
}

/// Build the tray popover's session card from settings and the detected session.
pub fn build_session_display(settings: &Settings, session: Option<&SessionInfo>) -> SessionDisplay {
    if !settings.presence_enabled {
        return SessionDisplay::Disabled;
    }
    if settings.do_not_disturb {
        return SessionDisplay::DoNotDisturb;
    }
    let Some(info) = session else {
        return SessionDisplay::Idle;
    };

    let model = if settings.show_model {
        info.model.clone().unwrap_or_else(|| "agentcord".to_string())
    } else {
        String::new()
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

    SessionDisplay::Active {
        model,
        project,
        tokens_line,
        start_ms: info.start_epoch_ms,
    }
}

/// Build the Rich Presence payload from settings and the active session.
fn build_presence(s: &Settings, info: &SessionInfo) -> RichPresence {
    // Header (bold title): the model, e.g. "Opus 4.8".
    let name = if s.show_model { info.model.clone() } else { None }
        .unwrap_or_else(|| "agentcord".to_string());

    let details = if s.show_project {
        Some(format!("Working on: {}", info.project_name))
    } else {
        None
    };

    let state = if s.show_tokens && info.total_tokens > 0 {
        Some(format!("{} tokens", format_tokens(info.total_tokens)))
    } else {
        None
    };

    let assets = Assets {
        large_image: non_empty(&s.large_image_key),
        large_text: Some("agentcord".to_string()),
        small_image: non_empty(&s.small_image_key),
        small_text: Some("Active session".to_string()),
    };

    let activity_type = if is_allowed_activity(s.activity_type) {
        s.activity_type
    } else {
        0
    };

    RichPresence {
        r#type: Some(activity_type),
        name: Some(name),
        details,
        state,
        timestamps: Some(Timestamps { start: Some(info.start_epoch_ms), end: None }),
        assets: Some(assets),
        buttons: Some(vec![PresenceButton {
            label: "What is Claude Code".to_string(),
            url: "https://www.anthropic.com".to_string(),
        }]),
    }
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
