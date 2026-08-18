# GPUI prototype — what's left

Windows-first AgentCord on [GPUI](https://gpui.rs). Production remains the C# tray app in [`../windows`](../windows). This tree ships Claude, Codex, Cursor, and Grok. Antigravity is out of scope.

## Done

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}` (`src/discord.rs`): handshake, READY, SET_ACTIVITY, ping/pong, reconnect with backoff, clear on quit
- Grok scan (`src/session.rs`): live PID + `last_active_at` / event-file mtimes + open-turn, `summary.json` / `signals.json`
- Cursor scan: newest `~/.cursor/projects/**/agent-transcripts/**/*.jsonl` within a 5-minute idle window, `meta.json` cwd / timestamps
- Claude scan: newest `~/.claude/projects/**/*.jsonl`, tail parse for cwd / model / tokens / event timestamps
- Codex scan: newest `~/.codex/sessions/**/*.jsonl` (`CODEX_HOME` honored), tail parse for `session_meta` / `turn_context` / `token_count`
- Winner = newest `activity_ms`; presence payload uses production Discord app id `1517099756063686677`
- Light popover UI (`src/main.rs`): header + status pill, agent rows, Settings (presence + Claude/Codex/Cursor/Grok toggles), agent detail, Quit
- Native Windows window move via `WM_SYSCOMMAND` / `SC_MOVE` (GPUI `start_window_move` is Wayland/X11-only)
- Parser / presence unit tests: `cargo test`

## Not done

Parity gaps vs [`../windows`](../windows). Check those files before reinventing.

### Agents

Cursor jsonl scan is the implementation. Extra Cursor sources are out of scope:

- Cursor via T3 Code sqlite (`windows/T3CursorSession.cs`)
- Cursor ACP live-turn (`windows/CursorSession.cs` `ScanAcp`)
- Cursor model from `store.db` `lastUsedModel` (`LocalSqlite.cs`)

### Session fidelity

- [ ] Configurable idle window (production default 300s is hardcoded; Settings slider 0–30 min)
- [ ] 24h rolling working duration / Discord elapsed (`windows/SessionActivity.cs`) — GPUI uses `opened_at` / `createdAtMs` / first tail timestamp
- [ ] Grok last-known grace after `active_sessions.json` clears (`GrokSession.cs`)
- [ ] Cursor embedded `<timestamp>` stamps + tree index memoization (`JsonlCursor.cs`, `SessionTreeIndex.cs`)
- [ ] Repo name from `.git/config` origin (`RepoNames.cs`) — GPUI only uses first `git_remotes` entry or basename
- [ ] Claude/Codex: prefer parsed event timestamps over mtime when picking which transcript is newest (today: newest by mtime, then tail timestamps for idle)

### Usage + status

- [ ] Unified usage card on the main screen
- [ ] Grok weekly credits (`windows/GrokUsage.cs`)
- [ ] Cursor period usage (`windows/CursorUsage.cs`)
- [ ] Claude / Codex usage pollers
- [ ] Claude status page (`windows/AnthropicStatus.cs`)

### App shell

- [ ] System tray, no taskbar entry (`windows/TrayApplicationContext.cs`)
- [ ] Settings persistence (`%APPDATA%\AgentCord\settings.json`, `windows/Settings.cs`)
- [ ] Launch at login (`windows/Autostart.cs`)
- [ ] Prevent sleep (`windows/SleepGuard.cs`)
- [ ] Display toggles: show project / model / tokens / unified usage
- [ ] Activity type cycle (Playing / Listening / Watching / Competing)
- [ ] Single-instance mutex
- [ ] Clear presence on logoff / shutdown with a short sync budget

### UI polish

- [ ] Size-to-content height (production popover is `Width=330` + `SizeToContent=Height`)
- [ ] Segoe Fluent / MDL2 glyphs — GPUI cannot render those PUA codepoints (they became boxes); current UI uses `⚙ › ‹ ⊞`
- [ ] Window-chrome corner radius 12 to match the WPF card (tried, reverted)
- [ ] Hide-on-close / stay running in tray

### Ship

- [ ] CI job for `gpui/` (release workflow only builds C# + macOS today)
- [ ] Publish `agentcord-gpui.exe` on GitHub Releases
- [ ] Decide whether this replaces `windows/` or stays a prototype

## Known issues

- `gpui::Window::start_window_move` is not a Windows API. Do not call it; it can panic. Native move is `PostMessage(WM_SYSCOMMAND, SC_MOVE | HTCAPTION)` **after** the mouse-down handler returns (`cx.defer`). `SendMessage` re-enters GPUI and crashes.
- Launch the debug exe via Explorer (see root `AGENTS.md`). `cargo run` / a job-owned process can die with the agent session.
- Outer HWND is ~13px wider than the client. Current request is 307×380 so four agent rows fit.
- Discord Rich Presence needs the desktop client, not the browser.

## Run

```powershell
cd gpui
cargo test
cargo build
Start-Process explorer.exe -ArgumentList "`"$((Resolve-Path 'target\debug\agentcord-gpui.exe').Path)`""
```
