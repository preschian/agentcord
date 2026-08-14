// Detects the currently active Grok (xAI) coding session from:
//   %USERPROFILE%\.grok\active_sessions.json  (live TUI PIDs)
//   %USERPROFILE%\.grok\sessions\<url-encoded-cwd>\<session-id>\summary.json
//   sibling signals.json                      (context tokens / model)
//
// A live PID in the active-sessions list is authoritative. Summary timestamps
// and signals enrich project, model, and token fields. After the list clears
// (quit), the last-known session stays visible for the idle window. Port of
// AgentCord/GrokSession.swift.

using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class GrokSession
{
    /// <summary>A recently closed session still counts as active inside this window.</summary>
    public double ActiveWindowSeconds { get; set; } = 60;

    /// <summary>True when ~/.grok/auth.json has at least one credential entry.</summary>
    public bool IsAuthenticated { get; private set; }

    private readonly string _grokHome;
    private readonly Dictionary<string, string> _summaryBySessionId = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _repoNameCache = [];
    private bool _hasBuiltSummaryIndex;
    private (SessionInfo Info, long ActivityMs)? _lastKnown;

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

    /// <summary>Newest live Grok session, or the last-known one still inside the idle window.</summary>
    public SessionInfo? Scan()
    {
        IsAuthenticated = ReadAuthenticated();
        var live = ReadActiveSessions().Where(e => ProcessIsAlive(e.Pid)).ToList();

        (SessionInfo Info, long ActivityMs)? best = null;
        foreach (var entry in live)
        {
            var summaryPath = FindSummary(entry.SessionId, entry.Cwd);
            var summary = summaryPath is null ? null : ReadSummary(summaryPath);
            var activityMs = summary?.LastActiveMs
                ?? (summaryPath is not null ? FileTimeMs(summaryPath) : null)
                ?? entry.OpenedAtMs;
            var signals = summaryPath is null
                ? null
                : ReadSignals(Path.GetDirectoryName(summaryPath)!);
            var tokens = signals?.ContextTokensUsed ?? 0;
            var modelRaw = summary?.ModelId ?? signals?.PrimaryModelId;
            var project = RepoName(entry.Cwd, summary?.GitRemotes);

            var info = new SessionInfo
            {
                ProjectName = string.IsNullOrWhiteSpace(project) ? "Grok" : project,
                Model = modelRaw is { Length: > 0 } raw ? PrettyModel(raw) : "Grok",
                StartEpochMs = entry.OpenedAtMs,
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

        if (best is { } found) _lastKnown = found;
        return best?.Info;
    }

    // --- Auth / active sessions

    private bool ReadAuthenticated()
    {
        try
        {
            var path = Path.Combine(_grokHome, "auth.json");
            if (!File.Exists(path)) return false;
            using var doc = JsonDocument.Parse(ReadAllShared(path));
            return doc.RootElement.ValueKind == JsonValueKind.Object
                && doc.RootElement.EnumerateObject().Any();
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

    private sealed record SummaryMeta(string? ModelId, long? LastActiveMs, string? Cwd, IReadOnlyList<string> GitRemotes);
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
            return new SummaryMeta(model, lastActive, cwd, remotes);
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
            var project = RepoName(cwd, summary?.GitRemotes);
            var modelRaw = summary?.ModelId ?? signals?.PrimaryModelId;
            var info = new SessionInfo
            {
                ProjectName = string.IsNullOrWhiteSpace(project) ? "Grok" : project,
                Model = modelRaw is { Length: > 0 } raw ? PrettyModel(raw) : "Grok",
                StartEpochMs = activity,
                TotalTokens = signals?.ContextTokensUsed ?? 0,
                LastModifiedMs = activity,
                Agent = AgentKind.Grok,
            };
            if (best is null || activity >= best.Value.ActivityMs)
                best = (info, activity);
        }
        return best;
    }

    // --- Project name

    private string RepoName(string cwd, IReadOnlyList<string>? remotes)
    {
        if (remotes is { Count: > 0 })
        {
            var fromRemote = RepoNameFromRemote(remotes[0]);
            if (!string.IsNullOrEmpty(fromRemote)) return fromRemote;
        }

        if (string.IsNullOrWhiteSpace(cwd)) return "";
        if (_repoNameCache.TryGetValue(cwd, out var cached)) return cached;

        var name = Path.GetFileName(cwd.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = cwd;

        if (RunGit(["-C", cwd, "config", "--get", "remote.origin.url"]) is { } remote)
        {
            var baseName = RepoNameFromRemote(remote);
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

    internal static string RepoNameFromRemote(string remote)
    {
        var baseName = remote.Split('/', '\\', ':')[^1];
        if (baseName.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
            baseName = baseName[..^4];
        return baseName;
    }

    private static string? RunGit(string[] args)
    {
        try
        {
            var start = new ProcessStartInfo("git")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var arg in args) start.ArgumentList.Add(arg);

            using var process = Process.Start(start);
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
