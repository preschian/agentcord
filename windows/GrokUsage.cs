// Polls Grok CLI / SuperGrok weekly credit usage via
// GET https://cli-chat-proxy.grok.com/v1/billing?format=credits
// using the OIDC tokens stored in ~/.grok/auth.json (same source as the
// Grok CLI `/usage` view).
//
// This is weekly included credits (`creditUsagePercent`) — NOT the per-session
// context window fill (that still lives on GrokSession for the session card).
// Port of AgentCord/GrokUsage.swift.

using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json;

namespace AgentCord;

public sealed class GrokUsage : IDisposable
{
    public GrokUsageInfo? Current { get; private set; }

    /// <summary>True when ~/.grok/auth.json has usable OIDC credentials.</summary>
    public bool IsAuthenticated { get; private set; }

    /// <summary>Email of the signed-in xAI account, recorded in ~/.grok/auth.json.</summary>
    public string? AccountEmail { get; private set; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(300);
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromSeconds(60);
    /// <summary>Keep a disk-cached snapshot for a day so relaunch / idle
    /// stretches still show the last known numbers.</summary>
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromHours(24);

    private static readonly Uri BillingUrl = new("https://cli-chat-proxy.grok.com/v1/billing?format=credits");
    private const string CliAuthHeader = "xai-grok-cli";

    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly string? _grokHomeOverride;
    private readonly object _lock = new();
    private DateTime _lastSuccess = DateTime.MinValue;
    private DateTime _lastAttempt = DateTime.MinValue;
    private string? _cachedAccessToken;
    private string? _cachedRefreshToken;
    private string? _cachedClientId;
    private string? _cachedIssuer;
    private string? _cachedUserId;
    private System.Threading.Timer? _timer;

    public GrokUsage(string? grokHome = null)
    {
        _grokHomeOverride = grokHome;
        if (LoadCache() is { } cached
            && DateTime.UtcNow - cached.FetchedAt <= MaxStaleness)
        {
            Current = cached.Info;
            _lastSuccess = cached.FetchedAt;
        }
        var auth = ReadAuthFile();
        IsAuthenticated = auth is not null;
        AccountEmail = auth?.Email;
    }

    public void Start() => SetEnabled(true);

    public void SetEnabled(bool enabled)
    {
        if (enabled)
        {
            if (_timer is not null) return;
            var first = Current is null ? TimeSpan.FromSeconds(2) : TimeSpan.FromSeconds(5);
            _timer = new System.Threading.Timer(_ => _ = FetchAsync(), null, first, PollInterval);
            return;
        }
        _timer?.Dispose();
        _timer = null;
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
            LoadCredentialsFromDisk();
            if (_cachedAccessToken is null && _cachedRefreshToken is null)
            {
                IsAuthenticated = false;
                AccountEmail = null;
                HandleFailure();
                return;
            }

            IsAuthenticated = true;
            var info = await RequestBillingAsync(allowRefresh: true);
            if (info is null)
            {
                HandleFailure();
                return;
            }

            lock (_lock) _lastSuccess = DateTime.UtcNow;
            Current = info;
            SaveCache(info, _lastSuccess);
        }
        catch
        {
            HandleFailure();
        }
    }

    private async Task<GrokUsageInfo?> RequestBillingAsync(bool allowRefresh)
    {
        if (string.IsNullOrEmpty(_cachedAccessToken))
        {
            if (allowRefresh && await RefreshAccessTokenAsync())
                return await RequestBillingAsync(allowRefresh: false);
            return null;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, BillingUrl);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _cachedAccessToken);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.TryAddWithoutValidation("X-XAI-Token-Auth", CliAuthHeader);
        request.Headers.TryAddWithoutValidation("User-Agent", "GrokCLI");
        if (!string.IsNullOrEmpty(_cachedUserId))
            request.Headers.TryAddWithoutValidation("x-userid", _cachedUserId);

        using var response = await _http.SendAsync(request);
        if ((int)response.StatusCode == 401 && allowRefresh && await RefreshAccessTokenAsync())
            return await RequestBillingAsync(allowRefresh: false);
        if (!response.IsSuccessStatusCode) return null;

        var body = await response.Content.ReadAsStringAsync();
        return ParseBilling(body);
    }

    private async Task<bool> RefreshAccessTokenAsync()
    {
        if (string.IsNullOrEmpty(_cachedRefreshToken) || string.IsNullOrEmpty(_cachedClientId))
            return false;

        var issuer = string.IsNullOrEmpty(_cachedIssuer) ? "https://auth.x.ai" : _cachedIssuer.TrimEnd('/');
        var url = issuer + "/oauth2/token";

        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new FormUrlEncodedContent(new Dictionary<string, string>
            {
                ["grant_type"] = "refresh_token",
                ["refresh_token"] = _cachedRefreshToken,
                ["client_id"] = _cachedClientId,
            }),
        };

        using var response = await _http.SendAsync(request);
        if (!response.IsSuccessStatusCode) return false;

        try
        {
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
            var access = doc.RootElement.TryGetProperty("access_token", out var accessEl)
                && accessEl.ValueKind == JsonValueKind.String
                ? accessEl.GetString()
                : null;
            if (string.IsNullOrEmpty(access)) return false;
            _cachedAccessToken = access;
            if (doc.RootElement.TryGetProperty("refresh_token", out var refreshEl)
                && refreshEl.ValueKind == JsonValueKind.String
                && refreshEl.GetString() is { Length: > 0 } refresh)
            {
                _cachedRefreshToken = refresh;
            }
            return true;
        }
        catch
        {
            return false;
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

    private void LoadCredentialsFromDisk()
    {
        var auth = ReadAuthFile();
        if (auth is null)
        {
            _cachedAccessToken = null;
            _cachedRefreshToken = null;
            _cachedClientId = null;
            _cachedIssuer = null;
            _cachedUserId = null;
            AccountEmail = null;
            return;
        }

        _cachedRefreshToken = auth.RefreshToken;
        _cachedClientId = auth.ClientId;
        _cachedIssuer = auth.Issuer;
        _cachedUserId = auth.UserId;
        AccountEmail = string.IsNullOrEmpty(auth.Email) ? null : auth.Email;
        if (!string.IsNullOrEmpty(auth.AccessToken))
            _cachedAccessToken = auth.AccessToken;
    }

    private sealed record AuthTokens(
        string? AccessToken,
        string? RefreshToken,
        string? ClientId,
        string? Issuer,
        string? UserId,
        string? Email);

    private AuthTokens? ReadAuthFile()
    {
        try
        {
            var path = AuthFilePath();
            if (path is null) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;

            foreach (var prop in doc.RootElement.EnumerateObject())
            {
                if (prop.Value.ValueKind != JsonValueKind.Object) continue;
                var obj = prop.Value;
                var access = StringProp(obj, "key");
                var refresh = StringProp(obj, "refresh_token");
                if (string.IsNullOrEmpty(access) && string.IsNullOrEmpty(refresh)) continue;
                return new AuthTokens(
                    access,
                    refresh,
                    StringProp(obj, "oidc_client_id"),
                    StringProp(obj, "oidc_issuer"),
                    StringProp(obj, "user_id"),
                    StringProp(obj, "email"));
            }
        }
        catch
        {
            // Missing or malformed auth is treated as signed out.
        }
        return null;
    }

    private string? AuthFilePath()
    {
        if (!string.IsNullOrEmpty(_grokHomeOverride))
        {
            var overridePath = Path.Combine(_grokHomeOverride, "auth.json");
            return File.Exists(overridePath) ? overridePath : null;
        }
        if (Environment.GetEnvironmentVariable("GROK_HOME") is { Length: > 0 } env)
        {
            var envPath = Path.Combine(env, "auth.json");
            if (File.Exists(envPath)) return envPath;
        }
        var home = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".grok", "auth.json");
        return File.Exists(home) ? home : null;
    }

    /// <summary>Parse a billing JSON body into weekly / on-demand windows.</summary>
    public static GrokUsageInfo? ParseBilling(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            return ParseBilling(doc.RootElement);
        }
        catch
        {
            return null;
        }
    }

    internal static GrokUsageInfo? ParseBilling(JsonElement root)
    {
        JsonElement? config = root.TryGetProperty("config", out var cfg) && cfg.ValueKind == JsonValueKind.Object
            ? cfg
            : null;

        string? periodEndRaw = null;
        if (config is JsonElement c)
        {
            if (c.TryGetProperty("currentPeriod", out var period) && period.ValueKind == JsonValueKind.Object)
                periodEndRaw = StringProp(period, "end");
            periodEndRaw ??= StringProp(c, "billingPeriodEnd");
        }
        periodEndRaw ??= StringProp(root, "billingPeriodEnd");

        var periodEndMs = ParseIsoMs(periodEndRaw);

        // `creditUsagePercent` is present with the real figure on SuperGrok
        // weekly accounts. Unified-billing accounts omit it entirely but still
        // report the weekly `currentPeriod` — the Grok CLI shows that as 0%
        // used, so treat an absent percent (when we have a period) as zero.
        var percentRaw = NumberProp(config, "creditUsagePercent")
            ?? NumberProp(root, "creditUsagePercent")
            ?? (periodEndMs is not null ? 0 : null);
        if (percentRaw is not double percentValue || double.IsNaN(percentValue) || double.IsInfinity(percentValue))
            return null;

        var percent = ClampPercent(percentValue);
        var weekly = MakeWindow(percent, periodEndMs);

        UsageWindow? onDemand = null;
        if (config is JsonElement cfgObj
            && MoneyVal(cfgObj, "onDemandCap") is double cap && cap > 0)
        {
            var used = MoneyVal(cfgObj, "onDemandUsed") ?? 0;
            onDemand = MakeWindow(ClampPercent(used / cap * 100.0), periodEndMs);
        }

        return new GrokUsageInfo { Weekly = weekly, OnDemand = onDemand };
    }

    private static UsageWindow MakeWindow(int percent, long? resetsAtMs) => new()
    {
        Percent = percent,
        Severity = percent >= 95 ? "critical" : percent >= 80 ? "warning" : "normal",
        ResetsAtMs = resetsAtMs,
    };

    private static int ClampPercent(double value) =>
        Math.Min(100, Math.Max(0, (int)Math.Round(value)));

    private static double? NumberProp(JsonElement? obj, string name)
    {
        if (obj is not JsonElement el) return NumberProp(default(JsonElement), name);
        return NumberProp(el, name);
    }

    private static double? NumberProp(JsonElement obj, string name)
    {
        if (obj.ValueKind != JsonValueKind.Object) return null;
        if (!obj.TryGetProperty(name, out var v) || v.ValueKind != JsonValueKind.Number)
            return null;
        return v.GetDouble();
    }

    private static double? MoneyVal(JsonElement obj, string name)
    {
        if (!obj.TryGetProperty(name, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
        if (v.ValueKind == JsonValueKind.Object)
            return NumberProp(v, "val");
        return null;
    }

    private static string? StringProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long? ParseIsoMs(string? value)
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

    // --- Disk cache

    private sealed record CachePayload(DateTime FetchedAt, GrokUsageInfo Info);

    private static string CachePath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            return Path.Combine(baseDir, "AgentCord", "grok-usage-cache.json");
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

    private static void SaveCache(GrokUsageInfo info, DateTime fetchedAt)
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
