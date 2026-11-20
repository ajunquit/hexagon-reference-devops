namespace Hexagon.Database.Bootstrap;

/// <summary>
/// The database maintenance of a cloud. Each cloud lives in its own files; <see cref="DatabaseMaintenances"/>
/// discovers them, so the core never names a cloud and each DevOps template brings only its own.
/// </summary>
internal interface IDatabaseMaintenance
{
    /// <summary>Whether the public settings of <c>HEXAGON_DATABASE_BOOTSTRAP</c> belong to this cloud.</summary>
    bool Accepts(string json);

    /// <summary>Runs the mode of <paramref name="args"/> and returns a message without values.</summary>
    Task<string> RunAsync(string[] args, string json, CancellationToken cancellationToken);
}
