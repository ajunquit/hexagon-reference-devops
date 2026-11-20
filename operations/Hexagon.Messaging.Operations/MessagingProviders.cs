namespace Hexagon.Messaging.Operations;

/// <summary>The providers compiled into this tool, found by their <see cref="IMessagingProvider"/> implementation.</summary>
internal static class MessagingProviders
{
    private static readonly Lazy<IReadOnlyDictionary<string, IMessagingProvider>> All = new(() => typeof(MessagingProviders).Assembly.GetTypes()
        .Where(type => type is { IsClass: true, IsAbstract: false } && typeof(IMessagingProvider).IsAssignableFrom(type))
        .Select(type => (IMessagingProvider)Activator.CreateInstance(type)!)
        .ToDictionary(provider => provider.Name, StringComparer.Ordinal));

    public static IReadOnlyCollection<string> Names => All.Value.Keys.ToArray();

    public static IMessagingProvider Get(string name) =>
        All.Value.TryGetValue(name, out var provider) ? provider : throw new InvalidOperationException("Unsupported provider.");
}
