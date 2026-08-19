// Detects the currently active Grok (xAI) coding session from:
//   %USERPROFILE%\.grok\active_sessions.json  (live TUI PIDs)
//   %USERPROFILE%\.grok\sessions\<url-encoded-cwd>\<session-id>\summary.json
//   sibling signals.json                      (context tokens / model)
//
// A live PID only means the TUI is open. Activity comes from summary
// last_active_at, event-log mtimes, and an open turn (turn_started without
// turn_ended) so a long think / tool run stays active even when files pause.
// An idle prompt after turn_ended is not treated as working. After the list
// clears (quit), the last-known session stays visible for the idle window.
// Elapsed time is today's working duration (idle gaps excluded).
// Port of AgentCord/GrokSession.swift.

using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class GrokSession
{
    /// <summary>A recently closed session still counts as active inside this window.</summary>
    public double ActiveWindowSeconds { get; set; } = SessionActivity.IdleWindowSeconds;

    /// <summary>True when ~/.grok/auth.json has at least one credential entry.</summary>
    public bool IsAuthenticated { get; private set; }

    public bool IsLinked =>
        File.Exists(Path.Combine(_grokHome, "auth.json"))
        || File.Exists(Path.Combine(_grokHome, "active_sessions.json"));

    private readonly string _grokHome;
    private readonly Dictionary<string, string> _summaryBySessionId = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _repoNameCache = [];
    private readonly Dictionary<string, DurationCacheEntry> _durationCache = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, EventTailCache> _eventTail = new(StringComparer.OrdinalIgnoreCase);
    private bool _hasBuiltSummaryIndex;
    private (SessionInfo Info, long ActivityMs)? _lastKnown;
    private DateTime? _authStamp;
    private bool _authCached;

    public GrokSession(string? grokHome = null)
    {
        if (grokHome is not null)
        {
            _grokHome = grokHome;
            return;
        }

        if (Environment.GetEnvironmentVariable("GROK_HOME") is { Length: > 0 } env)
            _grokHome = env;
        else
            _grokHome = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".grok");
    }

    /// <summary>Newest live Grok session, or the last-known one still inside the idle window.
    /// Today's work time is always computed, even when idle.</summary>
    public AgentScan Scan()
    {
        IsAuthenticated = ReadAuthenticated();
        var live = ReadActiveSessions().Where(e => ProcessIsAlive(e.Pid)).ToList();

        (SessionInfo Info, long ActivityMs)? best = null;
        foreach (var entry in live)
        {
            var summaryPath = FindSummary(entry.SessionId, entry.Cwd);
            var summary = summaryPath is null ? null : ReadSummary(summaryPath);
            var activityMs = ActivityMs(summary, summaryPath) ?? entry.OpenedAtMs;
            if (!SessionActivity.IsWithinWindow(activityMs, ActiveWindowSeconds)) continue;
            var signals = summaryPath is null
                ? null
                : ReadSignals(Path.GetDirectoryName(summaryPath)!);
            var tokens = signals?.ContextTokensUsed ?? 0;
            var modelRaw = summary?.ModelId ?? signals?.PrimaryModelId;
            var project = ResolveRepoName(entry.Cwd, summary?.GitRemotes);

            var info = new SessionInfo
            {
                ProjectName = string.IsNullOrWhiteSpace(project) ? "Grok" : project,
                Model = modelRaw is { Length: > 0 } raw ? PrettyModel(raw) : "Grok",
                StartEpochMs = 0,
                TotalTokens = tokens,
                LastModifiedMs = activityMs,
                Agent = AgentKind.Grok,
            };
            if (best is null || activityMs >= best.Value.ActivityMs)
                best = (info, activityMs);
        }

        if (best is null)
        {
            if (_lastKnown is { } known
                && SessionActivity.IsWithinWindow(known.ActivityMs, ActiveWindowSeconds))
            {
                best = known;
            }
            else if (NewestRecentSession(ActiveWindowSeconds) is { } fallback)
            {
                best = fallback;
            }
        }

        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var (activeMs, lastMs) = RollingActive(nowMs);
        var isLive = best is not null;
        var todayMs = SessionActivity.WithLiveTail(activeMs, lastMs, nowMs, isLive);
        if (best is { } found)
        {
            var info = found.Info with { StartEpochMs = nowMs - todayMs };
            _lastKnown = (info, found.ActivityMs);
            return new AgentScan(todayMs, info);
        }
        return new AgentScan(todayMs, null);
    }

    // --- Auth / active sessions

    private bool ReadAuthenticated()
    {
        try
        {
            var path = Path.Combine(_grokHome, "auth.json");
            if (!File.Exists(path))
            {
                _authStamp = null;
                _authCached = false;
                return false;
            }
            var stamp = File.GetLastWriteTimeUtc(path);
            if (_authCached && stamp == _authStamp) return true;
            using var doc = JsonDocument.Parse(ReadAllShared(path));
            var ok = doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.EnumerateObject().Any();
            _authStamp = stamp;
            _authCached = ok;
            return ok;
        }
        catch
        {
            return false;
        }
    }

    private sealed record LiveEntry(string SessionId, string Cwd, int Pid, long OpenedAtMs);

    private List<LiveEntry> ReadActiveSessions()
    {
        var path = Path.Combine(_grokHome, "active_sessions.json");
        try
        {
            if (!File.Exists(path)) return [];
            using var doc = JsonDocument.Parse(ReadAllShared(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return [];

            var list = new List<LiveEntry>();
            foreach (var item in doc.RootElement.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object) continue;
                var sid = StringProp(item, "session_id");
                var cwd = StringProp(item, "cwd");
                if (string.IsNullOrEmpty(sid) || string.IsNullOrEmpty(cwd)) continue;
                if (IntProp(item, "pid") is not int pid) continue;
                var opened = ParseIsoMs(StringProp(item, "opened_at"))
                    ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                list.Add(new LiveEntry(sid, cwd, pid, opened));
            }
            return list;
        }
        catch
        {
            return [];
        }
    }

    private static bool ProcessIsAlive(int pid)
    {
        if (pid <= 0) return false;
        try
        {
            using var process = Process.GetProcessById(pid);
            return !process.HasExited;
        }
        catch
        {
            return false;
        }
    }

    // --- Session files

    private sealed record SummaryMeta(string? ModelId, long? LastActiveMs, long? CreatedAtMs, string? Cwd, IReadOnlyList<string> GitRemotes);

    private sealed class DurationCacheEntry
    {
        public DateTime? EventsMtime;
        public DateTime? SummaryMtime;
        public JsonlCursor Cursor = new();
        public List<long> StampsMs = [];
        public long? CreatedAtMs;
        public long? LastActiveMs;
    }

    private sealed record SignalsMeta(long? ContextTokensUsed, long? ContextWindowTokens, string? PrimaryModelId);

    private string? FindSummary(string sessionId, string cwd)
    {
        var encoded = Uri.EscapeDataString(cwd);
        var direct = Path.Combine(_grokHome, "sessions", encoded, sessionId, "summary.json");
        if (File.Exists(direct)) return direct;

        if (_summaryBySessionId.TryGetValue(sessionId, out var cached) && File.Exists(cached))
            return cached;

        RebuildSummaryIndex();
        return _summaryBySessionId.TryGetValue(sessionId, out var found) ? found : null;
    }

    private void RebuildSummaryIndex()
    {
        _summaryBySessionId.Clear();
        _hasBuiltSummaryIndex = true;
        try
        {
            var sessions = Path.Combine(_grokHome, "sessions");
            if (!Directory.Exists(sessions)) return;
            foreach (var group in Directory.EnumerateDirectories(sessions))
            {
                foreach (var session in Directory.EnumerateDirectories(group))
                {
                    var summary = Path.Combine(session, "summary.json");
                    if (File.Exists(summary))
                        _summaryBySessionId[Path.GetFileName(session)] = summary;
                }
            }
        }
        catch
        {
            // Sessions tree can be mid-write; index stays best-effort.
        }
    }

    private static SummaryMeta? ReadSummary(string path)
    {
        try
        {
            using var doc = JsonDocument.Parse(ReadAllShared(path));
            var root = doc.RootElement;
            var model = StringProp(root, "current_model_id");
            var lastActive = ParseIsoMs(StringProp(root, "last_active_at"))
                ?? ParseIsoMs(StringProp(root, "updated_at"));
            var createdAt = ParseIsoMs(StringProp(root, "created_at"));
            string? cwd = null;
            if (root.TryGetProperty("info", out var info) && info.ValueKind == JsonValueKind.Object)
                cwd = StringProp(info, "cwd");
            var remotes = new List<string>();
            if (root.TryGetProperty("git_remotes", out var remotesEl) && remotesEl.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in remotesEl.EnumerateArray())
                {
                    if (item.ValueKind == JsonValueKind.String && item.GetString() is { Length: > 0 } remote)
                        remotes.Add(remote);
                }
            }
            return new SummaryMeta(model, lastActive, createdAt, cwd, remotes);
        }
        catch
        {
            return null;
        }
    }

    private static readonly string[] ActivityFiles =
        ["events.jsonl", "updates.jsonl", "chat_history.jsonl", "signals.json", "hunk_records.jsonl"];

    private sealed record EventTailCache(DateTime Mtime, long Length, string? Type);

    private long? ActivityMs(SummaryMeta? summary, string? summaryPath)
    {
        if (summary?.LastActiveMs is long last
            && SessionActivity.IsWithinWindow(last, ActiveWindowSeconds))
        {
            return last;
        }

        long? best = summary?.LastActiveMs;
        void Consider(long? value)
        {
            if (value is not long candidate) return;
            best = best is long current ? Math.Max(current, candidate) : candidate;
        }

        if (summaryPath is not null)
        {
            Consider(FileTimeMs(summaryPath));
            var dir = Path.GetDirectoryName(summaryPath);
            if (dir is not null)
            {
                foreach (var name in ActivityFiles)
                    Consider(FileTimeMs(Path.Combine(dir, name)));
                Consider(FileTimeMs(Path.Combine(dir, "terminal")));
            }
        }

        if (best is long fresh && SessionActivity.IsWithinWindow(fresh, ActiveWindowSeconds))
            return fresh;

        // Mid-turn thinking can pause file writes for tens of seconds. A live
        // events.jsonl whose last event is not turn_ended still counts as work.
        if (summaryPath is not null
            && Path.GetDirectoryName(summaryPath) is { } sessionDir
            && IsOpenTurn(sessionDir))
        {
            return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }
        return best;
    }

    private bool IsOpenTurn(string sessionDir)
    {
        var type = LastEventType(Path.Combine(sessionDir, "events.jsonl"));
        return type is { Length: > 0 }
            && !type.Equals("turn_ended", StringComparison.OrdinalIgnoreCase)
            && !type.Equals("session_end", StringComparison.OrdinalIgnoreCase)
            && !type.Equals("session_ended", StringComparison.OrdinalIgnoreCase);
    }

    private string? LastEventType(string eventsPath)
    {
        try
        {
            if (!File.Exists(eventsPath)) return null;
            var mtime = File.GetLastWriteTimeUtc(eventsPath);
            var length = new FileInfo(eventsPath).Length;
            if (_eventTail.TryGetValue(eventsPath, out var cached)
                && cached.Mtime == mtime && cached.Length == length)
            {
                return cached.Type;
            }

            var type = TailEventType(eventsPath, length);
            _eventTail[eventsPath] = new EventTailCache(mtime, length, type);
            return type;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>Last complete JSONL event <c>type</c>, reading only the tail.</summary>
    internal static string? TailEventType(string path, long length)
    {
        try
        {
            if (length <= 0) return null;
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var take = (int)Math.Min(length, 8192);
            stream.Seek(length - take, SeekOrigin.Begin);
            var buf = new byte[take];
            var read = stream.Read(buf, 0, take);
            if (read <= 0) return null;

            var text = System.Text.Encoding.UTF8.GetString(buf, 0, read);
            if (length > take)
            {
                var cut = text.IndexOf('\n');
                if (cut < 0) return null;
                text = text[(cut + 1)..];
            }
            string? last = null;
            var start = 0;
            for (var i = 0; i < text.Length; i++)
            {
                if (text[i] != '\n') continue;
                var line = text[start..i].Trim();
                if (line.Length > 0) last = line;
                start = i + 1;
            }
            var tail = text[start..].Trim();
            if (tail.Length > 0) last = tail;
            if (last is null) return null;

            using var doc = JsonDocument.Parse(last);
            return StringProp(doc.RootElement, "type");
        }
        catch
        {
            return null;
        }
    }

    private static SignalsMeta? ReadSignals(string sessionDir)
    {
        try
        {
            var path = Path.Combine(sessionDir, "signals.json");
            if (!File.Exists(path)) return null;
            using var doc = JsonDocument.Parse(ReadAllShared(path));
            var root = doc.RootElement;
            return new SignalsMeta(
                LongProp(root, "contextTokensUsed"),
                LongProp(root, "contextWindowTokens"),
                StringProp(root, "primaryModelId"));
        }
        catch
        {
            return null;
        }
    }

    private (SessionInfo Info, long ActivityMs)? NewestRecentSession(double windowSeconds)
    {
        if (!_hasBuiltSummaryIndex) RebuildSummaryIndex();

        (SessionInfo Info, long ActivityMs)? best = null;
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        foreach (var path in _summaryBySessionId.Values)
        {
            var summary = ReadSummary(path);
            var activityMs = summary?.LastActiveMs ?? FileTimeMs(path);
            if (activityMs is not long activity) continue;
            if (!SessionActivity.IsWithinWindow(activity, windowSeconds)) continue;

            var dir = Path.GetDirectoryName(path)!;
            var signals = ReadSignals(dir);
            var encodedGroup = Path.GetFileName(Path.GetDirectoryName(dir));
            var cwd = summary?.Cwd
                ?? (encodedGroup is null ? null : Uri.UnescapeDataString(encodedGroup))
                ?? "";
            var project = ResolveRepoName(cwd, summary?.GitRemotes);
            var modelRaw = summary?.ModelId ?? signals?.PrimaryModelId;
            var info = new SessionInfo
            {
                ProjectName = string.IsNullOrWhiteSpace(project) ? "Grok" : project,
                Model = modelRaw is { Length: > 0 } raw ? PrettyModel(raw) : "Grok",
                StartEpochMs = 0,
                TotalTokens = signals?.ContextTokensUsed ?? 0,
                LastModifiedMs = activity,
                Agent = AgentKind.Grok,
            };
            if (best is null || activity >= best.Value.ActivityMs)
                best = (info, activity);
        }
        return best;
    }

    /// <summary>Combined working time across every Grok session that touched
    /// today. Summaries are stat'd first so historical dirs are
    /// skipped without opening their event logs.</summary>
    private (long ActiveMs, long? LastMs) RollingActive(long nowMs)
    {
        if (!_hasBuiltSummaryIndex) RebuildSummaryIndex();

        var cutoffMs = SessionActivity.LocalMidnightMs();
        long total = 0;
        long? newestLast = null;
        var liveDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var summaryPath in _summaryBySessionId.Values)
        {
            var dir = Path.GetDirectoryName(summaryPath);
            if (dir is null) continue;
            liveDirs.Add(dir);

            var eventsPath = Path.Combine(dir, "events.jsonl");
            var eventsMtime = FileTimeUtc(eventsPath);
            var summaryMtime = FileTimeUtc(summaryPath);
            if (!_durationCache.TryGetValue(dir, out var entry))
                entry = new DurationCacheEntry();

            if (entry.SummaryMtime != summaryMtime)
            {
                var summary = ReadSummary(summaryPath);
                entry.CreatedAtMs = summary?.CreatedAtMs;
                entry.LastActiveMs = summary?.LastActiveMs;
                entry.SummaryMtime = summaryMtime;
            }

            var hintMs = FileTimeMs(eventsPath)
                ?? FileTimeMs(summaryPath)
                ?? entry.LastActiveMs
                ?? 0;
            if (hintMs < cutoffMs)
            {
                _durationCache[dir] = entry;
                continue;
            }

            if (File.Exists(eventsPath) && entry.EventsMtime != eventsMtime)
            {
                try
                {
                    entry.Cursor.PullLines(
                        eventsPath,
                        line =>
                        {
                            if (EventTimestampMs(line) is long ms)
                                entry.StampsMs.Add(ms);
                        },
                        () => entry.StampsMs.Clear());
                    entry.EventsMtime = eventsMtime;
                }
                catch
                {
                    // Live event logs can be briefly locked.
                }
            }
            _durationCache[dir] = entry;

            var (activeMs, lastMs) = SessionActivity.ActiveDuration(
                entry.StampsMs, entry.CreatedAtMs, entry.LastActiveMs, cutoffMs, nowMs);
            total += activeMs;
            if (lastMs is long last && (newestLast is null || last > newestLast))
                newestLast = last;
        }

        foreach (var stale in _durationCache.Keys.Where(k => !liveDirs.Contains(k)).ToList())
            _durationCache.Remove(stale);

        return (total, newestLast);
    }

    private static long? EventTimestampMs(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(trimmed);
            return ParseIsoMs(StringProp(doc.RootElement, "ts"));
        }
        catch
        {
            return null;
        }
    }

    private static DateTime? FileTimeUtc(string path)
    {
        try { return File.Exists(path) ? File.GetLastWriteTimeUtc(path) : null; }
        catch { return null; }
    }

    // --- Project name

    private string ResolveRepoName(string cwd, IReadOnlyList<string>? remotes)
    {
        if (remotes is { Count: > 0 })
        {
            var fromRemote = RepoNameFromRemote(remotes[0]);
            if (!string.IsNullOrEmpty(fromRemote)) return fromRemote;
        }

        if (string.IsNullOrWhiteSpace(cwd)) return "";
        return RepoNames.FromCwd(cwd, _repoNameCache);
    }

    internal static string RepoNameFromRemote(string remote) => RepoNames.FromRemote(remote);

    // --- Helpers

    /// <summary>Turn a raw model id such as "grok-4.5" into "Grok 4.5".</summary>
    public static string PrettyModel(string raw)
    {
        if (raw.StartsWith("grok-", StringComparison.OrdinalIgnoreCase))
        {
            var rest = raw[5..];
            return rest.Length == 0 ? "Grok" : $"Grok {rest}";
        }
        if (raw.Contains("grok", StringComparison.OrdinalIgnoreCase))
            return CultureInfo.InvariantCulture.TextInfo.ToTitleCase(raw.Replace('-', ' '));
        return raw;
    }

    internal static long? ParseIsoMs(string? value)
    {
        if (string.IsNullOrEmpty(value)) return null;
        if (DateTimeOffset.TryParse(
                value, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var dto))
        {
            return dto.ToUnixTimeMilliseconds();
        }
        return null;
    }

    private static long? FileTimeMs(string path)
    {
        try { return new DateTimeOffset(File.GetLastWriteTimeUtc(path)).ToUnixTimeMilliseconds(); }
        catch { return null; }
    }

    private static string ReadAllShared(string path)
    {
        using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int? IntProp(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var n)) return n;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var l) && l is >= int.MinValue and <= int.MaxValue)
            return (int)l;
        return null;
    }

    private static long? LongProp(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n)) return n;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var d)) return (long)d;
        return null;
    }
}
