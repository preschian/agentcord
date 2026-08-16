// Detects the currently active Claude Code session by scanning
// %USERPROFILE%\.claude\projects for the most recently modified .jsonl
// transcript. Port of AgentCord/ClaudeSession.swift.
//
// Tokens are summed across transcripts touched today (local calendar day).
// Elapsed time is the summed working duration across transcripts that
// touched the last 24 hours (idle gaps excluded), matching Grok / Codex /
// Cursor. The transcript schema is undocumented, so all parsing is defensive:
// malformed or unexpected lines are skipped, never fatal. Scans are driven by
// the presence controller's tick. A SessionTreeIndex plus per-file JSONL
// cursor keep idle ticks from walking or re-parsing the growing tree.

using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentCord;

public sealed class ClaudeSession : IDisposable
{
    /// <summary>A transcript counts as active if modified within this window.</summary>
    public double ActiveWindowSeconds { get; set; } = 60;

    private readonly SessionTreeIndex _tree;
    private readonly Dictionary<string, CacheEntry> _aggregateCache = [];
    private readonly Dictionary<string, string> _repoNameCache = [];

    public ClaudeSession(string? projectsDir = null)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var root = projectsDir ?? Path.Combine(home, ".claude", "projects");
        _tree = new SessionTreeIndex(root, "*.jsonl");
    }

    public void Dispose() => _tree.Dispose();

    /// <summary>Scan the transcript tree and return the active session, or null
    /// when none is active. Not thread-safe; call from one thread.</summary>
    public SessionInfo? Scan()
    {
        var files = _tree.Snapshot(TimeSpan.FromMilliseconds(SessionActivity.LookbackMs));
        if (files.Count == 0) return null;

        // Tokens stay on the local calendar day. Elapsed time is a rolling 24h
        // sum of working gaps, same window as Grok / Codex / Cursor.
        // Activity (idle + LastModifiedMs) prefers parsed event timestamps over
        // filesystem mtime so a stale mtime cannot hide a live session.
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var cutoffMs = nowMs - SessionActivity.LookbackMs;
        var dayStartMs = new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds();

        long totalTokensToday = 0;
        long totalActiveMs = 0;
        long? newestLast = null;
        string? bestPath = null;
        DayAggregate bestAgg = new();
        long bestActivityMs = long.MinValue;
        foreach (var file in files)
        {
            var agg = Aggregate(file.Path, file.Mtime, dayStartMs);
            totalTokensToday += agg.TokensToday;
            var (activeMs, lastMs) = SessionActivity.ActiveDuration(
                agg.StampsMs, null, null, cutoffMs, nowMs);
            totalActiveMs += activeMs;
            if (lastMs is long last && (newestLast is null || last > newestLast))
                newestLast = last;

            var activityMs = SessionActivity.NormalizeMs(agg.LastEventMs, file.Mtime);
            if (bestPath is null || activityMs >= bestActivityMs)
            {
                bestPath = file.Path;
                bestAgg = agg;
                bestActivityMs = activityMs;
            }
        }

        // Drop cache entries for transcripts that no longer exist.
        var live = files.Select(f => f.Path).ToHashSet();
        foreach (var stale in _aggregateCache.Keys.Where(k => !live.Contains(k)).ToList())
            _aggregateCache.Remove(stale);

        if (bestPath is null) return null;
        if (!SessionActivity.IsWithinWindow(bestActivityMs, ActiveWindowSeconds)) return null;

        return MakeSessionInfo(bestPath, bestActivityMs, bestAgg, totalTokensToday, totalActiveMs, newestLast, nowMs);
    }

    // --- Parsing

    /// <summary>Per-transcript figures from one .jsonl.</summary>
    private sealed class DayAggregate
    {
        public string? Cwd;
        public string? Model;
        /// <summary>Newest parseable event timestamp in the transcript (any day),
        /// used for idle detection and LastModifiedMs.</summary>
        public long? LastEventMs;
        /// <summary>Event timestamps used to sum working time inside the 24h window.</summary>
        public List<long> StampsMs = [];
        public long TokensToday;
    }

    private sealed class CacheEntry
    {
        public DateTime Mtime;
        public long DayStartMs;
        public JsonlCursor Cursor = new();
        public DayAggregate Aggregate = new();
    }

    /// <summary>Memoized per file. Unchanged files reuse the last aggregate; a
    /// growing file only parses newly appended JSONL lines. The day boundary
    /// forces a reset because it changes which lines count toward today's
    /// token total.</summary>
    private DayAggregate Aggregate(string path, DateTime mtime, long dayStartMs)
    {
        if (!_aggregateCache.TryGetValue(path, out var entry))
            entry = new CacheEntry { DayStartMs = dayStartMs };
        else if (entry.Mtime == mtime && entry.DayStartMs == dayStartMs && entry.Cursor.IsCurrent(path))
            return entry.Aggregate;

        if (entry.DayStartMs != dayStartMs)
            entry = new CacheEntry { Mtime = mtime, DayStartMs = dayStartMs };

        var stampFloorMs = dayStartMs - SessionActivity.LookbackMs;
        try
        {
            entry.Cursor.PullLines(
                path,
                line => ConsumeLine(line, entry.Aggregate, dayStartMs, stampFloorMs),
                () => entry.Aggregate = new DayAggregate());
        }
        catch
        {
            // File vanished or unreadable mid-scan; keep whatever we parsed.
        }

        entry.Mtime = mtime;
        entry.DayStartMs = dayStartMs;
        _aggregateCache[path] = entry;
        return entry.Aggregate;
    }

    private static void ConsumeLine(string line, DayAggregate agg, long dayStartMs, long stampFloorMs)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0) return;

        JsonDocument doc;
        try { doc = JsonDocument.Parse(trimmed); }
        catch { return; }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;

            if (agg.Cwd is null
                && root.TryGetProperty("cwd", out var cwd)
                && cwd.ValueKind == JsonValueKind.String
                && cwd.GetString() is { Length: > 0 } c)
            {
                agg.Cwd = c;
            }

            long? lineMs = null;
            if (root.TryGetProperty("timestamp", out var ts) && ts.ValueKind == JsonValueKind.String)
                lineMs = EpochMsFromIso(ts.GetString());
            if (lineMs is long anyMs)
            {
                agg.LastEventMs = Math.Max(agg.LastEventMs ?? anyMs, anyMs);
                if (anyMs >= stampFloorMs) agg.StampsMs.Add(anyMs);
            }
            var isToday = (lineMs ?? long.MinValue) >= dayStartMs;

            if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object)
            {
                if (message.TryGetProperty("model", out var model)
                    && model.ValueKind == JsonValueKind.String
                    && model.GetString() is { Length: > 0 } m
                    && m != "<synthetic>")
                {
                    agg.Model = m;
                }
                if (isToday && message.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Object)
                {
                    agg.TokensToday += IntProp(usage, "input_tokens") + IntProp(usage, "output_tokens");
                }
            }
        }
    }

    private static long IntProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : 0;

    private SessionInfo MakeSessionInfo(
        string newestPath, long activityMs, DayAggregate active, long totalTokensToday,
        long totalActiveMs, long? newestLast, long nowMs)
    {
        var projectName = DeriveProjectName(Path.GetFileName(Path.GetDirectoryName(newestPath)) ?? "");
        if (active.Cwd is not null) projectName = RepoNames.FromCwd(active.Cwd, _repoNameCache);

        return new SessionInfo
        {
            ProjectName = projectName.Length == 0 ? "Claude Code" : projectName,
            Model = active.Model is null ? null : PrettyModel(active.Model),
            StartEpochMs = SessionActivity.ElapsedStartMs(totalActiveMs, newestLast, nowMs),
            TotalTokens = totalTokensToday,
            LastModifiedMs = activityMs,
            Agent = AgentKind.Claude,
        };
    }

    /// <summary>Claude Code encodes the project's cwd into the directory name by
    /// replacing path separators with hyphens. As a fallback (when no cwd field
    /// is present) we take the trailing segment.</summary>
    private static string DeriveProjectName(string dir)
    {
        var parts = dir.Split('-', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length > 0 ? parts[^1] : dir;
    }

    // --- Static helpers

    public static long? EpochMsFromIso(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        return DateTimeOffset.TryParse(
            s, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.RoundtripKind, out var dto)
            ? dto.ToUnixTimeMilliseconds()
            : null;
    }

    /// <summary>Turn a raw model id such as "claude-opus-4-5-20260101" into "Opus 4.5".</summary>
    public static string PrettyModel(string raw)
    {
        var lower = raw.ToLowerInvariant();
        string family;
        if (lower.Contains("opus")) family = "Opus";
        else if (lower.Contains("sonnet")) family = "Sonnet";
        else if (lower.Contains("haiku")) family = "Haiku";
        else if (lower.Contains("fable")) family = "Fable";
        else return raw;

        var match = Regex.Match(raw, "[0-9]+([.-][0-9]+)?");
        return match.Success ? $"{family} {match.Value.Replace('-', '.')}" : family;
    }
}
