using System.Security.Cryptography;
using System.Text.Json;
using DotNet.Testcontainers.Builders;
using Hexagon.Database.Bootstrap;
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class KeycloakDatabaseTests
{
    [Theory]
    [InlineData("postgres")]
    [InlineData("maintenance")]
    [InlineData("api")]
    [InlineData("hexagon_app")]
    [InlineData("pg_reserved")]
    [InlineData("role; DROP SCHEMA public")]
    public void Reserved_or_conflicting_roles_are_rejected(string role) =>
        Assert.Throws<InvalidOperationException>(() => KeycloakDatabaseSettings.Parse(JsonSerializer.Serialize(new { role }), Settings("product")));

    [Fact]
    public void Credentials_are_not_accepted_in_the_public_settings() =>
        Assert.Throws<JsonException>(() => KeycloakDatabaseSettings.Parse("""{"role":"example-keycloak","password":"forbidden"}""", Settings("product")));

    [Fact]
    [Trait("Category", "Database")]
    public async Task Real_Keycloak_owns_only_its_schema_and_can_restart_with_the_same_product_database()
    {
        await using var network = new NetworkBuilder().Build();
        await network.CreateAsync();
        await using var postgres = new PostgreSqlBuilder("postgres:17-alpine")
            .WithDatabase("product").WithNetwork(network).WithNetworkAliases("database").Build();
        await postgres.StartAsync();
        await using var database = new NpgsqlConnection(postgres.GetConnectionString());
        await database.OpenAsync();
        var settings = Settings(database.Database);
        var identity = KeycloakDatabaseSettings.Parse("""{"role":"example-keycloak"}""", settings);
        var password = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
        await ExecuteAsync(database, "CREATE ROLE maintenance LOGIN CREATEROLE CREATEDB NOINHERIT PASSWORD 'test-maintenance'; ALTER DATABASE product OWNER TO maintenance");
        await using var maintenance = new NpgsqlConnection(new NpgsqlConnectionStringBuilder(postgres.GetConnectionString())
        {
            Username = "maintenance",
            Password = "test-maintenance"
        }.ConnectionString);
        await maintenance.OpenAsync();
        await KeycloakDatabaseBootstrapper.PrepareAsync(maintenance, settings, identity, password, CancellationToken.None);
        await ExecuteAsync(database, """
            CREATE ROLE api LOGIN;
            CREATE ROLE hexagon_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
            CREATE ROLE hexagon_outbox NOLOGIN NOSUPERUSER BYPASSRLS;
            CREATE SCHEMA platform;
            CREATE TABLE platform."Tenants" (id integer);
            CREATE TABLE platform."Memberships" (id integer);
            CREATE SCHEMA sales;
            CREATE TABLE sales.customers(id integer);
            GRANT USAGE ON SCHEMA sales TO hexagon_app;
            GRANT SELECT ON sales.customers TO hexagon_app;
            """);
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, CancellationToken.None);
        await using var keycloak = new ContainerBuilder("quay.io/keycloak/keycloak:26.6")
            .WithNetwork(network).WithPortBinding(8080, true)
            .WithEnvironment("KC_DB", "postgres")
            .WithEnvironment("KC_DB_URL", "jdbc:postgresql://database:5432/product")
            .WithEnvironment("KC_DB_SCHEMA", "keycloak")
            .WithEnvironment("KC_DB_USERNAME", identity.Role)
            .WithEnvironment("KC_DB_PASSWORD", password)
            .WithCommand("start-dev")
            .WithWaitStrategy(Wait.ForUnixContainer().UntilHttpRequestIsSucceeded(request => request
                .ForPort(8080).ForPath("/realms/master/.well-known/openid-configuration")))
            .Build();
        await keycloak.StartAsync();
        await using (var query = new NpgsqlCommand("SELECT to_regclass('keycloak.user_entity') IS NOT NULL", database))
        {
            Assert.True((bool)(await query.ExecuteScalarAsync())!);
        }
        await KeycloakDatabaseBootstrapper.PrepareAsync(maintenance, settings, identity, password, CancellationToken.None);
        await using (var membership = new NpgsqlCommand("SELECT NOT inherit_option AND NOT set_option FROM pg_auth_members WHERE roleid = 'example-keycloak'::regrole AND member = 'maintenance'::regrole", database))
        {
            Assert.True((bool)(await membership.ExecuteScalarAsync())!);
        }
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, CancellationToken.None);
        await keycloak.StopAsync();
        await keycloak.StartAsync();

        await using var identityConnection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder(postgres.GetConnectionString())
        {
            Username = identity.Role,
            Password = password
        }.ConnectionString);
        await identityConnection.OpenAsync();
        await ExecuteAsync(identityConnection, "SELECT count(*) FROM keycloak.realm");
        var denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(identityConnection, "SELECT * FROM sales.customers"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(identityConnection, "SET ROLE hexagon_app"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        await ExecuteAsync(database, "SET ROLE api");
        denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(database, "SELECT * FROM keycloak.user_entity"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        await ExecuteAsync(database, "SET ROLE hexagon_app");
        denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(database, "SELECT * FROM keycloak.user_entity"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        await ExecuteAsync(database, "RESET ROLE; GRANT USAGE ON SCHEMA keycloak TO hexagon_app");
        var accessConflict = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, CancellationToken.None));
        Assert.Equal("Runtime access to the identity schema is not allowed.", accessConflict.Message);
        await ExecuteAsync(database, "REVOKE USAGE ON SCHEMA keycloak FROM hexagon_app");
        await ExecuteAsync(database, "RESET ROLE; ALTER ROLE \"example-keycloak\" CREATEROLE");
        try
        {
            var conflict = await Assert.ThrowsAsync<InvalidOperationException>(() =>
                KeycloakDatabaseBootstrapper.PrepareAsync(database, settings, identity, password, CancellationToken.None));
            Assert.Equal("Identity database ownership conflict.", conflict.Message);
        }
        finally { await ExecuteAsync(database, "ALTER ROLE \"example-keycloak\" NOCREATEROLE"); }
    }

    private static BootstrapSettings Settings(string database) => new("example.postgres.database.azure.com", database,
        "maintenance", Guid.NewGuid().ToString(), new() { ["api"] = new(Guid.NewGuid().ToString(), true) });

    private static async Task ExecuteAsync(NpgsqlConnection database, string sql)
    {
        await using var command = new NpgsqlCommand(sql, database);
        await command.ExecuteNonQueryAsync();
    }
}
