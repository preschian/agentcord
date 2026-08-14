// Tracks Google Antigravity / Gemini usage across 5-hour and weekly limits
// by querying the official CLI (`agy -p "/usage" --output-format json`) for
// exact server-reported remaining percentages and reset timestamps, with a
// local transcript rolling-window fallback.

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

    // Fallback baseline capacities when agy CLI output is unavailable
    public const int DefaultFiveHourCapacity = 500_000;
    public const int DefaultWeeklyCapacity = 4_500_000;

    private readonly string _baseDir;
    private readonly bool _isCustomDir;
    private readonly object _lock = new();
    private readonly Dictionary<string, (DateTime Mtime, List<StepRecord> Steps)> _fileStepsCache = [];
    private DateTime _lastSuccess = DateTime.MinValue;
    private DateTime _lastAttempt = DateTime.MinValue;
    private int _fetching;
    private System.Threading.Timer? _timer;

    public sealed record StepRecord(long EpochMs, int EstTokens);

    public AntigravityUsage(string? customBaseDir = null)
    {
        _isCustomDir = !string.IsNullOrEmpty(customBaseDir);
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
        // agy /usage can take several seconds. Never run it on the tray click
        // path — Claude/Codex/Cursor/Grok already refresh off-thread.
        _ = Task.Run(Fetch);
    }

    public void Dispose()
    {
        _timer?.Dispose();
    }

    public void Fetch()
    {
        if (Interlocked.Exchange(ref _fetching, 1) == 1) return;
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

            var planLabel = plan ?? "Google AI Pro";

            // 1. First attempt: Query live official usage directly from agy CLI (when not in custom test dir)
            if (!_isCustomDir)
            {
                var officialInfo = QueryOfficialAgyUsage(planLabel);
                if (officialInfo is not null)
                {
                    lock (_lock)
                    {
                        Current = officialInfo;
                        _lastSuccess = DateTime.UtcNow;
                    }
                    SaveCache(officialInfo, _lastSuccess, AccountEmail);
                    return;
                }
            }

            // 2. Fallback: Local transcript rolling-window calculation
            var fallbackInfo = ComputeFallbackUsage(planLabel);
            if (fallbackInfo is not null)
            {
                lock (_lock)
                {
                    Current = fallbackInfo;
                    _lastSuccess = DateTime.UtcNow;
                }
                SaveCache(fallbackInfo, _lastSuccess, AccountEmail);
            }
        }
        catch
        {
            // Keep last valid snapshot
        }
        finally
        {
            Interlocked.Exchange(ref _fetching, 0);
        }
    }

    public static string? FindAgyExecutable()
    {
        var localApp = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "agy", "bin", "agy.exe");
        if (File.Exists(localApp)) return localApp;

        var geminiBin = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".gemini", "antigravity-cli", "bin", "agy.exe");
        if (File.Exists(geminiBin)) return geminiBin;

        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrEmpty(pathEnv))
        {
            foreach (var p in pathEnv.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var candidate = Path.Combine(p, "agy.exe");
                if (File.Exists(candidate)) return candidate;
            }
        }

        return "agy";
    }

    private static AntigravityUsageInfo? QueryOfficialAgyUsage(string planLabel)
    {
        var agyExe = FindAgyExecutable();
        if (string.IsNullOrEmpty(agyExe)) return null;

        try
        {
            var psi = new ProcessStartInfo(agyExe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            psi.ArgumentList.Add("-p");
            psi.ArgumentList.Add("/usage");
            psi.ArgumentList.Add("--output-format");
            psi.ArgumentList.Add("json");

            using var process = Process.Start(psi);
            if (process is null) return null;

            var output = process.StandardOutput.ReadToEnd().Trim();
            if (!process.WaitForExit(7000))
            {
                process.Kill();
                return null;
            }

            if (process.ExitCode == 0 && output.Length > 0)
            {
                return ParseAgyUsageJson(output, planLabel);
            }
        }
        catch { }

        return null;
    }

    public static AntigravityUsageInfo? ParseAgyUsageJson(string json, string planLabel = "Google AI Pro")
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (!root.TryGetProperty("command", out var cmd) || cmd.ValueKind != JsonValueKind.Object)
                return null;
            if (!cmd.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
                return null;
            if (!data.TryGetProperty("groups", out var groups) || groups.ValueKind != JsonValueKind.Array)
                return null;

            UsageWindow? fiveHour = null;
            UsageWindow? weekly = null;

            foreach (var group in groups.EnumerateArray())
            {
                var groupName = group.TryGetProperty("name", out var gName) ? gName.GetString() : null;
                if (!group.TryGetProperty("buckets", out var buckets) || buckets.ValueKind != JsonValueKind.Array)
                    continue;

                foreach (var bucket in buckets.EnumerateArray())
                {
                    var window = bucket.TryGetProperty("window", out var w) ? w.GetString() : null;
                    var remainingFraction = bucket.TryGetProperty("remaining_fraction", out var rf) && rf.ValueKind == JsonValueKind.Number
                        ? rf.GetDouble() : 1.0;
                    var resetTime = bucket.TryGetProperty("reset_time", out var rt) ? rt.GetString() : null;

                    // Convert remaining fraction to used percentage (e.g. 0.78 remaining -> 22% used)
                    var usedFraction = Math.Clamp(1.0 - remainingFraction, 0.0, 1.0);
                    var percent = (int)Math.Round(usedFraction * 100);

                    long? resetMs = null;
                    if (!string.IsNullOrEmpty(resetTime)
                        && DateTime.TryParse(resetTime, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal, out var dt))
                    {
                        resetMs = new DateTimeOffset(dt).ToUnixTimeMilliseconds();
                    }

                    var usageWindow = new UsageWindow
                    {
                        Percent = percent,
                        Severity = SeverityFor(percent),
                        ResetsAtMs = resetMs,
                    };

                    // Prioritize "Gemini Models" group
                    if (groupName?.Contains("Gemini", StringComparison.OrdinalIgnoreCase) == true || fiveHour is null)
                    {
                        var bucketId = bucket.TryGetProperty("id", out var id) ? id.GetString() : "";
                        if (window == "5h" || bucketId?.Contains("5h", StringComparison.OrdinalIgnoreCase) == true)
                        {
                            fiveHour = usageWindow;
                        }
                        else if (window == "weekly" || bucketId?.Contains("weekly", StringComparison.OrdinalIgnoreCase) == true)
                        {
                            weekly = usageWindow;
                        }
                    }
                }
            }

            if (fiveHour is null && weekly is null) return null;

            return new AntigravityUsageInfo
            {
                FiveHour = fiveHour ?? new UsageWindow { Percent = 0, Severity = "normal" },
                Weekly = weekly ?? new UsageWindow { Percent = 0, Severity = "normal" },
                PlanName = planLabel,
            };
        }
        catch
        {
            return null;
        }
    }

    private AntigravityUsageInfo? ComputeFallbackUsage(string planLabel)
    {
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

        return new AntigravityUsageInfo
        {
            FiveHour = fiveHourWindow,
            Weekly = weeklyWindow,
            PlanName = planLabel,
        };
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
