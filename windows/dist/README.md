# AgentCord for Windows — prebuilt binary

Compiled binaries are **not** stored in git. Download the latest build from
[GitHub Releases](https://github.com/preschian/agentcord/releases/latest).

Direct link: [agentcord.exe](https://github.com/preschian/agentcord/releases/latest/download/agentcord.exe)

## Install

1. Download `agentcord.exe` from the release page.
2. Place it somewhere permanent (e.g. `%LOCALAPPDATA%\Programs\AgentCord\`).
3. Double-click to run, or add that folder to your `PATH` and run `agentcord` from a terminal.

The default launch mode is the system-tray app (no console window). See
[../README.md](../README.md) for Discord setup, headless modes, and build-from-source
instructions.

## SmartScreen / unsigned binary

CI builds are **not code-signed**. Windows SmartScreen may warn that the publisher
is unknown the first time you run the exe. That is expected for an open-source
project without a commercial signing certificate.

To proceed: open the file properties and check **Unblock** if present, or choose
**More info → Run anyway** on the SmartScreen prompt.

## Build from source

```sh
cd windows
cargo build --release
```

The binary lands in `target/release/agentcord.exe` (this directory is gitignored).
