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
                    fanout = target.Provider is "azure-service-bus" or "rabbitmq",
                });
                return 0;
            }
            // Every run is bounded, including connection establishment and broker waits.
            using var cancellation = new CancellationTokenSource(TimeSpan.FromMinutes(3));
            Console.CancelKeyPress += (_, eventArgs) => { eventArgs.Cancel = true; cancellation.Cancel(); };
            OperationAudit.Write(target, request, "started");
            switch (target.Provider)
            {
                case "azure-service-bus": await AzureOperations.RunAsync(target, request, cancellation.Token); break;
                case "aws-sns-sqs": await AwsOperations.RunAsync(target, request, cancellation.Token); break;
                case "rabbitmq": await RabbitMqOperations.RunAsync(target, request, cancellation.Token); break;
            }
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
