// Builds the tray tooltip string, mirroring the macOS menu bar status line
// (session bits + compact multi-agent usage). NotifyIcon.Text is capped at
// 63 characters by WinForms, so the builder keeps the most useful parts and truncates.

namespace AgentCord;

public static class TrayStatusText
{
    public const int MaxLength = 63;

    public static string Build(
        Settings settings,
        PresenceController controller,
        UsageInfo? claudeUsage,
        CodexUsageInfo? codexUsage,
        CursorUsageInfo? cursorUsage,
        AntigravityUsageInfo? antigravityUsage = null,
        GrokUsageInfo? grokUsage = null)
    {
        var lines = new List<string>();

        if (controller.CurrentSession is { } session)
            lines.Add(SessionLine(session, settings));
        else
            lines.Add(IdleLine(controller));

        var usage = UsageLine(settings, claudeUsage, codexUsage, cursorUsage, antigravityUsage, grokUsage);
        if (usage is not null) lines.Add(usage);

        return Fit(string.Join("\n", lines));
    }

    /// <summary>macOS-style session readout: "project · model · 10m · 48.0K tokens".</summary>
    private static string SessionLine(SessionInfo session, Settings settings)
    {
        var parts = new List<string> { session.Agent.DisplayName() };
        if (settings.ShowProject) parts.Add(session.ProjectName);
        if (settings.ShowModel && session.Model is not null) parts.Add(session.Model);
        parts.Add(Format.Elapsed(Format.NowMs() - session.StartEpochMs));
        if (settings.ShowTokens && session.TotalTokens > 0)
            parts.Add($"{PresenceController.FormatTokens(session.TotalTokens)} tokens");
        return string.Join(" · ", parts);
    }

    private static string IdleLine(PresenceController controller)
    {
        var discord = controller.DiscordState switch
        {
            DiscordIpc.ConnState.Connected => "Connected",
            DiscordIpc.ConnState.Connecting => "Connecting",
            _ => "Disconnected",
        };
        return controller.LastError is { Length: > 0 } err
            ? $"AgentCord — {err}"
            : $"AgentCord — Idle · {discord}";
    }

    /// <summary>Compact usage like the macOS menu bar: "5h 45% (2h 17m) · Cursor 30%".</summary>
    private static string? UsageLine(
        Settings settings,
        UsageInfo? claudeUsage,
        CodexUsageInfo? codexUsage,
        CursorUsageInfo? cursorUsage,
        AntigravityUsageInfo? antigravityUsage,
        GrokUsageInfo? grokUsage)
    {
        var claude = settings.IsAgentEnabled(AgentKind.Claude) ? claudeUsage : null;
        var codex = settings.IsAgentEnabled(AgentKind.Codex) ? codexUsage : null;
        var cursor = settings.IsAgentEnabled(AgentKind.Cursor) ? cursorUsage : null;
        var grok = settings.IsAgentEnabled(AgentKind.Grok) ? grokUsage : null;
        var antigravity = settings.IsAgentEnabled(AgentKind.Antigravity) ? antigravityUsage : null;

        var contributing =
            (claude is not null ? 1 : 0)
            + (codex is not null ? 1 : 0)
            + (cursor is not null ? 1 : 0)
            + (grok is not null ? 1 : 0)
            + (antigravity is not null ? 1 : 0);
        if (contributing == 0) return null;

        var multi = contributing > 1;
        var parts = new List<string>();
        if (claude is not null) parts.Add(ClaudeUsage(claude, multi));
        if (codex is not null) parts.Add(CodexUsage(codex, multi));
        if (cursor is not null) parts.Add(CursorUsage(cursor, multi));
        if (grok is not null) parts.Add(GrokUsageLine(grok, multi));
        if (antigravity is not null) parts.Add(AntigravityUsageLine(antigravity, multi));
        return string.Join(" · ", parts);
    }

    private static string ClaudeUsage(UsageInfo usage, bool labeled)
    {
        var window = usage.FiveHour;
        var text = labeled ? $"Claude {window.Percent}%" : $"5h {window.Percent}%";
        if (!labeled && ResetSuffix(window) is { } reset) text += $" ({reset})";
        return text;
    }

    private static string CodexUsage(CodexUsageInfo usage, bool labeled)
    {
        var window = usage.Primary;
        string text;
        if (labeled)
            text = $"Codex {window.Percent}%";
        else if (usage.PrimaryLabel.Contains("5-hour", StringComparison.OrdinalIgnoreCase))
            text = $"Codex 5h {window.Percent}%";
        else
            text = $"Codex {window.Percent}%";
        if (!labeled && ResetSuffix(window) is { } reset) text += $" ({reset})";
        return text;
    }

    private static string CursorUsage(CursorUsageInfo usage, bool labeled)
    {
        var window = usage.Included;
        var text = $"Cursor {window.Percent}%";
        if (!labeled && ResetSuffix(window) is { } reset) text += $" ({reset})";
        return text;
    }

    private static string GrokUsageLine(GrokUsageInfo usage, bool labeled)
    {
        var window = usage.Weekly;
        var text = $"Grok {window.Percent}%";
        if (!labeled && ResetSuffix(window) is { } reset) text += $" ({reset})";
        return text;
    }

    private static string AntigravityUsageLine(AntigravityUsageInfo usage, bool labeled)
    {
        var window = usage.FiveHour;
        var text = labeled ? $"Antigravity {window.Percent}%" : $"5h {window.Percent}%";
        if (!labeled && ResetSuffix(window) is { } reset) text += $" ({reset})";
        return text;
    }

    private static string? ResetSuffix(UsageWindow window) =>
        window.ResetsAtMs is long resets ? Format.ResetIn(resets) : null;

    private static string Fit(string text)
    {
        if (text.Length <= MaxLength) return text;
        return text[..(MaxLength - 1)] + "…";
    }
}
