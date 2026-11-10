using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using RabbitMQ.Client;

namespace Hexagon.Messaging.Operations;

internal static class RabbitMqOperations
{
    public static async Task RunAsync(OperationTarget target, OperationRequest request, CancellationToken cancellationToken)
    {
        var connection = new Uri(System.Environment.GetEnvironmentVariable("HEXAGON_OPERATIONS_CONNECTION_STRING")
            ?? throw new InvalidOperationException("RabbitMQ operations connection is required."));
        if (connection.Scheme is not ("amqp" or "amqps") ||
            (connection.Scheme != "amqps" && (!request.Local || !connection.IsLoopback)) ||
            Uri.UnescapeDataString(connection.AbsolutePath.TrimStart('/')) != target.VirtualHost)
        {
            throw new InvalidOperationException("RabbitMQ requires TLS and the target virtual host; plaintext is restricted to local dev.");
        }
        if (request.Action == "inspect")
        {
            var management = new Uri(System.Environment.GetEnvironmentVariable("HEXAGON_OPERATIONS_RABBITMQ_MANAGEMENT_URL")
                ?? throw new InvalidOperationException("RabbitMQ management URL is required for passive inspection."));
            if (!string.IsNullOrEmpty(management.UserInfo) || management.Host != connection.Host ||
                (management.Scheme != "https" && (!request.Local || management.Scheme != "http" || !management.IsLoopback)))
            {
                throw new InvalidOperationException("Management endpoint must use the same host and TLS outside local dev.");
            }
            using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) { BaseAddress = management };
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Basic",
                Convert.ToBase64String(Encoding.UTF8.GetBytes(Uri.UnescapeDataString(connection.UserInfo))));
            foreach (var queue in new[] { ("source", target.SourceQueue), ("dead-letter", target.HasDeadLetter ? target.DeadLetterQueue : null) })
            {
                if (queue.Item2 is null) { continue; }
                using var response = await client.GetAsync($"api/queues/{Uri.EscapeDataString(target.VirtualHost!)}/{Uri.EscapeDataString(queue.Item2)}", cancellationToken);
                response.EnsureSuccessStatusCode();
                using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
                var root = document.RootElement;
                OperationAudit.Write(target, request, "inspected", metadata: new
                {
                    queue = queue.Item1,
                    ready = NumberOrNull(root, "messages_ready"),
                    unacknowledged = NumberOrNull(root, "messages_unacknowledged"),
                    consumers = NumberOrNull(root, "consumers"),
                });
            }
            return;
        }
        var factory = new ConnectionFactory { Uri = connection, AutomaticRecoveryEnabled = false };
        await using var broker = await factory.CreateConnectionAsync(cancellationToken);
        await using var channel = await broker.CreateChannelAsync(new CreateChannelOptions(
            publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true), cancellationToken);
        for (var index = 0; index < request.Limit; index++)
        {
            var message = await channel.BasicGetAsync(target.DeadLetterQueue!, autoAck: false, cancellationToken);
            if (message is null) { break; }
            // Channel disposal requeues an unacknowledged message if validation or publication fails.
            var properties = Properties(message.BasicProperties.Headers);
            var id = Envelope.Validate(properties, target);
            var outgoing = new BasicProperties(message.BasicProperties)
            {
                Persistent = true,
                MessageId = id,
                Type = properties["EventType"],
                Headers = message.BasicProperties.Headers?
                    .Where(pair => !pair.Key.StartsWith("x-death", StringComparison.Ordinal) &&
                        !pair.Key.StartsWith("x-first-death", StringComparison.Ordinal) &&
                        !pair.Key.StartsWith("x-last-death", StringComparison.Ordinal) && pair.Key != "x-delivery-count")
                    .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal),
            };
            OperationAudit.Write(target, request, "replay-attempt", id);
            // Mandatory + awaited publisher confirmation precedes the destructive source acknowledgement.
            await channel.BasicPublishAsync(target.Exchange!, properties["EventType"], mandatory: true, outgoing, message.Body, cancellationToken);
            OperationAudit.Write(target, request, "published", id);
            await channel.BasicAckAsync(message.DeliveryTag, multiple: false, cancellationToken);
            OperationAudit.Write(target, request, "settled", id);
            await Task.Delay(target.DelayMilliseconds, cancellationToken);
        }
    }

    private static long? NumberOrNull(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.TryGetInt64(out var number) ? number : null;

    private static Dictionary<string, string> Properties(IDictionary<string, object?>? headers) => headers?
        .Where(pair => Envelope.Keys.Contains(pair.Key, StringComparer.Ordinal))
        .ToDictionary(pair => pair.Key, pair => pair.Value switch
        {
            byte[] bytes => Encoding.UTF8.GetString(bytes),
            string text => text,
            _ => "",
        }, StringComparer.Ordinal) ?? new Dictionary<string, string>(StringComparer.Ordinal);
}
