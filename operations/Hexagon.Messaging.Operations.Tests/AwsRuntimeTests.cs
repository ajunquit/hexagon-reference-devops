using Amazon.Runtime;
using Amazon.SQS;
using Amazon.SQS.Model;
using Testcontainers.Floci;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class AwsRuntimeTests
{
    [BrokerFact]
    [Trait("Category", "Broker")]
    public async Task ReplayPreservesEnvelopeHonorsLimitAndRetainsUnconfirmedMessages()
    {
        await using var container = new FlociBuilder("floci/floci:2.3.0").Build();
        await container.StartAsync();
        using var client = new AmazonSQSClient(new BasicAWSCredentials("test", "test"), new AmazonSQSConfig
        {
            ServiceURL = container.GetConnectionString(),
            AuthenticationRegion = "us-east-1",
        });
        var deadLetter = await client.CreateQueueAsync(new CreateQueueRequest
        {
            QueueName = "sales-worker-dlq",
            Attributes = new Dictionary<string, string> { ["MessageRetentionPeriod"] = "1209600" },
        });
        var dlqArn = await client.GetQueueAttributesAsync(new GetQueueAttributesRequest { QueueUrl = deadLetter.QueueUrl, AttributeNames = ["QueueArn"] });
        var source = await client.CreateQueueAsync(new CreateQueueRequest
        {
            QueueName = "sales-worker",
            Attributes = new Dictionary<string, string>
            {
                ["VisibilityTimeout"] = "0",
                ["MessageRetentionPeriod"] = "345600",
                ["RedrivePolicy"] = System.Text.Json.JsonSerializer.Serialize(new { deadLetterTargetArn = dlqArn.QueueARN, maxReceiveCount = 1 }),
            },
        });
        var id = Guid.NewGuid().ToString();
        var attributes = new Dictionary<string, MessageAttributeValue>
        {
            ["HexagonMessageId"] = Value(id),
            ["EventType"] = Value("CustomerCreatedIntegrationEvent"),
            ["TenantId"] = Value(Guid.NewGuid().ToString()),
            ["TenantSlug"] = Value("example"),
            ["CorrelationId"] = Value("trace-1"),
        };
        const string body = "{\"email\":\"private@example.test\"}";
        await client.SendMessageAsync(new SendMessageRequest { QueueUrl = source.QueueUrl, MessageBody = body, MessageAttributes = attributes });
        for (var attempt = 0; attempt < 10; attempt++)
        {
            await client.ReceiveMessageAsync(new ReceiveMessageRequest { QueueUrl = source.QueueUrl, MaxNumberOfMessages = 1, VisibilityTimeout = 0 });
            if (await CountAsync(client, deadLetter.QueueUrl) == 1) { break; }
            await Task.Delay(100);
        }
        Assert.Equal(1, await CountAsync(client, deadLetter.QueueUrl));
        using var harness = new OperationHarness();
        harness.SetEnvironment("HEXAGON_OPERATIONS_AWS_ENDPOINT", container.GetConnectionString());
        var target = OperationHarness.Target("aws-sns-sqs");
        var inspection = await harness.RunAsync(target, "inspect");
        Assert.Equal(0, inspection.ExitCode);
        Assert.Equal(1, await CountAsync(client, deadLetter.QueueUrl));
        var replay = await harness.RunAsync(target, "replay");
        Assert.Equal(0, replay.ExitCode);
        Assert.Equal(0, await CountAsync(client, deadLetter.QueueUrl));
        var recovered = await client.ReceiveMessageAsync(new ReceiveMessageRequest
        {
            QueueUrl = source.QueueUrl,
            MaxNumberOfMessages = 1,
            WaitTimeSeconds = 2,
            MessageAttributeNames = ["All"],
        });
        var message = Assert.Single(recovered.Messages);
        Assert.Equal(body, message.Body);
        foreach (var attribute in attributes) { Assert.Equal(attribute.Value.StringValue, message.MessageAttributes[attribute.Key].StringValue); }
        Assert.DoesNotContain("private@example.test", inspection.Output + replay.Output);
        await client.DeleteMessageAsync(new DeleteMessageRequest { QueueUrl = source.QueueUrl, ReceiptHandle = message.ReceiptHandle });

        await client.SendMessageAsync(new SendMessageRequest { QueueUrl = deadLetter.QueueUrl, MessageBody = body, MessageAttributes = attributes });
        var failure = await harness.RunAsync(target with { SourceQueue = target.SourceQueue!.Replace("/sales-worker", "/missing-queue", StringComparison.Ordinal) }, "replay");
        Assert.Equal(1, failure.ExitCode);
        Assert.Equal(1, await CountAsync(client, deadLetter.QueueUrl));
        await client.SendMessageAsync(new SendMessageRequest { QueueUrl = deadLetter.QueueUrl, MessageBody = body, MessageAttributes = attributes });
        var bounded = await harness.RunAsync(target, "replay", limit: 1);
        Assert.Equal(0, bounded.ExitCode);
        Assert.Equal(1, await CountAsync(client, deadLetter.QueueUrl));
    }

    private static MessageAttributeValue Value(string value) => new() { DataType = "String", StringValue = value };

    private static async Task<int> CountAsync(IAmazonSQS client, string queue)
    {
        var attributes = await client.GetQueueAttributesAsync(new GetQueueAttributesRequest { QueueUrl = queue, AttributeNames = ["ApproximateNumberOfMessages"] });
        return attributes.ApproximateNumberOfMessages;
    }
}
