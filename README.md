# agentcord

AgentCord puts your coding-agent activity on your Discord profile. The Windows app tracks Claude Code, Codex, Cursor, Grok, and Antigravity; the macOS app supports Claude, Codex, Cursor, Grok, and Antigravity. When several sessions are running, the most recently active enabled agent wins. Your Discord status shows what you're working on: the current project, model, elapsed time, and token count. When the session goes quiet or you quit the app, the status clears itself.

The app lives in the macOS menu bar or Windows system tray with no window in the way. Elapsed time is today's working duration (local midnight) on every platform. On macOS, Discord elapsed is the sum of enabled agents' daily totals; the title stays the most recently active session. Claude's token totals still reset at midnight.

**Downloads:** prebuilt binaries for [macOS](https://github.com/preschian/agentcord/releases/latest/download/AgentCord.dmg) and [Windows](https://github.com/preschian/agentcord/releases/latest/download/agentcord.exe) are on [GitHub Releases](https://github.com/preschian/agentcord/releases).

> [!NOTE]
> The Windows exe needs the [.NET 10 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/10.0). If it doesn't start, install it with `winget install Microsoft.DotNet.DesktopRuntime.10` and try again.

> [!NOTE]
> The macOS app isn't signed or notarized by Apple yet, so the first time you open it macOS will block it. To open it anyway: open the app once (macOS shows a warning and refuses), then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the AgentCord message. This is only needed the first time.

Curious how it's built, or want to set it up and run it yourself? See [CONTRIBUTING.md](CONTRIBUTING.md). A Windows GPUI prototype (Grok + Cursor only) lives in [`gpui/`](gpui/).
