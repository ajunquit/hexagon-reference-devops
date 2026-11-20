namespace Hexagon.Database.Bootstrap;

/// <summary>The database maintenances compiled into this tool, found by their <see cref="IDatabaseMaintenance"/> implementation.</summary>
internal static class DatabaseMaintenances
{
    private static readonly Lazy<IDatabaseMaintenance[]> All = new(() => typeof(DatabaseMaintenances).Assembly.GetTypes()
        .Where(type => type is { IsClass: true, IsAbstract: false } && typeof(IDatabaseMaintenance).IsAssignableFrom(type))
        .Select(type => (IDatabaseMaintenance)Activator.CreateInstance(type)!)
        .ToArray());

    /// <summary>The only maintenance that accepts the settings; none, or more than one, is an error.</summary>
    public static IDatabaseMaintenance For(string json)
    {
        var matching = All.Value.Where(maintenance => maintenance.Accepts(json)).ToArray();
        return matching.Length == 1 ? matching[0] : throw new InvalidOperationException("Unsupported database bootstrap settings.");
    }
}
