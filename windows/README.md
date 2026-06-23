# AgentCord for Windows (Rust)

A native, lightweight Windows port of the macOS menu-bar app. Same idea: while a
Claude Code session is running, your Discord profile shows what you're working
on, and it clears itself when the session goes quiet or you quit.

Built in Rust to stay close to the macOS app's ethos — a small single binary,
native APIs, and a hand-written Discord IPC client with no RPC dependencies.

## Status

Feature-complete relative to the macOS app: run it and your active Claude Code
session shows up on your Discord profile, with a system-tray icon and a status
popover (Discord state, project/model/tokens, 5-hour + weekly usage, and
toggles). Release builds are a windowless GUI app with the app icon embedded.

| Component | macOS (Swift) | Windows (Rust) | State |
|---|---|---|---|
| Discord IPC | Unix socket `$TMPDIR/discord-ipc-N` | named pipe `\\.\pipe\discord-ipc-N` | ✅ ported (`discord_ipc.rs`) |
| IPC payload models | `Models.swift` (Codable) | `models.rs` (serde) | ✅ ported |
| Session detection | `FSEvents` on `~/.claude/projects` | timer re-scan of `%USERPROFILE%\.claude\projects` | ✅ ported (`claude_session.rs`) |
| Presence controller | `PresenceController.swift` | `presence_controller.rs` | ✅ ported |
| Settings | `UserDefaults` | JSON in `%APPDATA%\AgentCord` | ✅ ported (`settings.rs`) |
| Tray UI + popover | `MenuBarExtra` + popover | hand-rolled Win32 (`Shell_NotifyIcon`, `WS_POPUP`) | ✅ ported (`tray.rs`) |
| Tray + exe icon | app icon | multi-size `.ico` (tray via `LoadImageW`, exe via `windres` in build.rs) | ✅ done |
| Launch at login | `SMAppService` | `HKCU\...\Run` via `reg.exe` | ✅ ported (`autostart.rs`) |
| Hide console window | — (GUI app) | `#![windows_subsystem = "windows"]` (release) | ✅ done |
| Usage parsing | `ClaudeUsage.swift` (keychain) | `claude_usage.rs` (creds file + `curl`) | ✅ ported |

## Prerequisites

Rust is installed (rustup + stable 1.96). This crate uses the **GNU** toolchain
(`stable-x86_64-pc-windows-gnu`), pinned for the `windows/` directory via
`rustup override`, because it ships a self-contained linker — no Visual Studio
required. The build produces a native Windows `.exe` all the same.

If you'd rather target MSVC later (the more conventional choice for distributed
Windows apps), install the Visual Studio Build Tools with the "Desktop
development with C++" workload to get `link.exe`, then
`rustup override set stable-x86_64-pc-windows-msvc`.

Embedding the **executable icon** (shown in Explorer/taskbar) needs `windres`,
which the GNU toolchain doesn't bundle. Install a mingw-w64 that provides it —
e.g. `winget install BrechtSanders.WinLibs.POSIX.UCRT` — and make sure `windres`
is on `PATH` (or set the `WINDRES` env var to its full path). `build.rs` finds
it automatically; if it's absent the build still succeeds, just with the default
exe icon (the tray icon, loaded at runtime, is unaffected either way).

## Run it

The default (no arguments) launches the tray app — a hidden window plus a
notification-area icon. **Left-click** the icon for a status popover (Discord
connection, current project/model/tokens, and toggles for presence and
launch-at-login); **right-click** for a quick context menu. Needs the Discord
desktop client running (Rich Presence does not work in the browser).

```sh
cd windows
cargo run --release       # windowless tray app (no console)
cargo run                 # debug: same, but keeps a console for the logs
```

Debug builds keep a console so the `[discord]`/`[presence]` logs are visible;
release builds are a GUI app with no console window.

Launch-at-login adds this exe (no args, so it starts in tray mode) to
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## Other modes (debugging)

`main` also exposes headless modes for isolating issues.

**Headless** — same as the tray app but without the icon. Reads settings from
`%APPDATA%\AgentCord\settings.json`, falling back to defaults (including the
shipped Application ID):

```sh
cd windows
cargo run -- run
```

**Session detection** — print the active session whenever it changes (no
Discord needed):

```sh
cargo run -- session
```

**Discord IPC** — connect with an explicit Application ID and set a sample
presence, for isolating transport issues:

```sh
cargo run -- ipc <YOUR_DISCORD_APPLICATION_ID>
```

Ctrl-C to stop any of them.

## Notes on the presence controller

Unlike the macOS app, the controller is single-threaded. A Windows named pipe
opened in the default synchronous mode serializes all I/O on the file object, so
a write blocks behind any in-flight blocking read — a dedicated reader thread
deadlocks the writer. The controller therefore reads frames only until READY
(no write is pending then), then runs a write-only update loop; a failed write
means Discord closed the pipe and triggers a reconnect. See the module header in
`presence_controller.rs` for the full rationale.

## Notes on the tray UI

`tray.rs` is hand-rolled on the raw Win32 API via `windows-sys` — a hidden
message window, `Shell_NotifyIcon` for the notification-area icon, and
`TrackPopupMenu` for the context menu — rather than pulling `tray-icon` +
`winit`, matching the macOS app's minimal-dependency stance. `windows-sys` ships
prebuilt import libraries for the `*-pc-windows-gnu` target, so it links under
the GNU toolchain without `dlltool`. Launch-at-login (`autostart.rs`) shells out
to `reg.exe`, so it needs no registry bindings.

The popover is the Windows analog of the macOS `MenuBarExtra` window: a
borderless `WS_POPUP` window with native child controls (static labels,
auto-checkboxes, push buttons) that anchors to the bottom-right of the work
area and dismisses itself on `WM_ACTIVATE`/`WA_INACTIVE` (focus loss), exactly
like the macOS popover. The controller publishes a `StatusSnapshot` the popover
reads when shown. The tray icon is built from a multi-size `.ico` (generated
from the macOS app-icon PNGs) embedded with `include_bytes!` and loaded via
`LoadImageW` from a temp file — no resource compiler (`windres`) required.

## Notes on usage polling

`claude_usage.rs` shows the `/usage` quotas (5-hour + weekly) in the popover. The
macOS app reads Claude Code's OAuth token from the keychain; on Windows that
token lives in `%USERPROFILE%\.claude\.credentials.json`, so we read it there.
Rather than pull an HTTPS/TLS client crate, we shell out to the `curl.exe`
bundled with Windows to hit the same undocumented OAuth endpoint Claude Code
uses. A background thread polls every 5 minutes (opening the popover triggers a
throttled refresh); a failed poll keeps the last good value. Reset times are
shown relatively ("resets in 1h 20m"), which needs no timezone math. All of this
is best-effort — any failure just shows a dash. Subprocess spawns (`curl`,
`git`, `reg`, `powershell`) use `CREATE_NO_WINDOW` (`util.rs`) so they don't
flash a console in the windowless release build.

## Notes on session detection

`claude_session.rs` re-scans the transcript tree on a timer (the macOS app runs
the same fallback scan; a live `notify` watcher for instant updates can be added
later). It parses each `.jsonl` defensively, sums today's tokens, and computes
the "active work" elapsed timer by summing inter-message gaps while excluding
idle breaks — matching the Swift semantics. Repo names come from `git` (remote,
then toplevel, then the directory). `chrono` is used for timestamp parsing only;
the local UTC offset for the midnight reset is read once via PowerShell so the
build needs no MSVC/mingw toolchain (see the `chrono` note in `Cargo.toml`).

## Notes on the named-pipe port

On Windows a Discord IPC endpoint is a named pipe, which is just a file handle —
so `discord_ipc.rs` opens it with the standard library's `OpenOptions` and reads
and writes through `Read`/`Write`. The 8-byte little-endian frame header, the
handshake, `SET_ACTIVITY`, ping/pong, and clear-on-quit are all unchanged from
the Swift client. The blocking client here is intentionally low-level; the
reconnect-with-backoff loop and threading will live in `presence_controller.rs`,
mirroring how `PresenceController` drives `DiscordIPC` on macOS.
