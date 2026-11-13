namespace Hexagon.Database.Bootstrap;

/// <summary>The secrets that hold the generated credentials.</summary>
internal interface ISecretStore
{
    /// <summary>The current value, or null while the secret is still empty.</summary>
    Task<string?> ReadAsync(string secret, CancellationToken cancellationToken);

    Task WriteAsync(string secret, string value, CancellationToken cancellationToken);
}
