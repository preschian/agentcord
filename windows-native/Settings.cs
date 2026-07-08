// User-configurable settings. Port of AgentCord/Settings.swift.
//
// macOS persists these in UserDefaults; here they live in a JSON file at
// %APPDATA%\AgentCord\settings.json — the same path and snake_case schema as
// the Rust port, so either app picks up the other's config. Unknown fields are
// ignored on load and missing fields fall back to defaults, so old files keep
// loading as new fields are added.

using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentCord;

public sealed class Settings
{
    /// <summary>Discord Application ID baked into the app. Not a secret.</summary>
    public const string DiscordClientId = "1517099756063686677";

    [JsonPropertyName("presence_enabled")] public bool PresenceEnabled { get; set; } = true;
    [JsonPropertyName("show_model")] public bool ShowModel { get; set; } = true;
    [JsonPropertyName("show_tokens")] public bool ShowTokens { get; set; } = true;
    [JsonPropertyName("show_project")] public bool ShowProject { get; set; } = true;
    [JsonPropertyName("large_image_key")] public string LargeImageKey { get; set; } = "claude-color";
    [JsonPropertyName("small_image_key")] public string SmallImageKey { get; set; } = "discord-presence-icon";

    /// <summary>Discord activity type: 0 Playing, 2 Listening, 3 Watching, 5 Competing.</summary>
    [JsonPropertyName("activity_type")] public int ActivityType { get; set; }

    /// <summary>A transcript counts as active if touched within this many seconds.</summary>
    [JsonPropertyName("idle_window_seconds")] public double IdleWindowSeconds { get; set; } = 300.0;

    /// <summary>Keep the machine awake while the app runs (macOS "Prevent sleep").</summary>
    [JsonPropertyName("prevent_sleep")] public bool PreventSleep { get; set; }

    /// <summary>Activity types Discord permits for RPC updates (value, UI label).
    /// Streaming (1) and Custom (4) are intentionally excluded.</summary>
    public static readonly (int Value, string Name)[] ActivityTypes =
        [(0, "Playing"), (2, "Listening"), (3, "Watching"), (5, "Competing")];

    public static bool IsAllowedActivity(int value) => ActivityTypes.Any(t => t.Value == value);

    public static string ActivityLabel(int value) =>
        ActivityTypes.FirstOrDefault(t => t.Value == value).Name ?? "Playing";

    private static readonly JsonSerializerOptions FileOptions = new() { WriteIndented = true };

    public static string ConfigPath
    {
        get
        {
            var baseDir = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
            if (string.IsNullOrEmpty(baseDir)) baseDir = Path.GetTempPath();
            return Path.Combine(baseDir, "AgentCord", "settings.json");
        }
    }

    /// <summary>Load from disk, falling back to defaults on any error (missing
    /// file, malformed JSON). Writes nothing.</summary>
    public static Settings Load()
    {
        try
        {
            return JsonSerializer.Deserialize<Settings>(File.ReadAllText(ConfigPath)) ?? new Settings();
        }
        catch
        {
            return new Settings();
        }
    }

    public void Save()
    {
        try
        {
            var path = ConfigPath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, JsonSerializer.Serialize(this, FileOptions));
        }
        catch
        {
            // Best-effort: a read-only profile shouldn't crash the tray app.
        }
    }
}
