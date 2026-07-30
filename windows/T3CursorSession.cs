// Detects a live Cursor session orchestrated by T3 Code by reading
// %USERPROFILE%\.t3\userdata\state.sqlite (read-only). T3 keeps the canonical
// turn/runtime state there; Cursor's agent-transcripts often lag or stay quiet
// while ACP sessions under ~/.cursor/acp-sessions are hot.
//
// Returns AgentKind.Cursor — Discord shows the active provider (Cursor), not
// "T3 Code".

using System.Globalization;
using System.IO;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AgentCord;

public sealed class T3CursorSession
{
    public double ActiveWindowSeconds { get; set; } = 60;

    private readonly string _dbPath;
    private readonly Dictionary<string, string> _repoNameCache = [];

    public T3CursorSession()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _dbPath = Path.Combine(home, ".t3", "userdata", "state.sqlite");
    }

    public SessionInfo? Scan()
    {
        if (!File.Exists(_dbPath)) return null;

        try
        {
            var cs = new SqliteConnectionStringBuilder
            {
                DataSource = _dbPath,
                Mode = SqliteOpenMode.ReadOnly,
                Cache = SqliteCacheMode.Shared,
            }.ToString();

            using var conn = new SqliteConnection(cs);
            conn.Open();

            // Prefer an explicitly running Cursor turn; otherwise the newest
            // Cursor runtime that was seen inside the idle window.
            using var cmd = conn.CreateCommand();
            cmd.CommandText =
                """
                SELECT
                  r.thread_id,
                  r.status,
                  r.last_seen_at,
                  r.runtime_payload_json,
                  s.status AS session_status,
                  s.active_turn_id,
                  s.provider_name,
                  t.worktree_path,
                  t.model_selection_json,
                  p.title AS project_title,
                  p.workspace_root,
                  (
                    SELECT tr.started_at
                    FROM projection_turns tr
                    WHERE tr.thread_id = r.thread_id
                      AND (tr.state = 'running'
                           OR tr.turn_id = s.active_turn_id)
                    ORDER BY tr.started_at DESC
                    LIMIT 1
                  ) AS turn_started_at
                FROM provider_session_runtime r
                LEFT JOIN projection_thread_sessions s ON s.thread_id = r.thread_id
                LEFT JOIN projection_threads t ON t.thread_id = r.thread_id
                LEFT JOIN projection_projects p ON p.project_id = t.project_id
                WHERE s.provider_name = 'cursor'
                   OR instr(ifnull(r.runtime_payload_json, ''), '"instanceId":"cursor"') > 0
                ORDER BY r.last_seen_at DESC
                LIMIT 8
                """;

            using var reader = cmd.ExecuteReader();
            SessionInfo? best = null;
            while (reader.Read())
            {
                if (TryBuild(reader) is not { } info) continue;
                if (best is null || info.LastModifiedMs > best.LastModifiedMs)
                    best = info;
            }
            return best;
        }
        catch
        {
            return null;
        }
    }

    private SessionInfo? TryBuild(SqliteDataReader reader)
    {
        var status = reader["status"] as string ?? "";
        var sessionStatus = reader["session_status"] as string ?? "";
        var activeTurn = reader["active_turn_id"] as string;
        var lastSeenRaw = reader["last_seen_at"] as string;
        if (ParseIsoMs(lastSeenRaw) is not long lastSeenMs) return null;

        var ageSec = (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - lastSeenMs) / 1000.0;
        var live = status.Equals("running", StringComparison.OrdinalIgnoreCase)
            || sessionStatus.Equals("running", StringComparison.OrdinalIgnoreCase)
            || !string.IsNullOrEmpty(activeTurn);
        if (!live && ageSec > ActiveWindowSeconds) return null;
        if (ageSec > ActiveWindowSeconds) return null;

        string? cwd = null;
        string? model = null;
        if (reader["runtime_payload_json"] is string payload && payload.Length > 0)
        {
            try
            {
                using var doc = JsonDocument.Parse(payload);
                var root = doc.RootElement;
                if (root.TryGetProperty("cwd", out var cwdEl) && cwdEl.ValueKind == JsonValueKind.String)
                    cwd = cwdEl.GetString();
                if (root.TryGetProperty("model", out var modelEl) && modelEl.ValueKind == JsonValueKind.String)
                    model = modelEl.GetString();
            }
            catch
            {
                // Defensive: T3 payload schema can change.
            }
        }

        if (string.IsNullOrWhiteSpace(cwd) && reader["worktree_path"] is string wt && wt.Length > 0)
            cwd = wt;
        if (string.IsNullOrWhiteSpace(cwd) && reader["workspace_root"] is string rootPath && rootPath.Length > 0)
            cwd = rootPath;

        var project = reader["project_title"] as string;
        if (string.IsNullOrWhiteSpace(project) && !string.IsNullOrWhiteSpace(cwd))
            project = RepoName(cwd!);
        if (string.IsNullOrWhiteSpace(project)) project = "Cursor";

        if (string.IsNullOrWhiteSpace(model) && reader["model_selection_json"] is string sel)
            model = ModelFromSelection(sel);

        var startMs = ParseIsoMs(reader["turn_started_at"] as string) ?? lastSeenMs;

        return new SessionInfo
        {
            ProjectName = project!,
            Model = string.IsNullOrWhiteSpace(model) ? null : CursorSession.PrettyModel(model!),
            StartEpochMs = startMs,
            TotalTokens = 0,
            LastModifiedMs = lastSeenMs,
            Agent = AgentKind.Cursor,
        };
    }

    private static string? ModelFromSelection(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.TryGetProperty("model", out var model)
                && model.ValueKind == JsonValueKind.String)
            {
                return model.GetString();
            }
        }
        catch
        {
            // ignore
        }
        return null;
    }

    private static long? ParseIsoMs(string? iso)
    {
        if (string.IsNullOrWhiteSpace(iso)) return null;
        if (!DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var dto))
        {
            return null;
        }
        return dto.ToUnixTimeMilliseconds();
    }

    private string RepoName(string cwd)
    {
        if (_repoNameCache.TryGetValue(cwd, out var cached)) return cached;
        var name = Path.GetFileName(cwd.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = cwd;

        // Prefer git remote like the other scanners, without flashing a console.
        try
        {
            var start = new System.Diagnostics.ProcessStartInfo("git")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add("-C");
            start.ArgumentList.Add(cwd);
            start.ArgumentList.Add("config");
            start.ArgumentList.Add("--get");
            start.ArgumentList.Add("remote.origin.url");
            using var process = System.Diagnostics.Process.Start(start);
            if (process is not null)
            {
                var output = process.StandardOutput.ReadToEnd().Trim();
                if (process.WaitForExit(3000) && process.ExitCode == 0 && output.Length > 0)
                {
                    var baseName = output.Split('/', '\\')[^1];
                    if (baseName.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
                        baseName = baseName[..^4];
                    if (baseName.Length > 0) name = baseName;
                }
            }
        }
        catch
        {
            // Directory name is fine.
        }

        // T3 worktrees look like .../agentcord/t3code-xxxx — prefer the repo folder.
        var parent = Path.GetFileName(Path.GetDirectoryName(cwd.TrimEnd('\\', '/')));
        if (name.StartsWith("t3code-", StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrEmpty(parent))
        {
            name = parent;
        }

        _repoNameCache[cwd] = name;
        return name;
    }
}
