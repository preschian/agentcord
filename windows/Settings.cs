// User-configurable settings. Port of AgentCord/Settings.swift.
//
// macOS persists these in UserDefaults; here they live in a JSON file at
// %APPDATA%\AgentCord\settings.json. Unknown fields are ignored on load and
// missing fields fall back to defaults, so old config files keep loading as
// new fields are added.

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
    /// <summary>Show the summary card covering every connected agent's primary
    /// usage window above the agent list (macOS "Show unified usage").</summary>
    [JsonPropertyName("unified_usage")] public bool UnifiedUsage { get; set; } = true;
    [JsonPropertyName("small_image_key")] public string SmallImageKey { get; set; } = "discord-presence-icon";
    [JsonPropertyName("selected_agent")] public AgentKind SelectedAgent { get; set; } = AgentKind.Claude;
    [JsonPropertyName("agent_claude_enabled")] public bool AgentClaudeEnabled { get; set; } = true;
    [JsonPropertyName("agent_codex_enabled")] public bool AgentCodexEnabled { get; set; } = true;
    [JsonPropertyName("agent_cursor_enabled")] public bool AgentCursorEnabled { get; set; } = true;
    [JsonPropertyName("agent_antigravity_enabled")] public bool AgentAntigravityEnabled { get; set; } = true;
    [JsonPropertyName("agent_grok_enabled")] public bool AgentGrokEnabled { get; set; } = true;

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

    public bool IsAgentEnabled(AgentKind agent) => agent switch
    {
        AgentKind.Codex => AgentCodexEnabled,
        AgentKind.Cursor => AgentCursorEnabled,
        AgentKind.Antigravity => AgentAntigravityEnabled,
        AgentKind.Grok => AgentGrokEnabled,
        _ => AgentClaudeEnabled,
    };

    /// <summary>Agents the user has toggled on in Settings, in display order.</summary>
    public IReadOnlyList<AgentKind> EnabledAgents
    {
        get
        {
            var list = new List<AgentKind>(5);
            if (AgentClaudeEnabled) list.Add(AgentKind.Claude);
            if (AgentCodexEnabled) list.Add(AgentKind.Codex);
            if (AgentCursorEnabled) list.Add(AgentKind.Cursor);
            if (AgentGrokEnabled) list.Add(AgentKind.Grok);
            if (AgentAntigravityEnabled) list.Add(AgentKind.Antigravity);
            return list;
        }
    }

    public void SetAgentEnabled(AgentKind agent, bool enabled)
    {
        switch (agent)
        {
            case AgentKind.Codex: AgentCodexEnabled = enabled; break;
            case AgentKind.Cursor: AgentCursorEnabled = enabled; break;
            case AgentKind.Antigravity: AgentAntigravityEnabled = enabled; break;
            case AgentKind.Grok: AgentGrokEnabled = enabled; break;
            default: AgentClaudeEnabled = enabled; break;
        }

        if (!IsAgentEnabled(SelectedAgent))
            SelectedAgent = FirstEnabledAgent();
    }

    private AgentKind FirstEnabledAgent()
    {
        if (AgentClaudeEnabled) return AgentKind.Claude;
        if (AgentCodexEnabled) return AgentKind.Codex;
        if (AgentCursorEnabled) return AgentKind.Cursor;
        if (AgentGrokEnabled) return AgentKind.Grok;
        if (AgentAntigravityEnabled) return AgentKind.Antigravity;
        return AgentKind.Claude;
    }

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
