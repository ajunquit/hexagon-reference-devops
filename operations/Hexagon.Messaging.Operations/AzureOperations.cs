using Azure.Identity;
using Azure.Messaging.ServiceBus;

namespace Hexagon.Messaging.Operations;

internal static class AzureOperations
{
    public static async Task RunAsync(OperationTarget target, OperationRequest request, CancellationToken cancellationToken)
    {
        var connection = System.Environment.GetEnvironmentVariable("HEXAGON_OPERATIONS_CONNECTION_STRING");
        if (connection is not null && (!request.Local || !ServiceBusConnectionStringProperties.Parse(connection).Endpoint.IsLoopback))
        {
            throw new InvalidOperationException("Only local Azure connections may use a connection string.");
        }
        await using var client = connection is null
            ? new ServiceBusClient(target.Namespace, new DefaultAzureCredential())
            : new ServiceBusClient(connection);
        await using var receiver = client.CreateReceiver(target.Topic, target.Subscription, new ServiceBusReceiverOptions
        {
            SubQueue = SubQueue.DeadLetter,
            ReceiveMode = ServiceBusReceiveMode.PeekLock,
            PrefetchCount = 0,
        });
        if (request.Action == "inspect")
        {
            var sample = await receiver.PeekMessagesAsync(request.Limit, cancellationToken: cancellationToken);
            foreach (var message in sample)
            {
                var properties = Properties(message);
                var id = Envelope.Validate(properties, target);
                OperationAudit.Write(target, request, "peeked", id, new
                {
                    eventType = properties["EventType"],
                    message.EnqueuedTime,
                    message.DeliveryCount,
                });
            }
            OperationAudit.Write(target, request, "sampled", metadata: new { count = sample.Count, totalCountKnown = false });
            return;
        }

        await using var sender = client.CreateSender(target.Topic);
        for (var index = 0; index < request.Limit; index++)
        {
            var message = await receiver.ReceiveMessageAsync(TimeSpan.FromSeconds(2), cancellationToken);
            if (message is null) { break; }
            var properties = Properties(message);
            var id = Envelope.Validate(properties, target);
            if (message.Subject != properties["EventType"])
            {
                throw new InvalidOperationException("Subject and canonical event type disagree; keep quarantined.");
            }
            var outgoing = new ServiceBusMessage(message.Body)
            {
                MessageId = Envelope.ReplayTransportId(request.Incident, id),
                Subject = message.Subject,
                ContentType = message.ContentType,
                CorrelationId = message.CorrelationId,
            };
            foreach (var property in message.ApplicationProperties)
            {
                outgoing.ApplicationProperties[property.Key] = property.Value;
            }
            OperationAudit.Write(target, request, "replay-attempt", id);
            await sender.SendMessageAsync(outgoing, cancellationToken);
            OperationAudit.Write(target, request, "published", id);
            await receiver.CompleteMessageAsync(message, cancellationToken);
            OperationAudit.Write(target, request, "settled", id);
            await Task.Delay(target.DelayMilliseconds, cancellationToken);
        }
    }

    internal static Dictionary<string, string> Properties(ServiceBusReceivedMessage message) => message.ApplicationProperties
        .Where(pair => Envelope.Keys.Contains(pair.Key, StringComparer.Ordinal))
        .ToDictionary(pair => pair.Key, pair => pair.Value as string
            ?? throw new InvalidOperationException("Canonical Azure properties must be strings; keep quarantined."), StringComparer.Ordinal);
}
