# Agent instructions

Guidelines for coding agents working in this repository. For build, signing, and architecture details, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Conventional Commits

Use the [Conventional Commits](https://www.conventionalcommits.org/) format for:

- **Commit messages**
- **PR titles**
- **PR descriptions** (the summary line should follow the same convention)

Format:

```
<type>(<optional scope>): <description>
```

Common types: `feat`, `fix`, `docs`, `refactor`, `chore`, `test`, `ci`. Use a scope when the change targets one platform, e.g. `feat(macos): ...` or `fix(windows): ...`.

Examples from this repo's history:

```
feat(macos): add Cursor active session tracking
fix(windows): handle missing Discord IPC socket
docs: clarify one-time Discord setup
```

## Relaunch the app after every change

After every change under `macos/` or `windows/`, rebuild and relaunch the app so the change is actually running. Other trees build differently — `web/` (bun), `native/` (zig); see each directory's `README.md`.

### macOS

```sh
pkill -x AgentCord || true
xcodebuild -project macos/AgentCord.xcodeproj -scheme AgentCord -configuration Debug build
open "$(xcodebuild -project macos/AgentCord.xcodeproj -scheme AgentCord -configuration Debug -showBuildSettings | awk '$1 == "BUILT_PRODUCTS_DIR" {print $3}')/AgentCord.app"
```

The app is a menu bar utility (sparkles icon) — it has no Dock icon or window, so check the menu bar to confirm it relaunched.

### Windows

Run the built `WinExe` directly — do **not** use `dotnet run`, which opens a console host window.

```powershell
Get-Process -Name AgentCord -ErrorAction SilentlyContinue | Stop-Process -Force
dotnet build windows -c Debug --nologo
Start-Process "windows\bin\Debug\net8.0-windows\AgentCord.exe"
```

The app lives in the system tray (no taskbar entry) — check the tray to confirm it relaunched.
