namespace Epp.Otp;

public sealed class ProviderRegistry
{
    private readonly IReadOnlyDictionary<string, IProviderAdapter> _byId;

    public ProviderRegistry(IEnumerable<IProviderAdapter> adapters)
    {
        _byId = adapters.ToDictionary(a => a.Manifest.Id.ToLowerInvariant(), a => a);
    }

    public IProviderAdapter? Get(string? id)
    {
        if (string.IsNullOrWhiteSpace(id)) return null;
        return _byId.TryGetValue(id.ToLowerInvariant(), out var adapter) ? adapter : null;
    }
}
