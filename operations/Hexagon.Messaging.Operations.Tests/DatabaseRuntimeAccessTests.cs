using Hexagon.Database.Bootstrap;
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class DatabaseRuntimeAccessTests
{
    [Fact]
    [Trait("Category", "Database")]
    public async Task Runtime_roles_require_explicit_tenant_role_and_cannot_administer_the_database()
    {
        await using var container = new PostgreSqlBuilder("postgres:17-alpine").Build();
        await container.StartAsync();
        await using var database = new NpgsqlConnection(container.GetConnectionString());
        await database.OpenAsync();
        await ExecuteAsync(database, """
            CREATE ROLE hexagon_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
            CREATE ROLE hexagon_outbox NOLOGIN NOSUPERUSER BYPASSRLS;
            CREATE ROLE api LOGIN;
            CREATE ROLE worker LOGIN;
            CREATE SCHEMA platform;
            CREATE TABLE platform."Tenants" (id integer);
            CREATE TABLE platform."Memberships" (id integer);
            CREATE SCHEMA sales;
            CREATE TABLE sales.customers (tenant text);
            INSERT INTO sales.customers VALUES ('first'), ('second');
            GRANT USAGE ON SCHEMA sales TO hexagon_app;
            GRANT SELECT ON sales.customers TO hexagon_app;
            ALTER TABLE sales.customers ENABLE ROW LEVEL SECURITY;
            ALTER TABLE sales.customers FORCE ROW LEVEL SECURITY;
            CREATE POLICY tenant ON sales.customers TO hexagon_app USING (tenant = current_setting('app.tenant_id', true));
            """);
        var settings = new BootstrapSettings("unused", database.Database, "postgres", Guid.NewGuid().ToString(), new()
        {
            ["api"] = new(Guid.NewGuid().ToString(), true),
            ["worker"] = new(Guid.NewGuid().ToString(), false),
        });
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, CancellationToken.None);
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, CancellationToken.None);
        await ExecuteAsync(database, "SET SESSION AUTHORIZATION api;");
        await ExecuteAsync(database, "SELECT * FROM platform.\"Tenants\";");
        var denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(database, "SELECT * FROM sales.customers;"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        await ExecuteAsync(database, "SET ROLE hexagon_app; SET app.tenant_id = 'first';");
        await using (var query = new NpgsqlCommand("SELECT string_agg(tenant, ',') FROM sales.customers", database))
        {
            Assert.Equal("first", await query.ExecuteScalarAsync());
        }
        await ExecuteAsync(database, "RESET ROLE;");
        denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(database, "CREATE ROLE attacker;"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
        await ExecuteAsync(database, "RESET SESSION AUTHORIZATION; SET SESSION AUTHORIZATION worker;");
        denied = await Assert.ThrowsAsync<PostgresException>(() => ExecuteAsync(database, "SELECT * FROM platform.\"Tenants\";"));
        Assert.Equal(PostgresErrorCodes.InsufficientPrivilege, denied.SqlState);
    }

    private static async Task ExecuteAsync(NpgsqlConnection database, string sql)
    {
        await using var command = new NpgsqlCommand(sql, database);
        await command.ExecuteNonQueryAsync();
    }
}
