using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Hexagon.Database.Bootstrap;

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed record KeycloakDatabaseSettings(string Role)
{
    public static KeycloakDatabaseSettings Parse(string json, BootstrapSettings common)
    {
        var value = JsonSerializer.Deserialize<KeycloakDatabaseSettings>(json,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
            ?? throw new InvalidOperationException("Missing identity database settings.");
        if (value.Role is null || !Regex.IsMatch(value.Role, "^[a-z][a-z0-9_-]{0,62}$") ||
            value.Role == common.Administrator || common.Workloads.ContainsKey(value.Role) ||
            value.Role.StartsWith("pg_", StringComparison.Ordinal) ||
            value.Role is "postgres" or "public" or "hexagon_app" or "hexagon_outbox" or "azure_pg_admin")
        {
            throw new InvalidOperationException("Invalid identity database role.");
        }
        return value;
    }
}
