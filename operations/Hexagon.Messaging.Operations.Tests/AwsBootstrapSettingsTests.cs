using System.Text.Json;
using System.Text.Json.Nodes;
using Hexagon.Database.Bootstrap;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class AwsBootstrapSettingsTests
{
    internal const string Host = "example-dev-0001-postgres.abcdefghijkl.us-east-1.rds.amazonaws.com";

    internal static string Secret(string name) => $"arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/{name}-AbCdEf";

    /// <summary>The JSON the AWS hosting module writes for the database tasks.</summary>
    internal static JsonObject Json(string database = "hexagon_example", bool keycloak = false)
    {
        var json = new JsonObject
        {
            ["provider"] = "aws",
            ["host"] = Host,
            ["port"] = 5432,
            ["database"] = database,
            ["maintenance"] = new JsonObject { ["role"] = "example_dev_0001_maintenance", ["secret"] = Secret("database/maintenance") },
            ["workloads"] = new JsonObject
            {
                ["hexagon-example-api"] = new JsonObject { ["role"] = "example_dev_0001_api", ["secret"] = Secret("database/api"), ["readDirectory"] = true },
                ["hexagon-example-worker"] = new JsonObject { ["role"] = "example_dev_0001_worker", ["secret"] = Secret("database/worker"), ["readDirectory"] = false },
            },
        };
        if (keycloak)
        {
            json["purpose"] = "keycloak";
            json["keycloak"] = new JsonObject
            {
                ["role"] = "example_dev_0001_keycloak",
                ["passwordSecret"] = Secret("keycloak/database"),
                ["bootstrapSecret"] = Secret("keycloak/bootstrap"),
            };
        }
        return json;
    }

    [Fact]
    public void The_module_settings_are_recognized_and_parsed()
    {
        var json = Json(keycloak: true).ToJsonString();
        Assert.True(AwsBootstrapSettings.IsAws(json));
        Assert.False(AwsBootstrapSettings.IsAws("""{"host":"example.postgres.database.azure.com"}"""));
        var settings = AwsBootstrapSettings.Parse(json);
        Assert.True(settings.Workloads["hexagon-example-api"].ReadDirectory);
        Assert.Equal("example_dev_0001_keycloak", settings.Keycloak!.Role);
    }

    [Theory]
    [InlineData("host", "hexagon-floci-aws")]
    [InlineData("host", "example.postgres.database.azure.com")]
    [InlineData("database", "Product; DROP")]
    [InlineData("maintenance.role", "postgres")]
    [InlineData("maintenance.role", "rds_superuser")]
    [InlineData("maintenance.role", "hexagon_outbox")]
    [InlineData("maintenance.role", "example_dev_0001_api")]
    [InlineData("maintenance.secret", "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-dev-0001/database/api-AbCdEf")]
    [InlineData("maintenance.secret", "https://vault.example/secret")]
    [InlineData("purpose", "keycloak")]
    public void Unsafe_or_inconsistent_settings_are_rejected(string path, string value)
    {
        var json = Json();
        var segments = path.Split('.');
        var target = segments.Length == 1 ? json : json[segments[0]]!.AsObject();
        target[segments[^1]] = value;
        Assert.Throws<InvalidOperationException>(() => AwsBootstrapSettings.Parse(json.ToJsonString()));
    }

    [Fact]
    public void Credentials_are_not_accepted_in_the_public_settings()
    {
        var json = Json();
        json["maintenance"]!["password"] = "forbidden";
        Assert.Throws<JsonException>(() => AwsBootstrapSettings.Parse(json.ToJsonString()));
    }

    [Fact]
    public void A_local_Rds_alias_preserves_the_reported_proxy_port_and_tls()
    {
        var json = Json();
        json["host"] = "hexagon-floci-aws.rds.amazonaws.com";
        json["port"] = 7001;
        var settings = AwsBootstrapSettings.Parse(json.ToJsonString());
        var connection = new Npgsql.NpgsqlConnectionStringBuilder(settings.ConnectionString(settings.Maintenance.Role, Credential.Generate()));
        Assert.Equal("hexagon-floci-aws.rds.amazonaws.com", connection.Host);
        Assert.Equal(7001, connection.Port);
        Assert.Equal(Npgsql.SslMode.Require, connection.SslMode);
    }

    [Fact]
    public void A_stored_connection_string_must_belong_to_its_login()
    {
        var settings = AwsBootstrapSettings.Parse(Json().ToJsonString());
        var password = Credential.Generate();
        var stored = settings.ConnectionString("example_dev_0001_api", password);
        Assert.Equal(password, settings.PasswordOf(stored, "example_dev_0001_api"));
        Assert.Contains("SSL Mode=Require", stored, StringComparison.Ordinal);
        Assert.Throws<InvalidOperationException>(() => settings.PasswordOf(stored, "example_dev_0001_worker"));
        Assert.Throws<InvalidOperationException>(() => settings.PasswordOf(stored.Replace(Host, "other.rds.amazonaws.com", StringComparison.Ordinal), "example_dev_0001_api"));
        Assert.Throws<InvalidOperationException>(() => settings.PasswordOf(settings.ConnectionString("example_dev_0001_api", "short'; DROP"), "example_dev_0001_api"));
    }
}
