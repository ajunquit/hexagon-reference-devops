namespace Hexagon.Messaging.Operations;

/// <summary>
/// A messaging provider of the operations tool. Each provider lives in its own file and declares its
/// logical name from the backend contract (BE-0022); <see cref="MessagingProviders"/> discovers them, so
/// the core never names a cloud and each DevOps template brings only its provider.
/// </summary>
internal interface IMessagingProvider
{
    /// <summary>Logical provider name of <c>.hexagon/messaging-requirements.json</c>.</summary>
    string Name { get; }

    /// <summary>Whether one event reaches every subscription of the topic.</summary>
    bool Fanout { get; }

    /// <summary>Rejects a target whose provider-specific fields are missing or malformed.</summary>
    void Validate(OperationTarget target);

    Task RunAsync(OperationTarget target, OperationRequest request, CancellationToken cancellationToken);
}
