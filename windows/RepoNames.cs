// Resolve a working-directory to a short repo name by reading .git/config.
// Spawning git on the presence tick is wasted process create; the files git
// itself would read are already on disk.

using System.IO;

namespace AgentCord;

internal static class RepoNames
{
    public static string FromCwd(string cwd, Dictionary<string, string> cache)
    {
        if (cache.TryGetValue(cwd, out var cached)) return cached;

        var name = Path.GetFileName(cwd.TrimEnd('\\', '/'));
        if (string.IsNullOrEmpty(name)) name = cwd;

        if (FindGitDir(cwd) is { } gitDir)
        {
            if (ReadOriginUrl(gitDir) is { Length: > 0 } remote)
            {
                var fromRemote = FromRemote(remote);
                if (fromRemote.Length > 0) name = fromRemote;
            }
            else if (FindWorkingTreeRoot(cwd) is { } top)
            {
                var baseName = Path.GetFileName(top.TrimEnd('\\', '/'));
                if (!string.IsNullOrEmpty(baseName)) name = baseName;
            }
        }

        cache[cwd] = name;
        return name;
    }

    internal static string FromRemote(string remote)
    {
        var baseName = remote.Split('/', '\\', ':')[^1];
        if (baseName.EndsWith(".git", StringComparison.OrdinalIgnoreCase))
            baseName = baseName[..^4];
        return baseName;
    }

    private static string? FindWorkingTreeRoot(string start)
    {
        var dir = start;
        while (!string.IsNullOrEmpty(dir))
        {
            var git = Path.Combine(dir, ".git");
            if (Directory.Exists(git) || File.Exists(git)) return dir;
            dir = Path.GetDirectoryName(dir);
        }
        return null;
    }

    private static string? FindGitDir(string start)
    {
        var dir = start;
        while (!string.IsNullOrEmpty(dir))
        {
            var git = Path.Combine(dir, ".git");
            try
            {
                if (Directory.Exists(git)) return git;
                if (File.Exists(git))
                {
                    foreach (var raw in File.ReadAllLines(git))
                    {
                        var line = raw.Trim();
                        if (!line.StartsWith("gitdir:", StringComparison.OrdinalIgnoreCase))
                            continue;
                        var pointed = line["gitdir:".Length..].Trim();
                        if (pointed.Length == 0) continue;
                        if (!Path.IsPathRooted(pointed))
                            pointed = Path.GetFullPath(Path.Combine(dir, pointed));
                        var common = Path.Combine(pointed, "commondir");
                        if (File.Exists(common))
                        {
                            var rel = File.ReadAllText(common).Trim();
                            if (rel.Length > 0)
                                return Path.GetFullPath(Path.Combine(pointed, rel));
                        }
                        return pointed;
                    }
                }
            }
            catch
            {
                // Unreadable .git; keep walking up.
            }

            dir = Path.GetDirectoryName(dir);
        }
        return null;
    }

    private static string? ReadOriginUrl(string gitDir)
    {
        try
        {
            var config = Path.Combine(gitDir, "config");
            if (!File.Exists(config)) return null;

            var inOrigin = false;
            foreach (var raw in File.ReadAllLines(config))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith('#') || line.StartsWith(';'))
                    continue;
                if (line.StartsWith('[') && line.EndsWith(']'))
                {
                    inOrigin = line.Equals("[remote \"origin\"]", StringComparison.OrdinalIgnoreCase);
                    continue;
                }
                if (!inOrigin) continue;
                var eq = line.IndexOf('=');
                if (eq < 0) continue;
                var key = line[..eq].Trim();
                if (!key.Equals("url", StringComparison.OrdinalIgnoreCase)) continue;
                var url = line[(eq + 1)..].Trim();
                if (url.Length > 0) return url;
            }
        }
        catch
        {
            // Config is optional enrichment.
        }
        return null;
    }
}
