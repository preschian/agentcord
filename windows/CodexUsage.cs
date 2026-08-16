// Reads Codex / ChatGPT subscription rate limits through Codex's local
// app-server JSONL protocol. Codex remains the owner of its credentials and
// refresh lifecycle; AgentCord never reads OAuth tokens directly.
//
// Best-effort: a failed probe keeps the last disk-cached snapshot so relaunch
// / idle stretches still show numbers instead of "Waiting for Codex usage…".
// The cache is bound to Codex's local account_id so a logout or account switch
// cannot keep showing another account's numbers. We only read account_id for
// that binding — OAuth tokens stay owned by Codex / app-server.

using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace AgentCord;

public sealed class CodexUsage : IDisposable
{
    public CodexUsageInfo? Current { get; private set; }

    /// <summary>Email of the signed-in ChatGPT account, from account/read.</summary>
    public string? AccountEmail { get; private set; }

    public bool IsAuthenticated { get; private set; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromMinutes(5);
    public TimeSpan MinFetchInterval { get; init; } = TimeSpan.FromMinutes(1);
    /// <summary>How long a disk-cached snapshot may still be shown after the last
    /// successful fetch. Matches macOS — generous so an idle stretch or a
    /// relaunch shows the last known numbers instead of "Waiting…".</summary>
    public TimeSpan MaxStaleness { get; init; } = TimeSpan.FromHours(24);
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(15);

    private readonly object _lock = new();
    private DateTime _lastAttempt = DateTime.MinValue;
    private DateTime _lastSuccess = DateTime.MinValue;
    private string? _accountKey;
    private System.Threading.Timer? _timer;
    private int _fetching;
    private bool _disposed;

    public CodexUsage()
    {
        var key = CurrentAccountKey();
        if (key is null)
        {
            ClearCache();
            return;
        }

        var cached = LoadCache();
        if (cached is not null
            && cached.AccountKey == key
            && DateTime.UtcNow - cached.FetchedAt <= MaxStaleness)
        {
            Current = cached.Info;
            _lastSuccess = cached.FetchedAt;
            _accountKey = key;
            IsAuthenticated = true;
        }
        else if (cached is not null)
        {
            ClearCache();
        }
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
        _disposed = true;
        _timer?.Dispose();
    }

    private async Task FetchAsync()
    {
        if (_disposed || Interlocked.Exchange(ref _fetching, 1) == 1) return;
        lock (_lock) _lastAttempt = DateTime.UtcNow;

        try
        {
            var key = CurrentAccountKey();
            if (key is null)
            {
                InvalidateIdentity();
                return;
            }

            if (_accountKey is not null && _accountKey != key)
                InvalidateIdentity();
            _accountKey = key;

            var executable = FindExecutable();
            if (executable is null)
            {
                HandleFailure();
                return;
            }

            using var process = new Process
            {
                StartInfo = new ProcessStartInfo(executable)
                {
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                },
            };
            process.StartInfo.ArgumentList.Add("app-server");
            // Match macOS: point app-server at the same home CodexSession uses
            // so a custom CODEX_HOME is honored for credentials too.
            process.StartInfo.Environment["CODEX_HOME"] = CodexPaths.ResolveHome();
            if (!process.Start())
            {
                HandleFailure();
                return;
            }

            await process.StandardInput.WriteLineAsync(
                """{"method":"initialize","id":0,"params":{"clientInfo":{"name":"agentcord","title":"AgentCord","version":"0.4.0"}}}""");
            await process.StandardInput.WriteLineAsync(
                """{"method":"account/read","id":1,"params":{"refreshToken":false}}""");
            await process.StandardInput.WriteLineAsync(
                """{"method":"account/rateLimits/read","id":2,"params":null}""");
            await process.StandardInput.FlushAsync();

            using var timeout = new CancellationTokenSource(RequestTimeout);
            CodexUsageInfo? result = null;
            string? email = null;
            bool? authenticated = null;
            try
            {
                while (!timeout.IsCancellationRequested)
                {
                    var line = await process.StandardOutput.ReadLineAsync(timeout.Token);
                    if (line is null) break;
                    if (TryParseAccount(line, out var accountEmail, out var accountAuth))
                    {
                        email = accountEmail;
                        authenticated = accountAuth;
                        continue;
                    }
                    if (TryParseResponse(line, out result)) break;
                }
            }
            catch (OperationCanceledException)
            {
                // The app-server is intentionally short-lived from our point
                // of view; a timeout simply retains the last good snapshot.
            }

            if (!process.HasExited)
            {
                try { process.Kill(entireProcessTree: true); }
                catch { }
            }

            if (authenticated == false)
            {
                InvalidateIdentity();
                return;
            }

            if (authenticated is true) IsAuthenticated = true;
            AccountEmail = string.IsNullOrEmpty(email) ? null : email;

            if (result is null)
            {
                HandleFailure();
                return;
            }

            if (!IsAuthenticated) IsAuthenticated = true;
            Current = result;
            lock (_lock) _lastSuccess = DateTime.UtcNow;
            SaveCache(result, _lastSuccess, key);
        }
        catch
        {
            HandleFailure();
        }
        finally
        {
            Interlocked.Exchange(ref _fetching, 0);
        }
    }

    private void HandleFailure()
    {
        lock (_lock)
        {
            if (DateTime.UtcNow - _lastSuccess > MaxStaleness)
                InvalidateIdentityUnlocked();
        }
    }

    private void InvalidateIdentity()
    {
        lock (_lock) InvalidateIdentityUnlocked();
    }

    private void InvalidateIdentityUnlocked()
    {
        Current = null;
        AccountEmail = null;
        IsAuthenticated = false;
        _accountKey = null;
        _lastSuccess = DateTime.MinValue;
        ClearCache();
    }

    // --- Disk cache

    /// <summary>AccountKey is Codex's local tokens.account_id from auth.json.</summary>
    private sealed record CachePayload(DateTime FetchedAt, string AccountKey, CodexUsageInfo Info);

    private static string CachePath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            return Path.Combine(baseDir, "AgentCord", "codex-usage-cache.json");
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

    private static void SaveCache(CodexUsageInfo info, DateTime fetchedAt, string accountKey)
    {
        try
        {
            var path = CachePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(new CachePayload(fetchedAt, accountKey, info)));
            File.Move(tmp, path, overwrite: true);
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
        try { File.Delete(CachePath + ".tmp"); }
        catch { }
    }

    /// <summary>Stable ChatGPT account id from Codex's auth.json. Identity only —
    /// we never read or refresh the OAuth tokens ourselves.</summary>
    private static string? CurrentAccountKey()
    {
        try
        {
            var path = Path.Combine(CodexPaths.ResolveHome(), "auth.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("tokens", out var tokens)
                || tokens.ValueKind != JsonValueKind.Object)
                return null;
            var id = tokens.TryGetProperty("account_id", out var value) ? value.GetString() : null;
            return string.IsNullOrEmpty(id) ? null : id;
        }
        catch
        {
            return null;
        }
    }

    private static bool TryParseAccount(string line, out string? email, out bool authenticated)
    {
        email = null;
        authenticated = false;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("id", out var id)
                || !id.TryGetInt32(out var requestId)
                || requestId != 1)
                return false;

            if (!root.TryGetProperty("result", out var result)
                || result.ValueKind != JsonValueKind.Object
                || !result.TryGetProperty("account", out var account)
                || account.ValueKind != JsonValueKind.Object)
                return true;

            email = StringProp(account, "email");
            var type = StringProp(account, "type");
            authenticated = type is "chatgpt" or "personalAccessToken";
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryParseResponse(string line, out CodexUsageInfo? info)
    {
        info = null;
        try
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("id", out var id)
                || !id.TryGetInt32(out var requestId)
                || requestId != 2)
                return false;

            if (!root.TryGetProperty("result", out var result)
                || result.ValueKind != JsonValueKind.Object
                || !result.TryGetProperty("rateLimits", out var limits)
                || limits.ValueKind != JsonValueKind.Object
                || !limits.TryGetProperty("primary", out var primary)
                || primary.ValueKind != JsonValueKind.Object)
                return true;

            var primaryWindow = ParseWindow(primary, limits.GetPropertyOrNull("rateLimitReachedType") is not null);
            var secondary = limits.TryGetProperty("secondary", out var secondaryElement)
                && secondaryElement.ValueKind == JsonValueKind.Object
                ? ParseWindow(secondaryElement, false)
                : null;

            var additional = new List<NamedUsageWindow>();
            if (result.TryGetProperty("rateLimitsByLimitId", out var byId)
                && byId.ValueKind == JsonValueKind.Object)
            {
                foreach (var item in byId.EnumerateObject().OrderBy(item => item.Name))
                {
                    if (item.Name.Equals("codex", StringComparison.OrdinalIgnoreCase)
                        || item.Value.ValueKind != JsonValueKind.Object)
                        continue;

                    var snapshot = item.Value;
                    var rawName = StringProp(snapshot, "limitName")
                        ?? StringProp(snapshot, "limitId")
                        ?? item.Name;
                    var label = DisplayName(rawName);
                    var reached = snapshot.GetPropertyOrNull("rateLimitReachedType") is not null;

                    if (snapshot.TryGetProperty("primary", out var scopedPrimary)
                        && scopedPrimary.ValueKind == JsonValueKind.Object)
                    {
                        additional.Add(new NamedUsageWindow
                        {
                            Id = $"{item.Name}-primary",
                            Label = label,
                            Window = ParseWindow(scopedPrimary, reached),
                        });
                    }
                    if (snapshot.TryGetProperty("secondary", out var scopedSecondary)
                        && scopedSecondary.ValueKind == JsonValueKind.Object)
                    {
                        additional.Add(new NamedUsageWindow
                        {
                            Id = $"{item.Name}-secondary",
                            Label = $"{label} · {WindowLabel(scopedSecondary, "Secondary")}",
                            Window = ParseWindow(scopedSecondary, false),
                        });
                    }
                }
            }

            info = new CodexUsageInfo
            {
                Primary = primaryWindow,
                PrimaryLabel = WindowLabel(primary, "Primary limit"),
                Secondary = secondary,
                SecondaryLabel = secondary is null ? null : WindowLabel(secondaryElement, "Secondary limit"),
                PlanType = StringProp(limits, "planType"),
                AdditionalWindows = additional,
            };
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static UsageWindow ParseWindow(JsonElement window, bool reached)
    {
        var percent = NumberProp(window, "usedPercent") ?? 0;
        var rounded = Math.Clamp((int)Math.Round(percent), 0, 100);
        var resetSeconds = NumberProp(window, "resetsAt");
        return new UsageWindow
        {
            Percent = rounded,
            Severity = reached || rounded >= 90 ? "critical" : rounded >= 70 ? "warning" : "normal",
            ResetsAtMs = resetSeconds is null
                ? null
                : (long)(resetSeconds > 1_000_000_000_000 ? resetSeconds : resetSeconds * 1000),
        };
    }

    private static string WindowLabel(JsonElement window, string fallback)
    {
        var minutes = NumberProp(window, "windowDurationMins");
        if (minutes is null || minutes <= 0) return fallback;
        if (minutes <= 6 * 60) return "5-hour session";
        if (minutes <= 8 * 24 * 60) return "Weekly limit";
        if (minutes <= 40 * 24 * 60) return "Monthly limit";
        return fallback;
    }

    private static string DisplayName(string value) => string.Join(
        " ",
        value.Replace('_', ' ').Replace('-', ' ')
            .Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(word => char.ToUpperInvariant(word[0]) + word[1..]));

    private static string? StringProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static double? NumberProp(JsonElement obj, string name) =>
        obj.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetDouble(out var number)
            ? number
            : null;

    private static string? FindExecutable()
    {
        var candidates = new List<string>();
        if (Environment.GetEnvironmentVariable("CODEX_BINARY") is { Length: > 0 } configured)
            candidates.Add(configured);

        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "")
                     .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            candidates.Add(Path.Combine(dir.Trim('"'), "codex.exe"));
        }

        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        candidates.Add(Path.Combine(local, "Programs", "OpenAI", "Codex", "bin", "codex.exe"));
        candidates.Add(Path.Combine(profile, ".local", "bin", "codex.exe"));

        return candidates.FirstOrDefault(File.Exists);
    }
}

internal static class JsonElementExtensions
{
    public static JsonElement? GetPropertyOrNull(this JsonElement element, string name) =>
        element.TryGetProperty(name, out var value)
        && value.ValueKind is not JsonValueKind.Null and not JsonValueKind.Undefined
            ? value
            : null;
}
