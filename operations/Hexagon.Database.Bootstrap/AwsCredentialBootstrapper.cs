using Npgsql;

namespace Hexagon.Database.Bootstrap;

/// <summary>
/// Password logins for AWS. A secret that already holds a connection string keeps its password; only
/// an empty secret receives a new one. Rotation is a separate, explicit operation, not a side effect of
/// running a task again.
/// </summary>
internal static class AwsCredentialBootstrapper
{
    /// <summary>
    /// Run by the RDS master user before the migrations: creates or keeps the maintenance login, which
    /// owns the product database and runs the migrations, and returns its password.
    /// </summary>
    public static async Task<string> PrepareMaintenanceAsync(NpgsqlConnection master, AwsBootstrapSettings settings,
        ISecretStore secrets, CancellationToken cancellationToken)
    {
        var login = settings.Maintenance;
        var (password, generated) = await PasswordAsync(settings, secrets, login.Role, login.Secret, cancellationToken);
        var role = Quote(login.Role);
        await using (var transaction = await master.BeginTransactionAsync(cancellationToken))
        {
            await LockAsync(master, transaction, cancellationToken);
            await CreateIfMissingAsync(master, transaction, login.Role, "LOGIN NOSUPERUSER NOCREATEDB NOREPLICATION NOINHERIT", cancellationToken);
            // Like the Azure maintenance identity: it creates the runtime roles (one of them bypasses RLS
            // to drain outboxes) and owns the schemas, but it is no superuser. Since PostgreSQL 16 only a
            // superuser may even mention SUPERUSER or REPLICATION in ALTER ROLE, so they appear only in
            // CREATE ROLE; a non-superuser can never create or alter a superuser anyway.
            await ExecuteAsync(master, transaction, $"""
                SET LOCAL password_encryption = 'scram-sha-256';
                ALTER ROLE {role} WITH LOGIN NOCREATEDB NOINHERIT CREATEROLE BYPASSRLS PASSWORD '{password}';
                """, cancellationToken);
            // Only the first run transfers the database: afterwards the master user no longer owns it.
            await using (var owner = new NpgsqlCommand("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = @database", master, transaction))
            {
                owner.Parameters.AddWithValue("database", settings.Database);
                if (await owner.ExecuteScalarAsync(cancellationToken) as string != login.Role)
                {
                    await ExecuteAsync(master, transaction, $"""
                        GRANT {role} TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
                        ALTER DATABASE "{settings.Database}" OWNER TO {role};
                        GRANT {role} TO CURRENT_USER WITH INHERIT FALSE, SET FALSE;
                        """, cancellationToken);
                }
            }
            await transaction.CommitAsync(cancellationToken);
        }
        if (generated)
        {
            await secrets.WriteAsync(login.Secret, settings.ConnectionString(login.Role, password), cancellationToken);
        }
        return password;
    }

    /// <summary>
    /// Run by the maintenance login: creates or keeps one login per workload, without privileges. The
    /// database-access task grants their runtime roles after the migrations.
    /// </summary>
    public static async Task PrepareWorkloadsAsync(NpgsqlConnection maintenance, AwsBootstrapSettings settings,
        ISecretStore secrets, CancellationToken cancellationToken)
    {
        var generated = new List<(string Secret, string Value)>();
        await using (var transaction = await maintenance.BeginTransactionAsync(cancellationToken))
        {
            await LockAsync(maintenance, transaction, cancellationToken);
            foreach (var workload in settings.Workloads.Values)
            {
                var (password, isNew) = await PasswordAsync(settings, secrets, workload.Role, workload.Secret, cancellationToken);
                await CreateIfMissingAsync(maintenance, transaction, workload.Role,
                    "LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS", cancellationToken);
                await ExecuteAsync(maintenance, transaction, $"""
                    SET LOCAL password_encryption = 'scram-sha-256';
                    ALTER ROLE {Quote(workload.Role)} WITH {RuntimeAttributes} PASSWORD '{password}';
                    """, cancellationToken);
                if (isNew)
                {
                    generated.Add((workload.Secret, settings.ConnectionString(workload.Role, password)));
                }
            }
            await transaction.CommitAsync(cancellationToken);
        }
        // After the commit: a failed write leaves the secret empty, and the next run generates again.
        foreach (var (secret, value) in generated)
        {
            await secrets.WriteAsync(secret, value, cancellationToken);
        }
    }

    /// <summary>Run by the maintenance login: the Keycloak role and schema, and its initial administrator password.</summary>
    public static async Task PrepareKeycloakAsync(NpgsqlConnection maintenance, AwsBootstrapSettings settings,
        ISecretStore secrets, CancellationToken cancellationToken)
    {
        var keycloak = settings.Keycloak ?? throw new InvalidOperationException("Missing identity database settings.");
        var stored = await secrets.ReadAsync(keycloak.PasswordSecret, cancellationToken);
        if (stored is not null && !Credential.IsValid(stored))
        {
            throw new InvalidOperationException("A stored identity credential is not valid.");
        }
        var password = stored ?? Credential.Generate();
        await KeycloakDatabaseBootstrapper.PrepareAsync(maintenance, settings.Database, keycloak.Role, password, cancellationToken);
        if (stored is null)
        {
            await secrets.WriteAsync(keycloak.PasswordSecret, password, cancellationToken);
        }
        if (await secrets.ReadAsync(keycloak.BootstrapSecret, cancellationToken) is null)
        {
            await secrets.WriteAsync(keycloak.BootstrapSecret, Credential.Generate(), cancellationToken);
        }
    }

    /// <summary>Run by the maintenance login after the migrations: the same runtime grants as in Azure.</summary>
    public static Task GrantRuntimeAccessAsync(NpgsqlConnection maintenance, AwsBootstrapSettings settings,
        CancellationToken cancellationToken) =>
        DatabaseBootstrapper.GrantRuntimeAccessAsync(maintenance, settings.Database,
            settings.Workloads.Values.ToDictionary(workload => workload.Role, workload => workload.ReadDirectory),
            settings.MessagingEnabled, cancellationToken, RuntimeAttributes);

    // What a non-superuser may set on a login it administers (see PrepareMaintenanceAsync).
    private const string RuntimeAttributes = "LOGIN NOCREATEROLE NOINHERIT NOBYPASSRLS";

    private static async Task<(string Password, bool Generated)> PasswordAsync(AwsBootstrapSettings settings,
        ISecretStore secrets, string role, string secret, CancellationToken cancellationToken)
    {
        var stored = await secrets.ReadAsync(secret, cancellationToken);
        return stored is null ? (Credential.Generate(), true) : (settings.PasswordOf(stored, role), false);
    }

    private static async Task CreateIfMissingAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string role,
        string attributes, CancellationToken cancellationToken)
    {
        await using var exists = new NpgsqlCommand("SELECT EXISTS (SELECT FROM pg_roles WHERE rolname = @role)", connection, transaction);
        exists.Parameters.AddWithValue("role", role);
        if (!(bool)(await exists.ExecuteScalarAsync(cancellationToken))!)
        {
            await ExecuteAsync(connection, transaction, $"CREATE ROLE {Quote(role)} WITH {attributes}", cancellationToken);
        }
    }

    private static Task LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, CancellationToken cancellationToken) =>
        ExecuteAsync(connection, transaction, "SELECT pg_advisory_xact_lock(hashtextextended('hexagon.database.logins', 0))", cancellationToken);

    // Role names were validated by AwsBootstrapSettings and passwords by Credential: both are safe to inline.
    private static string Quote(string role) => '"' + role + '"';

    private static async Task ExecuteAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string sql,
        CancellationToken cancellationToken)
    {
        await using var command = new NpgsqlCommand(sql, connection, transaction);
        await command.ExecuteNonQueryAsync(cancellationToken);
    }
}
