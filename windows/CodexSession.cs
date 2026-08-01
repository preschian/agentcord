// Detects active Codex sessions by scanning the local transcript tree under
// %USERPROFILE%\.codex\sessions (or %CODEX_HOME%\sessions). Codex owns these
// records; AgentCord only reads session metadata, turn context, timestamps,
// and token counts defensively.

using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class CodexSession
{
    public double ActiveWindowSeconds { get; set; } = 60;

    private readonly string _sessionsDir;
    private readonly Dictionary<string, CacheEntry> _cache = [];
    private readonly Dictionary<string, string> _repoNameCache = [];

    public CodexSession(string? sessionsDir = null)
    {
        _sessionsDir = sessionsDir ?? Path.Combine(CodexPaths.ResolveHome(), "sessions");
    }

    public SessionInfo? Scan()
    {
        List<(string Path, DateTime Mtime)> files;
        try
        {
            files = Directory
                .EnumerateFiles(_sessionsDir, "*.jsonl", SearchOption.AllDirectories)
                .Select(path => (Path: path, Mtime: File.GetLastWriteTimeUtc(path)))
                .OrderByDescending(file => file.Mtime)
                .ToList();
        }
        catch
        {
            return null;
        }

        if (files.Count == 0) return null;

        // Prefer parsed event timestamps over filesystem mtime for idle and
        // selection. Every transcript must be inspected because an active
        // session can have a stale mtime; the per-file cache keeps re-scans of
        // unchanged files cheap.
        SessionInfo? best = null;
        foreach (var file in files)
        {
            var state = ReadTranscript(file.Path, file.Mtime);
            var activityMs = SessionActivity.NormalizeMs(state.LastEventAtMs, file.Mtime);
            if (!SessionActivity.IsWithinWindow(activityMs, ActiveWindowSeconds)) continue;

            var project = state.Cwd is { Length: > 0 } cwd
                ? RepoName(cwd)
                : Path.GetFileName(Path.GetDirectoryName(file.Path));
            if (string.IsNullOrWhiteSpace(project)) project = "Codex";

            var info = new SessionInfo
            {
                ProjectName = project,
                Model = state.Model is null ? null : PrettyModel(state.Model),
                StartEpochMs = state.StartedAtMs ?? activityMs,
                TotalTokens = state.TotalTokens,
                LastModifiedMs = activityMs,
                Agent = AgentKind.Codex,
            };
            if (best is null || info.LastModifiedMs > best.LastModifiedMs)
                best = info;
        }

        var livePaths = files.Select(file => file.Path).ToHashSet();
        foreach (var stale in _cache.Keys.Where(path => !livePaths.Contains(path)).ToList())
            _cache.Remove(stale);

        return best;
    }

    private sealed class TranscriptState
    {
        public string? Cwd;
        public string? Model;
        public long? StartedAtMs;
        public long? LastEventAtMs;
        public long TotalTokens;
    }

    private sealed record CacheEntry(DateTime Mtime, TranscriptState State);

    private TranscriptState ReadTranscript(string path, DateTime mtime)
    {
        if (_cache.TryGetValue(path, out var cached) && cached.Mtime == mtime)
            return cached.State;

        var state = new TranscriptState();
        try
        {
            // Codex keeps the active transcript open for appends. Explicitly
            // allow concurrent writes/deletion; File.ReadLines can otherwise
            // fail with a sharing violation and leave every field empty.
            using var stream = new FileStream(
                path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            while (reader.ReadLine() is { } line)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;

                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); }
                catch { continue; }

                using (doc)
                {
                    var root = doc.RootElement;
                    if (root.ValueKind != JsonValueKind.Object) continue;

                    var lineMs = root.TryGetProperty("timestamp", out var timestamp)
                        && timestamp.ValueKind == JsonValueKind.String
                        ? ClaudeSession.EpochMsFromIso(timestamp.GetString())
                        : null;
                    if (lineMs is long eventMs)
                    {
                        state.StartedAtMs ??= eventMs;
                        state.LastEventAtMs = Math.Max(state.LastEventAtMs ?? eventMs, eventMs);
                    }

                    if (!root.TryGetProperty("type", out var typeElement)
                        || typeElement.ValueKind != JsonValueKind.String
                        || !root.TryGetProperty("payload", out var payload)
                        || payload.ValueKind != JsonValueKind.Object)
                        continue;

                    var type = typeElement.GetString();
                    if (type is "session_meta" or "turn_context")
                    {
                        if (StringProp(payload, "cwd") is { Length: > 0 } cwd) state.Cwd = cwd;
                        if (type == "turn_context" && StringProp(payload, "model") is { Length: > 0 } model)
                            state.Model = model;
                        if (type == "session_meta"
                            && ClaudeSession.EpochMsFromIso(StringProp(payload, "timestamp")) is long started)
                            state.StartedAtMs = started;
                    }

                    if (type == "event_msg"
                        && StringProp(payload, "type") == "token_count"
                        && payload.TryGetProperty("info", out var info)
                        && info.ValueKind == JsonValueKind.Object
                        && info.TryGetProperty("last_token_usage", out var usage)
                        && usage.ValueKind == JsonValueKind.Object)
                    {
                        var total = IntProp(usage, "total_tokens");
                        if (total == 0)
                            total = IntProp(usage, "input_tokens") + IntProp(usage, "output_tokens");
                        // This is the active context/turn, not the cumulative
                        // amount processed over the entire transcript. Keep
                        // the newest event rather than the maximum because
                        // compaction can legitimately make the value smaller.
                        state.TotalTokens = total;
                    }
                }
            }
        }
        catch
        {
            // A live transcript can briefly be locked or disappear; partial
            // information is still preferable to crashing the tray process.
        }

        _cache[path] = new CacheEntry(mtime, state);
        return state;
    }

    private string RepoName(string cwd)
    {
        if (_repoNameCache.TryGetValue(cwd, out var cached)) return cached;

        var name = Path.GetFileName(cwd.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = cwd;

        if (RunGit(["-C", cwd, "config", "--get", "remote.origin.url"]) is { } remote)
        {
            var baseName = remote.Split('/', '\\')[^1];
            if (baseName.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
                baseName = baseName[..^4];
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

    public static string PrettyModel(string raw)
    {
        if (!raw.StartsWith("gpt-", StringComparison.OrdinalIgnoreCase))
            return raw;

        var parts = raw[4..].Split('-', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return "GPT";

        var versionParts = new List<string>();
        var suffixParts = new List<string>();
        foreach (var part in parts)
        {
            if (suffixParts.Count == 0 && part.All(c => char.IsDigit(c) || c == '.'))
                versionParts.Add(part);
            else
                suffixParts.Add(char.ToUpperInvariant(part[0]) + part[1..]);
        }

        var version = string.Join(".", versionParts);
        var suffix = suffixParts.Count > 0 ? $" {string.Join(" ", suffixParts)}" : "";
        return version.Length > 0 ? $"GPT-{version}{suffix}" : $"GPT{suffix}";
    }
}
