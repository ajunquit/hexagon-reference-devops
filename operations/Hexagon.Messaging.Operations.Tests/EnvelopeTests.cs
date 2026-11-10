using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class EnvelopeTests
{
    [Fact]
    public void StableIdentityAndTenantRemainUnchanged()
    {
        var id = Guid.NewGuid().ToString();
        var properties = new Dictionary<string, string>
        {
            ["HexagonMessageId"] = id,
            ["EventType"] = "CustomerCreatedIntegrationEvent",
            ["TenantId"] = Guid.NewGuid().ToString(),
            ["TenantSlug"] = "example",
            ["CorrelationId"] = "trace-1",
        };
        var original = properties.ToArray();
        Assert.Equal(id, Envelope.Validate(properties, OperationHarness.Target()));
        Assert.Equal(original, properties.ToArray());
    }

    [Theory]
    [InlineData("HexagonMessageId", "invalid")]
    [InlineData("HexagonMessageId", "00000000-0000-0000-0000-000000000000")]
    [InlineData("EventType", "UnknownEvent")]
    [InlineData("TenantId", "invalid")]
    [InlineData("TenantSlug", "orphan")]
    public void InvalidEnvelopeRemainsQuarantined(string name, string value)
    {
        var properties = new Dictionary<string, string>
        {
            ["HexagonMessageId"] = Guid.NewGuid().ToString(),
            ["EventType"] = "CustomerCreatedIntegrationEvent",
        };
        properties[name] = value;
        Assert.Throws<InvalidOperationException>(() => Envelope.Validate(properties, OperationHarness.Target()));
    }

    [Fact]
    public void TransportIdentityIsStablePerIncidentButDistinctFromBusinessIdentity()
    {
        var id = Guid.NewGuid().ToString();
        Assert.Equal(Envelope.ReplayTransportId("incident-1", id), Envelope.ReplayTransportId("incident-1", id));
        Assert.NotEqual(Envelope.ReplayTransportId("incident-1", id), Envelope.ReplayTransportId("incident-2", id));
        Assert.NotEqual(id, Envelope.ReplayTransportId("incident-1", id));
        Assert.True(Envelope.ReplayTransportId("incident-1", id).Length < 128);
    }
}
