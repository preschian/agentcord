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
}
