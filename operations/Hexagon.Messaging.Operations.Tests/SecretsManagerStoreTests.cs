using Amazon.Runtime;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Hexagon.Database.Bootstrap;
using Testcontainers.Floci;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class SecretsManagerStoreTests
{
    [Fact]
    [Trait("Category", "Database")]
    public async Task An_empty_secret_reads_as_null_until_the_task_writes_it()
    {
        await using var container = new FlociBuilder("floci/floci:2.3.0").Build();
        await container.StartAsync();
        using var client = new AmazonSecretsManagerClient(new BasicAWSCredentials("test", "test"), new AmazonSecretsManagerConfig
        {
            ServiceURL = container.GetConnectionString(),
            AuthenticationRegion = "us-east-1",
        });
        // Like Terraform: the secret exists without any value.
        var created = await client.CreateSecretAsync(new CreateSecretRequest { Name = "example-dev-0001/database/api" });
        var store = new SecretsManagerStore(client);
        Assert.Null(await store.ReadAsync(created.ARN, CancellationToken.None));
        await store.WriteAsync(created.ARN, "Host=example;Password=first", CancellationToken.None);
        Assert.Equal("Host=example;Password=first", await store.ReadAsync(created.ARN, CancellationToken.None));
    }
}
