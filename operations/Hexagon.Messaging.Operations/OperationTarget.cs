using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Hexagon.Messaging.Operations;

[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed record OperationTarget
{
    public required string ApiVersion { get; init; }
    public required string Product { get; init; }
    public required string Environment { get; init; }
    public required string Provider { get; init; }
    public required string Consumer { get; init; }
    public required string[] EventTypes { get; init; }
    public required bool ReplayEnabled { get; init; }
    public required bool HasDeadLetter { get; init; }
    public required int MaxBatchSize { get; init; }
    public required int DelayMilliseconds { get; init; }
    public string? Namespace { get; init; }
    public string? Topic { get; init; }
    public string? Subscription { get; init; }
    public string? Region { get; init; }
    public string? SourceQueue { get; init; }
    public string? DeadLetterQueue { get; init; }
    public string? VirtualHost { get; init; }
    public string? Exchange { get; init; }

    public static OperationTarget Load(string path)
    {
        var target = JsonSerializer.Deserialize<OperationTarget>(File.ReadAllText(path), new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        }) ?? throw new InvalidOperationException("Invalid operation target.");
        target.Validate();
        return target;
    }

    public void Validate()
    {
        if (ApiVersion != "hexagon.ec/messaging-operation-target/v1" ||
            !Regex.IsMatch(Product, "^[a-z][a-z0-9-]{0,62}$") ||
            !Regex.IsMatch(Consumer, "^[a-z][a-z0-9-]{0,62}$") ||
            Environment is not ("dev" or "staging" or "prod") ||
            MaxBatchSize is < 1 or > 100 || DelayMilliseconds is < 100 or > 10000 ||
            EventTypes.Length == 0 || EventTypes.Distinct(StringComparer.Ordinal).Count() != EventTypes.Length ||
            EventTypes.Any(value => !Regex.IsMatch(value, "^[A-Za-z][A-Za-z0-9_.+`-]{0,254}$")) ||
            (ReplayEnabled && !HasDeadLetter))
        {
            throw new InvalidOperationException("Invalid operation target constraints.");
        }

        MessagingProviders.Get(Provider).Validate(this);
    }

    internal static bool EntityName(string? value) => value is not null &&
        Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$");

}
