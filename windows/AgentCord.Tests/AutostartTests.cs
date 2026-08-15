using Xunit;

namespace AgentCord.Tests;

public sealed class AutostartTests
{
    [Fact]
    public void IsStartupApproved_missing_blob_is_allowed()
    {
        Assert.True(Autostart.IsStartupApproved(null));
        Assert.True(Autostart.IsStartupApproved([]));
    }

    [Theory]
    [InlineData(0x02, true)]
    [InlineData(0x06, true)]
    [InlineData(0x03, false)]
    [InlineData(0x07, false)]
    public void IsStartupApproved_reads_the_status_byte(byte status, bool expected)
    {
        var blob = new byte[12];
        blob[0] = status;
        Assert.Equal(expected, Autostart.IsStartupApproved(blob));
    }
}
