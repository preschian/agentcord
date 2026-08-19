//! Library crate for the GPUI Windows app. The popover lives in `main.rs`.
//!
//! - [`discord`] — Discord IPC / Rich Presence
//! - [`session`] — live session scans (`claude` / `codex` / `cursor` / `grok`)
//! - [`usage`] — quota polls (same agent split)
//! - [`settings`] — `settings.json`, autostart, single-instance
//! - [`status`] — Anthropic status page

pub mod discord;
pub mod session;
pub mod settings;
pub mod status;
pub mod usage;

pub use session::hooks as cursor_hooks;
