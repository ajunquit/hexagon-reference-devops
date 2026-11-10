using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using RabbitMQ.Client;
using Testcontainers.RabbitMq;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class RabbitMqRuntimeTests
{
    [BrokerFact]
    [Trait("Category", "Broker")]
    public async Task ReplayPreservesEnvelopeAndFailedAttemptsNeverDrainQuarantine()
    {
        await using var container = new RabbitMqBuilder("rabbitmq:4.1-management-alpine")
            .WithPortBinding(15672, true).Build();
        await container.StartAsync();
        var originalUri = new Uri(container.GetConnectionString());
        var connectionUri = new UriBuilder(originalUri) { Path = "operations" }.Uri;
        var managementUri = new Uri($"http://{container.Hostname}:{container.GetMappedPublicPort(15672)}/");
        using var management = new HttpClient { BaseAddress = managementUri };
        management.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic",
            Convert.ToBase64String(Encoding.UTF8.GetBytes(Uri.UnescapeDataString(originalUri.UserInfo))));
        using (var created = await management.PutAsJsonAsync("api/vhosts/operations", new { })) { created.EnsureSuccessStatusCode(); }
        using (var policy = await management.PutAsJsonAsync("api/policies/operations/quarantine", new Dictionary<string, object>
        {
            ["pattern"] = "^sales-worker-dlq$",
            ["definition"] = new Dictionary<string, object> { ["delivery-limit"] = -1 },
            ["priority"] = 20,
            ["apply-to"] = "queues",
        })) { policy.EnsureSuccessStatusCode(); }

        await using var connection = await new ConnectionFactory { Uri = connectionUri }.CreateConnectionAsync();
        await using var channel = await connection.CreateChannelAsync(new CreateChannelOptions(true, true));
        await channel.ExchangeDeclareAsync("integration-events", ExchangeType.Topic, durable: true);
        await channel.ExchangeDeclareAsync("failed", ExchangeType.Direct, durable: true);
        await channel.QueueDeclareAsync("sales-worker", durable: true, exclusive: false, autoDelete: false, arguments: new Dictionary<string, object?>
        {
            ["x-queue-type"] = "quorum",
            ["x-dead-letter-exchange"] = "failed",
            ["x-dead-letter-routing-key"] = "failed",
        });
        await channel.QueueDeclareAsync("sales-worker-dlq", durable: true, exclusive: false, autoDelete: false,
            arguments: new Dictionary<string, object?> { ["x-queue-type"] = "quorum" });
        await channel.QueueBindAsync("sales-worker", "integration-events", "CustomerCreatedIntegrationEvent");
        await channel.QueueBindAsync("sales-worker-dlq", "failed", "failed");
        var id = Guid.NewGuid().ToString();
        var tenant = Guid.NewGuid().ToString();
        var properties = new BasicProperties
        {
            Persistent = true,
            MessageId = id,
            Type = "CustomerCreatedIntegrationEvent",
            ContentType = "application/json",
            CorrelationId = "trace-1",
            Headers = new Dictionary<string, object?>
            {
                ["HexagonMessageId"] = id,
                ["EventType"] = "CustomerCreatedIntegrationEvent",
                ["TenantId"] = tenant,
                ["TenantSlug"] = "example",
                ["CorrelationId"] = "trace-1",
            },
        };
        var body = Encoding.UTF8.GetBytes("{\"email\":\"private@example.test\"}");
        await channel.BasicPublishAsync("integration-events", "CustomerCreatedIntegrationEvent", true, properties, body);
        var initial = await GetAsync(channel, "sales-worker");
        await channel.BasicRejectAsync(initial.DeliveryTag, requeue: false);
        await WaitForCountAsync(channel, "sales-worker-dlq", 1);

        using var harness = new OperationHarness();
        harness.SetEnvironment("HEXAGON_OPERATIONS_CONNECTION_STRING", connectionUri.ToString());
        harness.SetEnvironment("HEXAGON_OPERATIONS_RABBITMQ_MANAGEMENT_URL", managementUri.ToString());
        var target = OperationHarness.Target("rabbitmq");
        var inspection = await harness.RunAsync(target, "inspect");
        Assert.True(inspection.ExitCode == 0, inspection.Output);
        await WaitForCountAsync(channel, "sales-worker-dlq", 1);
        var replay = await harness.RunAsync(target, "replay");
        Assert.True(replay.ExitCode == 0, replay.Output);
        Assert.DoesNotContain("private@example.test", replay.Output + inspection.Output);
        var recovered = await GetAsync(channel, "sales-worker");
        Assert.Equal(body, recovered.Body.ToArray());
        Assert.Equal(id, Text(recovered.BasicProperties.Headers!["HexagonMessageId"]));
        Assert.Equal(tenant, Text(recovered.BasicProperties.Headers["TenantId"]));
        Assert.Equal("example", Text(recovered.BasicProperties.Headers["TenantSlug"]));
        Assert.Equal("trace-1", recovered.BasicProperties.CorrelationId);
        Assert.False(recovered.BasicProperties.Headers.ContainsKey("x-death"));
        await channel.BasicAckAsync(recovered.DeliveryTag, false);
        await WaitForCountAsync(channel, "sales-worker-dlq", 0);

        // An unroutable publication must fail before the DLQ acknowledgement.
        await channel.BasicPublishAsync("", "sales-worker-dlq", true, properties, body);
        await WaitForCountAsync(channel, "sales-worker-dlq", 1);
        var rejected = await harness.RunAsync(target with { Exchange = "missing-exchange" }, "replay");
        Assert.Equal(1, rejected.ExitCode);
        await WaitForCountAsync(channel, "sales-worker-dlq", 1);
        // More failures than RabbitMQ's default quorum delivery limit still retain the message.
        properties.Headers!["TenantId"] = "invalid";
        var retained = await GetAsync(channel, "sales-worker-dlq");
        await channel.BasicAckAsync(retained.DeliveryTag, false);
        await channel.BasicPublishAsync("", "sales-worker-dlq", true, properties, body);
        for (var attempt = 0; attempt < 22; attempt++)
        {
            var invalid = await harness.RunAsync(target, "replay");
            Assert.Equal(1, invalid.ExitCode);
            Assert.DoesNotContain("private@example.test", invalid.Output);
            await WaitForCountAsync(channel, "sales-worker-dlq", 1);
        }
    }

    private static string Text(object? value) => value is byte[] bytes ? Encoding.UTF8.GetString(bytes) : value?.ToString() ?? "";

    private static async Task<BasicGetResult> GetAsync(IChannel channel, string queue)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            var message = await channel.BasicGetAsync(queue, false);
            if (message is not null) { return message; }
            await Task.Delay(100);
        }
        throw new TimeoutException("Test message did not arrive.");
    }

    private static async Task WaitForCountAsync(IChannel channel, string queue, uint count)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            if ((await channel.QueueDeclarePassiveAsync(queue)).MessageCount == count) { return; }
            await Task.Delay(100);
        }
        throw new TimeoutException("Test queue count did not converge.");
    }
}
