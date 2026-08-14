// Tracks Google Antigravity / Gemini usage across rolling 5-hour and weekly
// (7-day) windows by scanning local conversation transcripts in
// %USERPROFILE%\.gemini\antigravity-cli\brain and parsing rate-limit / quota
// reset signals from cli logs.

using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentCord;

public sealed class AntigravityUsage : IDisposable
{
    public AntigravityUsageInfo? Current { get; private set; }

    public string? AccountEmail { get; private set; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(60);
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromSeconds(10);
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromHours(24);

    // Google AI Pro calibrated baseline capacities for rolling window percentages (used %)
    public const int DefaultFiveHourCapacity = 500_000;
    public const int DefaultWeeklyCapacity = 4_500_000;

    private readonly string _baseDir;
    private readonly object _lock = new();
    private readonly Dictionary<string, (DateTime Mtime, List<StepRecord> Steps)> _fileStepsCache = [];
    private DateTime _lastSuccess = DateTime.MinValue;
    private DateTime _lastAttempt = DateTime.MinValue;
    private System.Threading.Timer? _timer;

    public sealed record StepRecord(long EpochMs, int EstTokens);

    public AntigravityUsage(string? customBaseDir = null)
    {
        _baseDir = AntigravitySession.ResolveBaseDir(customBaseDir);
        if (LoadCache() is { } cached
            && DateTime.UtcNow - cached.FetchedAt <= MaxStaleness)
        {
            Current = cached.Info;
            AccountEmail = cached.Email;
            _lastSuccess = cached.FetchedAt;
        }
    }

    public void Start()
    {
        var first = Current is null ? TimeSpan.FromSeconds(1) : TimeSpan.FromSeconds(5);
        _timer = new System.Threading.Timer(_ => Fetch(), null, first, PollInterval);
    }

    public void Refresh()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _lastAttempt < MinFetchInterval) return;
        }
        Fetch();
    }

    public void Dispose()
    {
        _timer?.Dispose();
    }

    public void Fetch()
    {
        lock (_lock) _lastAttempt = DateTime.UtcNow;

        try
        {
            if (!Directory.Exists(_baseDir))
            {
                Current = null;
                return;
            }

            var (email, plan) = ScanAccountAndPlan();
            if (email is not null) AccountEmail = email;

            var (exhausted, exhaustResetsAtMs) = ScanQuotaExhaustion();

            var now = DateTime.UtcNow;
            var nowMs = new DateTimeOffset(now).ToUnixTimeMilliseconds();
            var fiveHoursAgoMs = new DateTimeOffset(now.AddHours(-5)).ToUnixTimeMilliseconds();
            var sevenDaysAgoMs = new DateTimeOffset(now.AddDays(-7)).ToUnixTimeMilliseconds();

            var allSteps = ScanAllSteps();

            var fiveHourTokens = 0;
            long? oldestInFiveHour = null;

            var weeklyTokens = 0;
            long? oldestInWeekly = null;

            foreach (var step in allSteps)
            {
                if (step.EpochMs >= fiveHoursAgoMs)
                {
                    fiveHourTokens += step.EstTokens;
                    if (oldestInFiveHour is null || step.EpochMs < oldestInFiveHour)
                        oldestInFiveHour = step.EpochMs;
                }

                if (step.EpochMs >= sevenDaysAgoMs)
                {
                    weeklyTokens += step.EstTokens;
                    if (oldestInWeekly is null || step.EpochMs < oldestInWeekly)
                        oldestInWeekly = step.EpochMs;
                }
            }

            // 5-Hour rolling window
            var fiveHourPercent = Math.Clamp((int)Math.Round((double)fiveHourTokens / DefaultFiveHourCapacity * 100), 0, 100);
            var fiveHourResetsAtMs = oldestInFiveHour is long o5
                ? o5 + (5 * 3600 * 1000)
                : nowMs + (5 * 3600 * 1000);

            var fiveHourWindow = new UsageWindow
            {
                Percent = fiveHourPercent,
                Severity = SeverityFor(fiveHourPercent),
                ResetsAtMs = fiveHourResetsAtMs,
            };

            // Weekly rolling window
            var weeklyPercent = exhausted
                ? 100
                : Math.Clamp((int)Math.Round((double)weeklyTokens / DefaultWeeklyCapacity * 100), 0, 100);

            var weeklyResetsAtMs = exhaustResetsAtMs ?? (oldestInWeekly is long ow
                ? ow + (7 * 24 * 3600 * 1000)
                : nowMs + (7 * 24 * 3600 * 1000));

            var weeklyWindow = new UsageWindow
            {
                Percent = weeklyPercent,
                Severity = exhausted ? "critical" : SeverityFor(weeklyPercent),
                ResetsAtMs = weeklyResetsAtMs,
            };

            var planLabel = plan ?? "Google AI Pro";

            var info = new AntigravityUsageInfo
            {
                FiveHour = fiveHourWindow,
                Weekly = weeklyWindow,
                PlanName = planLabel,
            };

            lock (_lock)
            {
                Current = info;
                _lastSuccess = DateTime.UtcNow;
            }

            SaveCache(info, _lastSuccess, AccountEmail);
        }
        catch
        {
            // Keep last valid snapshot
        }
    }

    private static string SeverityFor(int percent) => percent switch
    {
        >= 90 => "critical",
        >= 75 => "warning",
        _ => "normal",
    };

    private List<StepRecord> ScanAllSteps()
    {
        var brainDir = Path.Combine(_baseDir, "brain");
        if (!Directory.Exists(brainDir)) return [];

        List<string> transcriptPaths;
        try
        {
            transcriptPaths = Directory.EnumerateFiles(brainDir, "transcript.jsonl", SearchOption.AllDirectories).ToList();
        }
        catch
        {
            return [];
        }

        var results = new List<StepRecord>();

        foreach (var path in transcriptPaths)
        {
            try
            {
                var mtime = File.GetLastWriteTimeUtc(path);
                if (_fileStepsCache.TryGetValue(path, out var cached) && cached.Mtime == mtime)
                {
                    results.AddRange(cached.Steps);
                    continue;
                }

                var steps = ParseTranscriptSteps(path);
                _fileStepsCache[path] = (mtime, steps);
                results.AddRange(steps);
            }
            catch { }
        }

        // Drop stale cache entries
        var currentSet = transcriptPaths.ToHashSet();
        foreach (var stale in _fileStepsCache.Keys.Where(p => !currentSet.Contains(p)).ToList())
            _fileStepsCache.Remove(stale);

        return results;
    }

    private static List<StepRecord> ParseTranscriptSteps(string transcriptPath)
    {
        var steps = new List<StepRecord>();
        using var stream = new FileStream(transcriptPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream);

        while (reader.ReadLine() is { } line)
        {
            if (line.Length < 10) continue;
            try
            {
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                if (!root.TryGetProperty("created_at", out var created) || created.ValueKind != JsonValueKind.String)
                    continue;

                if (!DateTime.TryParse(created.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var dt))
                    continue;

                var epochMs = new DateTimeOffset(dt).ToUnixTimeMilliseconds();

                var len = 0;
                if (root.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String)
                    len += c.GetString()?.Length ?? 0;
                if (root.TryGetProperty("thinking", out var th) && th.ValueKind == JsonValueKind.String)
                    len += th.GetString()?.Length ?? 0;

                // Estimate tokens (~4 characters per token) with minimum 1 token per step
                var estTokens = Math.Max(1, (int)Math.Round(len / 4.0));
                steps.Add(new StepRecord(epochMs, estTokens));
            }
            catch { }
        }

        return steps;
    }

    private (string? Email, string? Plan) ScanAccountAndPlan()
    {
        var logDir = Path.Combine(_baseDir, "log");
        var logFiles = new List<string>();

        var mainLog = Path.Combine(_baseDir, "cli.log");
        if (File.Exists(mainLog)) logFiles.Add(mainLog);

        if (Directory.Exists(logDir))
        {
            try
            {
                var files = Directory.EnumerateFiles(logDir, "cli-*.log")
                    .Select(p => (Path: p, Mtime: File.GetLastWriteTimeUtc(p)))
                    .OrderByDescending(f => f.Mtime)
                    .Select(f => f.Path);
                logFiles.AddRange(files);
            }
            catch { }
        }

        string? email = null;
        string? plan = null;

        foreach (var logFile in logFiles)
        {
            try
            {
                using var stream = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream);
                while (reader.ReadLine() is { } line)
                {
                    if (email is null)
                    {
                        var m = Regex.Match(line, @"(?:applyAuthResult:\s*email=|authenticated successfully as\s+|email=)([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)");
                        if (m.Success) email = m.Groups[1].Value;
                    }
                    if (plan is null)
                    {
                        var m = Regex.Match(line, @"(?:authMethod|tier|plan)=([a-zA-Z0-9_-]+)");
                        if (m.Success) plan = AntigravitySession.FormatPlan(m.Groups[1].Value);
                    }
                }
            }
            catch { }

            if (email is not null && plan is not null) break;
        }

        if (email is not null && plan is null) plan = "Google AI Pro";
        return (email, plan);
    }

    private (bool Exhausted, long? ResetsAtMs) ScanQuotaExhaustion()
    {
        var logDir = Path.Combine(_baseDir, "log");
        if (!Directory.Exists(logDir)) return (false, null);

        try
        {
            var latestLog = Directory.EnumerateFiles(logDir, "cli-*.log")
                .Select(p => (Path: p, Mtime: File.GetLastWriteTimeUtc(p)))
                .OrderByDescending(f => f.Mtime)
                .FirstOrDefault();

            if (latestLog.Path is null || DateTime.UtcNow - latestLog.Mtime > TimeSpan.FromHours(1))
                return (false, null);

            using var stream = new FileStream(latestLog.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            string? lastQuotaLine = null;
            while (reader.ReadLine() is { } line)
            {
                if (line.Contains("RESOURCE_EXHAUSTED", StringComparison.OrdinalIgnoreCase)
                    || line.Contains("Individual quota reached", StringComparison.OrdinalIgnoreCase))
                {
                    lastQuotaLine = line;
                }
            }

            if (lastQuotaLine is not null)
            {
                var match = Regex.Match(lastQuotaLine, @"Resets in (?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?");
                if (match.Success)
                {
                    var hours = match.Groups[1].Success ? int.Parse(match.Groups[1].Value) : 0;
                    var minutes = match.Groups[2].Success ? int.Parse(match.Groups[2].Value) : 0;
                    var seconds = match.Groups[3].Success ? int.Parse(match.Groups[3].Value) : 0;
                    var remaining = new TimeSpan(hours, minutes, seconds);
                    var resetMs = new DateTimeOffset(latestLog.Mtime + remaining).ToUnixTimeMilliseconds();
                    if (resetMs > DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
                        return (true, resetMs);
                }
            }
        }
        catch { }

        return (false, null);
    }

    // --- Disk cache

    private sealed record CacheFile(
        AntigravityUsageInfo Info,
        DateTime FetchedAt,
        string? Email);

    private static string CachePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "AgentCord",
        "antigravity_usage.json");

    private static CacheFile? LoadCache()
    {
        try
        {
            var path = CachePath;
            if (!File.Exists(path)) return null;
            return JsonSerializer.Deserialize<CacheFile>(File.ReadAllText(path));
        }
        catch
        {
            return null;
        }
    }

    private static void SaveCache(AntigravityUsageInfo info, DateTime fetchedAt, string? email)
    {
        try
        {
            var path = CachePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var payload = JsonSerializer.Serialize(new CacheFile(info, fetchedAt, email));
            File.WriteAllText(path, payload);
        }
        catch { }
    }
}
