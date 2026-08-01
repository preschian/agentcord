using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using Xunit;

namespace AgentCord.Tests;

public sealed class SessionActivityDetectionTests
{
    [Fact]
    public void NormalizeMs_prefers_newer_event_over_mtime()
    {
        var mtime = DateTime.UtcNow.AddHours(-2);
        var eventMs = DateTimeOffset.UtcNow.AddSeconds(-5).ToUnixTimeMilliseconds();
        var activity = SessionActivity.NormalizeMs(eventMs, mtime);
        Assert.Equal(eventMs, activity);
        Assert.True(SessionActivity.IsWithinWindow(activity, 60));
    }

    [Fact]
    public void NormalizeMs_falls_back_to_mtime_when_no_event()
    {
        var mtime = DateTime.UtcNow.AddSeconds(-10);
        var activity = SessionActivity.NormalizeMs(null, mtime);
        Assert.Equal(new DateTimeOffset(mtime).ToUnixTimeMilliseconds(), activity);
        Assert.True(SessionActivity.IsWithinWindow(activity, 60));
    }

    [Fact]
    public void Claude_detects_active_session_when_mtime_is_stale()
    {
        using var dir = TempDir.Create();
        var project = Path.Combine(dir.Root, "C-Users-test-agentcord");
        Directory.CreateDirectory(project);
        var transcript = Path.Combine(project, "session.jsonl");
        var eventAt = DateTimeOffset.UtcNow.AddSeconds(-15);
        File.WriteAllText(transcript,
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + eventAt.ToString("o") +
            "\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":5}}}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-2));

        var scanner = new ClaudeSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Claude, info!.Agent);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
        Assert.True(info.LastModifiedMs >= eventAt.ToUnixTimeMilliseconds());
    }

    [Fact]
    public void Claude_ignores_idle_session_with_stale_mtime_and_old_events()
    {
        using var dir = TempDir.Create();
        var project = Path.Combine(dir.Root, "C-Users-test-agentcord");
        Directory.CreateDirectory(project);
        var transcript = Path.Combine(project, "session.jsonl");
        var eventAt = DateTimeOffset.UtcNow.AddHours(-3);
        File.WriteAllText(transcript,
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + eventAt.ToString("o") +
            "\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":5}}}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-2));

        var scanner = new ClaudeSession(dir.Root) { ActiveWindowSeconds = 60 };
        Assert.Null(scanner.Scan());
    }

    [Fact]
    public void Codex_detects_active_session_when_mtime_is_stale()
    {
        using var dir = TempDir.Create();
        var day = Path.Combine(dir.Root, "2026", "08", "01");
        Directory.CreateDirectory(day);
        var transcript = Path.Combine(day, "rollout.jsonl");
        var eventAt = DateTimeOffset.UtcNow.AddSeconds(-20);
        var iso = eventAt.ToString("o");
        File.WriteAllText(transcript,
            "{\"timestamp\":\"" + iso + "\",\"type\":\"session_meta\",\"payload\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + iso + "\"}}\n" +
            "{\"timestamp\":\"" + iso + "\",\"type\":\"turn_context\",\"payload\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"model\":\"gpt-5.2\"}}\n" +
            "{\"timestamp\":\"" + iso + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":42}}}}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-2));

        var scanner = new CodexSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Codex, info!.Agent);
        Assert.Equal("GPT-5.2", info.Model);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Cursor_detects_active_transcript_when_mtime_is_stale()
    {
        using var dir = TempDir.Create();
        var transcripts = Path.Combine(dir.Root, "projects", "D-Workspace-agentcord", "agent-transcripts");
        Directory.CreateDirectory(transcripts);
        var transcript = Path.Combine(transcripts, "abc123.jsonl");

        // Cursor embeds wall-clock stamps at minute resolution (no seconds).
        // Stamp "now" and use an idle window wider than one minute so truncating
        // seconds cannot push a fresh stamp outside the active window on CI.
        var local = DateTimeOffset.Now;
        var stamp = local.ToString("dddd, MMM d, yyyy, h:mm tt", CultureInfo.GetCultureInfo("en-US"));
        var offsetLabel = FormatUtcOffset(local.Offset);
        var updatedAtMs = DateTimeOffset.UtcNow.AddSeconds(-20).ToUnixTimeMilliseconds();

        File.WriteAllText(transcript,
            "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hi <timestamp>" +
            stamp + " (UTC" + offsetLabel + ")</timestamp>\"}]}}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-2));

        // Precise activity signal via chat meta (also exercised by NormalizeMs).
        var chatDir = Path.Combine(dir.Root, "chats", "workspace", "abc123");
        Directory.CreateDirectory(chatDir);
        File.WriteAllText(Path.Combine(chatDir, "meta.json"),
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"createdAtMs\":" + (updatedAtMs - 60_000) +
            ",\"updatedAtMs\":" + updatedAtMs + "}");

        const double windowSeconds = 180;
        var scanner = new CursorSession(dir.Root, enableT3: false) { ActiveWindowSeconds = windowSeconds };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Cursor, info!.Agent);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, windowSeconds));
        Assert.True(info.LastModifiedMs >= updatedAtMs);
    }

    private static string FormatUtcOffset(TimeSpan offset)
    {
        var sign = offset < TimeSpan.Zero ? "-" : "+";
        var abs = offset.Duration();
        return abs.Minutes == 0
            ? $"{sign}{(int)abs.TotalHours}"
            : $"{sign}{(int)abs.TotalHours}:{abs.Minutes:D2}";
    }
}

file sealed class TempDir : IDisposable
{
    public string Root { get; }

    private TempDir(string path) => Root = path;

    public static TempDir Create([CallerMemberName] string? name = null)
    {
        var path = Path.Combine(
            Path.GetTempPath(),
            "agentcord-tests",
            $"{name}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return new TempDir(path);
    }

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); }
        catch { /* best-effort cleanup */ }
    }
}
