# AgentCord for Windows (C# / .NET)

A native Windows port of the macOS menu bar app, written in C# on .NET 10. Same
idea: while a Claude Code, Codex, Cursor, Grok, or Antigravity session is running, your Discord
profile shows what you're working on, and it clears itself when the session
goes quiet or you quit. Cursor is active only while a hook turn is open.
If several agents are active, the most recently updated
session wins.

The app lives entirely in the system tray — no taskbar entry. Left-clicking the
tray icon opens a popover that mirrors the macOS one: an agent list that opens
a settings-style detail screen, optional unified usage summary, colored usage
bars, an expandable Claude status breakdown, and a settings screen with
iOS-style switches.

It uses the .NET base class library (WinForms for the tray icon, WPF for the
popover, named pipes, `HttpClient`, `System.Text.Json`, the registry API) plus
`Microsoft.Data.Sqlite` to read Cursor's local dashboard DB read-only. The
Discord IPC client is hand-written.

## Feature map

| Component | macOS (Swift) | Windows (C#) |
|---|---|---|
| Discord IPC | Unix socket `$TMPDIR/discord-ipc-N` | named pipe `\\.\pipe\discord-ipc-N` (`DiscordIpc.cs`) |
| IPC payload models | `Models.swift` (Codable) | `Models.cs` (System.Text.Json) |
| Session detection | `FSEvents` on agent data; Cursor from `$TMPDIR/AgentCord/yyyy-MM-dd-uptime.json` | timer re-scan of `%USERPROFILE%\.claude\projects`, `%USERPROFILE%\.codex\sessions`, `%TEMP%\AgentCord\yyyy-MM-dd-uptime.json` (Cursor hooks), `%USERPROFILE%\.grok\active_sessions.json`, and `%USERPROFILE%\.gemini\antigravity-cli` (`ClaudeSession.cs`, `CodexSession.cs`, `CursorSession.cs`, `GrokSession.cs`, `AntigravitySession.cs`) |
| Presence controller | `PresenceController.swift` | `PresenceController.cs` |
| Usage limits (5h / weekly / per-model) | provider usage pollers | `ClaudeUsage.cs`, `CodexUsage.cs` (`codex app-server`), `CursorUsage.cs` (`auth.json` / dashboard API), `GrokUsage.cs` (`~/.grok/auth.json` / SuperGrok billing API), and `AntigravityUsage.cs` (`agy /usage`) |
| Claude status page | `AnthropicStatus.swift` | `AnthropicStatus.cs` |
| Settings | `UserDefaults` | JSON in `%APPDATA%\AgentCord` (`Settings.cs`) |
| UI | `NSStatusItem` + SwiftUI popover | `NotifyIcon` (`TrayApplicationContext.cs`) + WPF popover (`PopoverWindow.xaml`) |
| Launch at login | `SMAppService` | `HKCU\...\Run` via the registry API (`Autostart.cs`) |

## Prerequisites

The [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) (or newer).
No Visual Studio required:

```sh
winget install Microsoft.DotNet.SDK.10
```

## Run it

Needs the Discord desktop client running (Rich Presence does not work in the
browser).

```sh
cd windows
dotnet run
```

**Left-click** the tray icon for the popover: connection pill, optional unified
usage card (one primary bar per linked agent), a row per enabled agent that
opens a detail screen (session, usage, and Claude status), and a Settings
screen with agent toggles, presence, launch-at-login, display
fields (including Show unified usage), and activity type.
**Right-click** for a quick menu (show, toggle presence, quit).

Two debug flags: `--popover` opens the popover at startup, and
`--screenshot <path>` renders the main, agent-detail, and settings screens to
PNGs off-screen and exits (no tray interaction, no focus steal).

## Build a standalone exe

The release build (see [`.github/workflows/release.yml`](../.github/workflows/release.yml))
is a framework-dependent single file — a few MB, and it needs the [.NET 10
Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0) on the target
machine (`winget install Microsoft.DotNet.DesktopRuntime.10`):

```sh
dotnet publish -c Release -r win-x64 --self-contained false \
  -p:PublishSingleFile=true
```

The exe lands in `bin/Release/net10.0-windows/win-x64/publish/`.

Add `--self-contained true -p:IncludeNativeLibrariesForSelfExtract=true` to get
an exe that runs with no runtime installed, at ~150 MB. WPF and WinForms support
neither trimming nor NativeAOT, so bundling the runtime is all-or-nothing;
`-p:EnableCompressionInSingleFile=true` brings that down to roughly 60-70 MB but
no further.

## Notes on the port

**Discord IPC.** On Windows a Discord IPC endpoint is a named pipe
(`\\.\pipe\discord-ipc-{0..9}`). The 8-byte little-endian frame header, the
handshake, `SET_ACTIVITY`, ping/pong, and clear-on-quit are all unchanged from
the Swift client. .NET's `NamedPipeClientStream` with `PipeOptions.Asynchronous`
uses overlapped I/O (a synchronous pipe would serialize reads and writes on one
file object and deadlock a reader against a writer), so the client keeps a
concurrent read loop (answering PINGs, catching
ERROR/CLOSE) alongside its writes, matching the macOS design. Reconnects use
exponential backoff capped at 30s, and the current activity is re-sent on
every READY.

**Session detection.** `ClaudeSession.cs`, `CodexSession.cs`, `CursorSession.cs`,
and `GrokSession.cs` re-scan their data on the
controller's 3-second tick and parse defensively. Claude sums tokens over the
local calendar day and working time since local midnight; Codex reports the
current transcript's model, latest context token count, and today's working
sum; Cursor sums today's hook `start`/`end` diffs
from `%TEMP%\AgentCord\yyyy-MM-dd-uptime.json`; Grok uses
`last_active_at` and event-log mtimes (a live PID alone is not enough) and reads
`summary.json` / `signals.json` for project, model, and context tokens.
Per-file aggregates are memoized by mtime so re-scans stay cheap. Repo names come from `git`
(remote origin, then toplevel, then the directory name), spawned with
`CreateNoWindow` so nothing flashes a console.

**Usage limits.** The macOS app reads Claude Code's OAuth token from the
keychain; on Windows that token lives in
`%USERPROFILE%\.claude\.credentials.json`, so `ClaudeUsage.cs` reads it there
and hits the same undocumented endpoint with `HttpClient`. Polls run every 5
minutes (opening the menu triggers a throttled refresh); a failed poll keeps
the last good snapshot for up to 30 minutes before showing a dash. Per-model
weekly windows (e.g. a separate Fable limit) are shown when the plan has them.
Codex usage is requested through Codex's local `app-server` JSONL protocol, so
AgentCord does not read or refresh ChatGPT credentials itself. Grok weekly
credits come from `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits`
using the OIDC tokens in `%USERPROFILE%\.grok\auth.json` (refreshed on 401).

**UI.** WinForms owns the tray icon and the message loop; the popover is a WPF
window (`PopoverWindow.xaml`) on that same thread, which is what makes the
macOS look reachable — rounded cards, drop shadow, capsule pills, custom
toggle switches, agent rows that open a detail screen, the unified usage card, and progress
bars whose fill is a star-sized grid column. It is borderless and transparent, shows on the taskbar like a normal window,
and stays open when you click elsewhere (Escape or a second tray click hides
it). It anchors itself to the bottom-right work-area corner on open and
re-anchors whenever a section expands, so it grows upward.

The folder glyph (`E8B7`) is a real folder only in Segoe Fluent Icons
(Windows 11); the style falls back to Segoe MDL2 Assets on Windows 10.

**Quit behavior.** The presence is cleared synchronously (best-effort, 500ms
budget) on quit and on logoff/shutdown via `Application.ApplicationExit`, so a
dead process doesn't leave a stuck status. A named mutex keeps a second
instance from fighting over the pipe and tray icon.
