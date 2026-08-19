using System.Text.Json;
using Xunit;

namespace AgentCord.Tests;

public sealed class SettingsTests
{
    [Fact]
    public void Serialize_omits_prevent_sleep()
    {
        var json = JsonSerializer.Serialize(new Settings());
        Assert.DoesNotContain("prevent_sleep", json);
    }

    [Fact]
    public void Serialize_keeps_unused_compat_keys()
    {
        var json = JsonSerializer.Serialize(new Settings());
        Assert.Contains("idle_window_seconds", json);
        Assert.Contains("agent_antigravity_enabled", json);
    }

    [Fact]
    public void EnabledAgents_never_includes_antigravity()
    {
        var settings = new Settings { AgentAntigravityEnabled = true };
        Assert.DoesNotContain(AgentKind.Antigravity, settings.EnabledAgents);
        Assert.False(settings.IsAgentEnabled(AgentKind.Antigravity));
    }

    [Fact]
    public void Idle_window_setting_is_unused_by_scans()
    {
        Assert.Equal(60.0, SessionActivity.IdleWindowSeconds);
        var settings = new Settings { IdleWindowSeconds = 300 };
        Assert.Equal(300, settings.IdleWindowSeconds);
        Assert.NotEqual(SessionActivity.IdleWindowSeconds, settings.IdleWindowSeconds);
    }

    [Fact]
    public void WindowValue_omits_resets_in()
    {
        var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var pending = new UsageWindow
        {
            Percent = 46,
            ResetsAtMs = now + (6 * 24 * 60 + 22 * 60) * 60_000L + 30_000,
        };
        var text = Format.WindowValue(pending);
        Assert.Equal("46% · 6d 22h", text);
        Assert.DoesNotContain("resets in", text);

        var due = new UsageWindow { Percent = 46, ResetsAtMs = now - 1000 };
        Assert.Equal("46% · resets now", Format.WindowValue(due));
        Assert.Equal("10%", Format.WindowValue(new UsageWindow { Percent = 10 }));
    }
}
