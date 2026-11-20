using Azure.Messaging.ServiceBus;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class AzureOperationTests
{
    internal static OperationTarget Target() => OperationHarness.Target() with
    {
        Provider = "azure-service-bus",
        Namespace = "sb-example.servicebus.windows.net",
        Topic = "integration-events",
        Subscription = "sales-worker",
    };

    [Fact]
    public Task PlanDoesNotRequireBrokerOrCredentials() => OperationRequestTests.AssertPlanWithoutBrokerAsync(Target());

    [Fact]
    public void WronglyTypedAzureTenantCannotBecomePlatformMessage()
    {
        var message = ServiceBusModelFactory.ServiceBusReceivedMessage(properties: new Dictionary<string, object>
        {
            ["HexagonMessageId"] = Guid.NewGuid().ToString(),
            ["EventType"] = "CustomerCreatedIntegrationEvent",
            ["TenantId"] = Guid.NewGuid(),
            ["TenantSlug"] = 123,
        });
        Assert.Throws<InvalidOperationException>(() => AzureOperations.Properties(message));
    }
}
