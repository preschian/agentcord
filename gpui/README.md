# AgentCord GPUI (Windows)

Minimal AgentCord on [GPUI](https://gpui.rs): Claude, Codex, Cursor, and Grok sessions → Discord Rich Presence.

Lives next to the production C# app in [`../windows`](../windows). This tree is Windows-first.

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}`
- Claude: newest `~/.claude/projects/**/*.jsonl` (idle window 5 min)
- Codex: newest `~/.codex/sessions/**/*.jsonl` (`CODEX_HOME` honored)
- Cursor: newest `~/.cursor/projects/**/agent-transcripts/**/*.jsonl`
- Grok: `~/.grok/active_sessions.json` + `summary.json` / `signals.json`
- Compact GPUI window: presence toggle, live session, per-agent idle/live

Not yet: usage bars, tray icon, settings persistence. Full leftover list: [handoff.md](handoff.md).

## Prerequisites

- [Rust](https://rustup.rs) (stable, MSVC toolchain)
- Visual Studio Build Tools with the C++ workload (GPUI links against the Windows SDK)
- Discord **desktop** client (Rich Presence does not work in the browser)

```powershell
winget install Rustlang.Rustup
# then a VS Build Tools install that includes MSVC + Windows SDK
```

## Run

```powershell
cd gpui
cargo run --release
```

Uses the production AgentCord Discord Application ID. Large-image assets: `logo-claude`, `logo-chatgpt`, `logo-cursor`, `logo-grok`.

## Test

```powershell
cd gpui
cargo test
```
