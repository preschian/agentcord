// Shared activity-timestamp helpers for Claude, Codex, Cursor, and Grok
// session scanners. Prefer parseable event/runtime timestamps;
// fall back to mtime. Duration helpers backdate Discord's elapsed timer so
// 1pm–2pm + 5pm–6pm shows as two hours, not five.

namespace AgentCord;

internal static class SessionActivity
{
    /// <summary>A gap longer than this between consecutive stamps is idle, not work.</summary>
    public const long GapToleranceMs = 5 * 60 * 1000;

    /// <summary>Presence idle timeout. Scans ignore Settings.IdleWindowSeconds.</summary>
    public const double IdleWindowSeconds = 60.0;

    /// <summary>File-retention bound for tree snapshots, not the clock cutoff.</summary>
    public const long LookbackMs = 24 * 60 * 60 * 1000;

    /// <summary>Local calendar-day start, used as the work-clock cutoff.</summary>
    public static long LocalMidnightMs() =>
        new DateTimeOffset(DateTime.Today).ToUnixTimeMilliseconds();

    /// <summary>Add <c>now - last</c> only while the session is live, so idle clocks freeze.</summary>
    public static long WithLiveTail(long totalActiveMs, long? lastMs, long nowMs, bool live)
    {
        var total = totalActiveMs;
        if (live && lastMs is long last && nowMs > last)
            total += nowMs - last;
        return Math.Max(0, total);
    }

    /// <summary>Activity signal from an optional event timestamp and filesystem
    /// mtime. The filesystem timestamp is only a fallback when no event
    /// timestamp is available.</summary>
    public static long NormalizeMs(long? eventMs, DateTime mtimeUtc)
    {
        var mtimeMs = new DateTimeOffset(mtimeUtc).ToUnixTimeMilliseconds();
        return eventMs is long e && e > 0 ? e : mtimeMs;
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

    /// <summary>Working time inside the lookback window for one session.</summary>
    public static (long ActiveMs, long? LastMs) ActiveDuration(
        IReadOnlyList<long> stamps,
        long? createdAtMs,
        long? updatedAtMs,
        long cutoffMs,
        long nowMs)
    {
        var inWindow = stamps.Where(ms => ms >= cutoffMs && ms <= nowMs).ToList();

        if (inWindow.Count == 0)
        {
            if (createdAtMs is not long created || updatedAtMs is not long updated)
                return (0, null);
            var start = Math.Max(created, cutoffMs);
            var end = Math.Min(updated, nowMs);
            return end > start ? (end - start, end) : (0, null);
        }

        var points = new HashSet<long>(inWindow);
        if (createdAtMs is long c && c >= cutoffMs && c <= nowMs) points.Add(c);
        if (updatedAtMs is long u && u >= cutoffMs && u <= nowMs) points.Add(u);
        if (createdAtMs is long createdBefore && updatedAtMs is long updatedAfter
            && createdBefore < cutoffMs && updatedAfter >= cutoffMs)
        {
            points.Add(cutoffMs);
            points.Add(Math.Min(updatedAfter, nowMs));
        }

        var unique = points.OrderBy(ms => ms).ToList();
        if (unique.Count == 0) return (0, null);

        long active = 0;
        for (var i = 1; i < unique.Count; i++)
        {
            var delta = unique[i] - unique[i - 1];
            if (delta > 0 && delta <= GapToleranceMs) active += delta;
        }
        return (active, unique[^1]);
    }

    /// <summary>Discord timestamps.start that makes elapsed time equal the summed work.</summary>
    public static long ElapsedStartMs(long totalActiveMs, long? lastMs, long nowMs)
    {
        var elapsed = totalActiveMs;
        if (lastMs is long last)
        {
            var tail = nowMs - last;
            if (tail > 0 && tail <= GapToleranceMs) elapsed += tail;
        }
        return nowMs - elapsed;
    }
}
