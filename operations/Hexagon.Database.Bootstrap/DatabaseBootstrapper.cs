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

    public static async Task GrantRuntimeAccessAsync(NpgsqlConnection database, BootstrapSettings settings, CancellationToken cancellationToken)
    {
        await using var transaction = await database.BeginTransactionAsync(cancellationToken);
        foreach (var pair in settings.Workloads)
        {
            // Identifiers were strictly validated before connecting. No application data is read or changed.
            var role = '"' + pair.Key + '"';
            var sql = $"""
                ALTER ROLE {role} NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
                GRANT CONNECT ON DATABASE "{settings.Database}" TO {role};
                GRANT hexagon_app, hexagon_outbox TO {role} WITH ADMIN FALSE, INHERIT FALSE, SET TRUE;
                REVOKE ALL ON SCHEMA platform FROM {role};
                REVOKE ALL ON platform."Tenants", platform."Memberships" FROM {role};
                """;
            if (pair.Value.ReadDirectory)
            {
                sql += $"""

                    GRANT USAGE ON SCHEMA platform TO {role};
                    GRANT SELECT ON platform."Tenants", platform."Memberships" TO {role};
                    """;
            }
            await using var command = new NpgsqlCommand(sql, database, transaction);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        await transaction.CommitAsync(cancellationToken);
    }
}
