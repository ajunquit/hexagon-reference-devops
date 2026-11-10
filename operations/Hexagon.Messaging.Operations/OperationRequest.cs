namespace Hexagon.Messaging.Operations;

internal sealed record OperationRequest(string Action, string Incident, int Limit, bool Local)
{
    public static (OperationTarget Target, OperationRequest Request) Parse(string[] args)
    {
        if (args.Length < 2 || args[0] is not ("plan" or "inspect" or "replay"))
        {
            throw new InvalidOperationException("Use plan|inspect|replay target.json --product ID --environment ENV --consumer ID [--limit N] [--incident UUID] [--local].");
        }
        var options = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 2; index < args.Length; index++)
        {
            var key = args[index];
            if (key is not ("--product" or "--environment" or "--consumer" or "--incident" or "--limit" or "--local"))
            {
                throw new InvalidOperationException("Unknown operation option.");
            }
            var value = key == "--local" ? "true" : ++index < args.Length ? args[index] : throw new InvalidOperationException("Missing option value.");
            if (!options.TryAdd(key, value)) { throw new InvalidOperationException("Duplicate operation option."); }
        }
        var target = OperationTarget.Load(args[1]);
        foreach (var expected in new[] { ("--product", target.Product), ("--environment", target.Environment), ("--consumer", target.Consumer) })
        {
            if (!options.TryGetValue(expected.Item1, out var value) || value != expected.Item2)
            {
                throw new InvalidOperationException("Explicit product, environment and consumer must match the target.");
            }
        }
        var local = options.ContainsKey("--local");
        if (local && target.Environment != "dev") { throw new InvalidOperationException("Local connections are restricted to dev."); }
        var limit = 1;
        if (options.TryGetValue("--limit", out var input) && !int.TryParse(input, out limit))
        {
            throw new InvalidOperationException("Limit must be an integer.");
        }
        if (limit < 1 || limit > target.MaxBatchSize) { throw new InvalidOperationException("Limit exceeds target policy."); }
        var incident = options.GetValueOrDefault("--incident", "");
        if (incident.Length > 0 && (!Guid.TryParseExact(incident, "D", out var incidentId) || incidentId == Guid.Empty))
        {
            throw new InvalidOperationException("Incident must be a nonempty opaque UUID.");
        }
        if (args[0] == "replay" && (!target.ReplayEnabled || !target.HasDeadLetter || incident.Length == 0))
        {
            throw new InvalidOperationException("Replay requires an enabled DLQ policy and an opaque incident UUID.");
        }
        return (target, new OperationRequest(args[0], incident, limit, local));
    }
}
