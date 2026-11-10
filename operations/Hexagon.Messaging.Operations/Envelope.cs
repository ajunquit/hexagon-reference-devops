using System.Security.Cryptography;
using System.Text;

namespace Hexagon.Messaging.Operations;

internal static class Envelope
{
    public static readonly string[] Keys = ["HexagonMessageId", "EventType", "TenantId", "TenantSlug", "CorrelationId"];

    public static string Validate(IReadOnlyDictionary<string, string> properties, OperationTarget target)
    {
        if (!properties.TryGetValue("HexagonMessageId", out var id) || !Guid.TryParse(id, out var guid) || guid == Guid.Empty ||
            !properties.TryGetValue("EventType", out var eventType) || !target.EventTypes.Contains(eventType, StringComparer.Ordinal))
        {
            throw new InvalidOperationException("Invalid stable identity or event type; message remains quarantined.");
        }
        var hasTenant = properties.TryGetValue("TenantId", out var tenant);
        var hasSlug = properties.TryGetValue("TenantSlug", out var slug);
        if (hasTenant != hasSlug || (hasTenant && (!Guid.TryParse(tenant, out var tenantId) || tenantId == Guid.Empty || string.IsNullOrWhiteSpace(slug))))
        {
            throw new InvalidOperationException("Invalid tenant envelope; message remains quarantined.");
        }
        return id;
    }

    public static string ReplayTransportId(string incident, string stableId) =>
        "replay-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(incident + ":" + stableId)));
}
