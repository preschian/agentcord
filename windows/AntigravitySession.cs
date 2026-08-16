// Detects active Antigravity CLI sessions by scanning the local transcript tree
// under %USERPROFILE%\.gemini\antigravity-cli\brain (or %ANTIGRAVITY_CLI_HOME%)
// and tracking presence lock files and history.

using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AgentCord;

public sealed class AntigravitySession : IDisposable
{
    public double ActiveWindowSeconds { get; set; } = 60;

    public string? AccountEmail { get; private set; }
    public string? PlanType { get; private set; }

    private readonly string _baseDir;
    private readonly SessionTreeIndex _transcriptTree;
    private readonly Dictionary<string, CacheEntry> _cache = [];
    private readonly Dictionary<string, string> _repoNameCache = [];
    private readonly Dictionary<string, (string Workspace, long Timestamp)> _historyByConvId = [];
    private DateTime _historyCacheMtime = DateTime.MinValue;
    private DateTime? _accountLogsStamp;
    private bool _accountLogsScanned;

    public AntigravitySession(string? baseDir = null)
    {
        _baseDir = ResolveBaseDir(baseDir);
        _transcriptTree = new SessionTreeIndex(Path.Combine(_baseDir, "brain"), "transcript.jsonl");
    }

    public void Dispose() => _transcriptTree.Dispose();

    public static string ResolveBaseDir(string? customBaseDir = null)
    {
        if (!string.IsNullOrEmpty(customBaseDir)) return customBaseDir;

        var envHome = Environment.GetEnvironmentVariable("ANTIGRAVITY_CLI_HOME")
            ?? Environment.GetEnvironmentVariable("ANTIGRAVITY_HOME")
            ?? Environment.GetEnvironmentVariable("GEMINI_CLI_HOME")
            ?? Environment.GetEnvironmentVariable("GEMINI_HOME");
        if (!string.IsNullOrEmpty(envHome) && Directory.Exists(envHome))
            return envHome;

        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var defaultGemini = Path.Combine(userProfile, ".gemini", "antigravity-cli");
        if (Directory.Exists(defaultGemini)) return defaultGemini;

        var altAntigravity = Path.Combine(userProfile, ".antigravity");
        if (Directory.Exists(altAntigravity)) return altAntigravity;

        return defaultGemini;
    }

    public static bool IsInstalled(string? customBaseDir = null)
    {
        var dir = ResolveBaseDir(customBaseDir);
        return Directory.Exists(dir);
    }

    public SessionInfo? Scan()
    {
        if (!Directory.Exists(_baseDir)) return null;

        RefreshHistory();
        RefreshAccountInfo();

        var presenceDir = Path.Combine(_baseDir, "presence");

        var transcriptFiles = _transcriptTree.Snapshot(TimeSpan.FromMilliseconds(SessionActivity.LookbackMs));

        // Check active presence locks
        var presenceLocks = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);
        if (Directory.Exists(presenceDir))
        {
            try
            {
                foreach (var lockFile in Directory.EnumerateFiles(presenceDir, "*.lock"))
                {
                    var convId = Path.GetFileNameWithoutExtension(lockFile);
                    if (!string.IsNullOrEmpty(convId))
                        presenceLocks[convId] = File.GetLastWriteTimeUtc(lockFile);
                }
            }
            catch { }
        }

        if (transcriptFiles.Count == 0 && presenceLocks.Count == 0 && _historyByConvId.Count == 0)
            return null;

        SessionInfo? best = null;

        foreach (var file in transcriptFiles)
        {
            var convId = ExtractConversationId(file.Path);
            var state = ReadTranscript(file.Path, file.Mtime, convId);

            var fileActivityMs = SessionActivity.NormalizeMs(state.LastEventAtMs, file.Mtime);
            if (convId is not null && presenceLocks.TryGetValue(convId, out var lockMtime))
            {
                var lockMs = new DateTimeOffset(lockMtime).ToUnixTimeMilliseconds();
                if (lockMs > fileActivityMs) fileActivityMs = lockMs;
            }

            if (!SessionActivity.IsWithinWindow(fileActivityMs, ActiveWindowSeconds)) continue;

            var workspace = state.Cwd;
            if (string.IsNullOrEmpty(workspace) && convId is not null && _historyByConvId.TryGetValue(convId, out var hist))
                workspace = hist.Workspace;

            var project = !string.IsNullOrWhiteSpace(workspace)
                ? RepoNames.FromCwd(workspace, _repoNameCache)
                : "Antigravity";

            var info = new SessionInfo
            {
                ProjectName = project,
                Model = state.Model is null ? null : PrettyModel(state.Model),
                StartEpochMs = 0,
                TotalTokens = state.TotalTokens,
                LastModifiedMs = fileActivityMs,
                Agent = AgentKind.Antigravity,
            };

            if (best is null || info.LastModifiedMs > best.LastModifiedMs)
                best = info;
        }

        // Clean stale cache entries
        var livePaths = transcriptFiles.Select(f => f.Path).ToHashSet();
        foreach (var stale in _cache.Keys.Where(p => !livePaths.Contains(p)).ToList())
            _cache.Remove(stale);

        return best is null ? null : WithRollingStart(best, transcriptFiles);
    }

    private SessionInfo WithRollingStart(SessionInfo info, IReadOnlyList<(string Path, DateTime Mtime)> files)
    {
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var cutoffMs = nowMs - SessionActivity.LookbackMs;
        long total = 0;
        long? newestLast = null;

        foreach (var file in files)
        {
            var convId = ExtractConversationId(file.Path);
            var state = ReadTranscript(file.Path, file.Mtime, convId);
            var activityMs = SessionActivity.NormalizeMs(state.LastEventAtMs, file.Mtime);
            if (activityMs < cutoffMs) continue;

            var (activeMs, lastMs) = SessionActivity.ActiveDuration(
                state.StampsMs, state.StartedAtMs, state.LastEventAtMs, cutoffMs, nowMs);
            total += activeMs;
            if (lastMs is long last && (newestLast is null || last > newestLast))
                newestLast = last;
        }

        return info with { StartEpochMs = SessionActivity.ElapsedStartMs(total, newestLast, nowMs) };
    }

    private static string? ExtractConversationId(string transcriptPath)
    {
        // Path pattern: .../brain/<conversation-id>/.system_generated/logs/transcript.jsonl
        var dir = Path.GetDirectoryName(transcriptPath);
        while (dir is not null)
        {
            var parent = Path.GetDirectoryName(dir);
            if (parent is not null && Path.GetFileName(parent).Equals("brain", StringComparison.OrdinalIgnoreCase))
                return Path.GetFileName(dir);
            dir = parent;
        }
        return null;
    }

    private void RefreshHistory()
    {
        var historyPath = Path.Combine(_baseDir, "history.jsonl");
        if (!File.Exists(historyPath)) return;

        try
        {
            var mtime = File.GetLastWriteTimeUtc(historyPath);
            if (_historyCacheMtime == mtime) return;

            using var stream = new FileStream(historyPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            while (reader.ReadLine() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var root = doc.RootElement;
                    if (root.ValueKind != JsonValueKind.Object) continue;

                    var convId = StringProp(root, "conversationId");
                    var workspace = StringProp(root, "workspace");
                    var ts = IntProp(root, "timestamp");

                    if (!string.IsNullOrEmpty(convId))
                        _historyByConvId[convId] = (workspace ?? "", ts);
                }
                catch { }
            }
            _historyCacheMtime = mtime;
        }
        catch { }
    }

    private void RefreshAccountInfo()
    {
        if (AccountEmail is not null && PlanType is not null) return;

        var logFiles = ListCliLogs();
        DateTime? newest = null;
        foreach (var path in logFiles)
        {
            try
            {
                var mtime = File.GetLastWriteTimeUtc(path);
                if (newest is null || mtime > newest) newest = mtime;
            }
            catch { }
        }
        if (_accountLogsScanned && newest == _accountLogsStamp) return;
        _accountLogsScanned = true;
        _accountLogsStamp = newest;

        foreach (var logFile in logFiles)
        {
            try
            {
                using var stream = new FileStream(logFile, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                using var reader = new StreamReader(stream);
                while (reader.ReadLine() is { } line)
                {
                    if (AccountEmail is null)
                    {
                        var m = Regex.Match(line, @"(?:applyAuthResult:\s*email=|authenticated successfully as\s+|email=)([a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+)");
                        if (m.Success) AccountEmail = m.Groups[1].Value;
                    }
                    if (PlanType is null)
                    {
                        var m = Regex.Match(line, @"(?:authMethod|tier|plan)=([a-zA-Z0-9_-]+)");
                        if (m.Success) PlanType = FormatPlan(m.Groups[1].Value);
                    }
                }
            }
            catch { }

            if (AccountEmail is not null && PlanType is not null) break;
        }

        if (AccountEmail is not null && PlanType is null)
        {
            PlanType = "Google AI Pro";
        }
    }

    /// <summary>Formats raw authMethod/tier names like "consumer" into clean display labels.</summary>
    public static string FormatPlan(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "Google AI Pro";
        var lower = raw.Trim().ToLowerInvariant();
        return lower switch
        {
            "consumer" => "Google AI Pro",
            "pro" => "Google AI Pro",
            "ultra" or "advanced" => "Google AI Ultra",
            "enterprise" => "Gemini Enterprise",
            "workforce" => "Google Workspace",
            "gcp" or "cloud" => "Google Cloud",
            "api_key" => "API Key",
            _ => char.ToUpperInvariant(raw[0]) + (raw.Length > 1 ? raw[1..] : "")
        };
    }

    private sealed class TranscriptState
    {
        public string? Cwd;
        public string? Model;
        public long? StartedAtMs;
        public long? LastEventAtMs;
        public long TotalTokens;
        public List<long> StampsMs = [];
    }

    private List<string> ListCliLogs()
    {
        var logFiles = new List<string>();
        var cliLog = Path.Combine(_baseDir, "cli.log");
        if (File.Exists(cliLog)) logFiles.Add(cliLog);

        var logDir = Path.Combine(_baseDir, "log");
        if (!Directory.Exists(logDir)) return logFiles;
        try
        {
            logFiles.AddRange(Directory.EnumerateFiles(logDir, "cli-*.log")
                .Select(p => (Path: p, Mtime: File.GetLastWriteTimeUtc(p)))
                .OrderByDescending(f => f.Mtime)
                .Select(f => f.Path));
        }
        catch { }
        return logFiles;
    }

    private sealed class CacheEntry
    {
        public DateTime Mtime;
        public JsonlCursor Cursor = new();
        public TranscriptState State = new();
    }

    private TranscriptState ReadTranscript(string path, DateTime mtime, string? convId)
    {
        if (!_cache.TryGetValue(path, out var cached))
            cached = new CacheEntry();
        if (cached.Mtime == mtime && _cache.ContainsKey(path) && cached.Cursor.IsCurrent(path))
            return cached.State;

        if (cached.State.Cwd is null
            && convId is not null
            && _historyByConvId.TryGetValue(convId, out var hist)
            && !string.IsNullOrEmpty(hist.Workspace))
        {
            cached.State.Cwd = hist.Workspace;
            if (hist.Timestamp > 0)
            {
                cached.State.StartedAtMs ??= hist.Timestamp;
                cached.State.LastEventAtMs = Math.Max(cached.State.LastEventAtMs ?? hist.Timestamp, hist.Timestamp);
            }
        }

        try
        {
            cached.Cursor.PullLines(
                path,
                line => ConsumeLine(line, cached.State),
                () => cached.State = new TranscriptState());
        }
        catch { }

        cached.Mtime = mtime;
        _cache[path] = cached;
        return cached.State;
    }

    private static void ConsumeLine(string line, TranscriptState state)
    {
        if (string.IsNullOrWhiteSpace(line)) return;

        JsonDocument doc;
        try { doc = JsonDocument.Parse(line); }
        catch { return; }

        using (doc)
        {
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return;

            long? lineMs = null;
            if (root.TryGetProperty("created_at", out var createdAt) && createdAt.ValueKind == JsonValueKind.String)
                lineMs = ClaudeSession.EpochMsFromIso(createdAt.GetString());

            if (lineMs is long eventMs)
            {
                state.StartedAtMs ??= eventMs;
                state.LastEventAtMs = Math.Max(state.LastEventAtMs ?? eventMs, eventMs);
                state.StampsMs.Add(eventMs);
            }

            if (root.TryGetProperty("content", out var contentElement) && contentElement.ValueKind == JsonValueKind.String)
            {
                var content = contentElement.GetString();
                if (!string.IsNullOrEmpty(content))
                {
                    if (state.Model is null)
                    {
                        var modelMatch = Regex.Match(content, @"(?i)(?:Model Selection[`'""\s]*(?:from\s+[^`'""]+\s+)?to\s+|model[:=\s]+['""]?)(Gemini[^\r\n`'""<]+|gemini-[a-z0-9.-]+)");
                        if (modelMatch.Success)
                            state.Model = modelMatch.Groups[1].Value;
                    }

                    if (state.Cwd is null)
                    {
                        var wsMatch = Regex.Match(content, @"([A-Za-z]:\\[^-\r\n\t]+|\/[^-\r\n\t]+)\s*->");
                        if (wsMatch.Success)
                            state.Cwd = wsMatch.Groups[1].Value.Trim();
                    }
                }
            }

            if (root.TryGetProperty("tool_calls", out var toolCalls) && toolCalls.ValueKind == JsonValueKind.Array)
            {
                foreach (var tool in toolCalls.EnumerateArray())
                {
                    if (tool.TryGetProperty("args", out var args) && args.ValueKind == JsonValueKind.Object)
                    {
                        if (state.Cwd is null)
                        {
                            var dir = StringProp(args, "DirectoryPath")
                                ?? StringProp(args, "SearchPath")
                                ?? StringProp(args, "Cwd");
                            if (!string.IsNullOrWhiteSpace(dir))
                                state.Cwd = dir;
                        }
                    }
                }
            }

            if (root.TryGetProperty("usage", out var usage) && usage.ValueKind == JsonValueKind.Object)
            {
                var total = IntProp(usage, "total_tokens");
                if (total == 0) total = IntProp(usage, "input_tokens") + IntProp(usage, "output_tokens");
                if (total > 0) state.TotalTokens += total;
            }
        }
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long IntProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt64(out var number)
            ? number
            : 0;

    /// <summary>Turns raw model IDs like "gemini-3.7-flash" or "Gemini 3.7 Flash (High)" into clean display names.</summary>
    public static string PrettyModel(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "Gemini";

        var trimmed = raw.Trim().TrimEnd('.').Trim();
        if (trimmed.EndsWith(")", StringComparison.Ordinal))
        {
            var paren = trimmed.IndexOf('(');
            if (paren > 0) trimmed = trimmed[..paren].Trim().TrimEnd('.').Trim();
        }

        var lower = trimmed.ToLowerInvariant();
        if (lower.Contains("gemini"))
        {
            var match = Regex.Match(trimmed, @"(?i)gemini(?:[- ](\d+(?:\.\d+)?))?(?:[- ]([a-z0-9-]+))?");
            if (match.Success)
            {
                var version = match.Groups[1].Value.Replace('-', '.');
                var variant = match.Groups[2].Value;
                var parts = new List<string> { "Gemini" };
                if (!string.IsNullOrEmpty(version)) parts.Add(version);
                if (!string.IsNullOrEmpty(variant))
                {
                    var variantWords = variant.Split(['-', '_', ' '], StringSplitOptions.RemoveEmptyEntries)
                        .Select(w => char.ToUpperInvariant(w[0]) + (w.Length > 1 ? w[1..].ToLowerInvariant() : ""));
                    parts.Add(string.Join(" ", variantWords));
                }
                return string.Join(" ", parts);
            }
            return "Gemini";
        }

        return trimmed;
    }
}
