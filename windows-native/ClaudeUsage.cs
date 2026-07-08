// Polls the user's Claude subscription usage limits — the rolling 5-hour
// "session" quota, the weekly quota, and any per-model weekly quotas shown by
// Claude Code's /usage. Port of AgentCord/ClaudeUsage.swift.
//
// These numbers are not in the local transcripts; they come from an
// undocumented OAuth endpoint that Claude Code itself calls. We reuse Claude
// Code's own access token and hit the same endpoint. On macOS the token lives
// in the keychain; on Windows Claude Code stores it in
// %USERPROFILE%\.claude\.credentials.json, so we read that. The token is read
// fresh on every poll, so while Claude Code keeps it refreshed we stay current
// without implementing the OAuth refresh flow.
//
// Everything is best-effort: any failure (no token, expired token, endpoint
// changed, offline) just leaves Current null and the menu shows a dash.

using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace AgentCord;

public sealed class ClaudeUsage : IDisposable
{
    /// <summary>The latest usage snapshot, or null when it could not be fetched.</summary>
    public UsageInfo? Current { get; private set; }

    /// <summary>How often to refresh while the app runs. The numbers move slowly
    /// and the endpoint rate-limits aggressively (HTTP 429), so poll sparingly.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(300);

    /// <summary>Lower bound between fetches. Guards the on-demand Refresh()
    /// (menu opens) so reopening the menu can't hammer the endpoint.</summary>
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>How long to keep showing the last good snapshot after fetches
    /// start failing, so a transient blip doesn't make the readout vanish.</summary>
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromSeconds(1800);

    private static readonly Uri Endpoint = new("https://api.anthropic.com/api/oauth/usage");

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

    // --- Fetch

    private async Task FetchAsync()
    {
        lock (_lock) _lastAttempt = DateTime.UtcNow;

        try
        {
            var token = ReadAccessToken();
            if (token is null) { HandleFailure(); return; }

            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Add("anthropic-beta", "oauth-2025-04-20");
            request.Headers.Add("anthropic-version", "2023-06-01");

            using var response = await _http.SendAsync(request);
            if (!response.IsSuccessStatusCode) { HandleFailure(); return; }

            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var info = ParseUsage(doc.RootElement);
            lock (_lock) _lastSuccess = DateTime.UtcNow;
            Current = info;
        }
        catch
        {
            HandleFailure();
        }
    }

    /// <summary>A failed fetch keeps the last good snapshot until it ages past
    /// MaxStaleness, so a transient hiccup doesn't make the readout flicker.</summary>
    private void HandleFailure()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _lastSuccess > MaxStaleness) Current = null;
        }
    }

    /// <summary>Reads Claude Code's OAuth access token from
    /// %USERPROFILE%\.claude\.credentials.json.</summary>
    private static string? ReadAccessToken()
    {
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var path = Path.Combine(home, ".claude", ".credentials.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var token = doc.RootElement.GetProperty("claudeAiOauth").GetProperty("accessToken").GetString();
            return string.IsNullOrEmpty(token) ? null : token;
        }
        catch
        {
            return null;
        }
    }

    // --- Wire format

    /// <summary>Parses the subset of the /api/oauth/usage response we care
    /// about. The endpoint is undocumented, so parsing is defensive: prefer the
    /// structured `limits` array (it carries severity), fall back to the flat
    /// top-level windows, and never throw on a missing or renamed key.</summary>
    private static UsageInfo ParseUsage(JsonElement root)
    {
        var limits = root.TryGetProperty("limits", out var l) && l.ValueKind == JsonValueKind.Array
            ? l.EnumerateArray().ToList()
            : new List<JsonElement>();

        JsonElement? session = null, weekly = null;
        var modelWeekly = new List<ModelUsageWindow>();
        foreach (var limit in limits)
        {
            var kind = StringProp(limit, "kind");
            var group = StringProp(limit, "group");
            var hasScope = limit.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.Object;

            if (session is null && (kind == "session" || group == "session")) session = limit;
            if (weekly is null && (kind == "weekly_all" || (group == "weekly" && !hasScope))) weekly = limit;

            // Weekly limits scoped to a single model (e.g. Fable on some plans)
            // arrive as extra entries carrying the model's display name.
            if (group == "weekly" && hasScope
                && scope.TryGetProperty("model", out var model) && model.ValueKind == JsonValueKind.Object
                && StringProp(model, "display_name") is { Length: > 0 } name)
            {
                modelWeekly.Add(new ModelUsageWindow { ModelName = name, Window = LimitWindow(limit, null) });
            }
        }

        JsonElement? fiveHour = root.TryGetProperty("five_hour", out var fh) && fh.ValueKind == JsonValueKind.Object ? fh : null;
        JsonElement? sevenDay = root.TryGetProperty("seven_day", out var sd) && sd.ValueKind == JsonValueKind.Object ? sd : null;

        return new UsageInfo
        {
            FiveHour = LimitWindow(session, fiveHour),
            Weekly = LimitWindow(weekly, sevenDay),
            ModelWeekly = modelWeekly,
        };
    }

    private static UsageWindow LimitWindow(JsonElement? limit, JsonElement? fallback)
    {
        var percent = NumberProp(limit, "percent") ?? NumberProp(fallback, "utilization") ?? 0;
        var resetsAt = (limit is { } lim ? StringProp(lim, "resets_at") : null)
            ?? (fallback is { } fb ? StringProp(fb, "resets_at") : null);
        return new UsageWindow
        {
            Percent = (int)Math.Round(percent),
            Severity = (limit is { } li ? StringProp(li, "severity") : null) ?? "normal",
            ResetsAtMs = ClaudeSession.EpochMsFromIso(resetsAt),
        };
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static double? NumberProp(JsonElement? obj, string name) =>
        obj is { ValueKind: JsonValueKind.Object } o && o.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : null;
}
