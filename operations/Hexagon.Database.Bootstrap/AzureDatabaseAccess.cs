using System.Text.Json;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

/// <summary>Azure Database for PostgreSQL: Entra principals of the workloads and the steps that take the Azure settings.</summary>
internal static class AzureDatabaseAccess
{
    public static async Task BindPrincipalsAsync(NpgsqlConnection postgres, AzureBootstrapSettings settings, CancellationToken cancellationToken)
    {
        foreach (var pair in settings.Workloads)
        {
            // Reject an existing PostgreSQL role mapped to another identity instead of taking it over.
            await using var lookup = new NpgsqlCommand("SELECT to_jsonb(p) FROM pg_catalog.pgaadauth_list_principals(false) p WHERE rolename = @role", postgres);
            lookup.Parameters.AddWithValue("role", pair.Key);
            var existing = await lookup.ExecuteScalarAsync(cancellationToken) as string;
            if (existing is not null)
            {
                using var document = JsonDocument.Parse(existing);
                var values = document.RootElement.EnumerateObject().ToDictionary(property => property.Name, property => property.Value, StringComparer.OrdinalIgnoreCase);
                if (!string.Equals(values["objectid"].GetString(), pair.Value.ObjectId, StringComparison.OrdinalIgnoreCase) ||
                    values["principaltype"].GetString() != "service" || values["isadmin"].GetInt32() != 0)
                {
                    throw new InvalidOperationException("Database principal mapping does not match the workload.");
                }
                continue;
            }
            await using var create = new NpgsqlCommand("SELECT pg_catalog.pgaadauth_create_principal_with_oid(@role, @oid, 'service', false, false)", postgres);
            create.Parameters.AddWithValue("role", pair.Key);
            create.Parameters.AddWithValue("oid", pair.Value.ObjectId);
            await create.ExecuteNonQueryAsync(cancellationToken);
        }
    }

    public static Task GrantRuntimeAccessAsync(NpgsqlConnection database, AzureBootstrapSettings settings, CancellationToken cancellationToken) =>
        DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings.Database,
            settings.Workloads.ToDictionary(pair => pair.Key, pair => pair.Value.ReadDirectory), settings.MessagingEnabled, cancellationToken);

    public static async Task PrepareKeycloakAsync(NpgsqlConnection database, AzureBootstrapSettings common,
        AzureKeycloakSettings settings, string password, CancellationToken cancellationToken)
    {
        // The role is parsed again at the mutation boundary; credentials never enter the public JSON.
        settings = AzureKeycloakSettings.Parse(System.Text.Json.JsonSerializer.Serialize(settings), common);
        await KeycloakDatabaseBootstrapper.PrepareAsync(database, common.Database, settings.Role, password, cancellationToken);
    }
}
