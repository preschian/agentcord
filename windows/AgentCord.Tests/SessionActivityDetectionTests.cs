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
    public void Antigravity_detects_active_session_from_transcript_and_history()
    {
        using var dir = TempDir.Create();
        var convId = "cf7143f8-3342-4012-a7f7-f0db72843250";
        var logsDir = Path.Combine(dir.Root, "brain", convId, ".system_generated", "logs");
        Directory.CreateDirectory(logsDir);

        var eventAt = DateTimeOffset.UtcNow.AddSeconds(-15);
        var iso = eventAt.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var transcript = Path.Combine(logsDir, "transcript.jsonl");
        File.WriteAllText(transcript,
            "{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"" + iso + "\",\"content\":\"The user changed setting `Model Selection` from None to Gemini 3.7 Flash (High).\"}\n" +
            "{\"step_index\":1,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"" + iso + "\",\"tool_calls\":[{\"name\":\"list_dir\",\"args\":{\"DirectoryPath\":\"D:\\\\Workspace\\\\agentcord\"}}]}\n");

        var history = Path.Combine(dir.Root, "history.jsonl");
        File.WriteAllText(history,
            "{\"display\":\"test prompt\",\"timestamp\":" + eventAt.ToUnixTimeMilliseconds() + ",\"workspace\":\"D:\\\\Workspace\\\\agentcord\",\"conversationId\":\"" + convId + "\"}\n");

        var scanner = new AntigravitySession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Antigravity, info!.Agent);
        Assert.Equal("Gemini 3.7 Flash", info.Model);
        Assert.Equal("agentcord", info.ProjectName);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Antigravity_detects_active_session_from_presence_lock()
    {
        using var dir = TempDir.Create();
        var convId = "test-conv-123";
        var logsDir = Path.Combine(dir.Root, "brain", convId, ".system_generated", "logs");
        Directory.CreateDirectory(logsDir);

        var oldEvent = DateTimeOffset.UtcNow.AddHours(-1);
        var transcript = Path.Combine(logsDir, "transcript.jsonl");
        File.WriteAllText(transcript,
            "{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"" + oldEvent.ToString("yyyy-MM-ddTHH:mm:ssZ") + "\",\"content\":\"[URI] -> [CorpusName]\\nD:\\\\Workspace\\\\agentcord -> preschian/agentcord\"}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-1));

        var presenceDir = Path.Combine(dir.Root, "presence");
        Directory.CreateDirectory(presenceDir);
        var lockFile = Path.Combine(presenceDir, convId + ".lock");
        File.WriteAllText(lockFile, "");
        File.SetLastWriteTimeUtc(lockFile, DateTime.UtcNow.AddSeconds(-5));

        var scanner = new AntigravitySession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Antigravity, info!.Agent);
        Assert.True(SessionActivity.IsWithinWindow(info.LastModifiedMs, 60));
    }

    [Fact]
    public void Antigravity_ignores_idle_session()
    {
        using var dir = TempDir.Create();
        var convId = "idle-conv";
        var logsDir = Path.Combine(dir.Root, "brain", convId, ".system_generated", "logs");
        Directory.CreateDirectory(logsDir);

        var oldEvent = DateTimeOffset.UtcNow.AddHours(-2);
        var transcript = Path.Combine(logsDir, "transcript.jsonl");
        File.WriteAllText(transcript,
            "{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"" + oldEvent.ToString("yyyy-MM-ddTHH:mm:ssZ") + "\",\"content\":\"hello\"}\n");
        File.SetLastWriteTimeUtc(transcript, DateTime.UtcNow.AddHours(-2));

        var scanner = new AntigravitySession(dir.Root) { ActiveWindowSeconds = 60 };
        Assert.Null(scanner.Scan());
    }

    [Theory]
    [InlineData("Gemini 3.7 Flash (High)", "Gemini 3.7 Flash")]
    [InlineData("gemini-3.7-flash", "Gemini 3.7 Flash")]
    [InlineData("gemini-2.5-pro", "Gemini 2.5 Pro")]
    [InlineData("gemini-2.0-flash-thinking", "Gemini 2.0 Flash Thinking")]
    [InlineData("Gemini 1.5 Pro", "Gemini 1.5 Pro")]
    [InlineData("gemini", "Gemini")]
    public void Antigravity_PrettyModel_formats_correctly(string raw, string expected)
    {
        Assert.Equal(expected, AntigravitySession.PrettyModel(raw));
    }

    [Fact]
    public void Antigravity_detects_workspace_from_tool_call_args()
    {
        using var dir = TempDir.Create();
        var convId = "tool-call-conv";
        var logsDir = Path.Combine(dir.Root, "brain", convId, ".system_generated", "logs");
        Directory.CreateDirectory(logsDir);

        var eventAt = DateTimeOffset.UtcNow.AddSeconds(-5);
        var iso = eventAt.ToString("yyyy-MM-ddTHH:mm:ssZ");
        var transcript = Path.Combine(logsDir, "transcript.jsonl");
        File.WriteAllText(transcript,
            "{\"step_index\":0,\"source\":\"MODEL\",\"type\":\"PLANNER_RESPONSE\",\"created_at\":\"" + iso + "\",\"tool_calls\":[{\"name\":\"run_command\",\"args\":{\"Cwd\":\"D:\\\\Workspace\\\\agentcord\"}}]}\n");

        var scanner = new AntigravitySession(dir.Root) { ActiveWindowSeconds = 60 };
        var info = scanner.Scan();

        Assert.NotNull(info);
        Assert.Equal(AgentKind.Antigravity, info!.Agent);
        Assert.Equal("agentcord", info.ProjectName);
    }

    [Fact]
    public void Antigravity_ResolveBaseDir_respects_custom_dir()
    {
        var custom = @"C:\Custom\Antigravity";
        Assert.Equal(custom, AntigravitySession.ResolveBaseDir(custom));
    }

    [Fact]
    public void Antigravity_extracts_account_email_and_plan_from_cli_logs()
    {
        using var dir = TempDir.Create();
        var logDir = Path.Combine(dir.Root, "log");
        Directory.CreateDirectory(logDir);

        var logFile = Path.Combine(logDir, "cli-20260814_003501.log");
        File.WriteAllText(logFile,
            "ERROR: logging before google.Init: I0814 00:35:01.556027 197 server_oauth.go:189] applyAuthResult: email=preschian27@gmail.com, authMethod=consumer, quotaProject=\n" +
            "ERROR: logging before google.Init: I0814 00:35:01.556027 197 server_oauth.go:194] OAuth: authenticated successfully as preschian27@gmail.com\n");

        var scanner = new AntigravitySession(dir.Root);
        scanner.Scan();

        Assert.Equal("preschian27@gmail.com", scanner.AccountEmail);
        Assert.Equal("Google AI Pro", scanner.PlanType);
    }

    [Theory]
    [InlineData("consumer", "Google AI Pro")]
    [InlineData("pro", "Google AI Pro")]
    [InlineData("ultra", "Google AI Ultra")]
    [InlineData("enterprise", "Gemini Enterprise")]
    [InlineData("workforce", "Google Workspace")]
    [InlineData("gcp", "Google Cloud")]
    [InlineData("api_key", "API Key")]
    public void Antigravity_FormatPlan_formats_correctly(string raw, string expected)
    {
        Assert.Equal(expected, AntigravitySession.FormatPlan(raw));
    }

    [Fact]
    public void TrayStatusText_does_not_exceed_max_length_for_winforms()
    {
        var settings = new Settings { ShowProject = true, ShowModel = true, ShowTokens = true };
        using var controller = new PresenceController(settings);
        var longSession = new SessionInfo
        {
            Agent = AgentKind.Antigravity,
            ProjectName = "a-very-long-project-name-that-would-exceed-the-limit-if-not-truncated",
            Model = "Gemini 3.7 Flash Thinking (Experimental)",
            StartEpochMs = DateTimeOffset.UtcNow.AddMinutes(-42).ToUnixTimeMilliseconds(),
            TotalTokens = 1234567,
            LastModifiedMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
        };

        var text = TrayStatusText.Build(settings, controller, null, null, null);
        Assert.True(text.Length <= 63, $"Text length {text.Length} exceeded 63 chars: '{text}'");
        Assert.Equal(63, TrayStatusText.MaxLength);
    }

    [Fact]
    public void AntigravityUsage_computes_rolling_five_hour_and_weekly_usage()
    {
        using var dir = TempDir.Create();
        var brainDir = Path.Combine(dir.Root, "brain", "test-conv", ".system_generated", "logs");
        Directory.CreateDirectory(brainDir);

        var now = DateTime.UtcNow;
        var twoHoursAgo = now.AddHours(-2).ToString("O");
        var twoDaysAgo = now.AddDays(-2).ToString("O");
        var tenDaysAgo = now.AddDays(-10).ToString("O");

        var transcript = Path.Combine(brainDir, "transcript.jsonl");
        File.WriteAllText(transcript,
            $"{{\"step_index\":0,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"{twoHoursAgo}\",\"content\":\"{new string('x', 40000)}\"}}\n" +
            $"{{\"step_index\":1,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"{twoDaysAgo}\",\"content\":\"{new string('y', 80000)}\"}}\n" +
            $"{{\"step_index\":2,\"source\":\"USER_EXPLICIT\",\"type\":\"USER_INPUT\",\"created_at\":\"{tenDaysAgo}\",\"content\":\"{new string('z', 200000)}\"}}\n");

        var logDir = Path.Combine(dir.Root, "log");
        Directory.CreateDirectory(logDir);
        var logFile = Path.Combine(logDir, "cli-test.log");
        File.WriteAllText(logFile, "applyAuthResult: email=preschian27@gmail.com, authMethod=consumer, quotaProject=\n");

        using var usageTracker = new AntigravityUsage(dir.Root);
        usageTracker.Fetch();

        var usage = usageTracker.Current;
        Assert.NotNull(usage);
        Assert.Equal("preschian27@gmail.com", usageTracker.AccountEmail);
        Assert.Equal("Google AI Pro", usage.PlanName);

        // 5-hour: 40000 chars / 4 = 10000 tokens => 10000 / 500000 = 2%
        Assert.Equal(2, usage.FiveHour.Percent);
        Assert.NotNull(usage.FiveHour.ResetsAtMs);

        // Weekly: (40000 + 80000) / 4 = 30000 tokens => 30000 / 4500000 = 1%
        Assert.Equal(1, usage.Weekly.Percent);
        Assert.NotNull(usage.Weekly.ResetsAtMs);
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
