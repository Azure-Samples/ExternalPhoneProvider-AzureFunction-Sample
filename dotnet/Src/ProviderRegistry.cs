namespace Epp.Otp;

// One provider is active per deployment; requestProvider is a test override.
public sealed class ProviderRegistry
{
    private readonly IReadOnlyDictionary<string, IProviderAdapter> _byId;
    private readonly IEnv _env;

    public ProviderRegistry(IEnumerable<IProviderAdapter> adapters, IEnv? env = null)
    {
        _byId = adapters.ToDictionary(a => a.Manifest.Id.ToLowerInvariant(), a => a);
        _env = env ?? new ProcessEnv();
    }

    public IProviderAdapter? Get(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return null;
        return _byId.TryGetValue(id.ToLowerInvariant(), out var adapter) ? adapter : null;
    }

    public IProviderAdapter? Resolve(string? requestProvider)
    {
        var id = !string.IsNullOrWhiteSpace(requestProvider)
            ? requestProvider
            : _env.Get("EPP_PROVIDER_NAME");
        return Get(id);
    }
}
