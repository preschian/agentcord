# AgentCord — Electron preview

Desktop prototype built with **Electron + Vue 3 + Vite**, scoped to **Codex / OpenAI and Claude subscription usage**. It lives alongside the existing Windows and macOS implementations; it does not replace either app.

## Implemented

- Real usage from Codex's official `app-server` JSONL interface.
- **Claude** 5-hour, weekly, and per-model weekly limits from the same OAuth endpoints Claude Code uses (`/api/oauth/usage` and `/api/oauth/profile`), ported from `windows/ClaudeUsage.cs`. The access token is read from `~/.claude/.credentials.json` (or `$CLAUDE_CONFIG_DIR`) on each poll; it is never refreshed, cached, logged, or sent to the renderer. Same 60-second cooldown, 5-minute visible polling, and 24-hour account-bound cache (`claude-usage-cache.json`) as Codex. macOS keychain credentials are not read yet.
- Primary / secondary subscription limits (usually 5-hour and weekly), plus additional per-model limits when returned by Codex.
- Windows-style **330px light popover**: frameless rounded shell, Noto Sans Mono text, compact main screen, Codex detail screen, and Settings screen.
- Thin blue/orange/red usage bars with Windows-style values (`46% · 6d 22h`); hover for remaining percentage and the local reset date.
- Signed-in account email (masked by default; click to reveal), ChatGPT plan, and additional credits when reported.
- Manual refresh with a 60-second cooldown and concurrent-request deduplication.
- Automatic refresh every 5 minutes while the window is visible and not minimized. Hidden tray ticks only check the local account identity and cache expiry; they do not spawn an app-server.
- Account-bound local cache, valid for at most 24 hours. Cached/offline results are labelled explicitly; logout or an account change clears old data.
- System tray: open, refresh, and quit. Closing the window hides it; use **Quit agentcord** or the tray's **Quit** to exit.
- Content-sized screens, initially anchored above the system tray; drag the header to detach. **Esc** goes back from detail/settings, or hides the main screen. **Alt+F4** quits the app.
- **Launch at login** toggle in Settings (off by default), backed by Electron's login item API on macOS and Windows packaged builds. The state is read from the OS each time, nothing is stored by the app, and a login launch starts hidden in the tray. Linux and unpackaged dev runs show it as unavailable.
- English throughout, including errors, tray actions, tooltips, and countdowns.
- All UI icons use Google's **Material Symbols Rounded**, bundled locally through Fontsource (no Lucide or custom SVG paths). App/header/tray branding remains the original AgentCord logo. Packaged builds include the symbol font license in `resources/licenses/MaterialSymbolsRounded-OFL.txt`.
- Noto Sans Mono variable font, bundled locally through Fontsource. No Google Fonts requests at runtime; the font works offline. Packaged builds include its SIL Open Font License in `resources/licenses/NotoSansMono-OFL.txt`.
- Existing Windows branding reused from `../windows/assets/agentcord.ico` for the executable, tray, app window, and header. The build copies the original multi-size ICO and extracts its embedded PNG frames into ignored `out/assets/`; no duplicate source artwork is committed. Windows loads the ICO directly for native app/tray icons so the OS can select the appropriate size rather than upscale a 16px PNG. The tray icon is reloaded on display-scale changes; other platforms retain PNG representations.
- Settings shows polling/cache behavior and an expandable installation section (Codex home/executable, Claude sign-in location). Unsupported native-app controls (Discord presence, sessions, other agents) are deliberately omitted.

**Not implemented:** Discord Rich Presence, activity/session tracking, providers other than Codex and Claude, OpenAI API-key usage/cost billing, login UI, auto-update, and signed release installers. This is ChatGPT/Codex subscription usage, not the OpenAI API billing dashboard.

## Requirements

- Node.js **22.12+** (Node 24 LTS recommended) and npm.
- Codex CLI installed and logged in with a **ChatGPT account**:

  ```sh
  npm install -g @openai/codex@latest
  codex login
  ```

AgentCord uses the existing Codex login. There is no API-key or OAuth-token input in this application.

## Run

From the repository root:

```sh
cd electron
npm ci
npm run dev
```

The dev script starts the Vite renderer server and Electron. Vue/CSS changes use HMR; main/preload changes rebuild and relaunch Electron. Do not open the Vite URL as a standalone app: the desktop IPC bridge is only available inside Electron.

For a production-renderer build:

```sh
npm run build
npm start
```

On Windows, if the app should outlive a terminal/agent job, build the unpacked app and launch its executable via Explorer:

```powershell
# From electron/
npm run dist
$exe = (Resolve-Path 'release\win-unpacked\AgentCord Electron.exe').Path
Start-Process explorer.exe -ArgumentList "`"$exe`""
```

## Configure Codex discovery

- `CODEX_HOME`: custom Codex data directory; defaults to `~/.codex`.
- `CODEX_BINARY`: absolute path to the Codex **executable**. On Windows use `codex.exe`, not `codex.cmd`.

Set variables **before** launching Electron. Discovery checks `PATH`, common local installations, and Windows npm's native optional package. An app launched from a GUI may have a different `PATH`; use `CODEX_BINARY` if auto-discovery fails.

Example in PowerShell:

```powershell
$env:CODEX_HOME = "$HOME\.codex"
$env:CODEX_BINARY = "$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin\codex.exe"
npm start
```

## Validate & package

```sh
npm run typecheck
npm test
npm run smoke       # Build, fetch real usage, verify all three screens/IPC isolation, then exit
npm run dist        # Unpacked platform app in release/
npm run dist:win    # Portable unsigned Windows executable in release/
```

`smoke` uses a separate temporary user-data directory and writes three screenshots to the OS temp directory: `agentcord-electron-smoke.png`, `agentcord-electron-smoke-detail.png`, and `agentcord-electron-smoke-settings.png`. It tests main/detail/settings navigation, email reveal/remask, English document language, 330px width, bundled text-font loading at weights 400/500/600, all seven Material Symbols ligatures, header/native icon loading and real tray construction (including ICO loading inside ASAR), content-height changes, Escape navigation, signed-out/cached UI states, Node isolation, and resize IPC validation. It never logs email, account ID, credentials, or raw Codex output. The detail screenshot masks the email by default; treat account-related screenshots as private.

Windows is validated locally. macOS/Linux build targets are configured, but have not been validated here. Unsigned builds may trigger SmartScreen or Gatekeeper. `release/`, `out/`, and `node_modules/` are ignored by git.

## Versions

Stable versions resolved from npm at implementation time, pinned in `package.json` and `package-lock.json`:

| Package | Version |
| --- | --- |
| Electron | 44.5.1 |
| Vue | 3.5.43 |
| Fontsource Noto Sans Mono Variable | 5.3.0 |
| Fontsource Material Symbols Rounded Variable | 5.3.8 |
| Vite | 8.3.2 |
| Vue Vite plugin | 6.0.9 |
| vue-tsc | 3.3.11 |
| TypeScript | 6.0.3 |
| electron-builder | 26.15.3 |

TypeScript 6.0.3 is intentional: the latest TypeScript 7.0.2 no longer exposes `typescript/lib/tsc`, which `vue-tsc` 3.3.11 still requires. The three requested frameworks use the latest stable versions. Vite is configured directly rather than using `electron-vite` 5, whose peer range does not support Vite 8.

## Architecture & privacy

```text
src/main/          Electron lifecycle, tray, Codex discovery, JSONL RPC, usage/cache service
src/preload/       Narrow contextBridge API, no filesystem or generic IPC exposure
src/renderer/      Vue popover, Windows-style usage rows/formatting, Settings
src/shared/        Typed display-only state and bridge contract
tests/             Parser, transport, identity, polling/cache, and Windows-format regressions
scripts/dev.mjs    Vite watch/HMR + Electron lifecycle
```

The main process starts a short-lived `codex app-server`, completes `initialize` / `initialized`, then calls `account/read` and `account/rateLimits/read`. Requests have a 15-second overall timeout; the process tree is terminated after the probe. Credentials and refresh behavior remain owned by Codex. No transcript/history trees are scanned.

The main process reads only identity fields from local `auth.json` to detect account changes (and API-key mode); it does not use or refresh access/refresh tokens. The usage cache contains account binding, plan, limits, credits and fetch timestamp, **not tokens or email**, and lives under Electron's `app.getPath('userData')/codex-usage-cache.json`. Cached email is deliberately omitted, so an offline relaunch may show a generic account label until the next successful refresh.

The renderer has Node integration disabled, context isolation and sandboxing enabled, a CSP, denied navigation/popups/permissions, and no arbitrary path/command IPC. All account display data reaches Vue through a typed, sender-validated bridge.
