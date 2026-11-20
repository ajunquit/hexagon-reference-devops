using Npgsql;

namespace Hexagon.Database.Bootstrap;

internal static class DatabaseBootstrapper
{
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
