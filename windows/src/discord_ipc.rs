//! A hand-written Discord RPC IPC client. No third-party RPC dependencies —
//! only serde for JSON, mirroring the macOS app's zero-dependency stance.
//!
//! Port of the transport in `AgentCord/DiscordIPC.swift`. The protocol is
//! byte-for-byte identical; only the transport differs:
//!
//!   * macOS  — Unix domain socket at `$TMPDIR/discord-ipc-{0..9}`
//!   * Windows — named pipe at `\\.\pipe\discord-ipc-{0..9}`
//!
//! On Windows a named pipe is just a file handle, so we open it with the
//! standard library's `OpenOptions` and use `Read`/`Write` directly.
//!
//! This module is the low-level toolkit: pipe discovery and frame read/write.
//! The connection lifecycle (handshake, reconnect-with-backoff, ping/pong) is
//! orchestrated by `presence_controller`, the way `PresenceController.swift`
//! drives `DiscordIPC` on macOS. The small [`DiscordIpc`] struct at the bottom
//! is a single-connection convenience used only by the `ipc` smoke test.
//!
//! Frame format on the wire:
//!   [ opcode: u32 LE ][ payloadLength: u32 LE ][ JSON bytes ]

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Write};
use std::sync::atomic::{AtomicU64, Ordering};

use crate::models::{HandshakePayload, RichPresence, SetActivityCommand};

/// Discord IPC opcodes.
pub mod opcode {
    pub const HANDSHAKE: u32 = 0;
    pub const FRAME: u32 = 1;
    pub const CLOSE: u32 = 2;
    pub const PING: u32 = 3;
    pub const PONG: u32 = 4;
}

/// Open the first available `\\.\pipe\discord-ipc-{0..9}` for read+write.
pub fn open_pipe() -> Option<File> {
    (0..=9).find_map(|i| {
        OpenOptions::new()
            .read(true)
            .write(true)
            .open(format!(r"\\.\pipe\discord-ipc-{i}"))
            .ok()
    })
}

/// Encode the opcode-0 handshake payload for a client id.
pub fn handshake_payload(client_id: &str) -> Vec<u8> {
    serde_json::to_vec(&HandshakePayload { v: 1, client_id }).unwrap_or_default()
}

/// Write one framed message: `[opcode LE][len LE][payload]`.
pub fn write_frame(w: &mut impl Write, opcode: u32, payload: &[u8]) -> io::Result<()> {
    let mut frame = Vec::with_capacity(8 + payload.len());
    frame.extend_from_slice(&opcode.to_le_bytes());
    frame.extend_from_slice(&(payload.len() as u32).to_le_bytes());
    frame.extend_from_slice(payload);
    w.write_all(&frame)?;
    w.flush()
}

/// Read one frame. `Ok(None)` means the peer closed the pipe (reconnect).
pub fn read_frame(r: &mut impl Read) -> io::Result<Option<(u32, Vec<u8>)>> {
    let mut header = [0u8; 8];
    if let Err(e) = r.read_exact(&mut header) {
        return match e.kind() {
            io::ErrorKind::UnexpectedEof | io::ErrorKind::BrokenPipe => Ok(None),
            _ => Err(e),
        };
    }
    let opcode = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let length = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if length == 0 {
        return Ok(Some((opcode, Vec::new())));
    }
    let mut payload = vec![0u8; length];
    if let Err(e) = r.read_exact(&mut payload) {
        return match e.kind() {
            io::ErrorKind::UnexpectedEof | io::ErrorKind::BrokenPipe => Ok(None),
            _ => Err(e),
        };
    }
    Ok(Some((opcode, payload)))
}

/// Build and write a `SET_ACTIVITY` frame (or, with `None`, a clear). The nonce
/// counter is shared so every command gets a unique nonce.
pub fn write_activity(
    w: &mut impl Write,
    pid: u32,
    nonce: &AtomicU64,
    activity: Option<RichPresence>,
) -> io::Result<()> {
    let nonce_str = format!("{}-{}", pid, nonce.fetch_add(1, Ordering::Relaxed));
    let cmd = SetActivityCommand::new(nonce_str, pid, activity);
    let payload = serde_json::to_vec(&cmd).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    write_frame(w, opcode::FRAME, &payload)
}

// MARK: - Single-connection convenience (used by the `ipc` smoke test)

/// A minimal blocking client over one pipe. The full app uses the free helpers
/// above from `presence_controller` instead, which adds reconnect and threading.
pub struct DiscordIpc {
    client_id: String,
    pid: u32,
    pipe: Option<File>,
    ready: bool,
    nonce: AtomicU64,
}

impl DiscordIpc {
    pub fn new(client_id: impl Into<String>) -> Self {
        Self {
            client_id: client_id.into(),
            pid: std::process::id(),
            pipe: None,
            ready: false,
            nonce: AtomicU64::new(0),
        }
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }

    pub fn connect(&mut self) -> io::Result<()> {
        self.pipe = None;
        self.ready = false;
        let mut pipe = open_pipe()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "no discord-ipc pipe found"))?;
        write_frame(&mut pipe, opcode::HANDSHAKE, &handshake_payload(&self.client_id))?;
        self.pipe = Some(pipe);
        Ok(())
    }

    pub fn set_activity(&mut self, activity: Option<RichPresence>) -> io::Result<()> {
        if !self.ready {
            return Ok(());
        }
        let pipe = self
            .pipe
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "not connected"))?;
        write_activity(pipe, self.pid, &self.nonce, activity)
    }

    /// Read and handle one inbound frame. `Ok(false)` => connection closed.
    pub fn pump(&mut self) -> io::Result<bool> {
        let frame = match self.pipe.as_mut() {
            Some(p) => read_frame(p)?,
            None => return Ok(false),
        };
        let (op, payload) = match frame {
            Some(f) => f,
            None => return Ok(false),
        };
        match op {
            opcode::FRAME => {
                if let Ok(v) = serde_json::from_slice::<serde_json::Value>(&payload) {
                    if v.get("evt").and_then(|e| e.as_str()) == Some("READY") {
                        self.ready = true;
                    }
                }
            }
            opcode::PING => {
                if let Some(p) = self.pipe.as_mut() {
                    let _ = write_frame(p, opcode::PONG, &payload);
                }
            }
            opcode::CLOSE => {
                self.ready = false;
                return Ok(false);
            }
            _ => {}
        }
        Ok(true)
    }
}
