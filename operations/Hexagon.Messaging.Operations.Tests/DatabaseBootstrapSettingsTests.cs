using System.Text.Json;
using Hexagon.Database.Bootstrap;
using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class DatabaseBootstrapSettingsTests
{
    [Fact]
    public void Public_identity_settings_are_valid_without_credentials()
    {
        var settings = BootstrapSettings.Parse(ValidJson());
        Assert.Single(settings.Workloads);
        Assert.True(settings.Workloads["example-api"].ReadDirectory);
    }

    [Theory]
    [InlineData("example-api", "api; DROP ROLE postgres")]
    [InlineData("example.postgres.database.azure.com", "localhost")]
    [InlineData("11111111-1111-1111-1111-111111111111", "00000000-0000-0000-0000-000000000000")]
    [InlineData("example-api", "maintenance")]
    public void Unsafe_identifiers_or_identity_mappings_are_rejected(string before, string after)
    {
        Assert.Throws<InvalidOperationException>(() => BootstrapSettings.Parse(ValidJson().Replace(before, after, StringComparison.Ordinal)));
    }

    [Fact]
    public void Credentials_and_unknown_fields_are_rejected()
    {
        var json = ValidJson();
        Assert.Throws<JsonException>(() => BootstrapSettings.Parse(json.Insert(1, "\"password\":\"forbidden\",")));
    }

    private static string ValidJson() => """
        {"host":"example.postgres.database.azure.com","database":"example","administrator":"maintenance",
         "clientId":"11111111-1111-1111-1111-111111111111",
         "workloads":{"example-api":{"objectId":"22222222-2222-2222-2222-222222222222","readDirectory":true}}}
        """;
}
