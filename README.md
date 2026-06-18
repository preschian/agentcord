# agentcord

A lightweight macOS menu bar app that shows a Discord Rich Presence while a
Claude Code session is active. When you have Claude Code running, your Discord
profile displays what you are working on (project, model, elapsed time). When no
session is active or the app quits, the presence is cleared.

> Looking to build it from source or understand how it works? See
> [DEVELOPMENT.md](DEVELOPMENT.md).

## Features

- Detects active Claude Code sessions automatically.
- Shows your current project and model, plus the day's total token count and
  combined working time, on your Discord profile (the totals reset at midnight).
- Menu bar only, no Dock icon.
- Auto-reconnects when Discord restarts.
- Clears the presence on idle and on quit so it never gets stuck.
- Optional "Launch at login".

## Requirements

- macOS 13.0 or later.
- The Discord **desktop** client running (Rich Presence does not work with
  Discord web).

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

1. Click the menu bar icon (a sparkles icon) to open the popover.
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
