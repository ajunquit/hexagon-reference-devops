using Hexagon.Database.Bootstrap;
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class AwsDatabaseLoginsTests
{
    [Fact]
    [Trait("Category", "Database")]
    public async Task Generated_logins_follow_the_aws_task_order_and_are_kept_when_the_tasks_run_again()
    {
        await using var container = new PostgreSqlBuilder("postgres:17-alpine").WithDatabase("hexagon_example").Build();
        await container.StartAsync();
        // RDS gives its master user CREATEROLE and CREATEDB, not SUPERUSER, and makes it the owner of the database.
        await using (var superuser = await OpenAsync(container.GetConnectionString()))
        {
            await ExecuteAsync(superuser, """
                CREATE ROLE master LOGIN NOSUPERUSER CREATEROLE CREATEDB BYPASSRLS PASSWORD 'test-master';
                ALTER DATABASE hexagon_example OWNER TO master;
                """);
        }
        var settings = AwsBootstrapSettings.Parse(AwsBootstrapSettingsTests.Json(keycloak: true).ToJsonString());
        var secrets = new InMemorySecretStore();

        await PrepareCredentialsAsync(container, settings, secrets);
        Assert.Equal(3, secrets.Writes);
        var maintenanceSecret = secrets.Values[settings.Maintenance.Secret];
        await using (var maintenance = await OpenAsync(Local(container, maintenanceSecret)))
        {
            await using var attributes = new NpgsqlCommand("SELECT rolsuper, rolcreaterole, rolbypassrls FROM pg_roles WHERE rolname = current_user", maintenance);
            await using (var reader = await attributes.ExecuteReaderAsync())
            {
                await reader.ReadAsync();
                Assert.False(reader.GetBoolean(0));
                Assert.True(reader.GetBoolean(1));
                Assert.True(reader.GetBoolean(2));
            }
            // The migrations, run by the maintenance login: runtime roles, directory and module data.
            await ExecuteAsync(maintenance, """
                CREATE ROLE hexagon_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
                CREATE ROLE hexagon_outbox NOLOGIN NOSUPERUSER BYPASSRLS;
                CREATE SCHEMA platform;
                CREATE TABLE platform."Tenants" (id integer);
                CREATE TABLE platform."Memberships" (id integer);
                CREATE SCHEMA sales;
                CREATE TABLE sales.customers (tenant text);
                GRANT USAGE ON SCHEMA sales TO hexagon_app;
                GRANT SELECT ON sales.customers TO hexagon_app;
                """);
            await AwsCredentialBootstrapper.GrantRuntimeAccessAsync(maintenance, settings, CancellationToken.None);
            await AwsCredentialBootstrapper.PrepareKeycloakAsync(maintenance, settings, secrets, CancellationToken.None);
        }
        Assert.Equal(5, secrets.Writes);

        await using (var api = await OpenAsync(Local(container, secrets.Values[settings.Workloads["hexagon-example-api"].Secret])))
        {
            await ExecuteAsync(api, "SELECT * FROM platform.\"Tenants\"; SET ROLE hexagon_app; SELECT * FROM sales.customers;");
        }
        await using (var worker = await OpenAsync(Local(container, secrets.Values[settings.Workloads["hexagon-example-worker"].Secret])))
        {
            var denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(worker, "SELECT * FROM platform.\"Tenants\";"));
            Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
            denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(worker, "CREATE ROLE attacker;"));
            Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        }
        var keycloak = new NpgsqlConnectionStringBuilder(container.GetConnectionString())
        {
            Username = settings.Keycloak!.Role,
            Password = secrets.Values[settings.Keycloak.PasswordSecret],
        };
        await using (var identity = await OpenAsync(keycloak.ConnectionString))
        {
            await ExecuteAsync(identity, "CREATE TABLE keycloak.realm (id text);");
        }

        // Running every task again keeps the credentials: no secret is written and the logins still work.
        var before = new Dictionary<string, string>(secrets.Values);
        await PrepareCredentialsAsync(container, settings, secrets);
        await using (var maintenance = await OpenAsync(Local(container, maintenanceSecret)))
        {
            await AwsCredentialBootstrapper.GrantRuntimeAccessAsync(maintenance, settings, CancellationToken.None);
            await AwsCredentialBootstrapper.PrepareKeycloakAsync(maintenance, settings, secrets, CancellationToken.None);
        }
        Assert.Equal(5, secrets.Writes);
        Assert.Equal(before, secrets.Values);
        await using (var api = await OpenAsync(Local(container, secrets.Values[settings.Workloads["hexagon-example-api"].Secret])))
        {
            await ExecuteAsync(api, "SELECT * FROM platform.\"Tenants\";");
        }

        // A secret that holds another login's connection string is rejected, never trusted.
        secrets.Values[settings.Workloads["hexagon-example-worker"].Secret] = secrets.Values[settings.Workloads["hexagon-example-api"].Secret];
        await Assert.ThrowsAsync<InvalidOperationException>(() => PrepareCredentialsAsync(container, settings, secrets));
    }

    /// <summary>The --prepare-credentials task: the master user prepares the maintenance login, which prepares the workloads.</summary>
    private static async Task PrepareCredentialsAsync(PostgreSqlContainer container, AwsBootstrapSettings settings, InMemorySecretStore secrets)
    {
        var master = new NpgsqlConnectionStringBuilder(container.GetConnectionString()) { Username = "master", Password = "test-master", Database = "postgres" };
        string password;
        await using (var connection = await OpenAsync(master.ConnectionString))
        {
            password = await AwsCredentialBootstrapper.PrepareMaintenanceAsync(connection, settings, secrets, CancellationToken.None);
        }
        await using var maintenance = await OpenAsync(Local(container, settings.ConnectionString(settings.Maintenance.Role, password)));
        await AwsCredentialBootstrapper.PrepareWorkloadsAsync(maintenance, settings, secrets, CancellationToken.None);
    }

    /// <summary>A stored connection string pointed at the test container, which has no TLS.</summary>
    private static string Local(PostgreSqlContainer container, string stored)
    {
        var local = new NpgsqlConnectionStringBuilder(container.GetConnectionString());
        return new NpgsqlConnectionStringBuilder(stored) { Host = local.Host, Port = local.Port, SslMode = SslMode.Disable }.ConnectionString;
    }

    private static async Task<NpgsqlConnection> OpenAsync(string connectionString)
    {
        var connection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder(connectionString) { Pooling = false }.ConnectionString);
        await connection.OpenAsync();
        return connection;
    }

    private static async Task ExecuteAsync(NpgsqlConnection connection, string sql)
    {
        await using var command = new NpgsqlCommand(sql, connection);
        await command.ExecuteNonQueryAsync();
    }
}
