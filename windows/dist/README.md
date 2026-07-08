# AgentCord for Windows — prebuilt binary

Compiled binaries are **not** stored in git. Download the latest build from
[GitHub Releases](https://github.com/preschian/agentcord/releases/latest).

Direct link: [agentcord.exe](https://github.com/preschian/agentcord/releases/latest/download/agentcord.exe)

## Install

1. Download `agentcord.exe` from the release page.
2. Place it somewhere permanent (e.g. `%LOCALAPPDATA%\Programs\AgentCord\`).
3. Double-click to run. It appears in the system tray (no window, no taskbar
   entry); left-click the tray icon for the status popover.

The release binary is a self-contained build, so it runs without installing the
.NET runtime.

## SmartScreen / unsigned binary

CI builds are **not code-signed**. Windows SmartScreen may warn that the publisher
is unknown the first time you run the exe. That is expected for an open-source
project without a commercial signing certificate.

To proceed: open the file properties and check **Unblock** if present, or choose
**More info → Run anyway** on the SmartScreen prompt.

## Build from source

```sh
cd windows
dotnet publish -c Release -r win-x64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

The binary lands in `bin/Release/net8.0-windows/win-x64/publish/AgentCord.exe`
(this directory is gitignored). See [../README.md](../README.md) for Discord
setup, debug flags, and the full feature map.
