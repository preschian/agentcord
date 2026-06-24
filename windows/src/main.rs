// Release builds are a GUI app with no console window. Debug builds keep the
// console so the [discord]/[presence] logs are visible while developing.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

//! AgentCord for Windows.
//!
//! Default (no args) launches the tray app: a notification-area icon with a
//! status popover (left-click) and context menu (right-click), driving the
//! presence controller. The other subcommands (`run`, `session`, `ipc`) are
//! headless modes for debugging — see the usage text in `main`.

mod autostart;
mod claude_session;
mod claude_usage;
mod discord_ipc;
mod models;
mod presence_controller;
mod settings;
mod tray;
mod usage_poller;
mod util;

use std::sync::atomic::AtomicU64;
use std::sync::Arc;
use std::thread::sleep;
use std::time::Duration;

use claude_session::{now_ms, ClaudeSession};
use discord_ipc::{connect_handshake, handle_inbound_frame, read_frame, write_activity, FrameAction};
use models::{Assets, RichPresence, SessionInfo, Timestamps};
use presence_controller::{PresenceController, SharedState};
use settings::Settings;

fn main() {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        // Default (no args) launches the tray app — this is what autostart runs.
        None | Some("tray") => tray::run(),
        Some("run") => {
            let shared = Arc::new(SharedState::new(Settings::load()));
            PresenceController::new(shared).run();
        }
        Some("session") => run_session(),
        Some("ipc") => match args.next() {
            Some(id) => run_ipc(&id),
            None => {
                eprintln!("usage: agentcord ipc <DISCORD_APPLICATION_ID>");
                std::process::exit(2);
            }
        },
        _ => {
            eprintln!(
                "usage:\n  \
                 agentcord                    tray app (default): session → Discord presence\n  \
                 agentcord run                headless: same, without the tray icon\n  \
                 agentcord session            detect the active Claude Code session\n  \
                 agentcord ipc <APP_ID>       Discord IPC smoke test"
            );
            std::process::exit(2);
        }
    }
}

/// Poll the Claude Code transcripts and print the detected session whenever it
/// changes. Ctrl-C to stop.
fn run_session() {
    let mut session = ClaudeSession::new();
    println!("watching {} (Ctrl-C to stop)\n", session.projects_dir().display());

    let mut last: Option<SessionInfo> = None;
    loop {
        let current = session.scan();
        if current != last {
            print_session(&current);
            last = current;
        }
        sleep(Duration::from_secs(3));
    }
}

fn print_session(session: &Option<SessionInfo>) {
    match session {
        Some(s) => {
            let model = s.model.as_deref().unwrap_or("(unknown)");
            let elapsed_min = (now_ms() - s.start_epoch_ms).max(0) / 60_000;
            println!(
                "● active — project: {} | model: {} | tokens today: {} | elapsed: {}m",
                s.project_name, model, s.total_tokens, elapsed_min
            );
        }
        None => println!("○ idle — no active session"),
    }
}

/// Connect to Discord over the named pipe, wait for READY, and set a sample
/// presence. Ctrl-C to stop.
fn run_ipc(client_id: &str) {
    let pid = std::process::id();
    let nonce = AtomicU64::new(0);

    let mut pipe = match connect_handshake(client_id) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("connect failed (is Discord running?): {e}");
            std::process::exit(1);
        }
    };
    println!("connected");

    let now = now_ms();
    let presence = RichPresence {
        details: Some("Coding with Claude Code".into()),
        state: Some("agentcord (windows port)".into()),
        timestamps: Some(Timestamps { start: Some(now), end: None }),
        assets: Some(Assets {
            large_image: Some("claude".into()),
            small_image: Some("coding".into()),
            ..Default::default()
        }),
        ..Default::default()
    };
    match write_activity(&mut pipe, pid, &nonce, Some(presence)) {
        Ok(()) => println!("presence set — check your Discord profile"),
        Err(e) => eprintln!("set_activity failed: {e}"),
    }

    loop {
        match read_frame(&mut pipe) {
            Ok(Some((op, payload))) => match handle_inbound_frame(op, &payload, &mut pipe) {
                FrameAction::Closed | FrameAction::Error(_) => break,
                _ => {}
            },
            Ok(None) | Err(_) => break,
        }
    }
    eprintln!("connection closed");
}
