namespace Hexagon.Database.Bootstrap;

/// <summary>A PostgreSQL login role and the Secrets Manager secret that holds its connection string.</summary>
internal sealed record AwsDatabaseLogin(string Role, string Secret);
