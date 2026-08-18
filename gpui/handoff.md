# GPUI prototype — what's left

Windows-first AgentCord on [GPUI](https://gpui.rs). Production remains the C# tray app in [`../windows`](../windows). This tree ships Claude, Codex, Cursor, and Grok. Antigravity is out of scope.

## Done

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}` (`src/discord.rs`): handshake, READY, SET_ACTIVITY, ping/pong, reconnect with backoff, clear on quit
- Grok scan (`src/session.rs`): live PID + `last_active_at` / event-file mtimes + open-turn, `summary.json` / `signals.json`
- Cursor scan: `agent-transcripts/**/*.jsonl` + embedded `<timestamp>` + `meta.json`; pick by event time over mtime
- Claude / Codex scan: tree index (30s walk) + jsonl cursor; pick by parsed event time over mtime
- Repo name from `.git/config` origin; 24h rolling working duration for Discord elapsed
- Grok last-known grace after `active_sessions.json` clears; newest `summary.json` fallback
- Winner = newest `activity_ms`; presence payload uses production Discord app id `1517099756063686677`
- Light popover UI (`src/main.rs`): header + status pill, agent rows, Settings (presence + Claude/Codex/Cursor/Grok toggles), agent detail, Quit; all text is Consolas
- Window height follows content (`Window::resize` after layout); width stays 307
- Window / taskbar / tray icon from `assets/agentcord.ico` (same file as `windows/assets/agentcord.ico`)
- Unified usage card: Claude 5h, Codex ChatGPT window, Cursor period, Grok weekly credits; agent detail shows the extra windows; disk cache + 24h staleness
- Plan name / account email on agent detail (masked email, tap to reveal)
- Codex app-server `account/rateLimits/read` first, ChatGPT `wham/usage` fallback
- Claude status card on Claude detail (`status.claude.com` summary, expand + open page)
- Tray tooltip: session line + compact usage, 63-char cap
- Native Windows window move via `WM_SYSCOMMAND` / `SC_MOVE` (GPUI `start_window_move` is Wayland/X11-only)
- Settings persist to `%APPDATA%\AgentCord\settings.json`; launch at login; prevent sleep; display toggles; activity type cycle; idle window ticks 0–30 min
- `WindowKind::PopUp` (no taskbar); close hides to tray; Quit / logoff clears presence; single-instance mutex
- Parser / presence unit tests: `cargo test`

## Not done

Parity gaps vs [`../windows`](../windows). Check those files before reinventing.

### Agents

Cursor jsonl scan is the implementation. Extra Cursor sources are out of scope:

- Cursor via T3 Code sqlite (`windows/T3CursorSession.cs`)
- Cursor ACP live-turn (`windows/CursorSession.cs` `ScanAcp`)
- Cursor model from `store.db` `lastUsedModel` (`LocalSqlite.cs`)

### Session fidelity

Shipped (see Done). Idle window is discrete minute ticks (0/5/10/15/20/25/30), not a WPF slider.

### App shell

Shipped (see Done).

### UI polish

- Size-to-content height: window width stays 307; height is measured from layout and `Window::resize`d (WPF `SizeToContent=Height`)
- Popover text is Consolas (was Segoe UI)
- Fluent UI System Icons (MIT subset TTF) for settings / chevron / folder / sparkle
- Window-chrome corner radius 12: skipped (tried, reverted; leave the GPUI chrome)
- Hide-on-close / stay running in tray (Quit still exits)

### Ship

- [ ] CI job for `gpui/` (release workflow only builds C# + macOS today)
- [ ] Publish `agentcord-gpui.exe` on GitHub Releases
- [ ] Decide whether this replaces `windows/` or stays a prototype

## Known issues

- `gpui::Window::start_window_move` is not a Windows API. Do not call it; it can panic. Native move is `PostMessage(WM_SYSCOMMAND, SC_MOVE | HTCAPTION)` **after** the mouse-down handler returns (`cx.defer`). `SendMessage` re-enters GPUI and crashes.
- Launch the debug exe via Explorer (see root `AGENTS.md`). `cargo run` / a job-owned process can die with the agent session.
- Outer HWND is ~13px wider than the client. Width request is 307; height follows content.
- Discord Rich Presence needs the desktop client, not the browser.

## Run

```powershell
cd gpui
cargo test
cargo build
Start-Process explorer.exe -ArgumentList "`"$((Resolve-Path 'target\debug\agentcord-gpui.exe').Path)`""
```
