using Azure.Core;
using Azure.Identity;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

internal static class Program
{
    public static async Task<int> Main()
    {
        try
        {
            var settings = BootstrapSettings.Parse(Environment.GetEnvironmentVariable("HEXAGON_DATABASE_BOOTSTRAP")
                ?? throw new InvalidOperationException("Missing database bootstrap settings."));
            using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(5));
            var credential = new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(settings.ClientId));
            var token = await credential.GetTokenAsync(new TokenRequestContext(["https://ossrdbms-aad.database.windows.net/.default"]), timeout.Token);
            async Task<NpgsqlConnection> OpenAsync(string database)
            {
                var connection = new NpgsqlConnection(new NpgsqlConnectionStringBuilder
                {
                    Host = settings.Host, Database = database, Username = settings.Administrator,
                    Password = token.Token, SslMode = SslMode.VerifyFull, Pooling = false,
                }.ConnectionString);
                await connection.OpenAsync(timeout.Token);
                return connection;
            }
            await using (var postgres = await OpenAsync("postgres"))
            {
                await DatabaseBootstrapper.BindPrincipalsAsync(postgres, settings, timeout.Token);
            }
            await using (var database = await OpenAsync(settings.Database))
            {
                await DatabaseBootstrapper.GrantRuntimeAccessAsync(database, settings, timeout.Token);
            }
            Console.WriteLine("Database workload access initialized.");
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
