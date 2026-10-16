// Shared JsonElement field readers. Missing or wrong-typed fields return
// null (or 0 for Long). A non-object element returns the same, so callers
// can skip a ValueKind check.

using System.Text.Json;

namespace AgentCord;

internal static class JsonProp
{
    public static string? String(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object
        && obj.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    public static double? Number(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object
        && obj.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetDouble(out var number)
            ? number
            : null;

    public static double? Number(JsonElement? obj, string name) =>
        obj is { } element ? Number(element, name) : null;

    public static long Long(JsonElement obj, string name) =>
        obj.ValueKind == JsonValueKind.Object
        && obj.TryGetProperty(name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt64(out var number)
            ? number
            : 0;
}
