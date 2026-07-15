# Contributing

Technical documentation for building, signing, and understanding agentcord. For the user-facing overview and setup, see [README.md](README.md).

Pure Swift + SwiftUI. The Discord IPC client is hand-written from scratch with zero third-party dependencies. Native frameworks only.

## Requirements

- macOS 13.0 or later.
- Xcode 15 or later to build.
- The Discord desktop client running. Rich Presence does not work with Discord in the browser.

## Build and run

```sh
xcodebuild -project macos/AgentCord.xcodeproj -scheme AgentCord -configuration Debug build
```

Or open `macos/AgentCord.xcodeproj` in Xcode and press Run. The app appears in the menu bar (a sparkles icon); there is no Dock icon and no app window.

## Releases

Prebuilt macOS (`.dmg`) and Windows (`.exe`) binaries are published on [GitHub Releases](https://github.com/preschian/agentcord/releases). They are not checked into git.

To cut a release, push a semver tag (`v*`):

```sh
git tag v0.1.0
git push origin v0.1.0
```

The [release workflow](.github/workflows/release.yml) builds both platforms and attaches `AgentCord.dmg` and `agentcord.exe` to the release. You can also trigger it manually from the Actions tab with a tag name.

Windows install notes (including SmartScreen) live in [windows/dist/README.md](windows/dist/README.md).

## One-time Discord setup

You do this once, by hand, in Discord's developer portal.

1. Create an application at https://discord.com/developers/applications. A personal app needs no Team.
2. Copy the **Application ID**. This is the Client ID the app asks for.
3. Under **Rich Presence > Art Assets**, upload your images and note their asset keys. The app defaults to `claude` for the large image and `coding` for the small one. Those keys are what `large_image` and `small_image` reference, so either name your uploads to match or change the keys in Settings.
4. Make sure the Discord desktop client is running.

## Using the app

1. Click the menu bar icon (a sparkles icon) to open the popover.
2. Expand **Settings**, paste your **Application ID**, and press Return to apply it. This connects to Discord.
3. Choose what to display: project, model, tokens, the activity type, the idle window, and the image asset keys.
4. Toggle **Enable presence** on. Toggle **Launch at login** to start the app automatically when you log in.

Once Discord is running and a Claude Code session is active, the presence shows up on your profile. It clears again when the session goes idle (no transcript activity within the idle window) or when you quit the app.

## App Sandbox: keep it OFF

This app is **not** sandboxed, and it must stay that way. This is a non App Store menu bar utility signed with a Developer ID (or run unsigned locally).

Why it matters:

- Discord exposes its IPC socket inside the system temp directory (`$TMPDIR/discord-ipc-N`). A sandboxed app gets a redirected `$TMPDIR` pointing into its own container, so it would never find Discord's socket and the connection would silently fail.
- The app also needs to read `~/.claude/projects/`, which a sandbox would block.

The Xcode project ships with App Sandbox disabled (see `macos/AgentCord/AgentCord.entitlements`). Do not enable it.

For local development the project signs with "Sign to Run Locally" and Hardened Runtime is off. If you later distribute the app, sign with your Developer ID and turn Hardened Runtime on; the no-sandbox requirement still applies.

## How it works

Five small components plus the SwiftUI app shell:

- `DiscordIPC.swift` - the raw IPC client: socket discovery (`discord-ipc-0` through `discord-ipc-9` under `XDG_RUNTIME_DIR` / `TMPDIR` / `TMP` / `TEMP` / `/tmp`), the 8-byte little-endian frame header, the handshake, `SET_ACTIVITY`, ping/pong, reconnect with exponential backoff, and clearing. All socket I/O runs off the main thread.
- `ClaudeSession.swift` - watches `~/.claude/projects/` with `FSEvents` plus a periodic re-scan. The most recently modified `.jsonl` transcript defines the active session (project + model), while tokens and the elapsed timer are aggregated across every transcript touched on the current local calendar day: tokens are summed, and the timer reflects the combined working time of all of today's sessions (idle gaps between sessions excluded). Per-file parse results are memoized (keyed by modification time and the day boundary) so each scan only re-reads files that actually changed. Parsing is defensive: malformed or unexpected lines are skipped, never fatal.
- `CodexSession.swift` - first connects to an existing Codex App Server daemon and reads official runtime thread status. Standalone CLI processes do not share that runtime, so it falls back to watching `~/.codex/sessions/` transcripts. Transcript data enriches both paths with cwd, model, timestamps, and token totals.
- `GrokSession.swift` - watches `~/.grok/active_sessions.json` and per-session `summary.json` / `signals.json` under `~/.grok/sessions/`. Live PIDs in the active-sessions list are authoritative; summary timestamps and context-window signals enrich project, model, and token fields. Falls back briefly to the last-known session during the idle grace period after a quit.
- `PresenceController.swift` - observes Claude, Codex, and Grok sessions, selects the most recently active enabled agent, builds the activity from your settings, debounces updates (at most roughly once every few seconds, and only when the content actually changes), and clears on idle or quit.
- `Settings.swift` - persisted settings (`UserDefaults`).
- `Models.swift` - the Codable IPC payload structs.
- `App.swift` - the `MenuBarExtra` UI and app lifecycle.

## Notes and limitations

- The Claude Code transcript schema is undocumented and may change. The parser tolerates missing keys and unknown event types.
- Codex App Server runtime status is authoritative when AgentCord can connect to the managed daemon. A separately launched Codex CLI is detected through its local transcript because independent CLI processes are not visible as loaded threads in another App Server instance.
- The Codex transcript fallback uses an internal on-disk format that may change. Its parser is defensive and only reads session metadata, turn context, timestamps, and token usage.
- A Claude or Codex session is considered active if its transcript was modified within the idle window (default 5 min, configurable 5-30 min in 5-minute steps). A Grok session stays active while its process is listed in `active_sessions.json` with a live PID, or for the same idle window after that list clears.
- For Claude Code, token and elapsed-time totals cover the current local calendar day and reset at midnight. Only the portion of a session that falls on the current day is counted, so a session spanning midnight contributes only its post-midnight time and tokens. Codex and Grok report the current session's context tokens instead.
- Discord throttles rapid activity updates, so updates are debounced.
