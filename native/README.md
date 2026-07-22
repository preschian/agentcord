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
- Auto `SET_ACTIVITY` (model, project, tokens, elapsed) when **Auto presence** is on
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

Not yet: Claude/Codex/Cursor session scanning, settings persistence.

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
(`logo-claude`, `logo-chatgpt`, `logo-cursor`, `logo-grok`) — today only Grok
detection is wired, so live presence uses `logo-grok`.

## Check / build

```sh
native check
native build
```

## Layout

| File | Role |
|---|---|
| `src/main.zig` | Model / Msg / update, Discord + Grok poll loop |
| `src/discord_ipc.zig` | Windows named-pipe Discord RPC client |
| `src/grok_session.zig` | Live Grok session scan (`active_sessions.json`) |
| `src/app.native` | Status UI |
| `app.zon` | App manifest |
