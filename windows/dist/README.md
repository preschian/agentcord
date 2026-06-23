# AgentCord for Windows — prebuilt

`agentcord.exe` is a standalone, self-contained build — copy it anywhere and
run it. No installer, runtime, or extra DLLs needed (it only uses DLLs that ship
with Windows 10/11).

## Requirements

- Windows 10 or 11 (x64)
- **Discord desktop** running (Rich Presence does not work in the browser)
- **Claude Code** installed (it reads `%USERPROFILE%\.claude\`)

## Run

Double-click `agentcord.exe`. It lives in the system tray (no window):

- **Left-click** the tray icon for the status popover (Discord connection,
  current project / model / tokens, 5-hour + weekly usage). Click **Settings**
  to expand the options panel; tick **Launch at login** to auto-start.
- **Right-click** for a quick menu.

While a Claude Code session is active, your Discord profile shows what you're
working on; it clears when the session goes idle or you quit.

## First-run note

This build is **not code-signed**, so Windows SmartScreen may warn
"unknown publisher" the first time. Click **More info → Run anyway**.

Settings are stored at `%APPDATA%\AgentCord\settings.json`.
