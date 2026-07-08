# AgentCord for Windows (C# / .NET)

A native Windows port of the macOS menu bar app, written in C# on .NET 8 with
Windows Forms. Same idea: while a Claude Code session is running, your Discord
profile shows what you're working on, and it clears itself when the session
goes quiet or you quit.

The app lives entirely in the system tray — no window, no taskbar entry. It
uses only the .NET base class library (named pipes, `HttpClient`,
`System.Text.Json`, the registry API); the Discord IPC client is hand-written
with no third-party dependencies, matching the macOS app's ethos.

> There is also a Rust port in [`windows/`](../windows). Both implement the
> same feature set and share the settings file at
> `%APPDATA%\AgentCord\settings.json`; this one trades the Rust toolchain for
> the .NET SDK and gets a much smaller codebase in return.

## Feature map

| Component | macOS (Swift) | Windows (C#) |
|---|---|---|
| Discord IPC | Unix socket `$TMPDIR/discord-ipc-N` | named pipe `\\.\pipe\discord-ipc-N` (`DiscordIpc.cs`) |
| IPC payload models | `Models.swift` (Codable) | `Models.cs` (System.Text.Json) |
| Session detection | `FSEvents` on `~/.claude/projects` | timer re-scan of `%USERPROFILE%\.claude\projects` (`ClaudeSession.cs`) |
| Presence controller | `PresenceController.swift` | `PresenceController.cs` |
| Usage limits (5h / weekly / per-model) | `ClaudeUsage.swift` (keychain) | `ClaudeUsage.cs` (credentials file + `HttpClient`) |
| Claude status page | `AnthropicStatus.swift` | `AnthropicStatus.cs` |
| Settings | `UserDefaults` | JSON in `%APPDATA%\AgentCord` (`Settings.cs`) |
| UI | `NSStatusItem` + SwiftUI popover | `NotifyIcon` + native context menu (`TrayApplicationContext.cs`) |
| Launch at login | `SMAppService` | `HKCU\...\Run` via the registry API (`Autostart.cs`) |
| Prevent sleep | `IOPMAssertion` | `SetThreadExecutionState` (`SleepGuard.cs`) |

## Prerequisites

The [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) (or newer).
No Visual Studio required:

```sh
winget install Microsoft.DotNet.SDK.8
```

## Run it

Needs the Discord desktop client running (Rich Presence does not work in the
browser).

```sh
cd windows-native
dotnet run
```

Left- or right-click the tray icon for the menu: connection state, the active
session (project, model, elapsed time, today's tokens), usage limits (5-hour,
weekly, and any per-model weekly windows), the Claude status page summary, and
toggles for presence, launch-at-login, prevent-sleep, display fields, activity
type, and the idle window.

## Build a standalone exe

```sh
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
```

The exe lands in `bin/Release/net8.0-windows/win-x64/publish/`. With
`--self-contained false` it needs the .NET 8 Desktop Runtime on the machine;
use `--self-contained true` for a runtime-free (but larger) binary.

## Notes on the port

**Discord IPC.** On Windows a Discord IPC endpoint is a named pipe
(`\\.\pipe\discord-ipc-{0..9}`). The 8-byte little-endian frame header, the
handshake, `SET_ACTIVITY`, ping/pong, and clear-on-quit are all unchanged from
the Swift client. Unlike the Rust port — which is write-only after READY
because synchronous pipe I/O serializes reads and writes on one file object —
.NET's `NamedPipeClientStream` with `PipeOptions.Asynchronous` uses overlapped
I/O, so the client keeps a concurrent read loop (answering PINGs, catching
ERROR/CLOSE) alongside its writes, matching the macOS design. Reconnects use
exponential backoff capped at 30s, and the current activity is re-sent on
every READY.

**Session detection.** `ClaudeSession.cs` re-scans the transcript tree on the
controller's 3-second tick, parsing each `.jsonl` defensively: today's tokens
are summed across all transcripts, and the elapsed timer reflects combined
working time with idle gaps (>5 min between messages) excluded — matching the
Swift semantics, including the midnight reset. Per-file aggregates are
memoized by mtime so re-scans stay cheap. Repo names come from `git` (remote
origin, then toplevel, then the directory name), spawned with
`CreateNoWindow` so nothing flashes a console.

**Usage limits.** The macOS app reads Claude Code's OAuth token from the
keychain; on Windows that token lives in
`%USERPROFILE%\.claude\.credentials.json`, so `ClaudeUsage.cs` reads it there
and hits the same undocumented endpoint with `HttpClient`. Polls run every 5
minutes (opening the menu triggers a throttled refresh); a failed poll keeps
the last good snapshot for up to 30 minutes before showing a dash. Per-model
weekly windows (e.g. a separate Fable limit) are shown when the plan has them.

**Tray UI.** A `NotifyIcon` with a native `ContextMenuStrip` — informational
rows (session, usage, Claude status) are disabled menu items refreshed while
the menu is open, and settings are checkable items and radio submenus. The
tooltip carries a compact session summary. Opening the menu on left-click uses
the framework's internal `ShowContextMenu` (there is no public API for it).

**Quit behavior.** The presence is cleared synchronously (best-effort, 500ms
budget) on quit and on logoff/shutdown via `Application.ApplicationExit`, so a
dead process doesn't leave a stuck status. A named mutex keeps a second
instance from fighting over the pipe and tray icon.
