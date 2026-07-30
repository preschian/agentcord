// Polls the user's Cursor subscription usage limits — included spend for the
// current billing period (Pro/Team/Ultra) or request buckets (legacy).
//
// Numbers come from undocumented endpoints the Cursor app itself calls. We
// reuse Cursor's access token from %APPDATA%\Cursor\auth.json (preferred) or
// state.vscdb via sqlite3, then hit the same endpoints. Account email and plan
// prefer the IDE's state.vscdb cache (cursorAuth/cachedEmail,
// stripeMembershipType); when those are missing — typical for CLI-only
// auth.json installs — we fall back to AuthService/GetEmail and
// /auth/full_stripe_profile. Best-effort: missing token / expired auth /
// endpoint change leaves Current null (or the last cached snapshot while still
// fresh). Port of AgentCord/CursorUsage.swift.

using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace AgentCord;

public sealed class CursorUsage : IDisposable
{
    public CursorUsageInfo? Current { get; private set; }

    /// <summary>Email of the signed-in Cursor account, cached by the Cursor app.</summary>
    public string? AccountEmail { get; private set; }

    public bool IsAuthenticated { get; private set; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(300);
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromSeconds(60);
    /// <summary>Keep a disk-cached snapshot for a day so relaunch / idle
    /// stretches still show the last known numbers.</summary>
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromHours(24);

    private static readonly Uri PeriodUsageUrl = new(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage");
    private static readonly Uri LegacyUsageUrl = new("https://api2.cursor.sh/auth/usage");
    private static readonly Uri GetEmailUrl = new(
        "https://api2.cursor.sh/aiserver.v1.AuthService/GetEmail");
    private static readonly Uri StripeProfileUrl = new(
        "https://api2.cursor.sh/auth/full_stripe_profile");

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly object _lock = new();
    private DateTime _lastSuccess = DateTime.MinValue;
    private DateTime _lastAttempt = DateTime.MinValue;
    private System.Threading.Timer? _timer;

    public CursorUsage()
    {
        if (LoadCache() is { } cached
            && DateTime.UtcNow - cached.FetchedAt <= MaxStaleness)
        {
            Current = cached.Info;
            _lastSuccess = cached.FetchedAt;
        }
        IsAuthenticated = ReadAccessToken() is not null;
        if (IsAuthenticated) AccountEmail = ReadLocalEmail();
    }

    public void Start()
    {
        var first = Current is null ? TimeSpan.FromSeconds(2) : TimeSpan.FromSeconds(5);
        _timer = new System.Threading.Timer(_ => _ = FetchAsync(), null, first, PollInterval);
    }

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
            var token = ReadAccessToken();
            if (token is null)
            {
                IsAuthenticated = false;
                AccountEmail = null;
                HandleFailure();
                return;
            }

            IsAuthenticated = true;
            // Desktop IDE caches email/plan in state.vscdb; CLI-only installs
            // (auth.json alone) have neither, so fall back to Cursor APIs.
            AccountEmail = ReadLocalEmail() ?? await FetchEmailAsync(token);
            var membership = ReadLocalMembershipType() ?? await FetchMembershipAsync(token);

            var info = await FetchPeriodUsageAsync(token)
                ?? await FetchLegacyUsageAsync(token);
            if (info is null) { HandleFailure(); return; }

            if (info.PlanName is null && membership is not null)
                info = info with { PlanName = membership };

            lock (_lock) _lastSuccess = DateTime.UtcNow;
            Current = info;
            SaveCache(info, _lastSuccess);
        }
        catch
        {
            HandleFailure();
        }
    }

    private void HandleFailure()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _lastSuccess > MaxStaleness)
            {
                Current = null;
                ClearCache();
            }
        }
    }

    private async Task<CursorUsageInfo?> FetchPeriodUsageAsync(string token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, PeriodUsageUrl)
        {
            Content = new StringContent("{}", Encoding.UTF8, "application/json"),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
        request.Headers.TryAddWithoutValidation("User-Agent", "AgentCord");

        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return ParsePeriodUsage(doc.RootElement);
    }

    private async Task<CursorUsageInfo?> FetchLegacyUsageAsync(string token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, LegacyUsageUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        request.Headers.TryAddWithoutValidation("User-Agent", "AgentCord");

        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return null;

        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
        return ParseLegacyUsage(doc.RootElement);
    }

    /// <summary>POST AuthService/GetEmail — used when state.vscdb has no
    /// cachedEmail (typical for Cursor CLI-only auth.json installs).</summary>
    private async Task<string?> FetchEmailAsync(string token)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Post, GetEmailUrl)
            {
                Content = new StringContent("{}", Encoding.UTF8, "application/json"),
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
            request.Headers.TryAddWithoutValidation("User-Agent", "AgentCord");

            using var response = await _http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var email = doc.RootElement.TryGetProperty("email", out var value)
                && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
            return string.IsNullOrEmpty(email) ? null : email;
        }
        catch
        {
            return null;
        }
    }

    /// <summary>GET /auth/full_stripe_profile → membershipType (e.g. "pro").</summary>
    private async Task<string?> FetchMembershipAsync(string token)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, StripeProfileUrl);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("User-Agent", "AgentCord");

            using var response = await _http.SendAsync(request);
            if (!response.IsSuccessStatusCode) return null;

            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var membership = doc.RootElement.TryGetProperty("membershipType", out var value)
                && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
            return string.IsNullOrEmpty(membership) ? null : membership;
        }
        catch
        {
            return null;
        }
    }

    // --- Auth

    /// <summary>Prefer auth.json (common on Windows CLI installs), then the
    /// IDE state DB key used by the desktop app.</summary>
    private static string? ReadAccessToken() =>
        ReadAuthJsonToken() ?? ReadStateValue("cursorAuth/accessToken");

    private static string? ReadLocalMembershipType() =>
        ReadStateValue("cursorAuth/stripeMembershipType");

    private static string? ReadLocalEmail() =>
        ReadStateValue("cursorAuth/cachedEmail");

    private static string? ReadAuthJsonToken()
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor", "auth.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var token = doc.RootElement.TryGetProperty("accessToken", out var value)
                && value.ValueKind == JsonValueKind.String
                ? value.GetString()
                : null;
            return string.IsNullOrEmpty(token) ? null : token;
        }
        catch
        {
            return null;
        }
    }

    private static string? ReadStateValue(string key)
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor", "User", "globalStorage", "state.vscdb");
            if (!File.Exists(path)) return null;

            var start = new ProcessStartInfo("sqlite3")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            start.ArgumentList.Add(path);
            start.ArgumentList.Add($"SELECT value FROM ItemTable WHERE key = '{key.Replace("'", "''")}';");

            using var process = Process.Start(start);
            if (process is null) return null;
            var output = process.StandardOutput.ReadToEnd().Trim();
            if (!process.WaitForExit(3000))
            {
                process.Kill();
                return null;
            }
            if (process.ExitCode != 0 || output.Length == 0) return null;
            return output.Trim('"');
        }
        catch
        {
            return null;
        }
    }

    // --- Parsing

    private static CursorUsageInfo? ParsePeriodUsage(JsonElement root)
    {
        if (!root.TryGetProperty("planUsage", out var plan) || plan.ValueKind != JsonValueKind.Object)
            return null;

        int? totalPercent = null;
        if (NumberProp(plan, "totalPercentUsed") is double p)
            totalPercent = ClampPercent(p);
        else if (NumberProp(plan, "limit") is double limit && limit > 0)
        {
            var used = NumberProp(plan, "includedSpend") ?? NumberProp(plan, "totalSpend");
            if (used is double u)
                totalPercent = ClampPercent(u / limit * 100.0);
        }
        if (totalPercent is null) return null;

        var resetsAt = ParseEpochMillis(FlexibleString(root, "billingCycleEnd"));

        UsageWindow? auto = null;
        if (NumberProp(plan, "autoPercentUsed") is double autoPct && autoPct > 0)
        {
            var pct = ClampPercent(autoPct);
            if (pct != totalPercent) auto = MakeWindow(pct, resetsAt);
        }

        UsageWindow? api = null;
        if (NumberProp(plan, "apiPercentUsed") is double apiPct && apiPct > 0)
        {
            var pct = ClampPercent(apiPct);
            if (pct != totalPercent) api = MakeWindow(pct, resetsAt);
        }

        UsageWindow? onDemand = null;
        if (root.TryGetProperty("spendLimitUsage", out var spend) && spend.ValueKind == JsonValueKind.Object
            && NumberProp(spend, "individualLimit") is double lim && lim > 0)
        {
            var remaining = NumberProp(spend, "individualRemaining") ?? lim;
            var used = Math.Max(0, lim - remaining);
            onDemand = MakeWindow(ClampPercent(used / lim * 100.0), resetsAt);
        }

        return new CursorUsageInfo
        {
            Included = MakeWindow(totalPercent.Value, resetsAt),
            Auto = auto,
            Api = api,
            OnDemand = onDemand,
        };
    }

    private static CursorUsageInfo? ParseLegacyUsage(JsonElement root)
    {
        string? startOfMonth = null;
        string? bestKey = null;
        int bestUsed = 0;
        int bestMax = 0;

        foreach (var prop in root.EnumerateObject())
        {
            if (prop.NameEquals("startOfMonth") && prop.Value.ValueKind == JsonValueKind.String)
            {
                startOfMonth = prop.Value.GetString();
                continue;
            }
            if (prop.Value.ValueKind != JsonValueKind.Object) continue;
            if (NumberProp(prop.Value, "maxRequestUsage") is not double max || max <= 0) continue;
            var used = (int)(NumberProp(prop.Value, "numRequests") ?? 0);
            if (bestKey is null || max > bestMax)
            {
                bestKey = prop.Name;
                bestUsed = used;
                bestMax = (int)max;
            }
        }

        if (bestKey is null || bestMax <= 0) return null;
        var percent = ClampPercent(bestUsed * 100.0 / bestMax);
        return new CursorUsageInfo
        {
            Included = MakeWindow(percent, ParseMonthStartPlusOne(startOfMonth)),
            PlanName = bestKey,
        };
    }

    private static UsageWindow MakeWindow(int percent, long? resetsAtMs) => new()
    {
        Percent = percent,
        Severity = percent >= 95 ? "critical" : percent >= 80 ? "warning" : "normal",
        ResetsAtMs = resetsAtMs,
    };

    private static int ClampPercent(double value) =>
        Math.Min(100, Math.Max(0, (int)Math.Round(value)));

    private static double? NumberProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble()
            : null;

    private static string? FlexibleString(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var v)) return null;
        return v.ValueKind switch
        {
            JsonValueKind.String => v.GetString(),
            JsonValueKind.Number => v.TryGetInt64(out var n) ? n.ToString(CultureInfo.InvariantCulture) : null,
            _ => null,
        };
    }

    private static long? ParseEpochMillis(string? raw)
    {
        if (string.IsNullOrEmpty(raw)
            || !double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var millis))
        {
            return null;
        }
        // Accept seconds or milliseconds.
        if (millis > 1_000_000_000_000) return (long)millis;
        return (long)(millis * 1000);
    }

    private static long? ParseMonthStartPlusOne(string? iso)
    {
        if (string.IsNullOrEmpty(iso)) return null;
        if (!DateTimeOffset.TryParse(iso, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var start))
        {
            return null;
        }
        // Legacy field is startOfMonth; quota resets at the next month boundary.
        return start.AddMonths(1).ToUnixTimeMilliseconds();
    }

    // --- Disk cache

    private sealed record CachePayload(DateTime FetchedAt, CursorUsageInfo Info);

    private static string CachePath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            return Path.Combine(baseDir, "AgentCord", "cursor-usage-cache.json");
        }
    }

    private static CachePayload? LoadCache()
    {
        try
        {
            return JsonSerializer.Deserialize<CachePayload>(File.ReadAllText(CachePath));
        }
        catch
        {
            return null;
        }
    }

    private static void SaveCache(CursorUsageInfo info, DateTime fetchedAt)
    {
        try
        {
            var path = CachePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(new CachePayload(fetchedAt, info)));
        }
        catch
        {
            // Best-effort cache.
        }
    }

    private static void ClearCache()
    {
        try { File.Delete(CachePath); }
        catch { }
    }
}
