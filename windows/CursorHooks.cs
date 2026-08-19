// Install Cursor user hooks once. Marker is agentcord-cursor-turn.ps1.

using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AgentCord;

internal static class CursorHooks
{
    public const string Marker = "agentcord-cursor-turn.ps1";
    public const string HookCmd =
        "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"./hooks/agentcord-cursor-turn.ps1\"";

    private static readonly string[] Events = ["beforeSubmitPrompt", "stop"];

    public static void Ensure()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(home)) return;
        EnsureIn(Path.Combine(home, ".cursor"));
    }

    /// <summary>Returns true when hooks.json was rewritten.</summary>
    public static bool EnsureIn(string cursorHome)
    {
        var hooksDir = Path.Combine(cursorHome, "hooks");
        Directory.CreateDirectory(hooksDir);
        var scriptPath = Path.Combine(hooksDir, Marker);
        var script = ReadEmbeddedScript();
        var existing = File.Exists(scriptPath) ? File.ReadAllText(scriptPath) : null;
        if (existing != script)
            File.WriteAllText(scriptPath, script);

        var path = Path.Combine(cursorHome, "hooks.json");
        JsonObject root;
        try
        {
            root = File.Exists(path)
                ? JsonNode.Parse(File.ReadAllText(path)) as JsonObject ?? NewRoot()
                : NewRoot();
        }
        catch
        {
            root = NewRoot();
        }

        if (root["hooks"] is not JsonObject)
            root["hooks"] = new JsonObject();
        root["version"] ??= 1;

        var hooks = root["hooks"]!.AsObject();
        var changed = false;
        foreach (var ev in Events)
            changed |= EnsureEvent(hooks, ev);

        if (changed)
            File.WriteAllText(path, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        return changed;
    }

    private static JsonObject NewRoot() => new()
    {
        ["version"] = 1,
        ["hooks"] = new JsonObject(),
    };

    public static bool IsOurs(string cmd) => cmd.Contains(Marker, StringComparison.Ordinal);

    private static bool EnsureEvent(JsonObject hooks, string ev)
    {
        var arr = hooks[ev] as JsonArray ?? new JsonArray();
        var before = arr.Count;
        var kept = false;
        var next = new JsonArray();
        foreach (var item in arr)
        {
            var cmd = item?["command"]?.GetValue<string>() ?? "";
            if (!IsOurs(cmd))
            {
                next.Add(item?.DeepClone());
                continue;
            }
            if (kept) continue;
            kept = true;
            next.Add(item?.DeepClone());
        }
        var changed = next.Count != before;
        if (!kept)
        {
            next.Add(new JsonObject { ["command"] = HookCmd, ["timeout"] = 5 });
            changed = true;
        }
        if (changed)
            hooks[ev] = next;
        return changed;
    }

    public static string ReadEmbeddedScript()
    {
        var asm = Assembly.GetExecutingAssembly();
        using var stream = asm.GetManifestResourceStream("agentcord-cursor-turn.ps1")
            ?? throw new InvalidOperationException("Missing embedded Cursor hook script.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
