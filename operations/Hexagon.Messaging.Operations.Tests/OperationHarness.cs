using System.Text.Json;

namespace Hexagon.Messaging.Operations.Tests;

internal sealed class OperationHarness : IDisposable
{
    private readonly string directory = Path.Combine(Path.GetTempPath(), "hexagon-operation-test-" + Guid.NewGuid().ToString("N"));
    private readonly Dictionary<string, string?> previous = new(StringComparer.Ordinal);

    public OperationHarness() => Directory.CreateDirectory(directory);

    public static OperationTarget Target(string provider = "azure-service-bus") => new()
    {
        ApiVersion = "hexagon.ec/messaging-operation-target/v1",
        Product = "hexagon-example",
        Environment = "dev",
        Provider = provider,
        Consumer = "sales-worker",
        EventTypes = ["CustomerCreatedIntegrationEvent"],
        ReplayEnabled = true,
        HasDeadLetter = true,
        MaxBatchSize = 2,
        DelayMilliseconds = 100,
        Namespace = "sb-example.servicebus.windows.net",
        Topic = "integration-events",
        Subscription = "sales-worker",
        Region = "us-east-1",
        SourceQueue = provider == "aws-sns-sqs" ? "https://sqs.us-east-1.amazonaws.com/000000000000/sales-worker" : "sales-worker",
        DeadLetterQueue = provider == "aws-sns-sqs" ? "https://sqs.us-east-1.amazonaws.com/000000000000/sales-worker-dlq" : "sales-worker-dlq",
        VirtualHost = "operations",
        Exchange = "integration-events",
    };

    public string Save(OperationTarget target)
    {
        var path = Path.Combine(directory, Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(path, JsonSerializer.Serialize(target, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
        return path;
    }

    public void SetEnvironment(string name, string? value)
    {
        previous.TryAdd(name, Environment.GetEnvironmentVariable(name));
        Environment.SetEnvironmentVariable(name, value);
    }

    public async Task<(int ExitCode, string Output)> RunAsync(OperationTarget target, string action, int limit = 1)
    {
        var originalOut = Console.Out;
        var originalError = Console.Error;
        using var output = new StringWriter();
        try
        {
            Console.SetOut(output);
            Console.SetError(output);
            var code = await Program.Main([action, Save(target), "--product", target.Product, "--environment", target.Environment,
                "--consumer", target.Consumer, "--limit", limit.ToString(), "--incident", "00000000-0000-0000-0000-000000000001", "--local"]);
            return (code, output.ToString());
        }
        finally
        {
            Console.SetOut(originalOut);
            Console.SetError(originalError);
        }
    }

    public void Dispose()
    {
        foreach (var pair in previous) { Environment.SetEnvironmentVariable(pair.Key, pair.Value); }
        Directory.Delete(directory, recursive: true);
    }
}
