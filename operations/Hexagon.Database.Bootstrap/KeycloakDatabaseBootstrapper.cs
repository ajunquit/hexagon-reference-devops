using System.Text.RegularExpressions;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

internal static class KeycloakDatabaseBootstrapper
{
    public static async Task PrepareAsync(NpgsqlConnection database, BootstrapSettings common,
        KeycloakDatabaseSettings settings, string password, CancellationToken cancellationToken)
    {
        // The role is parsed again at the mutation boundary; credentials never enter the public JSON.
        settings = KeycloakDatabaseSettings.Parse(System.Text.Json.JsonSerializer.Serialize(settings), common);
        if (!Regex.IsMatch(password, "^[A-Za-z0-9]{32,128}$"))
        {
            throw new InvalidOperationException("Identity database credentials must be 32 to 128 alphanumeric characters.");
        }
        await using var transaction = await database.BeginTransactionAsync(cancellationToken);
        await using (var ownership = new NpgsqlCommand("""
            SELECT pg_advisory_xact_lock(hashtextextended('hexagon.keycloak.database', 0));
            SELECT EXISTS (
                SELECT FROM pg_roles WHERE rolname = @role
                  AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolinherit OR rolreplication OR rolbypassrls OR NOT rolcanlogin)
            ) OR EXISTS (
                SELECT FROM pg_auth_members membership JOIN pg_roles member ON member.oid = membership.member
                WHERE member.rolname = @role
            ) OR EXISTS (
                SELECT FROM pg_namespace schema JOIN pg_roles owner ON owner.oid = schema.nspowner
                WHERE schema.nspname = 'keycloak' AND owner.rolname <> @role
            );
            """, database, transaction))
        {
            ownership.Parameters.AddWithValue("role", settings.Role);
            await using var reader = await ownership.ExecuteReaderAsync(cancellationToken);
            await reader.NextResultAsync(cancellationToken);
            await reader.ReadAsync(cancellationToken);
            if (reader.GetBoolean(0)) { throw new InvalidOperationException("Identity database ownership conflict."); }
        }
        var role = '"' + settings.Role + '"';
        await using (var exists = new NpgsqlCommand("SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = @role)", database, transaction))
        {
            exists.Parameters.AddWithValue("role", settings.Role);
            if (!(bool)(await exists.ExecuteScalarAsync(cancellationToken))!)
            {
                await using var create = new NpgsqlCommand($"CREATE ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS", database, transaction);
                await create.ExecuteNonQueryAsync(cancellationToken);
            }
        }
        // Both identifiers and the password alphabet are bounded above. No SQL is logged by this tool.
        await using var prepare = new NpgsqlCommand($"""
            SET LOCAL password_encryption = 'scram-sha-256';
            ALTER ROLE {role} PASSWORD '{password}';
            GRANT {role} TO CURRENT_USER WITH INHERIT TRUE, SET TRUE;
            REVOKE ALL ON DATABASE "{common.Database}" FROM PUBLIC;
            GRANT CONNECT ON DATABASE "{common.Database}" TO {role};
            REVOKE CREATE ON SCHEMA public FROM PUBLIC;
            CREATE SCHEMA IF NOT EXISTS keycloak AUTHORIZATION {role};
            REVOKE ALL ON SCHEMA keycloak FROM PUBLIC;
            ALTER ROLE {role} IN DATABASE "{common.Database}" SET search_path = keycloak;
            GRANT {role} TO CURRENT_USER WITH INHERIT FALSE, SET FALSE;
            """, database, transaction);
        await prepare.ExecuteNonQueryAsync(cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }
}
