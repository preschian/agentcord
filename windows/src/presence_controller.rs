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
use crate::discord_ipc::{handshake_payload, open_pipe, opcode, read_frame, write_activity, write_frame};
use crate::models::{Assets, PresenceButton, RichPresence, SessionInfo, Timestamps, UsageInfo};
use crate::settings::{Settings, ALLOWED_ACTIVITY_TYPES};

/// Discord throttles rapid activity updates, so we never push more often than
/// this. The loop period also serves as the debounce interval.
const UPDATE_INTERVAL: Duration = Duration::from_secs(3);

/// A human-readable snapshot of what the controller is doing, for the tray
/// popover to display.
#[derive(Default, Clone)]
pub struct StatusSnapshot {
    /// "Connected", "Connecting…", or "Disconnected".
    pub connection: String,
    /// Primary line, e.g. "Opus 4.8 · agentcord".
    pub line1: String,
    /// Secondary line, e.g. "871.7K tokens".
    pub line2: String,
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

    fn set_session_lines(&self, line1: String, line2: String) {
        let mut s = self.status.lock().unwrap();
        s.line1 = line1;
        s.line2 = line2;
    }
}

pub struct PresenceController {
    shared: Arc<SharedState>,
    client_id: String,
    pid: u32,
    nonce: AtomicU64,
    session: ClaudeSession,
    /// JSON of the last payload we sent; lets us skip unchanged updates.
    last_signature: Option<String>,
    /// Reconnect attempt counter, for exponential backoff.
    attempt: u32,
}

impl PresenceController {
    pub fn new(shared: Arc<SharedState>) -> Self {
        let (client_id, idle_window) = {
            let s = shared.settings.lock().unwrap();
            (s.client_id.trim().to_string(), s.idle_window_seconds.max(1.0))
        };
        let session = ClaudeSession::new().with_active_window(Duration::from_secs_f64(idle_window));
        Self {
            shared,
            client_id,
            pid: std::process::id(),
            nonce: AtomicU64::new(0),
            session,
            last_signature: None,
            attempt: 0,
        }
    }

    /// Run the controller. Blocks the calling thread until `quit` is set.
    pub fn run(mut self) {
        if self.client_id.is_empty() {
            eprintln!("no Discord Application ID configured");
            return;
        }

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
        if write_frame(&mut pipe, opcode::HANDSHAKE, &handshake_payload(&self.client_id)).is_err() {
            return ConnectionEnd::CouldNotConnect;
        }
        if !wait_for_ready(&mut pipe) {
            return ConnectionEnd::CouldNotConnect;
        }

        println!("[discord] connected");
        self.shared.set_connection("Connected");
        self.attempt = 0;
        // Force a send on (re)connect even if the content is unchanged.
        self.last_signature = None;

        loop {
            if self.shared.quit.load(Ordering::Relaxed) {
                let _ = write_activity(&mut pipe, self.pid, &self.nonce, None);
                return ConnectionEnd::Quit;
            }

            // Snapshot settings so we react to tray toggles within one tick.
            let settings = self.shared.settings.lock().unwrap().clone();
            let presence = if !settings.presence_enabled || settings.do_not_disturb {
                None
            } else {
                self.session.scan().map(|info| build_presence(&settings, &info))
            };
            self.shared.set_session_lines(
                status_line1(&settings, &presence),
                presence.as_ref().and_then(|p| p.state.clone()).unwrap_or_default(),
            );
            let signature = match &presence {
                Some(p) => serde_json::to_string(p).unwrap_or_default(),
                None => "CLEARED".to_string(),
            };

            if self.last_signature.as_deref() != Some(signature.as_str()) {
                match write_activity(&mut pipe, self.pid, &self.nonce, presence.clone()) {
                    Ok(()) => {
                        self.last_signature = Some(signature);
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
            Ok(Some((op, payload))) => match op {
                opcode::FRAME => {
                    if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&payload) {
                        match v.get("evt").and_then(|e| e.as_str()) {
                            Some("READY") => return true,
                            Some("ERROR") => {
                                let msg = v
                                    .get("data")
                                    .and_then(|d| d.get("message"))
                                    .and_then(|m| m.as_str())
                                    .unwrap_or("Discord reported an error");
                                eprintln!("[discord] error: {msg}");
                                return false;
                            }
                            _ => {}
                        }
                    }
                }
                opcode::PING => {
                    let _ = write_frame(pipe, opcode::PONG, &payload);
                }
                opcode::CLOSE => return false,
                _ => {}
            },
            Ok(None) | Err(_) => return false,
        }
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

    let activity_type = if ALLOWED_ACTIVITY_TYPES.contains(&s.activity_type) {
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

/// The popover's primary status line: the controller's current intent, or the
/// active session summarized as "Model · project".
fn status_line1(settings: &Settings, presence: &Option<RichPresence>) -> String {
    if !settings.presence_enabled {
        return "Presence disabled".to_string();
    }
    if settings.do_not_disturb {
        return "Do Not Disturb".to_string();
    }
    match presence {
        Some(p) => {
            let model = p.name.clone().unwrap_or_default();
            let project = p
                .details
                .as_deref()
                .map(|d| d.trim_start_matches("Working on: ").to_string())
                .unwrap_or_default();
            match (model.is_empty(), project.is_empty()) {
                (false, false) => format!("{model} · {project}"),
                (false, true) => model,
                (true, false) => project,
                (true, true) => "Active session".to_string(),
            }
        }
        None => "No active session".to_string(),
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
