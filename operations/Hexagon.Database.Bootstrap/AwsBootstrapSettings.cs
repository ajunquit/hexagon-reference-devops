using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Npgsql;

namespace Hexagon.Database.Bootstrap;

/// <summary>
/// Public settings that the AWS hosting module passes to every database maintenance task. They hold
/// names and secret ARNs, never a credential.
/// </summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
internal sealed record AwsBootstrapSettings(string Provider, string Host, int Port, string Database,
    AwsDatabaseLogin Maintenance, Dictionary<string, AwsWorkloadLogin> Workloads,
    bool MessagingEnabled = true, string? Purpose = null, AwsKeycloakLogins? Keycloak = null)
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNameCaseInsensitive = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private static readonly string[] Reserved = ["postgres", "public", "rdsadmin", "hexagon_app", "hexagon_outbox"];

    /// <summary>Whether the settings were written by the AWS hosting module.</summary>
    public static bool IsAws(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.ValueKind == JsonValueKind.Object &&
            document.RootElement.TryGetProperty("provider", out var provider) &&
            provider.ValueKind == JsonValueKind.String && provider.GetString() == "aws";
    }

    public static AwsBootstrapSettings Parse(string json)
    {
        var settings = JsonSerializer.Deserialize<AwsBootstrapSettings>(json, Options)
            ?? throw new InvalidOperationException("Invalid database bootstrap settings.");
        if (settings.Maintenance is null || settings.Workloads is null || settings.Workloads.Count == 0)
        {
            throw new InvalidOperationException("Invalid database bootstrap constraints.");
        }
        var logins = settings.Workloads.Values.Select(workload => (workload.Role, workload.Secret))
            .Append((settings.Maintenance.Role, settings.Maintenance.Secret)).ToList();
        if (settings.Keycloak is not null)
        {
            logins.Add((settings.Keycloak.Role, settings.Keycloak.PasswordSecret));
        }
        var secrets = logins.Select(login => login.Secret).ToList();
        if (settings.Keycloak is not null)
        {
            secrets.Add(settings.Keycloak.BootstrapSecret);
        }
        if (settings.Provider != "aws" ||
            !Regex.IsMatch(settings.Host, "^[a-z0-9][a-z0-9-]*([.][a-z0-9-]+)*[.]rds[.]amazonaws[.]com$") ||
            settings.Port is < 1 or > 65535 || !Identifier(settings.Database) ||
            settings.Workloads.Keys.Any(id => !Regex.IsMatch(id, "^[a-z][a-z0-9-]{0,62}$")) ||
            logins.Any(login => !Role(login.Role)) || secrets.Any(secret => !SecretArn(secret)) ||
            logins.Select(login => login.Role).Distinct(StringComparer.Ordinal).Count() != logins.Count ||
            secrets.Distinct(StringComparer.Ordinal).Count() != secrets.Count ||
            (settings.Purpose is not null and not "keycloak") ||
            (settings.Purpose == "keycloak") != (settings.Keycloak is not null))
        {
            throw new InvalidOperationException("Invalid database bootstrap constraints.");
        }
        return settings;
    }

    /// <summary>The connection string stored for a login: the same host and database, encrypted in transit.</summary>
    public string ConnectionString(string role, string password) => new NpgsqlConnectionStringBuilder
    {
        Host = Host,
        Port = Port,
        Database = Database,
        Username = role,
        Password = password,
        // The RDS certificate authority is not in the application images: traffic stays encrypted
        // inside the VPC, and server identity verification waits for that bundle (ADR 0023).
        SslMode = SslMode.Require,
    }.ConnectionString;

    /// <summary>The password of a stored connection string, after checking that it belongs to this login.</summary>
    public string PasswordOf(string connectionString, string role)
    {
        var stored = new NpgsqlConnectionStringBuilder(connectionString);
        if (stored.Host != Host || stored.Port != Port || stored.Database != Database || stored.Username != role ||
            stored.Password is null || !Credential.IsValid(stored.Password))
        {
            throw new InvalidOperationException("A stored connection string does not match its login.");
        }
        return stored.Password;
    }

    private static bool Identifier(string value) => Regex.IsMatch(value, "^[a-z][a-z0-9_]{0,62}$");

    private static bool Role(string value) => Identifier(value) &&
        !value.StartsWith("pg_", StringComparison.Ordinal) && !value.StartsWith("rds_", StringComparison.Ordinal) &&
        !Reserved.Contains(value);

    private static bool SecretArn(string value) =>
        Regex.IsMatch(value, "^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+$");
}
