using System.Text.Json;

namespace Hexagon.Messaging.Operations;

internal static class OperationAudit
{
    public static void Write(OperationTarget target, OperationRequest request, string outcome, string? stableId = null, object? metadata = null) =>
        Console.WriteLine(JsonSerializer.Serialize(new
        {
            timestamp = DateTimeOffset.UtcNow,
            target.Product,
            target.Environment,
            target.Provider,
            target.Consumer,
            request.Action,
            request.Incident,
            outcome,
            hexagonMessageId = stableId,
            metadata,
        }));
}
