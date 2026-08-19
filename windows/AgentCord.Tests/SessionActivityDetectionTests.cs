using System.Globalization;
using System.IO;
using System.Runtime.CompilerServices;
using Xunit;

namespace AgentCord.Tests;

public sealed class SessionActivityDetectionTests
{
    [Fact]
    public void ActiveDuration_sums_dense_stamps_and_drops_idle_gaps()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var cutoff = now - SessionActivity.LookbackMs;
        var morning = BurstMs(now - 6 * 3600_000, now - 5 * 3600_000);
        var evening = BurstMs(now - 3600_000, now - 8_000);
        var stamps = morning.Concat(evening).ToList();

        var (active, last) = SessionActivity.ActiveDuration(stamps, null, null, cutoff, now);

        Assert.InRange(active, 2 * 3600_000L - 30_000, 2 * 3600_000L + 5_000);
        Assert.Equal(stamps[^1], last);
    }

    [Fact]
    public void ElapsedStartMs_adds_a_short_live_tail()
    {
        var now = 2_000_000L;
        var start = SessionActivity.ElapsedStartMs(3_600_000, now - 4_000, now);
        Assert.Equal(now - 3_604_000, start);
    }

    private static List<long> BurstMs(long startMs, long endMs)
    {
        var stamps = new List<long>();
        for (var t = startMs; t < endMs; t += 4 * 60_000)
            stamps.Add(t);
        stamps.Add(endMs);
        return stamps;
    }

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
    public void NormalizeMs_uses_event_when_mtime_is_newer()
    {
        var eventAt = DateTime.UtcNow.AddHours(-2);
        var mtime = DateTime.UtcNow.AddSeconds(-10);
        var activity = SessionActivity.NormalizeMs(
            new DateTimeOffset(eventAt).ToUnixTimeMilliseconds(), mtime);

        Assert.Equal(new DateTimeOffset(eventAt).ToUnixTimeMilliseconds(), activity);
        Assert.False(SessionActivity.IsWithinWindow(activity, 60));
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
    public void Claude_ignores_fresh_mtime_when_events_are_old()
    {
        using var dir = TempDir.Create();
        var project = Path.Combine(dir.Root, "C-Users-test-hippocamp");
        Directory.CreateDirectory(project);
        var transcript = Path.Combine(project, "session.jsonl");
        var eventAt = DateTimeOffset.UtcNow.AddDays(-30);
        File.WriteAllText(transcript,
            "{\"cwd\":\"/Users/pres/orca/workspaces/com/hippocamp\",\"timestamp\":\"" +
            eventAt.ToString("o") +
            "\",\"message\":{\"model\":\"claude-fable-5\",\"role\":\"assistant\"}}\n" +
            "{\"type\":\"bridge-session\",\"sessionId\":\"dead\"}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddSeconds(-5));

        var scanner = new ClaudeSession(dir.Root) { ActiveWindowSeconds = 60 };
        Assert.Null(scanner.Scan());
    }

    [Fact]
    public void Claude_picks_up_appended_jsonl_lines_on_the_next_scan()
    {
        using var dir = TempDir.Create();
        var project = Path.Combine(dir.Root, "C-Users-test-agentcord");
        Directory.CreateDirectory(project);
        var transcript = Path.Combine(project, "session.jsonl");
        var first = DateTimeOffset.UtcNow.AddSeconds(-20);
        File.WriteAllText(transcript,
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + first.ToString("o") +
            "\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":3,\"output_tokens\":5}}}\n");

        using var scanner = new ClaudeSession(dir.Root) { ActiveWindowSeconds = 60 };
        var firstInfo = scanner.Scan();
        Assert.NotNull(firstInfo);
        Assert.Equal(8, firstInfo!.TotalTokens);

        var second = DateTimeOffset.UtcNow.AddSeconds(-5);
        File.AppendAllText(transcript,
            "{\"timestamp\":\"" + second.ToString("o") +
            "\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow);

        var secondInfo = scanner.Scan();
        Assert.NotNull(secondInfo);
        Assert.Equal(20, secondInfo!.TotalTokens);
    }

    [Fact]
    public void RepoNames_reads_origin_from_git_config()
    {
        using var dir = TempDir.Create();
        var git = Path.Combine(dir.Root, ".git");
        Directory.CreateDirectory(git);
        File.WriteAllText(Path.Combine(git, "config"),
            "[core]\n\trepositoryformatversion = 0\n[remote \"origin\"]\n\turl = git@github.com:preschian/agentcord.git\n");

        var cache = new Dictionary<string, string>();
        Assert.Equal("agentcord", RepoNames.FromCwd(dir.Root, cache));
        Assert.Equal("agentcord", RepoNames.FromCwd(dir.Root, cache));
    }

    [Fact]
    public void Claude_sums_working_time_across_sessions_in_the_last_24_hours()
    {
        using var dir = TempDir.Create();
        var project = Path.Combine(dir.Root, "C-Users-test-agentcord");
        Directory.CreateDirectory(project);
        var now = DateTimeOffset.UtcNow;

        File.WriteAllText(Path.Combine(project, "morning.jsonl"),
            ClaudeBurst(now.AddHours(-6), now.AddHours(-5)));
        File.WriteAllText(Path.Combine(project, "evening.jsonl"),
            ClaudeBurst(now.AddHours(-1), now.AddSeconds(-8)));
        File.SetLastWriteTimeUtc(Path.Combine(project, "morning.jsonl"), now.AddHours(-5).UtcDateTime);
        File.SetLastWriteTimeUtc(Path.Combine(project, "evening.jsonl"), now.AddSeconds(-8).UtcDateTime);

        var scanner = new ClaudeSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 2 * 3600_000L - 30_000, 2 * 3600_000L + 30_000);
    }

    private static string ClaudeBurst(DateTimeOffset start, DateTimeOffset end)
    {
        var text = "";
        foreach (var ts in Burst(start, end))
        {
            text += "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + ts.ToString("o") +
                    "\",\"message\":{\"model\":\"claude-opus-4-5\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n";
        }
        return text;
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
    public void Codex_finds_active_session_beyond_the_mtime_candidate_limit()
    {
        using var dir = TempDir.Create();
        var day = Path.Combine(dir.Root, "2026", "08", "01");
        Directory.CreateDirectory(day);

        var now = DateTime.UtcNow;
        for (var i = 0; i < 100; i++)
        {
            var filler = Path.Combine(day, $"filler-{i:D3}.jsonl");
            File.WriteAllText(filler, "");
            File.SetLastWriteTimeUtc(filler, now.AddSeconds(-30));
        }

        var eventAt = DateTimeOffset.UtcNow.AddSeconds(-10);
        var iso = eventAt.ToString("o");
        var active = Path.Combine(day, "active.jsonl");
        File.WriteAllText(active,
            "{\"timestamp\":\"" + iso + "\",\"type\":\"session_meta\",\"payload\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\"}}\n");
        File.SetLastWriteTimeUtc(active, now.AddHours(-2));

        var scanner = new CodexSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.True(info!.LastModifiedMs >= eventAt.ToUnixTimeMilliseconds());
    }

    [Fact]
    public void Codex_sums_working_time_across_sessions_in_the_last_24_hours()
    {
        using var dir = TempDir.Create();
        var day = Path.Combine(dir.Root, "2026", "08", "01");
        Directory.CreateDirectory(day);
        var now = DateTimeOffset.UtcNow;
        var morningStart = now.AddHours(-5);
        var morningEnd = now.AddHours(-4);
        var eveningStart = now.AddMinutes(-20);
        var eveningEnd = now.AddSeconds(-8);

        File.WriteAllText(Path.Combine(day, "morning.jsonl"), CodexBurst(morningStart, morningEnd));
        File.WriteAllText(Path.Combine(day, "evening.jsonl"), CodexBurst(eveningStart, eveningEnd));
        File.SetLastWriteTimeUtc(Path.Combine(day, "morning.jsonl"), morningEnd.UtcDateTime);
        File.SetLastWriteTimeUtc(Path.Combine(day, "evening.jsonl"), eveningEnd.UtcDateTime);

        var scanner = new CodexSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 3600_000L + 18 * 60_000L, 3600_000L + 22 * 60_000L);
    }

    private static string CodexLine(DateTimeOffset ts, string type)
    {
        var iso = ts.ToString("o");
        return "{\"timestamp\":\"" + iso + "\",\"type\":\"" + type +
               "\",\"payload\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"timestamp\":\"" + iso +
               "\",\"model\":\"gpt-5.2\"}}\n";
    }

    private static string CodexBurst(DateTimeOffset start, DateTimeOffset end)
    {
        var stamps = Burst(start, end);
        var text = CodexLine(stamps[0], "session_meta");
        for (var i = 1; i < stamps.Length; i++)
            text += CodexLine(stamps[i], "turn_context");
        return text;
    }

    /// <summary>Stamps every 4 minutes so each gap stays inside the 5-minute
    /// work tolerance. Two endpoints an hour apart would otherwise count as idle.</summary>
    private static DateTimeOffset[] Burst(DateTimeOffset start, DateTimeOffset end)
    {
        var stamps = new List<DateTimeOffset>();
        for (var t = start; t < end; t = t.AddMinutes(4))
            stamps.Add(t);
        stamps.Add(end);
        return stamps.ToArray();
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

    [Fact]
    public void Cursor_counts_a_live_agent_turn_longer_than_the_five_minute_gap()
    {
        using var dir = TempDir.Create();
        var transcripts = Path.Combine(dir.Root, "projects", "D-Workspace-agentcord", "agent-transcripts");
        Directory.CreateDirectory(transcripts);
        var transcript = Path.Combine(transcripts, "abc123.jsonl");

        // One user stamp 12 minutes ago, then 12 minutes of agent writes.
        // The 5-minute gap cap used to treat that as idle and reset Discord to 00:00.
        var started = DateTimeOffset.Now.AddMinutes(-12);
        File.WriteAllText(transcript, CursorUserLine(started, "long turn"));
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddSeconds(-5));

        var createdAtMs = started.ToUnixTimeMilliseconds();
        var updatedAtMs = DateTimeOffset.UtcNow.AddSeconds(-5).ToUnixTimeMilliseconds();
        var chatDir = Path.Combine(dir.Root, "chats", "workspace", "abc123");
        Directory.CreateDirectory(chatDir);
        File.WriteAllText(Path.Combine(chatDir, "meta.json"),
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"createdAtMs\":" + createdAtMs +
            ",\"updatedAtMs\":" + updatedAtMs + "}");

        var scanner = new CursorSession(dir.Root, enableT3: false) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 10 * 60_000L, 14 * 60_000L);
    }

    [Fact]
    public void Cursor_keeps_elapsed_across_sparse_user_turns()
    {
        using var dir = TempDir.Create();
        var transcripts = Path.Combine(dir.Root, "projects", "D-Workspace-agentcord", "agent-transcripts");
        Directory.CreateDirectory(transcripts);
        var transcript = Path.Combine(transcripts, "abc123.jsonl");

        // Two user messages an hour apart — the 5-minute gap-sum used to drop
        // that hour, then the new stamp snapped Discord to 00:00.
        var started = DateTimeOffset.Now.AddMinutes(-60);
        var latest = DateTimeOffset.Now.AddSeconds(-8);
        File.WriteAllText(transcript, CursorUserLine(started, "first") + CursorUserLine(latest, "second"));
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddSeconds(-5));

        var scanner = new CursorSession(dir.Root, enableT3: false) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 55 * 60_000L, 65 * 60_000L);
    }

    [Fact]
    public void Cursor_keeps_transcript_elapsed_when_acp_is_newer()
    {
        using var dir = TempDir.Create();
        var transcripts = Path.Combine(dir.Root, "projects", "D-Workspace-agentcord", "agent-transcripts");
        Directory.CreateDirectory(transcripts);
        var transcript = Path.Combine(transcripts, "abc123.jsonl");

        var started = DateTimeOffset.Now.AddMinutes(-60);
        var latest = DateTimeOffset.Now.AddSeconds(-8);
        File.WriteAllText(transcript, CursorUserLine(started, "first") + CursorUserLine(latest, "second"));
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddSeconds(-5));

        var createdAtMs = started.ToUnixTimeMilliseconds();
        var updatedAtMs = DateTimeOffset.UtcNow.AddSeconds(-5).ToUnixTimeMilliseconds();
        var chatDir = Path.Combine(dir.Root, "chats", "workspace", "abc123");
        Directory.CreateDirectory(chatDir);
        File.WriteAllText(Path.Combine(chatDir, "meta.json"),
            "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"createdAtMs\":" + createdAtMs +
            ",\"updatedAtMs\":" + updatedAtMs + "}");

        var acp = Path.Combine(dir.Root, "acp-sessions", "live-turn");
        Directory.CreateDirectory(acp);
        File.WriteAllText(Path.Combine(acp, "store.db"), "x");
        File.WriteAllText(Path.Combine(acp, "meta.json"), "{\"cwd\":\"D:\\\\Workspace\\\\agentcord\"}");
        File.SetLastWriteTimeUtc(Path.Combine(acp, "store.db"), DateTime.UtcNow);

        var scanner = new CursorSession(dir.Root, enableT3: false) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 55 * 60_000L, 65 * 60_000L);
    }

    [Fact]
    public void Cursor_sums_working_time_across_sessions_in_the_last_24_hours()
    {
        using var dir = TempDir.Create();
        var transcripts = Path.Combine(dir.Root, "projects", "D-Workspace-agentcord", "agent-transcripts");
        Directory.CreateDirectory(transcripts);
        var now = DateTimeOffset.Now;

        File.WriteAllText(Path.Combine(transcripts, "morning.jsonl"), CursorBurst(now.AddHours(-6), now.AddHours(-5)));
        File.WriteAllText(Path.Combine(transcripts, "evening.jsonl"), CursorBurst(now.AddHours(-1), now.AddSeconds(-8)));
        File.SetLastWriteTimeUtc(Path.Combine(transcripts, "morning.jsonl"), now.AddHours(-5).UtcDateTime);
        File.SetLastWriteTimeUtc(Path.Combine(transcripts, "evening.jsonl"), now.AddSeconds(-8).UtcDateTime);

        var scanner = new CursorSession(dir.Root, enableT3: false) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        Assert.InRange(elapsed, 2 * 3600_000L - 90_000, 2 * 3600_000L + 90_000);
    }

    private static string CursorBurst(DateTimeOffset start, DateTimeOffset end)
    {
        var text = "";
        foreach (var ts in Burst(start, end))
            text += CursorUserLine(ts, "hi");
        return text;
    }

    private static string CursorUserLine(DateTimeOffset local, string text)
    {
        var stamp = local.ToString("dddd, MMM d, yyyy, h:mm tt", CultureInfo.GetCultureInfo("en-US"));
        var offsetLabel = FormatUtcOffset(local.Offset);
        return "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"<timestamp>" +
            stamp + " (UTC" + offsetLabel + ")</timestamp>\\n" + text + "\"}]}}\n";
    }

    [Fact]
    public void Grok_detects_active_session_from_live_pid_and_summary()
    {
        using var dir = TempDir.Create();
        var sessionId = "019f880e-19ae-75c3-98d9-e6d29feb4b70";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        var openedAt = DateTimeOffset.UtcNow.AddMinutes(-12);
        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"" +
            openedAt.ToString("o") + "\"}]");
        File.WriteAllText(Path.Combine(dir.Root, "auth.json"),
            "{\"acct\":{\"key\":\"test\",\"email\":\"user@x.ai\"}}");

        var lastActive = DateTimeOffset.UtcNow.AddSeconds(-8);
        File.WriteAllText(Path.Combine(sessionDir, "summary.json"),
            "{\"info\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\"},\"current_model_id\":\"grok-4.5\"," +
            "\"last_active_at\":\"" + lastActive.ToString("o") + "\"," +
            "\"git_remotes\":[\"git@github.com:preschian/agentcord.git\"]}");
        File.WriteAllText(Path.Combine(sessionDir, "signals.json"),
            "{\"contextTokensUsed\":42221,\"contextWindowTokens\":500000,\"contextWindowUsage\":8," +
            "\"primaryModelId\":\"grok-4.5\"}");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Grok, info!.Agent);
        Assert.Equal("Grok 4.5", info.Model);
        Assert.Equal("agentcord", info.ProjectName);
        Assert.Equal(42221, info.TotalTokens);
        Assert.True(scanner.IsAuthenticated);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Grok_sums_working_time_across_sessions_in_the_last_24_hours()
    {
        using var dir = TempDir.Create();
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var now = DateTimeOffset.UtcNow;

        WriteGrokSession(dir.Root, encoded, "morning", cwd,
            created: now.AddHours(-6),
            lastActive: now.AddHours(-5),
            events: Burst(now.AddHours(-6), now.AddHours(-5)));
        WriteGrokSession(dir.Root, encoded, "evening", cwd,
            created: now.AddHours(-1),
            lastActive: now.AddSeconds(-8),
            events: Burst(now.AddHours(-1), now.AddSeconds(-8)));

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"evening\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"" +
            now.AddHours(-1).ToString("o") + "\"}]");
        File.WriteAllText(Path.Combine(dir.Root, "auth.json"),
            "{\"acct\":{\"key\":\"test\"}}");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        // 1h morning + 1h evening, idle gap between them excluded. Allow slack
        // for the live tail (last event ~8s ago through now).
        Assert.InRange(elapsed, 2 * 3600_000L - 30_000, 2 * 3600_000L + 30_000);
    }

    [Fact]
    public void Grok_excludes_idle_gaps_inside_a_session()
    {
        using var dir = TempDir.Create();
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var now = DateTimeOffset.UtcNow;

        WriteGrokSession(dir.Root, encoded, "gapped", cwd,
            created: now.AddHours(-4),
            lastActive: now.AddSeconds(-5),
            events: Burst(now.AddHours(-4), now.AddHours(-3))
                .Concat(Burst(now.AddMinutes(-10), now.AddSeconds(-5)))
                .ToArray());

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"gapped\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"" +
            now.AddHours(-4).ToString("o") + "\"}]");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - info!.StartEpochMs;
        // Two 1h-apart morning stamps (1h) plus a 10m evening burst, not 4h wall clock.
        Assert.InRange(elapsed, 3600_000L + 9 * 60_000L, 3600_000L + 12 * 60_000L);
    }

    private static void WriteGrokSession(
        string root, string encodedCwd, string sessionId, string cwd,
        DateTimeOffset created, DateTimeOffset lastActive, DateTimeOffset[] events)
    {
        var sessionDir = Path.Combine(root, "sessions", encodedCwd, sessionId);
        Directory.CreateDirectory(sessionDir);
        File.WriteAllText(Path.Combine(sessionDir, "summary.json"),
            "{\"info\":{\"cwd\":\"" + cwd.Replace("\\", "\\\\") + "\"},\"current_model_id\":\"grok-4.5\"," +
            "\"created_at\":\"" + created.ToString("o") + "\"," +
            "\"last_active_at\":\"" + lastActive.ToString("o") + "\"}");
        File.WriteAllText(Path.Combine(sessionDir, "events.jsonl"),
            string.Concat(events.Select(ts =>
                "{\"ts\":\"" + ts.ToString("o") + "\",\"type\":\"turn\"}\n")));
    }

    [Fact]
    public void Grok_falls_back_to_recent_summary_when_pid_is_dead()
    {
        using var dir = TempDir.Create();
        var sessionId = "dead-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":2000000000,\"cwd\":\"D:\\\\Workspace\\\\agentcord\"," +
            "\"opened_at\":\"2026-01-01T00:00:00Z\"}]");

        var lastActive = DateTimeOffset.UtcNow.AddSeconds(-10);
        File.WriteAllText(Path.Combine(sessionDir, "summary.json"),
            "{\"info\":{\"cwd\":\"D:\\\\Workspace\\\\agentcord\"},\"current_model_id\":\"grok-4.5\"," +
            "\"last_active_at\":\"" + lastActive.ToString("o") + "\"," +
            "\"git_remotes\":[\"https://github.com/preschian/agentcord.git\"]}");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Grok, info!.Agent);
        Assert.Equal("agentcord", info.ProjectName);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Grok_ignores_idle_session_with_live_pid()
    {
        using var dir = TempDir.Create();
        var sessionId = "idle-live-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"2026-01-01T00:00:00Z\"}]");
        var summaryPath = Path.Combine(sessionDir, "summary.json");
        File.WriteAllText(summaryPath,
            "{\"current_model_id\":\"grok-4.5\",\"last_active_at\":\"2026-01-01T00:00:00Z\"}");
        File.SetLastWriteTimeUtc(summaryPath, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        Assert.Null(scanner.Scan());
    }

    [Fact]
    public void Grok_keeps_live_pid_active_when_event_log_is_recent()
    {
        using var dir = TempDir.Create();
        var sessionId = "tool-run-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"2026-01-01T00:00:00Z\"}]");
        var summaryPath = Path.Combine(sessionDir, "summary.json");
        File.WriteAllText(summaryPath,
            "{\"current_model_id\":\"grok-4.5\",\"last_active_at\":\"2026-01-01T00:00:00Z\"}");
        File.SetLastWriteTimeUtc(summaryPath, new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        File.WriteAllText(Path.Combine(sessionDir, "events.jsonl"),
            "{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"turn_started\"}\n");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Grok, info!.Agent);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Grok_keeps_live_pid_active_during_open_turn_even_when_files_are_stale()
    {
        using var dir = TempDir.Create();
        var sessionId = "open-turn-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"2026-01-01T00:00:00Z\"}]");
        var summaryPath = Path.Combine(sessionDir, "summary.json");
        File.WriteAllText(summaryPath,
            "{\"current_model_id\":\"grok-4.5\",\"last_active_at\":\"2026-01-01T00:00:00Z\"}");
        var eventsPath = Path.Combine(sessionDir, "events.jsonl");
        File.WriteAllText(eventsPath,
            "{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"turn_started\"}\n" +
            "{\"ts\":\"2026-01-01T00:00:01Z\",\"type\":\"phase_changed\",\"phase\":\"streaming_reasoning\"}\n");
        var stale = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(summaryPath, stale);
        File.SetLastWriteTimeUtc(eventsPath, stale);

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 1 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Grok, info!.Agent);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 1));
    }

    [Fact]
    public void Grok_treats_turn_ended_as_idle_when_files_are_stale()
    {
        using var dir = TempDir.Create();
        var sessionId = "ended-turn-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(dir.Root, "active_sessions.json"),
            "[{ \"session_id\":\"" + sessionId + "\",\"pid\":" + Environment.ProcessId +
            ",\"cwd\":\"D:\\\\Workspace\\\\agentcord\",\"opened_at\":\"2026-01-01T00:00:00Z\"}]");
        var summaryPath = Path.Combine(sessionDir, "summary.json");
        File.WriteAllText(summaryPath,
            "{\"current_model_id\":\"grok-4.5\",\"last_active_at\":\"2026-01-01T00:00:00Z\"}");
        var eventsPath = Path.Combine(sessionDir, "events.jsonl");
        File.WriteAllText(eventsPath,
            "{\"ts\":\"2026-01-01T00:00:00Z\",\"type\":\"turn_started\"}\n" +
            "{\"ts\":\"2026-01-01T00:00:02Z\",\"type\":\"turn_ended\",\"outcome\":\"completed\"}\n");
        var stale = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        File.SetLastWriteTimeUtc(summaryPath, stale);
        File.SetLastWriteTimeUtc(eventsPath, stale);

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 1 };
        Assert.Null(scanner.Scan());
    }

    [Fact]
    public void Grok_ignores_idle_session_with_dead_pid()
    {
        using var dir = TempDir.Create();
        var sessionId = "idle-session";
        var cwd = @"D:\Workspace\agentcord";
        var encoded = Uri.EscapeDataString(cwd);
        var sessionDir = Path.Combine(dir.Root, "sessions", encoded, sessionId);
        Directory.CreateDirectory(sessionDir);

        File.WriteAllText(Path.Combine(sessionDir, "summary.json"),
            "{\"current_model_id\":\"grok-4.5\",\"last_active_at\":\"2026-01-01T00:00:00Z\"}");

        var scanner = new GrokSession(dir.Root) { ActiveWindowSeconds = 60 };
        Assert.Null(scanner.Scan());
    }

    [Theory]
    [InlineData("grok-4.5", "Grok 4.5")]
    [InlineData("grok-", "Grok")]
    [InlineData("Grok 4", "Grok 4")]
    public void Grok_PrettyModel_formats_correctly(string raw, string expected)
    {
        Assert.Equal(expected, GrokSession.PrettyModel(raw));
    }

    [Fact]
    public void Grok_RepoNameFromRemote_strips_git_suffix()
    {
        Assert.Equal("agentcord", GrokSession.RepoNameFromRemote("git@github.com:preschian/agentcord.git"));
        Assert.Equal("agentcord", GrokSession.RepoNameFromRemote("https://github.com/preschian/agentcord.git"));
    }

    [Fact]
    public void GrokUsage_parses_weekly_credits_and_on_demand()
    {
        var json = """
        {
          "config": {
            "creditUsagePercent": 42.4,
            "currentPeriod": {
              "type": "week",
              "start": "2026-07-15T00:00:00Z",
              "end": "2026-07-22T00:00:00Z"
            },
            "onDemandCap": { "val": 20 },
            "onDemandUsed": { "val": 5 }
          }
        }
        """;

        var info = GrokUsage.ParseBilling(json);
        Assert.NotNull(info);
        Assert.Equal(42, info!.Weekly.Percent);
        Assert.Equal("normal", info.Weekly.Severity);
        Assert.Equal(DateTimeOffset.Parse("2026-07-22T00:00:00Z").ToUnixTimeMilliseconds(), info.Weekly.ResetsAtMs);
        Assert.NotNull(info.OnDemand);
        Assert.Equal(25, info.OnDemand!.Percent);
    }

    [Fact]
    public void GrokUsage_treats_missing_percent_as_zero_when_period_present()
    {
        var json = """
        {
          "config": {
            "currentPeriod": {
              "type": "week",
              "end": "2026-07-22T00:00:00Z"
            }
          }
        }
        """;

        var info = GrokUsage.ParseBilling(json);
        Assert.NotNull(info);
        Assert.Equal(0, info!.Weekly.Percent);
        Assert.Null(info.OnDemand);
    }

    [Fact]
    public void GrokUsage_reads_plan_from_settings_display_string()
    {
        var label = GrokUsage.PlanLabelFromJson("""{"subscription_tier_display":"SuperGrok"}""");
        Assert.Equal("SuperGrok", label);
    }

    [Theory]
    [InlineData("GrokPro", "SuperGrok")]
    [InlineData("SuperGrok", "SuperGrok")]
    [InlineData("SuperGrokPro", "SuperGrok Heavy")]
    [InlineData("SuperGrokHeavy", "SuperGrok Heavy")]
    [InlineData("Free", "Free")]
    public void GrokUsage_maps_subscription_tier_enums(string raw, string expected)
    {
        Assert.Equal(expected, GrokUsage.MapSubscriptionTier(raw));
        Assert.Equal(expected, GrokUsage.PlanLabelFromJson($@"{{""subscriptionTier"":""{raw}""}}"));
    }

    [Fact]
    public void TrayStatusText_does_not_exceed_max_length_for_winforms()
    {
        var settings = new Settings { ShowProject = true, ShowModel = true, ShowTokens = true };
        using var controller = new PresenceController(settings);
        var longSession = new SessionInfo
        {
            Agent = AgentKind.Grok,
            ProjectName = "a-very-long-project-name-that-would-exceed-the-limit-if-not-truncated",
            Model = "Grok 4.5",
            StartEpochMs = DateTimeOffset.UtcNow.AddMinutes(-42).ToUnixTimeMilliseconds(),
            TotalTokens = 1234567,
            LastModifiedMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
        };

        var text = TrayStatusText.Build(settings, controller, null, null, null);
        Assert.True(text.Length <= 63, $"Text length {text.Length} exceeded 63 chars: '{text}'");
        Assert.Equal(63, TrayStatusText.MaxLength);
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
