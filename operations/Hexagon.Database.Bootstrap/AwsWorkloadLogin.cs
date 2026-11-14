namespace Hexagon.Database.Bootstrap;

/// <summary>The login of a workload; only the API reads the tenant directory.</summary>
internal sealed record AwsWorkloadLogin(string Role, string Secret, bool ReadDirectory);
