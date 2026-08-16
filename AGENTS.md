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

## GitHub

For all GitHub needs (issues, PRs, checks, releases, reviews, etc.), use the local `gh` CLI as much as possible. Prefer `gh` over the GitHub web UI, browser automation, or other APIs when `gh` can do the job.

## Merging pull requests

Always **squash merge** PRs (`gh pr merge --squash`). Merge commits and rebase merges are disabled on this repo. The squash commit message should follow Conventional Commits — usually the PR title is enough.

## Keep scanners cheap

Session and usage scanners run on a timer in a menu-bar / tray app. Prefer the lightest signal that is still correct:

- Stat or read only the files needed for the current decision. Skip extra I/O when a cheaper field (for example `last_active_at`) already answers the question.
- Do not walk growing history trees on every tick. Index, memoize by mtime, and reuse the last snapshot.
- A live process is not a reason to poll more. Idle must stay idle without extra work.

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
# Launch via explorer so the process is not killed with the agent job object.
Start-Process explorer.exe -ArgumentList "`"$((Resolve-Path 'windows\bin\Debug\net10.0-windows\AgentCord.exe').Path)`""
```

The app lives in the system tray (no taskbar entry) — check the tray to confirm it relaunched.
