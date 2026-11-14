using System.Text.Json;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

internal static class DatabaseBootstrapper
{
    public static async Task BindPrincipalsAsync(NpgsqlConnection postgres, BootstrapSettings settings, CancellationToken cancellationToken)
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

    public static Task GrantRuntimeAccessAsync(NpgsqlConnection database, BootstrapSettings settings, CancellationToken cancellationToken) =>
        GrantRuntimeAccessAsync(database, settings.Database,
            settings.Workloads.ToDictionary(pair => pair.Key, pair => pair.Value.ReadDirectory), settings.MessagingEnabled, cancellationToken);

    /// <summary>Grants each login role its runtime roles; <paramref name="readDirectoryByRole"/> marks the API.</summary>
    public static async Task GrantRuntimeAccessAsync(NpgsqlConnection database, string databaseName,
        IReadOnlyDictionary<string, bool> readDirectoryByRole, bool messagingEnabled, CancellationToken cancellationToken,
        string roleAttributes = "NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS")
    {
        await using var transaction = await database.BeginTransactionAsync(cancellationToken);
        foreach (var pair in readDirectoryByRole)
        {
            // Identifiers were strictly validated before connecting. No application data is read or changed.
            var role = '"' + pair.Key + '"';
            var runtimeRoles = messagingEnabled ? "hexagon_app, hexagon_outbox" : "hexagon_app";
            var sql = $"""
                ALTER ROLE {role} {roleAttributes};
                GRANT CONNECT ON DATABASE "{databaseName}" TO {role};
                GRANT {runtimeRoles} TO {role} WITH ADMIN FALSE, INHERIT FALSE, SET TRUE;
                REVOKE ALL ON SCHEMA platform FROM {role};
                REVOKE ALL ON platform."Tenants", platform."Memberships" FROM {role};
                """;
            if (pair.Value)
            {
                sql += $"""

                    GRANT USAGE ON SCHEMA platform TO {role};
                    GRANT SELECT ON platform."Tenants", platform."Memberships" TO {role};
                    """;
            }
            if (!messagingEnabled)
            {
                sql += $"""

                    DO $$ BEGIN
                        IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'hexagon_outbox') THEN
                            REVOKE hexagon_outbox FROM {role};
                        END IF;
                    END $$;
                    """;
            }
            await using var command = new NpgsqlCommand(sql, database, transaction);
            await command.ExecuteNonQueryAsync(cancellationToken);
            // This tool does not own Keycloak's schema: reject unexpected access instead of taking ownership.
            await using var boundary = new NpgsqlCommand("""
                SELECT EXISTS (
                    SELECT FROM pg_namespace schema CROSS JOIN unnest(@roles) runtime_role(name)
                    WHERE schema.nspname = 'keycloak'
                      AND has_schema_privilege(runtime_role.name, schema.oid, 'USAGE,CREATE')
                );
                """, database, transaction);
            boundary.Parameters.AddWithValue("roles", messagingEnabled ? new[] { pair.Key, "hexagon_app", "hexagon_outbox" } : new[] { pair.Key, "hexagon_app" });
            if ((bool)(await boundary.ExecuteScalarAsync(cancellationToken))!)
            {
                throw new InvalidOperationException("Runtime access to the identity schema is not allowed.");
            }
        }
        await transaction.CommitAsync(cancellationToken);
    }
}
