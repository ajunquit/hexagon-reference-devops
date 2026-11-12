using Hexagon.Database.Bootstrap;
using Npgsql;
using Testcontainers.PostgreSql;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class MessagingFreeDatabaseTests
{
    [Fact]
    [Trait("Category", "Database")]
    public async Task Runtime_preparation_does_not_require_or_grant_an_outbox_role()
    {
        await using var postgres = new PostgreSqlBuilder("postgres:17-alpine").WithDatabase("product").Build();
        await postgres.StartAsync();
        await using var db = new NpgsqlConnection(postgres.GetConnectionString());
        await db.OpenAsync();
        await using (var prepare = new NpgsqlCommand("""
            CREATE ROLE hexagon_app NOLOGIN NOSUPERUSER NOBYPASSRLS;
            CREATE ROLE api LOGIN;
            CREATE SCHEMA platform;
            CREATE TABLE platform."Tenants" (id integer);
            CREATE TABLE platform."Memberships" (id integer);
            """, db)) { await prepare.ExecuteNonQueryAsync(); }
        var settings = new BootstrapSettings("example.postgres.database.azure.com", "product", "maintenance", Guid.NewGuid().ToString(),
            new() { ["api"] = new(Guid.NewGuid().ToString(), true) }, MessagingEnabled: false);
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(db, settings, CancellationToken.None);
        await using (var query = new NpgsqlCommand("SELECT pg_has_role('api','hexagon_app','MEMBER') AND NOT EXISTS (SELECT FROM pg_roles WHERE rolname='hexagon_outbox')", db))
        {
            Assert.True((bool)(await query.ExecuteScalarAsync())!);
        }
        await using (var legacy = new NpgsqlCommand("CREATE ROLE hexagon_outbox NOLOGIN; GRANT hexagon_outbox TO api", db)) { await legacy.ExecuteNonQueryAsync(); }
        await DatabaseBootstrapper.GrantRuntimeAccessAsync(db, settings, CancellationToken.None);
        await using var narrowed = new NpgsqlCommand("SELECT NOT pg_has_role('api','hexagon_outbox','MEMBER')", db);
        Assert.True((bool)(await narrowed.ExecuteScalarAsync())!);
    }
}
