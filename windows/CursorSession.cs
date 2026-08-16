// Detects the currently active Cursor agent session from:
//   1. %USERPROFILE%\.cursor\projects\**\agent-transcripts\**\*.jsonl (CLI)
//   2. T3 Code's ~/.t3/userdata/state.sqlite when provider is Cursor
//   3. %USERPROFILE%\.cursor\acp-sessions\** (live ACP turn signal)
//
// Enrich transcripts with ~/.cursor/chats/**/<session-id>/meta.json plus
// store.db (`lastUsedModel`) when sqlite3 is on PATH. Port of
// AgentCord/CursorSession.swift, extended for T3 Code / ACP on Windows.

using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentCord;

public sealed class CursorSession : IDisposable
{
    /// <summary>A transcript counts as active if modified within this window.</summary>
    public double ActiveWindowSeconds { get; set; } = 60;

    private const long ActiveGapToleranceMs = 5 * 60 * 1000;
    private const long LookbackMs = 24 * 60 * 60 * 1000;

    private static readonly Regex TimestampRegex = new(
        @"<timestamp>(.*?)</timestamp>",
        RegexOptions.Singleline | RegexOptions.Compiled);

    private readonly string _chatsDir;
    private readonly string _acpDir;
    private readonly bool _enableT3;
    private readonly T3CursorSession _t3Scanner = new();
    private readonly SessionTreeIndex _transcriptTree;
    private readonly SessionTreeIndex _chatsTree;
    private readonly Dictionary<string, string> _metaBySessionId = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _repoNameCache = [];
    private readonly Dictionary<string, (DateTime? Stamp, string? Model)> _modelCache = [];
    private readonly Dictionary<string, TranscriptCacheEntry> _transcriptCache = [];
    private DateTime _metaIndexStamp = DateTime.MinValue;

    public CursorSession(string? cursorHome = null, bool enableT3 = true)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var resolved = cursorHome ?? Path.Combine(home, ".cursor");
        var projectsDir = Path.Combine(resolved, "projects");
        _chatsDir = Path.Combine(resolved, "chats");
        _acpDir = Path.Combine(resolved, "acp-sessions");
        _enableT3 = enableT3;
        _transcriptTree = new SessionTreeIndex(projectsDir, "*.jsonl", IsAgentTranscript);
        _chatsTree = new SessionTreeIndex(_chatsDir, "meta.json");
    }

    public void Dispose()
    {
        _transcriptTree.Dispose();
        _chatsTree.Dispose();
    }

    private static bool IsAgentTranscript(string path) =>
        path.Contains($"{Path.DirectorySeparatorChar}agent-transcripts{Path.DirectorySeparatorChar}",
            StringComparison.OrdinalIgnoreCase)
        || path.Contains("/agent-transcripts/", StringComparison.OrdinalIgnoreCase);

    /// <summary>Newest live Cursor session across CLI transcripts, T3 Code, and ACP.</summary>
    public SessionInfo? Scan()
    {
        _t3Scanner.ActiveWindowSeconds = ActiveWindowSeconds;
        var candidates = new List<SessionInfo?> { ScanTranscripts(), ScanAcp() };
        if (_enableT3) candidates.Add(_t3Scanner.Scan());
        return candidates
            .Where(s => s is not null)
            .MaxBy(s => s!.LastModifiedMs);
    }

    private SessionInfo? ScanTranscripts()
    {
        var files = _transcriptTree.Snapshot(TimeSpan.FromMilliseconds(LookbackMs));
        if (files.Count == 0) return null;

        RebuildMetaIndexIfNeeded();

        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var cutoffMs = nowMs - LookbackMs;

        long totalActiveMs = 0;
        string? bestPath = null;
        long bestActivityMs = long.MinValue;
        long? activeLastMs = null;

        foreach (var file in files)
        {
            var entry = TranscriptAggregate(file.Path, file.Mtime);
            var lastStamp = entry.ConversationalStampsMs.Count > 0
                ? entry.ConversationalStampsMs[^1]
                : (long?)null;
            var activityMs = SessionActivity.NormalizeMs(file.Mtime, lastStamp, entry.UpdatedAtMs);

            var (activeMs, lastMs) = ActiveDuration(
                entry.ConversationalStampsMs,
                entry.CreatedAtMs,
                entry.UpdatedAtMs,
                cutoffMs,
                nowMs);

            // Include duration for anything whose activity (or mtime fallback)
            // touched the lookback window — stale mtime alone must not exclude
            // a transcript with recent embedded timestamps.
            if (activityMs >= cutoffMs)
                totalActiveMs += activeMs;

            if (bestPath is null || activityMs >= bestActivityMs)
            {
                bestPath = file.Path;
                bestActivityMs = activityMs;
                activeLastMs = lastMs ?? lastStamp ?? entry.UpdatedAtMs;
            }
        }

        var livePaths = files.Select(f => f.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var stale in _transcriptCache.Keys.Where(k => !livePaths.Contains(k)).ToList())
            _transcriptCache.Remove(stale);

        if (bestPath is null) return null;
        if (!SessionActivity.IsWithinWindow(bestActivityMs, ActiveWindowSeconds)) return null;

        var elapsedMs = totalActiveMs;
        if (activeLastMs is long last)
        {
            var tail = nowMs - last;
            if (tail > 0 && tail <= ActiveGapToleranceMs) elapsedMs += tail;
        }

        var sessionId = Path.GetFileNameWithoutExtension(bestPath);
        var meta = ReadMeta(sessionId, includeModel: true);

        var projectName = ResolveProjectName(meta?.Cwd, bestPath);
        if (string.IsNullOrWhiteSpace(projectName)) projectName = "Cursor";

        return new SessionInfo
        {
            ProjectName = projectName,
            Model = meta?.Model is { Length: > 0 } model ? PrettyModel(model) : null,
            StartEpochMs = nowMs - elapsedMs,
            TotalTokens = 0,
            LastModifiedMs = bestActivityMs,
            Agent = AgentKind.Cursor,
        };
    }

    /// <summary>T3 Code (and other ACP hosts) keep the live turn in
    /// acp-sessions/*/store.db(-wal) even when agent-transcripts are idle.</summary>
    private SessionInfo? ScanAcp()
    {
        try
        {
            if (!Directory.Exists(_acpDir)) return null;

            string? bestDir = null;
            DateTime bestMtime = DateTime.MinValue;
            foreach (var dir in Directory.EnumerateDirectories(_acpDir))
            {
                var mtime = AcpActivityUtc(dir);
                if (mtime is null) continue;
                if (mtime > bestMtime)
                {
                    bestMtime = mtime.Value;
                    bestDir = dir;
                }
            }

            if (bestDir is null) return null;
            var activityMs = new DateTimeOffset(bestMtime).ToUnixTimeMilliseconds();
            if (!SessionActivity.IsWithinWindow(activityMs, ActiveWindowSeconds)) return null;

            string? cwd = null;
            var metaPath = Path.Combine(bestDir, "meta.json");
            if (File.Exists(metaPath))
            {
                try
                {
                    using var doc = JsonDocument.Parse(File.ReadAllText(metaPath));
                    if (doc.RootElement.TryGetProperty("cwd", out var cwdEl)
                        && cwdEl.ValueKind == JsonValueKind.String)
                    {
                        cwd = cwdEl.GetString();
                    }
                }
                catch
                {
                    // meta is optional enrichment.
                }
            }

            var project = string.IsNullOrWhiteSpace(cwd) ? "Cursor" : RepoNames.FromCwd(cwd!, _repoNameCache);
            var createdMs = new DateTimeOffset(Directory.GetCreationTimeUtc(bestDir)).ToUnixTimeMilliseconds();

            return new SessionInfo
            {
                ProjectName = project,
                Model = null,
                StartEpochMs = createdMs > 0 && createdMs <= activityMs ? createdMs : activityMs,
                TotalTokens = 0,
                LastModifiedMs = activityMs,
                Agent = AgentKind.Cursor,
            };
        }
        catch
        {
            return null;
        }
    }

    private static DateTime? AcpActivityUtc(string dir)
    {
        DateTime? best = null;
        foreach (var name in new[] { "store.db-wal", "store.db", "meta.json" })
        {
            var path = Path.Combine(dir, name);
            try
            {
                if (!File.Exists(path)) continue;
                var mtime = File.GetLastWriteTimeUtc(path);
                if (best is null || mtime > best) best = mtime;
            }
            catch
            {
                // skip locked/vanished files
            }
        }
        return best;
    }

    private sealed class TranscriptCacheEntry
    {
        public DateTime Mtime;
        public JsonlCursor Cursor = new();
        public List<long> ConversationalStampsMs = [];
        public long? CreatedAtMs;
        public long? UpdatedAtMs;
    }

    private sealed record SessionMeta(string? Cwd, long? CreatedAtMs, long? UpdatedAtMs, string? Model);

    private TranscriptCacheEntry TranscriptAggregate(string path, DateTime mtime)
    {
        if (!_transcriptCache.TryGetValue(path, out var cached))
            cached = new TranscriptCacheEntry();
        if (cached.Mtime == mtime && _transcriptCache.ContainsKey(path) && cached.Cursor.IsCurrent(path))
            return cached;

        var sessionId = Path.GetFileNameWithoutExtension(path);
        var meta = ReadMeta(sessionId, includeModel: false);
        cached.CreatedAtMs = meta?.CreatedAtMs;
        cached.UpdatedAtMs = meta?.UpdatedAtMs;

        try
        {
            cached.Cursor.PullLines(
                path,
                line => cached.ConversationalStampsMs.AddRange(TimestampsInJsonlLine(line)),
                () => cached.ConversationalStampsMs.Clear());
        }
        catch
        {
            // Live transcripts can be briefly locked; partial stamps are fine.
        }

        cached.ConversationalStampsMs.Sort();
        cached.Mtime = mtime;
        _transcriptCache[path] = cached;
        return cached;
    }

    private static (long ActiveMs, long? LastMs) ActiveDuration(
        List<long> conversationalStamps,
        long? createdAtMs,
        long? updatedAtMs,
        long cutoffMs,
        long nowMs)
    {
        var inWindow = conversationalStamps
            .Where(ms => ms >= cutoffMs && ms <= nowMs)
            .ToList();

        if (inWindow.Count == 0)
        {
            if (createdAtMs is not long created || updatedAtMs is not long updated)
                return (0, null);
            var start = Math.Max(created, cutoffMs);
            var end = Math.Min(updated, nowMs);
            return end > start ? (end - start, end) : (0, null);
        }

        var points = new HashSet<long>(inWindow);
        if (createdAtMs is long c && c >= cutoffMs && c <= nowMs) points.Add(c);
        if (updatedAtMs is long u && u >= cutoffMs && u <= nowMs) points.Add(u);
        if (createdAtMs is long createdBefore && updatedAtMs is long updatedAfter
            && createdBefore < cutoffMs && updatedAfter >= cutoffMs)
        {
            points.Add(cutoffMs);
            points.Add(Math.Min(updatedAfter, nowMs));
        }

        var unique = points.OrderBy(ms => ms).ToList();
        if (unique.Count == 0) return (0, null);

        long active = 0;
        for (var i = 1; i < unique.Count; i++)
        {
            var delta = unique[i] - unique[i - 1];
            if (delta > 0 && delta <= ActiveGapToleranceMs) active += delta;
        }
        return (active, unique[^1]);
    }

    private static IEnumerable<long> TimestampsInJsonlLine(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) yield break;

        JsonDocument doc;
        try { doc = JsonDocument.Parse(trimmed); }
        catch { yield break; }

        using (doc)
        {
            var root = doc.RootElement;
            if (!root.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object)
                yield break;

            foreach (var text in MessageTexts(message))
            {
                foreach (Match match in TimestampRegex.Matches(text))
                {
                    if (ParseEmbeddedTimestamp(match.Groups[1].Value) is long ms)
                        yield return ms;
                }
            }
        }
    }

    private static IEnumerable<string> MessageTexts(JsonElement message)
    {
        if (!message.TryGetProperty("content", out var content)) yield break;
        if (content.ValueKind == JsonValueKind.String && content.GetString() is { Length: > 0 } s)
        {
            yield return s;
            yield break;
        }
        if (content.ValueKind != JsonValueKind.Array) yield break;
        foreach (var part in content.EnumerateArray())
        {
            if (part.ValueKind == JsonValueKind.Object
                && part.TryGetProperty("text", out var text)
                && text.ValueKind == JsonValueKind.String
                && text.GetString() is { Length: > 0 } t)
            {
                yield return t;
            }
        }
    }

    private static long? ParseEmbeddedTimestamp(string raw)
    {
        var trimmed = raw.Trim();
        var utcAt = trimmed.LastIndexOf("(UTC", StringComparison.Ordinal);
        if (utcAt < 0 || !trimmed.EndsWith(')')) return null;

        var offsetBody = trimmed[(utcAt + "(UTC".Length)..^1];
        if (ParseUtcOffsetSeconds(offsetBody) is not int offsetSeconds) return null;
        var body = trimmed[..utcAt].Trim();

        var tz = TimeSpan.FromSeconds(offsetSeconds);
        string[] formats =
        [
            "dddd, MMM d, yyyy, h:mm tt",
            "dddd, MMMM d, yyyy, h:mm tt",
        ];
        var culture = CultureInfo.GetCultureInfo("en-US");
        foreach (var format in formats)
        {
            if (DateTime.TryParseExact(body, format, culture, DateTimeStyles.None, out var dt))
                return new DateTimeOffset(dt, tz).ToUnixTimeMilliseconds();
        }
        return null;
    }

    private static int? ParseUtcOffsetSeconds(string raw)
    {
        var trimmed = raw.Trim();
        if (trimmed.Length == 0) return null;
        var signChar = trimmed[0];
        if (signChar is not ('+' or '-')) return null;
        var sign = signChar == '-' ? -1 : 1;
        var body = trimmed[1..];
        var parts = body.Split(':', 2);
        if (!int.TryParse(parts[0], out var hours) || hours is < 0 or > 18) return null;
        var minutes = 0;
        if (parts.Length == 2)
        {
            if (!int.TryParse(parts[1], out minutes) || minutes is < 0 or > 59) return null;
        }
        return sign * (hours * 3600 + minutes * 60);
    }

    private SessionMeta? ReadMeta(string sessionId, bool includeModel)
    {
        if (!_metaBySessionId.TryGetValue(sessionId, out var metaPath)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(metaPath));
            var root = doc.RootElement;
            string? cwd = root.TryGetProperty("cwd", out var cwdEl) && cwdEl.ValueKind == JsonValueKind.String
                ? cwdEl.GetString()
                : null;
            long? created = LongProp(root, "createdAtMs");
            long? updated = LongProp(root, "updatedAtMs");
            string? model = includeModel
                ? ReadLastUsedModel(Path.GetDirectoryName(metaPath)!)
                : null;
            return new SessionMeta(cwd, created, updated, model);
        }
        catch
        {
            return null;
        }
    }

    private static long? LongProp(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var n)) return n;
        return null;
    }

    private string? ReadLastUsedModel(string chatDir)
    {
        var dbPath = Path.Combine(chatDir, "store.db");
        if (!File.Exists(dbPath)) return null;

        DateTime? Stamp(string path)
        {
            try { return File.GetLastWriteTimeUtc(path); }
            catch { return null; }
        }

        var stamp = new[] { Stamp(dbPath), Stamp(dbPath + "-wal") }.Where(d => d is not null).Max();
        if (_modelCache.TryGetValue(dbPath, out var cached) && cached.Stamp == stamp)
            return cached.Model;

        var model = QueryLastUsedModel(dbPath);
        _modelCache[dbPath] = (stamp, model);
        return model;
    }

    private static string? QueryLastUsedModel(string dbPath)
    {
        var bytes = LocalSqlite.QueryBytes(dbPath, "SELECT value FROM meta WHERE key = 0 LIMIT 1;");
        if (bytes is null || bytes.Length == 0) return null;
        try
        {
            using var doc = JsonDocument.Parse(bytes);
            if (doc.RootElement.TryGetProperty("lastUsedModel", out var model)
                && model.ValueKind == JsonValueKind.String
                && model.GetString() is { Length: > 0 } m)
            {
                return m;
            }
        }
        catch
        {
            // Blob is not JSON — model stays unknown.
        }
        return null;
    }

    public static string PrettyModel(string raw)
    {
        if (raw.Equals("default", StringComparison.OrdinalIgnoreCase)) return "Auto";

        var value = raw;
        if (value.StartsWith("cursor-", StringComparison.OrdinalIgnoreCase))
            value = value["cursor-".Length..];

        return string.Join(' ', value.Split('-', StringSplitOptions.RemoveEmptyEntries).Select(part =>
        {
            if (part.Length > 0 && char.IsDigit(part[0])) return part;
            if (part.Equals("gpt", StringComparison.OrdinalIgnoreCase)) return "GPT";
            return char.ToUpperInvariant(part[0]) + part[1..];
        }));
    }

    private void RebuildMetaIndexIfNeeded()
    {
        var files = _chatsTree.Snapshot(TimeSpan.FromMilliseconds(LookbackMs));
        DateTime newest = DateTime.MinValue;
        foreach (var file in files)
            if (file.Mtime > newest) newest = file.Mtime;
        if (newest == _metaIndexStamp && _metaBySessionId.Count == files.Count)
            return;

        _metaBySessionId.Clear();
        foreach (var file in files)
        {
            var sessionId = Path.GetFileName(Path.GetDirectoryName(file.Path));
            if (string.IsNullOrEmpty(sessionId)) continue;
            _metaBySessionId[sessionId] = file.Path;
        }
        _metaIndexStamp = newest;
    }

    private string ResolveProjectName(string? cwd, string transcriptPath)
    {
        if (!string.IsNullOrWhiteSpace(cwd)) return RepoNames.FromCwd(cwd, _repoNameCache);

        // ...\projects\<encoded-cwd>\agent-transcripts\...
        var parts = transcriptPath.Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var projectsIdx = Array.FindIndex(parts, p => p.Equals("projects", StringComparison.OrdinalIgnoreCase));
        if (projectsIdx >= 0 && projectsIdx + 1 < parts.Length)
        {
            var encoded = parts[projectsIdx + 1];
            var segs = encoded.Split('-', StringSplitOptions.RemoveEmptyEntries);
            if (segs.Length > 0) return segs[^1];
            return encoded;
        }
        return "";
    }

}
