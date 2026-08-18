# AgentCord GPUI (Windows)

Windows-first AgentCord on [GPUI](https://gpui.rs): Claude, Codex, Cursor, and Grok sessions → Discord Rich Presence.

**Prototype.** Production Windows remains the C# tray app in [`../windows`](../windows). Releases attach `agentcord-gpui.exe` next to `agentcord.exe`; the `agentcord.exe` download URL stays the C# build.

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}`
- Claude / Codex / Cursor / Grok session scans; Cursor turn times from user hooks
- Tray, usage bars, settings (`%APPDATA%\AgentCord\settings.json`)
- Idle window 1–30 min; 24h rolling work duration

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
