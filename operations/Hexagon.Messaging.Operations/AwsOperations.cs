using Amazon;
using Amazon.Runtime;
using Amazon.SQS;
using Amazon.SQS.Model;

namespace Hexagon.Messaging.Operations;

internal static class AwsOperations
{
    public static async Task RunAsync(OperationTarget target, OperationRequest request, CancellationToken cancellationToken)
    {
        var endpoint = System.Environment.GetEnvironmentVariable("HEXAGON_OPERATIONS_AWS_ENDPOINT");
        if (endpoint is not null && (!request.Local || !Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || !uri.IsLoopback))
        {
            throw new InvalidOperationException("Only loopback AWS emulators are allowed with --local.");
        }
        using var client = endpoint is null
            ? new AmazonSQSClient(RegionEndpoint.GetBySystemName(target.Region))
            : new AmazonSQSClient(new BasicAWSCredentials("test", "test"), new AmazonSQSConfig
            {
                ServiceURL = endpoint,
                AuthenticationRegion = target.Region,
            });
        string Queue(string url) => endpoint is null ? url : endpoint.TrimEnd('/') + new Uri(url).AbsolutePath;
        var source = Queue(target.SourceQueue!);
        var dlq = target.HasDeadLetter ? Queue(target.DeadLetterQueue!) : null;
        if (request.Action == "inspect")
        {
            // SQS has no non-destructive peek. Never ReceiveMessage just to inspect it.
            foreach (var queue in new[] { ("source", source), ("dead-letter", dlq) })
            {
                if (queue.Item2 is null) { continue; }
                var response = await client.GetQueueAttributesAsync(new GetQueueAttributesRequest
                {
                    QueueUrl = queue.Item2,
                    AttributeNames = ["ApproximateNumberOfMessages", "ApproximateNumberOfMessagesNotVisible", "MessageRetentionPeriod"],
                }, cancellationToken);
                OperationAudit.Write(target, request, "inspected", metadata: new
                {
                    queue = queue.Item1,
                    visible = response.ApproximateNumberOfMessages,
                    inFlight = response.ApproximateNumberOfMessagesNotVisible,
                    retentionSeconds = response.MessageRetentionPeriod,
                });
            }
            return;
        }
        for (var index = 0; index < request.Limit; index++)
        {
            var response = await client.ReceiveMessageAsync(new ReceiveMessageRequest
            {
                QueueUrl = dlq,
                MaxNumberOfMessages = 1,
                WaitTimeSeconds = 2,
                VisibilityTimeout = 60,
                MessageAttributeNames = ["All"],
            }, cancellationToken);
            var message = response.Messages?.SingleOrDefault();
            if (message is null) { break; }
            try
            {
                var properties = Properties(message);
                var id = Envelope.Validate(properties, target);
                OperationAudit.Write(target, request, "replay-attempt", id);
                await client.SendMessageAsync(new SendMessageRequest
                {
                    QueueUrl = source,
                    MessageBody = message.Body,
                    MessageAttributes = message.MessageAttributes,
                }, cancellationToken);
                OperationAudit.Write(target, request, "published", id);
                await client.DeleteMessageAsync(new DeleteMessageRequest { QueueUrl = dlq, ReceiptHandle = message.ReceiptHandle }, cancellationToken);
                OperationAudit.Write(target, request, "settled", id);
            }
            catch
            {
                // Leave an unconfirmed message in quarantine. Best effort release, then fail closed.
                try
                {
                    await client.ChangeMessageVisibilityAsync(new ChangeMessageVisibilityRequest
                    {
                        QueueUrl = dlq,
                        ReceiptHandle = message.ReceiptHandle,
                        VisibilityTimeout = 0,
                    }, cancellationToken);
                }
                catch (Exception) { }
                throw;
            }
            await Task.Delay(target.DelayMilliseconds, cancellationToken);
        }
    }

    internal static Dictionary<string, string> Properties(Message message) => message.MessageAttributes
        .Where(pair => Envelope.Keys.Contains(pair.Key, StringComparer.Ordinal))
        .ToDictionary(pair => pair.Key, pair => pair.Value.DataType == "String" ? pair.Value.StringValue
            : throw new InvalidOperationException("Canonical SQS attributes must be strings; keep quarantined."), StringComparer.Ordinal);
}
