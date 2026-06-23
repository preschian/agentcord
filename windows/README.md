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
| Tray UI + popover | `MenuBarExtra` + popover | `eframe`/`egui` popover + `tray-icon` | ✅ ported (`tray.rs`) |
| Tray + exe icon | app icon | multi-size `.ico` (exe via `windres`) + PNG (tray/window via `image`) | ✅ done |
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

**mingw-w64 is required on PATH.** The GUI crates (`eframe`/`tray-icon` →
`windows-*`) generate import libraries at build time with `dlltool`, which the
Rust GNU toolchain doesn't bundle. Install a mingw-w64 that provides it (and
`windres`, used to embed the exe icon):

```sh
winget install BrechtSanders.WinLibs.POSIX.UCRT
```

Then make sure its `mingw64\bin` is on `PATH` (winget adds it). `build.rs` finds
`windres` there automatically (or set the `WINDRES` env var to its full path); if
`windres` is missing the build still succeeds, just with the default exe icon.

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

`tray.rs` is an `eframe`/`egui` app with a `tray-icon` notification-area icon —
chosen over a hand-rolled Win32 popover so the popover can match the macOS
`MenuBarExtra` look (rounded cards, a status pill, colored usage bars). The
window starts hidden and is shown bottom-right (above the taskbar, positioned
from the Win32 work area) on a tray left-click, dismissing itself when it loses
focus. The presence controller and usage poller run on background threads and
publish into `SharedState`; the egui UI reads that each frame and renders.

Two egui quirks worth noting: the light theme is forced every frame with
`ctx.set_theme(ThemePreference::Light)` (eframe otherwise follows the OS dark
theme), and the status dot is painted (egui's default font lacks `●`). The tray
and window icons are decoded from embedded PNGs with the `image` crate.

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
