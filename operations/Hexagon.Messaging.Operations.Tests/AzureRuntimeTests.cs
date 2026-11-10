using Azure.Messaging.ServiceBus;
using Testcontainers.ServiceBus;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class AzureRuntimeTests
{
    [BrokerFact]
    [Trait("Category", "Broker")]
    public async Task ReplayBypassesTransportDeduplicationWhilePreservingInboxIdentity()
    {
        // Accepts the emulator/SQL Server licenses only for this disposable local test.
        await using var container = new ServiceBusBuilder("mcr.microsoft.com/azure-messaging/servicebus-emulator:2.0.0")
            .WithAcceptLicenseAgreement(true).WithConfig(Path.Combine(AppContext.BaseDirectory, "servicebus-config.json")).Build();
        await container.StartAsync();
        await using var client = new ServiceBusClient(container.GetConnectionString());
        await using var sender = client.CreateSender("integration-events");
        await using var source = client.CreateReceiver("integration-events", "sales-worker");
        await using var quarantine = client.CreateReceiver("integration-events", "sales-worker", new ServiceBusReceiverOptions { SubQueue = SubQueue.DeadLetter });
        var id = Guid.NewGuid().ToString();
        var tenant = Guid.NewGuid().ToString();
        const string body = "{\"email\":\"private@example.test\"}";
        var original = new ServiceBusMessage(body) { MessageId = id, Subject = "CustomerCreatedIntegrationEvent", ContentType = "application/json", CorrelationId = "trace-1" };
        original.ApplicationProperties["HexagonMessageId"] = id;
        original.ApplicationProperties["EventType"] = original.Subject;
        original.ApplicationProperties["TenantId"] = tenant;
        original.ApplicationProperties["TenantSlug"] = "example";
        original.ApplicationProperties["CorrelationId"] = "trace-1";
        await sender.SendMessageAsync(original);
        var received = await source.ReceiveMessageAsync(TimeSpan.FromSeconds(20));
        Assert.NotNull(received);
        await source.DeadLetterMessageAsync(received, "test");
        Assert.NotNull(await quarantine.PeekMessageAsync(fromSequenceNumber: 0));
        using var harness = new OperationHarness();
        harness.SetEnvironment("HEXAGON_OPERATIONS_CONNECTION_STRING", container.GetConnectionString());
        var target = OperationHarness.Target();
        var inspection = await harness.RunAsync(target, "inspect");
        Assert.Equal(0, inspection.ExitCode);
        Assert.NotNull(await quarantine.PeekMessageAsync(fromSequenceNumber: 0));
        var replay = await harness.RunAsync(target, "replay");
        Assert.Equal(0, replay.ExitCode);
        var recovered = await source.ReceiveMessageAsync(TimeSpan.FromSeconds(20));
        Assert.NotNull(recovered);
        Assert.Equal(body, recovered.Body.ToString());
        Assert.Equal(id, recovered.ApplicationProperties["HexagonMessageId"]);
        Assert.Equal(tenant, recovered.ApplicationProperties["TenantId"]);
        Assert.Equal("example", recovered.ApplicationProperties["TenantSlug"]);
        Assert.Equal("trace-1", recovered.CorrelationId);
        Assert.NotEqual(id, recovered.MessageId);
        Assert.DoesNotContain("private@example.test", inspection.Output + replay.Output);
        await source.CompleteMessageAsync(recovered);
        Assert.Null(await quarantine.PeekMessageAsync(fromSequenceNumber: 0));

        var second = new ServiceBusMessage(original.Body) { MessageId = Guid.NewGuid().ToString(), Subject = original.Subject };
        foreach (var property in original.ApplicationProperties) { second.ApplicationProperties[property.Key] = property.Value; }
        await sender.SendMessageAsync(second);
        received = await source.ReceiveMessageAsync(TimeSpan.FromSeconds(20));
        Assert.NotNull(received);
        await source.DeadLetterMessageAsync(received, "test");
        var failure = await harness.RunAsync(target with { Topic = "missing-topic" }, "replay");
        Assert.Equal(1, failure.ExitCode);
        Assert.NotNull(await quarantine.PeekMessageAsync(fromSequenceNumber: 0));
    }
}
