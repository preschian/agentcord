// Shared Codex home resolution. CodexSession and CodexUsage must agree on
// where sessions and auth.json live when CODEX_HOME is set.

using System.IO;

namespace AgentCord;

internal static class CodexPaths
{
    /// <summary>Codex home directory: %CODEX_HOME% when set and non-empty,
    /// otherwise %USERPROFILE%\.codex.</summary>
    public static string ResolveHome()
    {
        var configured = Environment.GetEnvironmentVariable("CODEX_HOME");
        return string.IsNullOrWhiteSpace(configured)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex")
            : configured.Trim();
    }
}
