using Xunit;

namespace Hexagon.Messaging.Operations.Tests;

internal sealed class BrokerFactAttribute : FactAttribute
{
    public BrokerFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("HEXAGON_RUN_BROKER_TESTS") != "1")
        {
            Skip = "Set HEXAGON_RUN_BROKER_TESTS=1 to run disposable Docker broker tests.";
        }
    }
}
