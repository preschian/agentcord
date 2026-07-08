// Polls Anthropic's public status page (https://status.claude.com) so the
// tray menu can surface when Claude Code / the API / claude.ai are having
// trouble. Port of AgentCord/AnthropicStatus.swift. The page is an Atlassian
// Statuspage, which exposes an unauthed JSON summary at /api/v2/summary.json.
//
// Best-effort like ClaudeUsage: any failure (offline, endpoint moved, bad
// JSON) just leaves Current null and the menu hides the row.

using System.Net.Http;
using System.Text.Json;

namespace AgentCord;

public sealed class AnthropicStatus : IDisposable
{
    /// <summary>The latest status snapshot, or null when it could not be fetched.</summary>
    public StatusInfo? Current { get; private set; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(300);
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromSeconds(60);
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromSeconds(1800);

    public const string PageUrl = "https://status.claude.com";
    private static readonly Uri Endpoint = new(PageUrl + "/api/v2/summary.json");

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly object _lock = new();
    private DateTime _lastSuccess = DateTime.MinValue;
    private DateTime _lastAttempt = DateTime.MinValue;
    private System.Threading.Timer? _timer;

    public void Start()
    {
        _timer = new System.Threading.Timer(_ => _ = FetchAsync(), null, TimeSpan.FromSeconds(1), PollInterval);
    }

    /// <summary>Request a refresh (e.g. when the menu opens). Throttled by
    /// MinFetchInterval.</summary>
    public void Refresh()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _lastAttempt < MinFetchInterval) return;
        }
        _ = FetchAsync();
    }

    public void Dispose()
    {
        _timer?.Dispose();
        _http.Dispose();
    }

    private async Task FetchAsync()
    {
        lock (_lock) _lastAttempt = DateTime.UtcNow;
        try
        {
            using var doc = JsonDocument.Parse(await _http.GetStringAsync(Endpoint));
            var info = Parse(doc.RootElement);
            lock (_lock) _lastSuccess = DateTime.UtcNow;
            Current = info;
        }
        catch
        {
            lock (_lock)
            {
                if (DateTime.UtcNow - _lastSuccess > MaxStaleness) Current = null;
            }
        }
    }

    private static StatusInfo Parse(JsonElement root)
    {
        var indicator = root.TryGetProperty("status", out var status)
            && status.ValueKind == JsonValueKind.Object
            && status.TryGetProperty("indicator", out var ind)
            && ind.ValueKind == JsonValueKind.String
            ? ind.GetString() ?? "unknown" : "unknown";

        var components = new List<StatusComponent>();
        if (root.TryGetProperty("components", out var comps) && comps.ValueKind == JsonValueKind.Array)
        {
            foreach (var c in comps.EnumerateArray())
            {
                // Statuspage marks container rows with group: true; skip those.
                if (c.TryGetProperty("group", out var g) && g.ValueKind == JsonValueKind.True) continue;
                if (StringProp(c, "name") is not { Length: > 0 } name) continue;
                components.Add(new StatusComponent
                {
                    Name = ShortName(name),
                    Status = StringProp(c, "status") ?? "unknown",
                });
            }
        }

        var incidents = new List<StatusIncident>();
        if (root.TryGetProperty("incidents", out var inc) && inc.ValueKind == JsonValueKind.Array)
        {
            foreach (var i in inc.EnumerateArray())
            {
                if (StringProp(i, "name") is not { Length: > 0 } name) continue;
                incidents.Add(new StatusIncident
                {
                    Name = name,
                    Status = StringProp(i, "status") ?? "investigating",
                    Impact = StringProp(i, "impact") ?? "none",
                    StartedAtMs = ClaudeSession.EpochMsFromIso(StringProp(i, "started_at")),
                });
            }
        }

        return new StatusInfo
        {
            Indicator = indicator,
            SummaryLabel = SummaryLabel(indicator),
            Components = components,
            Incidents = incidents,
            FetchedAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
        };
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    /// <summary>Drops the trailing parenthetical so names stay compact, e.g.
    /// "Claude API (api.anthropic.com)" -> "Claude API".</summary>
    private static string ShortName(string name)
    {
        var paren = name.IndexOf('(');
        return paren < 0 ? name : name[..paren].Trim();
    }

    private static string SummaryLabel(string indicator) => indicator switch
    {
        "none" => "Operational",
        "minor" => "Degraded",
        "major" => "Partial Outage",
        "critical" => "Major Outage",
        "maintenance" => "Maintenance",
        _ => "Unknown",
    };
}
