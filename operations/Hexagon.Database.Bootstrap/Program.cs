namespace Hexagon.Database.Bootstrap;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            var json = Environment.GetEnvironmentVariable("HEXAGON_DATABASE_BOOTSTRAP")
                ?? throw new InvalidOperationException("Missing database bootstrap settings.");
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            Console.WriteLine(await DatabaseMaintenances.For(json).RunAsync(args, json, timeout.Token));
            return 0;
        }
        catch (Exception exception)
        {
            // Neither Npgsql errors nor token/connection values are allowed in operational logs.
            Console.Error.WriteLine($"Database bootstrap failed ({exception.GetType().Name}).");
            return 1;
        }
    }
}
