using System.Collections.Concurrent;
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

namespace Epp.Otp;

// Resolves Key Vault secret names to values via the Function's managed identity (user-assigned when
// AZURE_CLIENT_ID is set, else system-assigned), cached briefly so rotations are picked up.
public sealed class SecretResolver : ISecretResolver
{
    private static readonly TimeSpan CacheTtl = TimeSpan.FromMinutes(5);
    private readonly ConcurrentDictionary<string, (string Value, DateTimeOffset Expires)> _cache = new();
    private readonly Lazy<SecretClient?> _client;

    public SecretResolver(IEnv? env = null)
    {
        var environment = env ?? new ProcessEnv();
        _client = new Lazy<SecretClient?>(() =>
        {
            var url = environment.Get("KEY_VAULT_URL");
            if (string.IsNullOrWhiteSpace(url)) return null;
            var clientId = environment.Get("AZURE_CLIENT_ID");
            var credential = string.IsNullOrEmpty(clientId)
                ? new ManagedIdentityCredential()
                : new ManagedIdentityCredential(clientId);
            return new SecretClient(new Uri(url), credential);
        });
    }

    public async Task<string> ResolveAsync(string? secretName)
    {
        if (string.IsNullOrWhiteSpace(secretName)) return string.Empty;
        if (_cache.TryGetValue(secretName, out var cached) && cached.Expires > DateTimeOffset.UtcNow) return cached.Value;

        var client = _client.Value ?? throw new InvalidOperationException("KEY_VAULT_URL not set");
        var value = (await client.GetSecretAsync(secretName)).Value.Value ?? string.Empty;
        _cache[secretName] = (value, DateTimeOffset.UtcNow.Add(CacheTtl));
        return value;
    }
}
