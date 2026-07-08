// Detects the currently active Claude Code session by scanning
// %USERPROFILE%\.claude\projects for the most recently modified .jsonl
// transcript. Port of AgentCord/ClaudeSession.swift.
//
// The transcript schema is undocumented, so all parsing is defensive:
// malformed or unexpected lines are skipped, never fatal. Scans are driven by
// the presence controller's tick (the macOS FSEvents watcher becomes a plain
// re-scan here; the per-file cache keeps that cheap).

using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentCord;

public sealed class ClaudeSession
{
    /// <summary>A transcript counts as active if modified within this window.</summary>
    public double ActiveWindowSeconds { get; set; } = 60;

    /// <summary>When summing the day's working time, a gap between two consecutive
    /// messages longer than this is treated as a break (idle), not work, so a
    /// session left open does not inflate the total. This also excludes the gaps
    /// between separate sessions.</summary>
    private const long ActiveGapToleranceMs = 5 * 60 * 1000;

    private readonly string _projectsDir;
    private readonly Dictionary<string, CacheEntry> _aggregateCache = [];
    private readonly Dictionary<string, string> _repoNameCache = [];

    public ClaudeSession()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _projectsDir = Path.Combine(home, ".claude", "projects");
    }

    /// <summary>Scan the transcript tree and return the active session, or null
    /// when none is active. Not thread-safe; call from one thread.</summary>
    public SessionInfo? Scan()
    {
        List<(string Path, DateTime Mtime)> files;
        try
        {
            files = Directory
                .EnumerateFiles(_projectsDir, "*.jsonl", SearchOption.AllDirectories)
                .Select(p => (Path: p, Mtime: File.GetLastWriteTimeUtc(p)))
                .ToList();
        }
        catch
        {
            return null;
        }
        if (files.Count == 0) return null;

        var newest = files.MaxBy(f => f.Mtime);
        if ((DateTime.UtcNow - newest.Mtime).TotalSeconds > ActiveWindowSeconds) return null;

        // The presence shows daily totals: tokens summed across every transcript
        // touched today, and an elapsed timer that reflects the combined working
        // time of all of today's sessions (idle gaps between sessions excluded).
        // "Today" is the local calendar day, so the totals reset at midnight.
        var dayStartMs = new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds();

        long totalTokensToday = 0;
        long totalActiveMs = 0;
        var activeAgg = new DayAggregate();
        foreach (var file in files)
        {
            var agg = Aggregate(file.Path, file.Mtime, dayStartMs);
            totalTokensToday += agg.TokensToday;
            totalActiveMs += agg.ActiveMsToday;
            if (file.Path == newest.Path) activeAgg = agg;
        }

        // Drop cache entries for transcripts that no longer exist.
        var live = files.Select(f => f.Path).ToHashSet();
        foreach (var stale in _aggregateCache.Keys.Where(k => !live.Contains(k)).ToList())
            _aggregateCache.Remove(stale);

        return MakeSessionInfo(newest.Path, newest.Mtime, activeAgg, totalTokensToday, totalActiveMs);
    }

    // --- Parsing

    /// <summary>Per-transcript figures restricted to today, from one .jsonl.</summary>
    private sealed class DayAggregate
    {
        public string? Cwd;
        public string? Model;
        /// <summary>Timestamp (epoch ms) of the last message recorded today, used
        /// to extend the active session's working time up to "now".</summary>
        public long? LastTodayMs;
        /// <summary>Working time today: the sum of gaps between consecutive
        /// messages, counting only gaps short enough to be continuous work.</summary>
        public long ActiveMsToday;
        public long TokensToday;
    }

    private sealed record CacheEntry(DateTime Mtime, long DayStartMs, DayAggregate Aggregate);

    /// <summary>Parsing every transcript on each scan would be wasteful, so
    /// results are memoized per file. An entry is reused only while the file is
    /// unmodified and we are still on the same calendar day (the day boundary
    /// changes which lines count as "today").</summary>
    private DayAggregate Aggregate(string path, DateTime mtime, long dayStartMs)
    {
        if (_aggregateCache.TryGetValue(path, out var entry)
            && entry.Mtime == mtime && entry.DayStartMs == dayStartMs)
        {
            return entry.Aggregate;
        }

        var agg = new DayAggregate();
        long? prevTodayMs = null;
        try
        {
            foreach (var line in File.ReadLines(path))
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0) continue;

                JsonDocument doc;
                try { doc = JsonDocument.Parse(trimmed); }
                catch { continue; }

                using (doc)
                {
                    var root = doc.RootElement;
                    if (root.ValueKind != JsonValueKind.Object) continue;

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

                    if (isToday && lineMs is long ms)
                    {
                        // Add the gap from the previous message only if it is short
                        // enough to count as continuous work (idle breaks excluded).
                        if (prevTodayMs is long prev)
                        {
                            var delta = ms - prev;
                            if (delta > 0 && delta <= ActiveGapToleranceMs) agg.ActiveMsToday += delta;
                        }
                        prevTodayMs = ms;
                        agg.LastTodayMs = ms;
                    }
                }
            }
        }
        catch
        {
            // File vanished or unreadable mid-scan; keep whatever we parsed.
        }

        _aggregateCache[path] = new CacheEntry(mtime, dayStartMs, agg);
        return agg;
    }

    private static long IntProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt64(out var n) ? n : 0;

    private SessionInfo MakeSessionInfo(
        string newestPath, DateTime newestMtime, DayAggregate active, long totalTokensToday, long totalActiveMs)
    {
        var projectName = DeriveProjectName(Path.GetFileName(Path.GetDirectoryName(newestPath)) ?? "");
        if (active.Cwd is not null) projectName = RepoName(active.Cwd);

        // totalActiveMs covers work up to each session's last logged message.
        // The active session is ongoing, so extend it from its last message to
        // "now" (while that gap stays within the work tolerance). Backdating
        // start by the total makes Discord's elapsed timer show the combined
        // working time of all of today's sessions.
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var elapsedMs = totalActiveMs;
        if (active.LastTodayMs is long last)
        {
            var tail = nowMs - last;
            if (tail > 0 && tail <= ActiveGapToleranceMs) elapsedMs += tail;
        }

        return new SessionInfo
        {
            ProjectName = projectName.Length == 0 ? "Claude Code" : projectName,
            Model = active.Model is null ? null : PrettyModel(active.Model),
            StartEpochMs = nowMs - elapsedMs,
            TotalTokens = totalTokensToday,
            LastModifiedMs = new DateTimeOffset(newestMtime).ToUnixTimeMilliseconds(),
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

    /// <summary>Resolve the repository name for a working directory. Prefers the
    /// git remote (so a worktree like ".../agentcord/abuja" still reports
    /// "agentcord"), then the git toplevel, then the directory name.</summary>
    private string RepoName(string cwd)
    {
        if (_repoNameCache.TryGetValue(cwd, out var cached)) return cached;

        var name = Path.GetFileName(cwd.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = cwd;

        if (RunGit(["-C", cwd, "config", "--get", "remote.origin.url"]) is { } remote)
        {
            var baseName = remote.Split('/', '\\')[^1];
            if (baseName.EndsWith(".git", StringComparison.OrdinalIgnoreCase)) baseName = baseName[..^4];
            if (baseName.Length > 0) name = baseName;
        }
        else if (RunGit(["-C", cwd, "rev-parse", "--show-toplevel"]) is { } top)
        {
            var baseName = Path.GetFileName(top.TrimEnd('\\', '/'));
            if (!string.IsNullOrEmpty(baseName)) name = baseName;
        }

        _repoNameCache[cwd] = name;
        return name;
    }

    private static string? RunGit(string[] args)
    {
        try
        {
            var psi = new ProcessStartInfo("git")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true, // don't flash a console from the tray app
            };
            foreach (var a in args) psi.ArgumentList.Add(a);

            using var process = Process.Start(psi);
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd().Trim();
            if (!process.WaitForExit(5000))
            {
                process.Kill();
                return null;
            }
            return process.ExitCode == 0 && output.Length > 0 ? output : null;
        }
        catch
        {
            return null;
        }
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
