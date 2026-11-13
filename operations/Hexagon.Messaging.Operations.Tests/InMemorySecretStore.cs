using Hexagon.Database.Bootstrap;

namespace Hexagon.Messaging.Operations.Tests;

/// <summary>Secrets Manager double: secrets start empty, like the ones Terraform creates.</summary>
internal sealed class InMemorySecretStore : ISecretStore
{
    public Dictionary<string, string> Values { get; } = new(StringComparer.Ordinal);

    public int Writes { get; private set; }

    public Task<string?> ReadAsync(string secret, CancellationToken cancellationToken) =>
        Task.FromResult(Values.TryGetValue(secret, out var value) ? value : null);

    public Task WriteAsync(string secret, string value, CancellationToken cancellationToken)
    {
        Values[secret] = value;
        Writes++;
        return Task.CompletedTask;
    }
}
