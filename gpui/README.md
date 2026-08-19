# AgentCord GPUI (Windows)

Windows-first AgentCord on [GPUI](https://gpui.rs): Claude, Codex, Cursor, and Grok sessions → Discord Rich Presence.

**Prototype, not a replacement.** Each GitHub Release ships two Windows builds: `agentcord.exe` from [`../windows`](../windows) and `agentcord-gpui.exe` from this tree. Do not swap them.

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}`
- Claude / Codex / Cursor / Grok session scans; all four show today’s work time on the row (gray when idle). Cursor uptime is today’s hook sum (`%TEMP%\AgentCord\yyyy-MM-dd-uptime.json`)
- Tray, usage bars, settings (`%APPDATA%\AgentCord\settings.json`)
- Presence clears ~1 minute after the last Claude / Codex / Grok activity; Cursor is active only while a hook turn is open

## Prerequisites

- [Rust](https://rustup.rs) (stable, MSVC toolchain)
- Visual Studio Build Tools with the C++ workload (GPUI links against the Windows SDK)
- Discord **desktop** client (Rich Presence does not work in the browser)

```powershell
winget install Rustlang.Rustup
```

## Run

Launch via Explorer so the process is not killed with the agent job (see root `AGENTS.md`):

```powershell
cd gpui
cargo test
cargo build
Start-Process explorer.exe -ArgumentList "`"$((Resolve-Path 'target\debug\agentcord-gpui.exe').Path)`""
```

Uses the production AgentCord Discord Application ID. Large-image assets: `logo-claude`, `logo-chatgpt`, `logo-cursor`, `logo-grok`.
