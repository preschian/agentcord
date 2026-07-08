// Wire-format models for the Discord Rich Presence IPC protocol, plus the
// value types describing a detected Claude Code session and the user's
// subscription usage. Port of AgentCord/Models.swift.

using System.Text.Json.Serialization;

namespace AgentCord;

// --- Rich Presence payload

/// <summary>
/// A Discord activity (Rich Presence). All fields are nullable so only what we
/// actually want to display gets encoded (nulls are omitted on the wire).
/// </summary>
public sealed class RichPresence
{
    /// <summary>Activity type. 0 Playing, 2 Listening, 3 Watching, 5 Competing.
    /// Types 1 (Streaming) and 4 (Custom) are not allowed for RPC updates.</summary>
    [JsonPropertyName("type")] public int? Type { get; set; }

    /// <summary>The bold title line. Discord honors this for the activity header.</summary>
    [JsonPropertyName("name")] public string? Name { get; set; }

    [JsonPropertyName("details")] public string? Details { get; set; }
    [JsonPropertyName("state")] public string? State { get; set; }
    [JsonPropertyName("timestamps")] public Timestamps? Timestamps { get; set; }
    [JsonPropertyName("assets")] public Assets? Assets { get; set; }
    [JsonPropertyName("buttons")] public List<PresenceButton>? Buttons { get; set; }
}

public sealed class Timestamps
{
    /// <summary>Epoch milliseconds. Setting Start makes Discord show an elapsed counter.</summary>
    [JsonPropertyName("start")] public long? Start { get; set; }
    [JsonPropertyName("end")] public long? End { get; set; }
}

public sealed class Assets
{
    [JsonPropertyName("large_image")] public string? LargeImage { get; set; }
    [JsonPropertyName("large_text")] public string? LargeText { get; set; }
    [JsonPropertyName("small_image")] public string? SmallImage { get; set; }
    [JsonPropertyName("small_text")] public string? SmallText { get; set; }
}

public sealed class PresenceButton
{
    [JsonPropertyName("label")] public required string Label { get; set; }
    [JsonPropertyName("url")] public required string Url { get; set; }
}

// --- Claude Code session

/// <summary>A snapshot of the currently active Claude Code session.</summary>
public sealed record SessionInfo
{
    public required string ProjectName { get; init; }
    public string? Model { get; init; }
    public long StartEpochMs { get; init; }
    public long TotalTokens { get; init; }
    public long LastModifiedMs { get; init; }
}

// --- Claude subscription usage

/// <summary>One rate-limit window: how much of it is used and when it resets.</summary>
public sealed record UsageWindow
{
    public int Percent { get; init; }
    /// <summary>Raw severity from the API ("normal", "warning", ...). Drives color.</summary>
    public string Severity { get; init; } = "normal";
    public long? ResetsAtMs { get; init; }
}

/// <summary>A weekly limit scoped to a single model (e.g. "Fable"). Some plans
/// get these in addition to the all-models weekly limit.</summary>
public sealed record ModelUsageWindow
{
    public required string ModelName { get; init; }
    public required UsageWindow Window { get; init; }
}

/// <summary>The user's subscription usage, as shown by Claude Code's /usage.</summary>
public sealed record UsageInfo
{
    /// <summary>The rolling 5-hour session limit.</summary>
    public required UsageWindow FiveHour { get; init; }
    /// <summary>The weekly (all-models) limit.</summary>
    public required UsageWindow Weekly { get; init; }
    /// <summary>Per-model weekly limits, in API order. Empty when the plan has none.</summary>
    public IReadOnlyList<ModelUsageWindow> ModelWeekly { get; init; } = [];
}

// --- Anthropic status page

/// <summary>One status-page component, e.g. "Claude API" (Statuspage
/// parenthetical stripped). Status is the raw Statuspage string:
/// operational / degraded_performance / partial_outage / major_outage /
/// under_maintenance.</summary>
public sealed record StatusComponent
{
    public required string Name { get; init; }
    public required string Status { get; init; }
}

/// <summary>An unresolved incident from the status page.</summary>
public sealed record StatusIncident
{
    public required string Name { get; init; }
    /// <summary>"investigating" / "identified" / "monitoring" / ...</summary>
    public string Status { get; init; } = "investigating";
    public string Impact { get; init; } = "none";
    public long? StartedAtMs { get; init; }
}

/// <summary>Snapshot of status.claude.com for the popover and tray menu.</summary>
public sealed record StatusInfo
{
    /// <summary>Overall indicator: none / minor / major / critical / maintenance.</summary>
    public required string Indicator { get; init; }
    /// <summary>Short label, e.g. "Operational" / "Degraded".</summary>
    public required string SummaryLabel { get; init; }
    public IReadOnlyList<StatusComponent> Components { get; init; } = [];
    /// <summary>Unresolved incidents (the page only lists active ones here).</summary>
    public IReadOnlyList<StatusIncident> Incidents { get; init; } = [];
    /// <summary>When the snapshot was fetched (for the "updated …" line).</summary>
    public long FetchedAtMs { get; init; }

    /// <summary>Number of components that aren't fully operational.</summary>
    public int DegradedCount => Components.Count(c => c.Status != "operational");
    public int IncidentCount => Incidents.Count;
}
