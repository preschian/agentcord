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
//! drives `DiscordIPC` on macOS.
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
    serde_json::to_vec(&HandshakePayload { v: 1, client_id })
        .expect("HandshakePayload serialization is infallible")
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

/// Result of handling one inbound IPC frame.
#[derive(Debug, PartialEq, Eq)]
pub enum FrameAction {
    /// Keep reading; no terminal state change.
    Continue,
    /// Discord sent READY — handshake complete.
    Ready,
    /// Discord sent ERROR with a message.
    Error(String),
    /// Peer closed the connection.
    Closed,
}

/// Handle one inbound frame: answer PINGs, detect READY/ERROR/CLOSE.
pub fn handle_inbound_frame<W: Write>(op: u32, payload: &[u8], pipe: &mut W) -> FrameAction {
    match op {
        opcode::FRAME => {
            let Ok(v) = serde_json::from_slice::<serde_json::Value>(payload) else {
                return FrameAction::Continue;
            };
            match v.get("evt").and_then(|e| e.as_str()) {
                Some("READY") => FrameAction::Ready,
                Some("ERROR") => {
                    let msg = v
                        .get("data")
                        .and_then(|d| d.get("message"))
                        .and_then(|m| m.as_str())
                        .unwrap_or("Discord reported an error")
                        .to_string();
                    FrameAction::Error(msg)
                }
                _ => FrameAction::Continue,
            }
        }
        opcode::PING => {
            let _ = write_frame(pipe, opcode::PONG, payload);
            FrameAction::Continue
        }
        opcode::CLOSE => FrameAction::Closed,
        _ => FrameAction::Continue,
    }
}

/// Read frames until READY. Answers PINGs along the way.
pub fn wait_for_ready(pipe: &mut (impl Read + Write)) -> Result<(), String> {
    loop {
        match read_frame(pipe) {
            Ok(Some((op, payload))) => match handle_inbound_frame(op, &payload, pipe) {
                FrameAction::Ready => return Ok(()),
                FrameAction::Error(msg) => return Err(msg),
                FrameAction::Closed => return Err("connection closed".to_string()),
                FrameAction::Continue => {}
            },
            Ok(None) => return Err("connection closed".to_string()),
            Err(e) => return Err(e.to_string()),
        }
    }
}

/// Open the pipe, send the handshake, and block until READY.
pub fn connect_handshake(client_id: &str) -> io::Result<File> {
    let mut pipe = open_pipe()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "no discord-ipc pipe found"))?;
    write_frame(&mut pipe, opcode::HANDSHAKE, &handshake_payload(client_id))?;
    wait_for_ready(&mut pipe).map_err(|msg| io::Error::new(io::ErrorKind::NotConnected, msg))?;
    Ok(pipe)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn ready_frame_returns_ready() {
        let payload = br#"{"evt":"READY"}"#;
        let mut buf: Vec<u8> = Vec::new();
        let action = handle_inbound_frame(opcode::FRAME, payload, &mut buf);
        assert_eq!(action, FrameAction::Ready);
    }

    #[test]
    fn ping_writes_pong() {
        let payload = b"1234";
        let mut written = Vec::new();
        let action = handle_inbound_frame(opcode::PING, payload, &mut written);
        assert_eq!(action, FrameAction::Continue);
        assert!(!written.is_empty());
    }

    #[test]
    fn error_frame_surfaces_message() {
        let payload = br#"{"evt":"ERROR","data":{"message":"bad id"}}"#;
        let mut buf = Cursor::new(Vec::new());
        let action = handle_inbound_frame(opcode::FRAME, payload, &mut buf);
        assert_eq!(action, FrameAction::Error("bad id".to_string()));
    }

    #[test]
    fn close_frame_is_closed() {
        let action = handle_inbound_frame(opcode::CLOSE, &[], &mut Vec::<u8>::new());
        assert_eq!(action, FrameAction::Closed);
    }
}
