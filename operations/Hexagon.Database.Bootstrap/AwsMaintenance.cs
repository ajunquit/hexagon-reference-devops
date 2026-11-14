using Amazon.SecretsManager;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

/// <summary>
/// The AWS maintenance tasks, in the order delivery runs them:
/// <c>--prepare-credentials</c> (RDS master user), the product migrations, the runtime grants (no
/// argument) and, with integrated identity, <c>--prepare-keycloak</c>. The last two connect with the
/// maintenance login that ECS injects from its secret.
/// </summary>
internal static class AwsMaintenance
{
    public static async Task<string> RunAsync(string[] args, string json, CancellationToken cancellationToken)
    {
        var settings = AwsBootstrapSettings.Parse(json);
        var mode = args switch
        {
            [] => "access",
            ["--prepare-credentials"] => "credentials",
            ["--prepare-keycloak"] => "keycloak",
            _ => throw new InvalidOperationException("Unknown database maintenance mode."),
        };
        if ((mode == "keycloak") != (settings.Purpose == "keycloak"))
        {
            throw new InvalidOperationException("Database maintenance purpose does not match its mode.");
        }
        // ECS sets AWS_REGION; the task role supplies the credentials.
        using var client = new AmazonSecretsManagerClient();
        var secrets = new SecretsManagerStore(client);
        if (mode == "credentials")
        {
            // The master user connects to the postgres database: once the maintenance login owns the
            // product database and the identity schema revoked PUBLIC access, it can no longer enter it.
            var master = new NpgsqlConnectionStringBuilder(settings.ConnectionString(
                Required("HEXAGON_DATABASE_ADMIN_USERNAME"), Required("HEXAGON_DATABASE_ADMIN_PASSWORD")))
            { Database = "postgres" };
            string password;
            await using (var administrator = await OpenAsync(master.ConnectionString, cancellationToken))
            {
                password = await AwsCredentialBootstrapper.PrepareMaintenanceAsync(administrator, settings, secrets, cancellationToken);
            }
            await using var maintenance = await OpenAsync(settings.ConnectionString(settings.Maintenance.Role, password), cancellationToken);
            await AwsCredentialBootstrapper.PrepareWorkloadsAsync(maintenance, settings, secrets, cancellationToken);
            return "Database logins initialized.";
        }
        var connectionString = Required("HEXAGON_DATABASE_MAINTENANCE");
        settings.PasswordOf(connectionString, settings.Maintenance.Role);
        await using var connection = await OpenAsync(connectionString, cancellationToken);
        if (mode == "keycloak")
        {
            await AwsCredentialBootstrapper.PrepareKeycloakAsync(connection, settings, secrets, cancellationToken);
            return "Identity database schema initialized.";
        }
        await AwsCredentialBootstrapper.GrantRuntimeAccessAsync(connection, settings, cancellationToken);
        return "Database workload access initialized.";
    }

    private static string Required(string name) => Environment.GetEnvironmentVariable(name)
        ?? throw new InvalidOperationException("Missing database maintenance credentials.");

    private static async Task<NpgsqlConnection> OpenAsync(string connectionString, CancellationToken cancellationToken)
    {
        var connection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder(connectionString) { Pooling = false }.ConnectionString);
        await connection.OpenAsync(cancellationToken);
        return connection;
    }
}
