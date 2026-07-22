# AgentCord Native (prototype)

Native SDK port of AgentCord — **Windows first**, starting with Discord Rich Presence only.

This lives beside the production C# app in [`../windows`](../windows). The C# build remains the working Windows release until this path covers session detection, tray UI, and settings.

## Phase 1 — Discord presence

- Connect to Discord IPC via named pipe (`\\.\pipe\discord-ipc-0` … `9`)
- Handshake + READY
- `SET_ACTIVITY` / clear / reconnect with exponential backoff

## Phase 2 — Grok session detection

- Read `%USERPROFILE%\.grok\active_sessions.json`
- Treat a session as active when its PID is still alive
- Enrich from `sessions/<encoded-cwd>/<id>/summary.json` + `signals.json`
- Auto `SET_ACTIVITY` (model, project, tokens, elapsed) when presence is on
- Clear presence when the Grok process exits

## Phase 3 — System tray

- Status item / notification-area icon (`assets/icon.png`)
- Tray menu: **Open AgentCord**, **Quit**
- Window close **hides** (keeps running in tray); Open shows the window again

## Phase 4 — Grok usage

- Session context % from `signals.json` (`contextWindowUsage`)
- Weekly SuperGrok/CLI credits via billing API (`creditUsagePercent` + period end → “resets in …”)
- Auth from `~/.grok/auth.json` (refresh token on 401)
- Refresh button + auto poll every 5 minutes

## Phase 5 — Cursor session detection + macOS-like UI

- Scan `%USERPROFILE%\.cursor\projects\**\agent-transcripts\**\*.jsonl` (mtime within 60s)
- Enrich from `~/.cursor\chats\**\<session-id>\meta.json`
- Grok | Cursor switcher; Discord `logo-cursor` when Cursor wins
- Popover-style window (header, session card, usage bars, Settings)

## Phase 6 — Cursor usage

- Token from `%APPDATA%\Cursor\auth.json` or `state.vscdb` (`cursorAuth/accessToken`)
- `GetCurrentPeriodUsage` → included / auto / API / on-demand bars

Not yet: settings persistence.

## Prerequisites

- [Node.js](https://nodejs.org/) 22.15+ (CLI only; the shipped binary has no JS runtime)
- Zig **0.16.0** (`native` downloads it if missing)
- Discord **desktop** client running (Rich Presence does not work in the browser)

```sh
npm install -g @native-sdk/cli
```

## Run

```sh
cd native
native dev
```

With Discord desktop open and a Grok CLI session running, the window should show **Grok: active** and push presence automatically. Toggle **Auto presence from Grok** off to stop.

Uses the AgentCord Discord Application ID. Large-image assets are per agent
(`logo-codex`, `logo-cursor`, `logo-grok`) — today Codex, Cursor, and Grok
detection is wired, so live presence uses `logo-grok`.

## Check / build

```sh
native check
native build
```

## Layout

| File | Role |
|---|---|
| `src/main.zig` | Msg / update / usage fetch orchestration |
| `src/app_model.zig` | Model + chrome / session / usage projection |
| `src/usage_fx.zig` | Shared usage fetch helpers (Grok + Cursor) |
| `src/presence.zig` | Presence mode + session→Activity policy |
| `src/discord_ipc.zig` | Windows named-pipe Discord RPC client |
| `src/grok_session.zig` | Live Grok session scan (`active_sessions.json`) |
| `src/cursor_session.zig` | Live Cursor transcript scan (`~/.cursor`) |
| `src/cursor_usage.zig` | Cursor auth stores + period/legacy usage |
| `src/grok_usage.zig` | Auth + billing parse / header budget |
| `src/json_lite.zig` | Shared JSON scrapers |
| `src/win32_fs.zig` | Shared Win32 file / env / process helpers |
| `src/app.native` | macOS-like status UI |
| `app.zon` | App manifest |
