using Azure.Identity;
using Azure.Security.KeyVault.Secrets;

namespace Epp.Otp;

// Resolves Key Vault secret names to values via the Function's managed identity (user-assigned when
// AZURE_CLIENT_ID is set, else system-assigned). ProviderCredentials caches the complete bundle.
public sealed class SecretResolver : ISecretResolver
{
    private readonly object _gate = new();
    private readonly IEnv _env;
    private SecretClient? _client;
    private (string Url, string? Identity)? _clientKey;

    public SecretResolver(IEnv? env = null)
    {
        _env = env ?? new ProcessEnv();
    }

    private SecretClient GetClient()
    {
        var url = _env.Get("KEY_VAULT_URL");
        var clientId = _env.Get("AZURE_CLIENT_ID");
        if (string.IsNullOrWhiteSpace(url)) throw new InvalidOperationException("KEY_VAULT_URL not set");
        lock (_gate)
        {
            if (_client is not null && _clientKey == (url, clientId)) return _client;
            var identityOptions = new TokenCredentialOptions();
            identityOptions.Retry.MaxRetries = 0;
            identityOptions.Retry.NetworkTimeout = TimeSpan.FromSeconds(2.5);
            identityOptions.Diagnostics.IsLoggingEnabled = false;
            identityOptions.Diagnostics.IsLoggingContentEnabled = false;
            var credential = new ManagedIdentityCredential(clientId, identityOptions);
            var options = new SecretClientOptions();
            options.Retry.MaxRetries = 0;
            options.Retry.NetworkTimeout = TimeSpan.FromSeconds(2.5);
            options.Diagnostics.IsLoggingEnabled = false;
            options.Diagnostics.IsLoggingContentEnabled = false;
            _client = new SecretClient(new Uri(url), credential, options);
            _clientKey = (url, clientId);
            return _client;
        }
    }

    public async Task<string> ResolveAsync(string? secretName, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(secretName)) return string.Empty;
        return (await GetClient().GetSecretAsync(secretName, cancellationToken: cancellationToken)).Value.Value ?? string.Empty;
    }
}
