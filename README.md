# agentcord

AgentCord is a macOS menu bar app that puts your coding-agent activity on your Discord profile. On macOS it tracks active Claude Code and Codex sessions, choosing the most recently active one when both are running. Your Discord status shows what you're working on: the current project, model, elapsed time, and token count. When the session goes quiet or you quit the app, the status clears itself.

The app lives in the menu bar with no Dock icon and no window in the way. The daily totals reset at midnight, so every day starts fresh.

**Downloads:** prebuilt binaries for [macOS](https://github.com/preschian/agentcord/releases/latest/download/AgentCord.dmg) and [Windows](https://github.com/preschian/agentcord/releases/latest/download/agentcord.exe) are on [GitHub Releases](https://github.com/preschian/agentcord/releases).

> [!NOTE]
> The macOS app isn't signed or notarized by Apple yet, so the first time you open it macOS will block it. To open it anyway: open the app once (macOS shows a warning and refuses), then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to the AgentCord message. This is only needed the first time.

Curious how it's built, or want to set it up and run it yourself? See [CONTRIBUTING.md](CONTRIBUTING.md).
