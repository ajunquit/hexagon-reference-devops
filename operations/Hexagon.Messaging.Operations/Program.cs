namespace Hexagon.Messaging.Operations;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        OperationTarget? target = null;
        OperationRequest? request = null;
        try
        {
            (target, request) = OperationRequest.Parse(args);
            if (request.Action == "plan")
            {
                OperationAudit.Write(target, request, "planned", metadata: new
                {
                    request.Limit,
                    target.ReplayEnabled,
                    target.HasDeadLetter,
                    fanout = MessagingProviders.Get(target.Provider).Fanout,
                });
                return 0;
            }
            // Every run is bounded, including connection establishment and broker waits.
            using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
            OperationAudit.Write(target, request, "started");
            await MessagingProviders.Get(target.Provider).RunAsync(target, request, cancellation.Token);
            OperationAudit.Write(target, request, "completed");
            return 0;
        }
        catch (Exception exception)
        {
            // SDK exception messages may contain endpoints, credentials or payload fragments.
            // Never print the exception, stack trace, native headers or arbitrary error text.
            if (target is not null && request is not null)
            {
                OperationAudit.Write(target, request, "failed", metadata: new { errorType = exception.GetType().Name });
            }
            else { Console.Error.WriteLine("Invalid operation arguments or target; no broker operation performed."); }
            return 1;
        }
    }
}
