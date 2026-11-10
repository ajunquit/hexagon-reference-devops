using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Hexagon.Database.Bootstrap;

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed record BootstrapSettings(string Host, string Database, string Administrator, string ClientId,
    Dictionary<string, BootstrapWorkload> Workloads)
{
    public static BootstrapSettings Parse(string json)
    {
        var settings = JsonSerializer.Deserialize<BootstrapSettings>(json, new JsonSerializerOptions { PropertyNameCaseInsensitive = true, UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow })
            ?? throw new InvalidOperationException("Invalid database bootstrap settings.");
        if (!Regex.IsMatch(settings.Host, "^[a-z][a-z0-9-]+[.]postgres[.]database[.]azure[.]com$") ||
            !Identifier(settings.Database) || !Identifier(settings.Administrator) || !ValidGuid(settings.ClientId) ||
            settings.Workloads.Count == 0 || settings.Workloads.Any(pair => !Identifier(pair.Key) ||
                pair.Key == settings.Administrator || !ValidGuid(pair.Value.ObjectId)) ||
            settings.Workloads.Values.Select(value => value.ObjectId).Distinct(StringComparer.OrdinalIgnoreCase).Count() != settings.Workloads.Count)
        {
            throw new InvalidOperationException("Invalid database bootstrap constraints.");
        }
        return settings;
    }

    private static bool Identifier(string value) => Regex.IsMatch(value, "^[a-z][a-z0-9_-]{0,62}$");
    private static bool ValidGuid(string value) => Guid.TryParse(value, out var parsed) && parsed != Guid.Empty;
}
