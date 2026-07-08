// Shared display formatting, mirroring the strings the macOS popover shows.

using System.Globalization;

namespace AgentCord;

public static class Format
{
    public static long NowMs() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    /// <summary>Duration without seconds: "1h 05m" / "10m".</summary>
    public static string Elapsed(long ms)
    {
        var totalMinutes = Math.Max(0, ms / 60000);
        var h = totalMinutes / 60;
        var m = totalMinutes % 60;
        return h > 0 ? $"{h}h {m:00}m" : $"{m}m";
    }

    /// <summary>Ticking clock: "1:02:03" / "2:03".</summary>
    public static string Clock(long ms)
    {
        var total = Math.Max(0, ms / 1000);
        var h = total / 3600;
        var m = total / 60 % 60;
        var s = total % 60;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }

    /// <summary>Reset moment as a clock time, e.g. "12.29 pm"; "now" once due.</summary>
    public static string ResetTime(long resetsAtMs)
    {
        if (resetsAtMs <= NowMs()) return "now";
        var local = DateTimeOffset.FromUnixTimeMilliseconds(resetsAtMs).ToLocalTime();
        return local.ToString("h.mm tt", CultureInfo.InvariantCulture).ToLowerInvariant();
    }

    /// <summary>Reset moment as a calendar date, e.g. "Jun 29"; "now" once due.</summary>
    public static string ResetDate(long resetsAtMs)
    {
        if (resetsAtMs <= NowMs()) return "now";
        var local = DateTimeOffset.FromUnixTimeMilliseconds(resetsAtMs).ToLocalTime();
        return local.ToString("MMM d", CultureInfo.InvariantCulture);
    }

    /// <summary>Compact "since" duration: "45s", "22m", "1h 12m", "3d".</summary>
    public static string Since(long startMs)
    {
        var secs = Math.Max(0, (NowMs() - startMs) / 1000);
        if (secs < 60) return $"{secs}s";
        if (secs < 3600) return $"{secs / 60}m";
        if (secs < 86400)
        {
            var h = secs / 3600;
            var m = secs % 3600 / 60;
            return m > 0 ? $"{h}h {m}m" : $"{h}h";
        }
        return $"{secs / 86400}d";
    }

    /// <summary>Relative freshness: "just now", "5m ago", "2h ago".</summary>
    public static string Ago(long momentMs)
    {
        var secs = Math.Max(0, (NowMs() - momentMs) / 1000);
        if (secs < 60) return "just now";
        if (secs < 3600) return $"{secs / 60}m ago";
        if (secs < 86400) return $"{secs / 3600}h ago";
        return $"{secs / 86400}d ago";
    }
}
