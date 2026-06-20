# Development

Technical documentation for building, signing, and understanding agentcord. For
the user-facing overview and setup, see [README.md](README.md).

Pure Swift + SwiftUI. The Discord IPC client is hand-written from scratch with
zero third-party dependencies. Native frameworks only.

## Requirements

- macOS 13.0 or later.
- Xcode 15 or later to build.

## Build and run

```sh
xcodebuild -project AgentCord.xcodeproj -scheme AgentCord -configuration Debug build
```

Or open `AgentCord.xcodeproj` in Xcode and press Run. The app appears in the
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
`AgentCord/AgentCord.entitlements`). Do not enable it.

For local development the project signs with "Sign to Run Locally" and Hardened
Runtime is off. If you later distribute the app, sign with your Developer ID and
turn Hardened Runtime on; the no-sandbox requirement still applies.

## How it works

Five small components plus the SwiftUI app shell:

- `DiscordIPC.swift` - the raw IPC client: socket discovery
  (`discord-ipc-0` through `discord-ipc-9` under `XDG_RUNTIME_DIR` / `TMPDIR` /
  `TMP` / `TEMP` / `/tmp`), the 8-byte little-endian frame header, the
  handshake, `SET_ACTIVITY`, ping/pong, reconnect with exponential backoff, and
  clearing. All socket I/O runs off the main thread.
- `ClaudeSession.swift` - watches `~/.claude/projects/` with `FSEvents` plus a
  periodic re-scan. The most recently modified `.jsonl` transcript defines the
  active session (project + model), while tokens and the elapsed timer are
  aggregated across every transcript touched on the current local calendar day:
  tokens are summed, and the timer reflects the combined working time of all of
  today's sessions (idle gaps between sessions excluded). Per-file parse results
  are memoized (keyed by modification time and the day boundary) so each scan
  only re-reads files that actually changed. Parsing is defensive: malformed or
  unexpected lines are skipped, never fatal.
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
  window (default 5 min, configurable 5-30 min in 5-minute steps).
- Token and elapsed-time totals cover the current local calendar day and reset
  at midnight. Only the portion of a session that falls on the current day is
  counted, so a session spanning midnight contributes only its post-midnight
  time and tokens.
- Discord throttles rapid activity updates, so updates are debounced.
