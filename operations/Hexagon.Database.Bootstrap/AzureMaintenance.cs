using Azure.Core;
using Azure.Identity;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

/// <summary>
/// The Azure maintenance job: with its user-assigned identity it binds the Entra principals of the
/// workloads (no argument) or prepares the identity schema (<c>--prepare-keycloak</c>).
/// </summary>
internal sealed class AzureMaintenance : IDatabaseMaintenance
{
    /// <summary>The Azure settings carry no <c>provider</c> field; the other clouds declare theirs.</summary>
    public bool Accepts(string json)
    {
        using var document = System.Text.Json.JsonDocument.Parse(json);
        return document.RootElement.ValueKind == System.Text.Json.JsonValueKind.Object && !document.RootElement.TryGetProperty("provider", out _);
    }

    public async Task<string> RunAsync(string[] args, string json, CancellationToken cancellationToken)
    {
        var identity = args.SequenceEqual(["--prepare-keycloak"]);
        if (args.Length != 0 && !identity) { throw new InvalidOperationException("Unknown database maintenance mode."); }
        var settings = AzureBootstrapSettings.Parse(json);
        if (identity != (settings.Purpose == "keycloak")) { throw new InvalidOperationException("Database maintenance purpose does not match its mode."); }
        var credential = new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(settings.ClientId));
        var token = await credential.GetTokenAsync(new TokenRequestContext(["https://ossrdbms-aad.database.windows.net/.default"]), cancellationToken);
        async Task<NpgsqlConnection> OpenAsync(string database)
        {
            var connection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder
            {
                Host = settings.Host,
                Database = database,
                Username = settings.Administrator,
                Password = token.Token,
                SslMode = SslMode.VerifyFull,
                Pooling = false,
            }.ConnectionString);
            await connection.OpenAsync(cancellationToken);
            return connection;
        }
        if (identity)
        {
            var options = AzureKeycloakSettings.Parse(Environment.GetEnvironmentVariable("HEXAGON_KEYCLOAK_DATABASE")
                ?? throw new InvalidOperationException("Missing identity database settings."), settings);
            var password = Environment.GetEnvironmentVariable("HEXAGON_KEYCLOAK_DATABASE_PASSWORD")
                ?? throw new InvalidOperationException("Missing identity database credential.");
            await using var database = await OpenAsync(settings.Database);
            await AzureDatabaseAccess.PrepareKeycloakAsync(database, settings, options, password, cancellationToken);
            return "Identity database schema initialized.";
        }
        await using (var postgres = await OpenAsync("postgres"))
        {
            await AzureDatabaseAccess.BindPrincipalsAsync(postgres, settings, cancellationToken);
        }
        await using (var database = await OpenAsync(settings.Database))
        {
            await AzureDatabaseAccess.GrantRuntimeAccessAsync(database, settings, cancellationToken);
        }
        return "Database workload access initialized.";
    }
}
