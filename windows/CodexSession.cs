// Detects active Codex sessions by scanning the local transcript tree under
// %USERPROFILE%\.codex\sessions (or %CODEX_HOME%\sessions). Codex owns these
// records; AgentCord only reads session metadata, turn context, timestamps,
// and token counts defensively. Elapsed time is the summed working duration
// across transcripts that touched the last 24 hours (idle gaps excluded).

using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class CodexSession : IDisposable
{
    public double ActiveWindowSeconds { get; set; } = 60;

    private readonly SessionTreeIndex _tree;
    private readonly Dictionary<string, CacheEntry> _cache = [];
    private readonly Dictionary<string, string> _repoNameCache = [];

    public CodexSession(string? sessionsDir = null)
    {
        var root = sessionsDir ?? Path.Combine(CodexPaths.ResolveHome(), "sessions");
        _tree = new SessionTreeIndex(root, "*.jsonl");
    }

    public void Dispose() => _tree.Dispose();

    public SessionInfo? Scan()
    {
        var files = _tree.Snapshot(TimeSpan.FromMilliseconds(SessionActivity.LookbackMs));
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
                ? RepoNames.FromCwd(cwd, _repoNameCache)
                : Path.GetFileName(Path.GetDirectoryName(file.Path));
            if (string.IsNullOrWhiteSpace(project)) project = "Codex";

            var info = new SessionInfo
            {
                ProjectName = project,
                Model = state.Model is null ? null : PrettyModel(state.Model),
                StartEpochMs = 0,
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

        return best is null ? null : WithRollingStart(best, files);
    }

    private SessionInfo WithRollingStart(SessionInfo info, IReadOnlyList<(string Path, DateTime Mtime)> files)
    {
        var nowMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var cutoffMs = nowMs - SessionActivity.LookbackMs;
        long total = 0;
        long? newestLast = null;

        foreach (var file in files)
        {
            var state = ReadTranscript(file.Path, file.Mtime);
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

    private sealed class TranscriptState
    {
        public string? Cwd;
        public string? Model;
        public long? StartedAtMs;
        public long? LastEventAtMs;
        public long TotalTokens;
        public List<long> StampsMs = [];
    }

    private sealed class CacheEntry
    {
        public DateTime Mtime;
        public JsonlCursor Cursor = new();
        public TranscriptState State = new();
    }

    private TranscriptState ReadTranscript(string path, DateTime mtime)
    {
        if (!_cache.TryGetValue(path, out var cached))
            cached = new CacheEntry();
        if (cached.Mtime == mtime && _cache.ContainsKey(path) && cached.Cursor.IsCurrent(path))
            return cached.State;

        try
        {
            cached.Cursor.PullLines(
                path,
                line => ConsumeLine(line, cached.State),
                () => cached.State = new TranscriptState());
        }
        catch
        {
            // A live transcript can briefly be locked or disappear; partial
            // information is still preferable to crashing the tray process.
        }

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

            var lineMs = root.TryGetProperty("timestamp", out var timestamp)
                && timestamp.ValueKind == JsonValueKind.String
                ? ClaudeSession.EpochMsFromIso(timestamp.GetString())
                : null;
            if (lineMs is long eventMs)
            {
                state.StartedAtMs ??= eventMs;
                state.LastEventAtMs = Math.Max(state.LastEventAtMs ?? eventMs, eventMs);
                state.StampsMs.Add(eventMs);
            }

            if (!root.TryGetProperty("type", out var typeElement)
                || typeElement.ValueKind != JsonValueKind.String
                || !root.TryGetProperty("payload", out var payload)
                || payload.ValueKind != JsonValueKind.Object)
                return;

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
