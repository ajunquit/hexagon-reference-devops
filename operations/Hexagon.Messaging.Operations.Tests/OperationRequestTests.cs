using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

public sealed class OperationRequestTests
{
    [Theory]
    [InlineData("--product", "different")]
    [InlineData("--environment", "prod")]
    [InlineData("--consumer", "different")]
    [InlineData("--limit", "3")]
    [InlineData("--limit", "invalid")]
    [InlineData("--limit", "0")]
    [InlineData("--incident", "customer@example.test")]
    [InlineData("--incident", "00000000-0000-0000-0000-000000000000")]
    public void UnsafeReplayArgumentsAreRejectedBeforeConnecting(string option, string value)
    {
        using var harness = new OperationHarness();
        var args = Arguments(harness.Save(OperationHarness.Target()));
        args[Array.IndexOf(args, option) + 1] = value;
        Assert.Throws<InvalidOperationException>(() => OperationRequest.Parse(args));
    }

    [Fact]
    public void DisabledReplayIsRejected()
    {
        using var harness = new OperationHarness();
        Assert.Throws<InvalidOperationException>(() => OperationRequest.Parse(Arguments(harness.Save(OperationHarness.Target() with { ReplayEnabled = false }))));
    }

    [Theory]
    [InlineData("azure-service-bus")]
    [InlineData("aws-sns-sqs")]
    [InlineData("rabbitmq")]
    public async Task PlanDoesNotRequireBrokerOrCredentials(string provider)
    {
        using var harness = new OperationHarness();
        harness.SetEnvironment("HEXAGON_OPERATIONS_CONNECTION_STRING", "secret://invalid");
        var result = await harness.RunAsync(OperationHarness.Target(provider), "plan");
        Assert.Equal(0, result.ExitCode);
        Assert.Contains("planned", result.Output);
        Assert.DoesNotContain("secret", result.Output);
    }

    [Fact]
    public void CrossAccountQueueUrlsAreRejected()
    {
        Assert.Throws<InvalidOperationException>(() => (OperationHarness.Target("aws-sns-sqs") with
        {
            DeadLetterQueue = "https://sqs.us-east-1.amazonaws.com/111111111111/sales-worker-dlq",
        }).Validate());
    }

    [Fact]
    public async Task CredentialErrorsNeverLeakSecrets()
    {
        using var harness = new OperationHarness();
        harness.SetEnvironment("HEXAGON_OPERATIONS_CONNECTION_STRING", "secret://credential@example.test");
        var result = await harness.RunAsync(OperationHarness.Target(), "replay");
        Assert.Equal(1, result.ExitCode);
        Assert.Contains("failed", result.Output);
        Assert.DoesNotContain("credential", result.Output);
        Assert.DoesNotContain("example.test", result.Output);
    }

    private static string[] Arguments(string target) => ["replay", target, "--product", "hexagon-example", "--environment", "dev",
        "--consumer", "sales-worker", "--limit", "1", "--incident", "00000000-0000-0000-0000-000000000001"];
}
