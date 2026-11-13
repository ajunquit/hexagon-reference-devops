using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;

namespace Hexagon.Database.Bootstrap;

/// <summary>AWS Secrets Manager with the credentials of the task role.</summary>
internal sealed class SecretsManagerStore(IAmazonSecretsManager client) : ISecretStore
{
    public async Task<string?> ReadAsync(string secret, CancellationToken cancellationToken)
    {
        try
        {
            var response = await client.GetSecretValueAsync(new GetSecretValueRequest { SecretId = secret }, cancellationToken);
            return string.IsNullOrEmpty(response.SecretString) ? null : response.SecretString;
        }
        catch (ResourceNotFoundException)
        {
            // Terraform creates the secret without a value: it has no AWSCURRENT version yet.
            return null;
        }
    }

    public async Task WriteAsync(string secret, string value, CancellationToken cancellationToken) =>
        await client.PutSecretValueAsync(new PutSecretValueRequest { SecretId = secret, SecretString = value }, cancellationToken);
}
