using Amazon.SQS.Model;
using Azure.Messaging.ServiceBus;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class EnvelopeMappingTests
{
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

    [Fact]
    public void WronglyTypedSqsTenantCannotBecomePlatformMessage()
    {
        var message = new Message
        {
            MessageAttributes = new Dictionary<string, MessageAttributeValue>
            {
                ["HexagonMessageId"] = new() { DataType = "String", StringValue = Guid.NewGuid().ToString() },
                ["EventType"] = new() { DataType = "String", StringValue = "CustomerCreatedIntegrationEvent" },
                ["TenantId"] = new() { DataType = "Number", StringValue = "123" },
                ["TenantSlug"] = new() { DataType = "Number", StringValue = "123" },
            },
        };
        Assert.Throws<InvalidOperationException>(() => AwsOperations.Properties(message));
    }
}
