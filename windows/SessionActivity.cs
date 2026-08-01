// Shared activity-timestamp helpers for Claude, Codex, and Cursor session
// scanners. Prefer parseable event/runtime timestamps; fall back to mtime.

namespace AgentCord;

internal static class SessionActivity
{
    /// <summary>Newest activity signal from an optional event timestamp and
    /// filesystem mtime. Event timestamps win when present and newer.</summary>
    public static long NormalizeMs(long? eventMs, DateTime mtimeUtc)
    {
        var mtimeMs = new DateTimeOffset(mtimeUtc).ToUnixTimeMilliseconds();
        return eventMs is long e && e > 0 ? Math.Max(e, mtimeMs) : mtimeMs;
    }

    /// <summary>Newest activity among several optional event timestamps, with
    /// filesystem mtime as the fallback.</summary>
    public static long NormalizeMs(DateTime mtimeUtc, params long?[] eventCandidates)
    {
        long? best = null;
        foreach (var candidate in eventCandidates)
        {
            if (candidate is not long value || value <= 0) continue;
            best = best is long current ? Math.Max(current, value) : value;
        }
        return NormalizeMs(best, mtimeUtc);
    }

    /// <summary>True when <paramref name="activityMs"/> falls inside the
    /// configured idle window ending at <paramref name="now"/>.</summary>
    public static bool IsWithinWindow(long activityMs, double windowSeconds, DateTimeOffset? now = null)
    {
        var nowMs = (now ?? DateTimeOffset.UtcNow).ToUnixTimeMilliseconds();
        return (nowMs - activityMs) / 1000.0 <= windowSeconds;
    }
}
