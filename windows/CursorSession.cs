// Detects the currently active Cursor agent session from today's hook file
// (`%TEMP%\AgentCord\yyyy-MM-dd-uptime.json`). Cursor is live only while a
// turn is open (unmatched `start`). Today's clock is the sum of start/end diffs.

using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class CursorSession
{
    private readonly string _cursorHome;
    private readonly string _uptimeFile;
    private readonly Dictionary<string, string> _repoNameCache = [];

    public CursorSession(string? cursorHome = null, string? uptimeFile = null)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _cursorHome = cursorHome ?? Path.Combine(home, ".cursor");
        _uptimeFile = uptimeFile ?? DefaultUptimeFile();
    }

    public bool IsLinked =>
        Directory.Exists(Path.Combine(_cursorHome, "projects"))
        || Directory.Exists(Path.Combine(_cursorHome, "chats"));

    public static string DefaultUptimeFile()
    {
        var dir = Environment.GetEnvironmentVariable("AGENTCORD_CURSOR_UPTIME_DIR");
        if (string.IsNullOrWhiteSpace(dir))
            dir = Path.Combine(Path.GetTempPath(), "AgentCord");
        return Path.Combine(dir, $"{DateTime.Today:yyyy-MM-dd}-uptime.json");
    }

    public AgentScan Scan() => ScanAt(_uptimeFile, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    internal AgentScan ScanAt(string path, long nowMs)
    {
        var day = ParseDay(path, nowMs);
        if (!day.Open)
            return new AgentScan(day.TotalMs, null);

        var project = string.IsNullOrEmpty(day.Project) ? "Cursor" : day.Project;
        return new AgentScan(day.TotalMs, new SessionInfo
        {
            ProjectName = project,
            Model = null,
            StartEpochMs = nowMs - day.TotalMs,
            TotalTokens = 0,
            LastModifiedMs = nowMs,
            Agent = AgentKind.Cursor,
        });
    }

    private Day ParseDay(string path, long nowMs)
    {
        string text;
        try
        {
            text = File.ReadAllText(path);
        }
        catch
        {
            return default;
        }

        var open = new Dictionary<string, List<long>>(StringComparer.Ordinal);
        long total = 0;
        var project = "";
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim().TrimStart('\uFEFF');
            if (line.Length == 0) continue;
            JsonDocument doc;
            try { doc = JsonDocument.Parse(line); }
            catch { continue; }
            using (doc)
            {
                var v = doc.RootElement;
                if (v.ValueKind != JsonValueKind.Object) continue;
                var kind = JsonProp.String(v, "e");
                if (kind is null) continue;
                if (!TryInt64(v, "ms", out var ms)) continue;
                var id = JsonProp.String(v, "id") ?? "";
                var cwd = JsonProp.String(v, "cwd");
                if (!string.IsNullOrEmpty(cwd))
                    project = RepoNames.FromCwd(cwd, _repoNameCache);

                if (kind == "start")
                {
                    if (!open.TryGetValue(id, out var stack))
                    {
                        stack = [];
                        open[id] = stack;
                    }
                    stack.Add(ms);
                }
                else if (kind == "end" && open.TryGetValue(id, out var ends) && ends.Count > 0)
                {
                    var start = ends[^1];
                    ends.RemoveAt(ends.Count - 1);
                    if (ms > start) total += ms - start;
                }
            }
        }

        var live = false;
        foreach (var starts in open.Values)
        {
            foreach (var start in starts)
            {
                live = true;
                if (nowMs > start) total += nowMs - start;
            }
        }

        return new Day(Math.Max(0, total), live, project);
    }

    private readonly record struct Day(long TotalMs, bool Open, string Project);

    private static bool TryInt64(JsonElement v, string key, out long n)
    {
        n = 0;
        if (!v.TryGetProperty(key, out var p)) return false;
        if (p.ValueKind == JsonValueKind.Number && p.TryGetInt64(out n)) return true;
        if (p.ValueKind == JsonValueKind.Number && p.TryGetDouble(out var d))
        {
            n = (long)d;
            return true;
        }
        return false;
    }
}
