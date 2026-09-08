using Azure.Core;
using Azure.Identity;

namespace Epp.Otp;

// Provider auth in oauth2 mode: mint our own app-only Entra JWT (client-credentials) for the
// provider's API and send it as a Bearer token, never the caller's inbound token. Issuer is our app,
// audience is the provider's app (the scope). Injectable so tests do not reach Entra.
public interface IProviderTokenAcquirer
{
    Task<string> AcquireAsync(CancellationToken cancellationToken = default);
}

public sealed class ProviderTokenAcquirer : IProviderTokenAcquirer
{
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromMinutes(5);
    private readonly IEnv _env;
    private readonly ISecretResolver _secrets;
    private (string Token, DateTimeOffset Expires, string Key)? _cache;

    public ProviderTokenAcquirer(IEnv env, ISecretResolver secrets)
    {
        _env = env;
        _secrets = secrets;
    }

    public async Task<string> AcquireAsync(CancellationToken cancellationToken = default)
    {
        var tenantId = _env.Get("EPP_PROVIDER_TENANT_ID");
        var clientId = _env.Get("EPP_PROVIDER_CLIENT_ID");
        var scope = _env.Get("EPP_PROVIDER_SCOPE");
        if (string.IsNullOrEmpty(tenantId) || string.IsNullOrEmpty(clientId) || string.IsNullOrEmpty(scope))
            throw new InvalidOperationException("oauth2 requires EPP_PROVIDER_TENANT_ID, EPP_PROVIDER_CLIENT_ID and EPP_PROVIDER_SCOPE");

        var cacheKey = $"{tenantId}|{clientId}|{scope}";
        if (_cache is { } cached && cached.Key == cacheKey && cached.Expires - ExpirySkew > DateTimeOffset.UtcNow)
            return cached.Token;

        var credential = await BuildCredentialAsync(tenantId, clientId);
        var token = await credential.GetTokenAsync(new TokenRequestContext(new[] { scope }), cancellationToken);
        _cache = (token.Token, token.ExpiresOn, cacheKey);
        return token.Token;
    }

    // Managed-identity federation (selected by EPP_PROVIDER_MI_CLIENT_ID) keeps the cross-tenant call
    // secretless; otherwise use a client secret from Key Vault (or an env var for local runs).
    private async Task<TokenCredential> BuildCredentialAsync(string tenantId, string clientId)
    {
        var managedIdentityClientId = _env.Get("EPP_PROVIDER_MI_CLIENT_ID");
        if (!string.IsNullOrEmpty(managedIdentityClientId))
        {
            var managedIdentity = new ManagedIdentityCredential(managedIdentityClientId);
            var audience = _env.Get("EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE") ?? "api://AzureADTokenExchange";
            var exchangeScope = audience.EndsWith("/.default", StringComparison.Ordinal) ? audience : $"{audience}/.default";
            return new ClientAssertionCredential(tenantId, clientId, async ct =>
            {
                var assertion = await managedIdentity.GetTokenAsync(
                    new TokenRequestContext(new[] { exchangeScope }), ct);
                return assertion.Token;
            });
        }

        var secret = _env.Get("EPP_PROVIDER_CLIENT_SECRET");
        if (string.IsNullOrEmpty(secret))
        {
            var secretName = _env.Get("EPP_PROVIDER_CLIENT_SECRET_NAME");
            secret = string.IsNullOrEmpty(secretName) ? string.Empty : await _secrets.ResolveAsync(secretName);
        }
        if (string.IsNullOrEmpty(secret))
            throw new InvalidOperationException("oauth2 requires EPP_PROVIDER_MI_CLIENT_ID (managed identity) or EPP_PROVIDER_CLIENT_SECRET_NAME");
        return new ClientSecretCredential(tenantId, clientId, secret);
    }
}
