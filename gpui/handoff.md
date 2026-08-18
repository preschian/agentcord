# GPUI prototype

Windows-first AgentCord on [GPUI](https://gpui.rs). Production remains the C# tray app in [`../windows`](../windows). This tree ships Claude, Codex, Cursor, and Grok. Antigravity is out of scope.

## Shipped

- Discord IPC on `\\.\pipe\discord-ipc-{0..9}`; production app id `1517099756063686677`
- Session scans: Claude / Codex jsonl, Cursor transcripts + `chats/**/meta.json` + user hooks (`beforeSubmitPrompt` / `stop`), Grok live PID + last-known
- Idle window ticks 1 / 5 / 10 / 15 / 20 / 25 / 30 min; 24h rolling work duration (stamp gaps ≤5 min, Cursor prefers hook turn intervals)
- Tray + taskbar, settings in `%APPDATA%\AgentCord\settings.json`, usage bars, Claude status, Fluent icons, Consolas
- Close hides to tray; Quit / logoff clears presence; scans off the UI thread

## Leftover

[Issue #115](https://github.com/preschian/agentcord/issues/115): CI for `gpui/`, release `agentcord-gpui.exe`, decide whether this replaces `windows/`.

Skipped: Cursor T3 sqlite, ACP `ScanAcp`, `store.db` `lastUsedModel`.

## Known issues

- `gpui::Window::start_window_move` is not a Windows API. Native move is `PostMessage(WM_SYSCOMMAND, SC_MOVE | HTCAPTION)` after mouse-down returns (`cx.defer`).
- Launch the debug exe via Explorer (root `AGENTS.md`). `cargo run` can die with the agent job.
- Discord Rich Presence needs the desktop client, not the browser.

## Run

```powershell
cd gpui
cargo test
cargo build
Start-Process explorer.exe -ArgumentList "`"$((Resolve-Path 'target\debug\agentcord-gpui.exe').Path)`""
```
