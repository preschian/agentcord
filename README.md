# agentcord

A lightweight macOS menu bar app that shows a Discord Rich Presence while a
Claude Code session is active. When you have Claude Code running, your Discord
profile displays what you are working on (project, model, elapsed time). When no
session is active or the app quits, the presence is cleared.

Pure Swift + SwiftUI. The Discord IPC client is hand-written from scratch with
zero third-party dependencies. Native frameworks only.

## Features

- Detects active Claude Code sessions by watching `~/.claude/projects/`.
- Talks to the local Discord desktop client over its Unix domain socket (IPC).
- Shows project, model, token count, and an elapsed timer.
- Menu bar only, no Dock icon.
- Auto-reconnects when Discord restarts.
- Clears the presence on idle and on quit so it never gets stuck.
- Optional "Launch at login" (via `SMAppService`).

## Requirements

- macOS 13.0 or later.
- Xcode 15 or later to build.
- The Discord **desktop** client running (Rich Presence does not work with
  Discord web).

## Build and run

```sh
xcodebuild -project ClaudeCodeRPC.xcodeproj -scheme ClaudeCodeRPC -configuration Debug build
```

Or open `ClaudeCodeRPC.xcodeproj` in Xcode and press Run. The app appears in the
menu bar (a sparkles icon); there is no Dock icon and no app window.

## App Sandbox: keep it OFF

This app is **not** sandboxed, and it must stay that way. This is a non App
Store menu bar utility signed with a Developer ID (or run unsigned locally).

Why it matters:

- Discord exposes its IPC socket inside the system temp directory
  (`$TMPDIR/discord-ipc-N`). A sandboxed app gets a redirected `$TMPDIR`
  pointing into its own container, so it would never find Discord's socket and
  the connection would silently fail.
- The app also needs to read `~/.claude/projects/`, which a sandbox would block.

The Xcode project ships with App Sandbox disabled (see
`ClaudeCodeRPC/ClaudeCodeRPC.entitlements`). Do not enable it.

For local development the project signs with "Sign to Run Locally" and Hardened
Runtime is off. If you later distribute the app, sign with your Developer ID and
turn Hardened Runtime on; the no-sandbox requirement still applies.

## One-time Discord setup (you do this manually)

1. Create an application at https://discord.com/developers/applications. No Team
   is required for a personal app.
2. Copy the **Application ID** (this is the Client ID).
3. Under **Rich Presence > Art Assets**, upload your images and note their asset
   keys. The defaults this app uses are `claude` (large image) and `coding`
   (small image). These keys are what `large_image` / `small_image` reference,
   so either name your uploads to match or change the keys in Settings.
4. Make sure the Discord desktop client is running.

## Using the app

1. Click the menu bar icon to open the popover.
2. Expand **Settings** and paste your **Application ID**, then press Return to
   apply it (this connects to Discord).
3. Choose what to display: project, model, tokens, the activity type, the idle
   window, and the image asset keys.
4. Toggle **Enable presence** on. Toggle **Do not disturb** to pause updates
   without disconnecting. Toggle **Launch at login** to start the app
   automatically when you log in.

Once Discord is running and a Claude Code session is active, your profile shows
the presence with project, model, and an elapsed timer. When the session goes
idle (no transcript activity within the idle window) or you quit the app, the
presence clears.

## How it works

Five small components plus the SwiftUI app shell:

- `DiscordIPC.swift` - the raw IPC client: socket discovery
  (`discord-ipc-0` through `discord-ipc-9` under `XDG_RUNTIME_DIR` / `TMPDIR` /
  `TMP` / `TEMP` / `/tmp`), the 8-byte little-endian frame header, the
  handshake, `SET_ACTIVITY`, ping/pong, reconnect with exponential backoff, and
  clearing. All socket I/O runs off the main thread.
- `ClaudeSession.swift` - watches `~/.claude/projects/` with `FSEvents` plus a
  periodic re-scan, finds the most recently modified `.jsonl` transcript, and
  parses project, model, session start, and token totals. Parsing is defensive:
  malformed or unexpected lines are skipped, never fatal.
- `PresenceController.swift` - observes the session, builds the activity from
  your settings, debounces updates (at most roughly once every few seconds, and
  only when the content actually changes), and clears on idle or quit.
- `Settings.swift` - persisted settings (`UserDefaults`).
- `Models.swift` - the Codable IPC payload structs.
- `App.swift` - the `MenuBarExtra` UI and app lifecycle.

## Notes and limitations

- The Claude Code transcript schema is undocumented and may change. The parser
  tolerates missing keys and unknown event types.
- A session is considered active if its transcript was modified within the idle
  window (default 60s, configurable 15-300s).
- Discord throttles rapid activity updates, so updates are debounced.
