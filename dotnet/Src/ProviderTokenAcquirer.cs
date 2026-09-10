using Azure.Core;
using Azure.Identity;

namespace Epp.Otp;

public sealed record ProviderTokenConfig(
    string ProviderId,
    string Endpoint,
    string TenantId,
    string ClientId,
    string Scope,
    string? ManagedIdentityClientId,
    string? ClientSecretName,
    string? KeyVaultUrl,
    string? VaultManagedIdentityClientId,
    int TimeoutMs)
{
    public override string ToString() => nameof(ProviderTokenConfig);

    public static ProviderTokenConfig Read(IEnv env, string providerId, string endpoint, int timeoutMs)
    {
        if (env.Get("EPP_PROVIDER_CLIENT_SECRET") is not null)
            throw new InvalidOperationException("plaintext provider client secret is not supported");
        if (env.Get("EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE") is not null)
            throw new InvalidOperationException("provider token exchange audience override is not supported");

        var config = new ProviderTokenConfig(providerId, endpoint,
            env.Get("EPP_PROVIDER_TENANT_ID") ?? string.Empty,
            env.Get("EPP_PROVIDER_CLIENT_ID") ?? string.Empty,
            env.Get("EPP_PROVIDER_SCOPE") ?? string.Empty,
            env.Get("EPP_PROVIDER_MI_CLIENT_ID"),
            env.Get("EPP_PROVIDER_CLIENT_SECRET_NAME"),
            env.Get("KEY_VAULT_URL"), env.Get("AZURE_CLIENT_ID"), timeoutMs);
        config.Validate();
        return config;
    }

    internal void Validate()
    {
        static bool IsValue(string? value) => ProviderCredential.IsHeaderSafeToken(value);
        var hasIdentity = !string.IsNullOrEmpty(ManagedIdentityClientId);
        var hasSecret = !string.IsNullOrEmpty(ClientSecretName);
        if (!DispatchEngine.IsHttpsEndpoint(Endpoint)
            || !IsValue(TenantId) || TenantId.Any(c => !char.IsAsciiLetterOrDigit(c) && c != '-' && c != '.')
            || new[] { "common", "organizations", "consumers", "adfs" }.Contains(TenantId, StringComparer.OrdinalIgnoreCase)
            || !IsValue(ClientId)
            || !IsValue(Scope) || Scope.Length <= "/.default".Length || !Scope.EndsWith("/.default", StringComparison.Ordinal)
            || hasIdentity == hasSecret
            || (hasIdentity && !IsValue(ManagedIdentityClientId))
            || (hasSecret && (!IsValue(ClientSecretName) || !DispatchEngine.IsHttpsEndpoint(KeyVaultUrl)))
            || (!string.IsNullOrEmpty(VaultManagedIdentityClientId) && !IsValue(VaultManagedIdentityClientId))
            || TimeoutMs <= 0 || TimeoutMs > 2500)
            throw new InvalidOperationException("provider token configuration invalid");
    }
}

public interface IProviderTokenAcquirer
{
    Task<string> AcquireAsync(ProviderTokenConfig config);
}

public sealed class ProviderTokenAcquirer : IProviderTokenAcquirer
{
    private readonly ISecretResolver _secrets;
    private readonly ProviderCredentialFactory _factory;
    private readonly object _gate = new();
    private CredentialEntry? _cached;

    public ProviderTokenAcquirer(ISecretResolver secrets) : this(secrets, new ProviderCredentialFactory()) { }

    internal ProviderTokenAcquirer(ISecretResolver secrets, ProviderCredentialFactory factory)
    {
        _secrets = secrets;
        _factory = factory;
    }

    public async Task<string> AcquireAsync(ProviderTokenConfig config)
    {
        config.Validate();
        using var timeout = new CancellationTokenSource(config.TimeoutMs);
        var cancellation = timeout.Token;
        string? secret = null;
        if (!string.IsNullOrEmpty(config.ClientSecretName))
        {
            // The existing resolver has no cancellation overload; bound how long this request waits.
            secret = await _secrets.ResolveAsync(config.ClientSecretName).WaitAsync(cancellation);
            if (string.IsNullOrWhiteSpace(secret))
                throw new InvalidOperationException("provider credential unavailable");
        }

        TokenCredential credential;
        lock (_gate)
        {
            cancellation.ThrowIfCancellationRequested();
            if (_cached is null || _cached.Config != config || _cached.Secret != secret)
                _cached = new CredentialEntry(config, secret, CreateCredential(config, secret));
            credential = _cached.Credential;
        }

        // Reuse the SDK credential/cache, not a custom access-token cache or expiry scheduler.
        var token = await credential.GetTokenAsync(new TokenRequestContext(new[] { config.Scope }), cancellation)
            .AsTask().WaitAsync(cancellation);
        cancellation.ThrowIfCancellationRequested();
        return RequireUsableToken(token);
    }

    private TokenCredential CreateCredential(ProviderTokenConfig config, string? secret)
    {
        var budget = TimeSpan.FromMilliseconds(config.TimeoutMs);
        if (secret is not null)
            return _factory.CreateClientSecret(config, secret,
                Configure(new ClientSecretCredentialOptions(), budget));

        var identity = _factory.CreateManagedIdentity(config.ManagedIdentityClientId!,
            Configure(new TokenCredentialOptions(), budget));
        return _factory.CreateClientAssertion(config, async cancellation =>
        {
            // Entra exchanges the managed-identity assertion for a provider-scoped application token.
            // Use the callback's current cancellation token; never capture a previous request's timeout.
            var assertion = await identity.GetTokenAsync(
                new TokenRequestContext(new[] { "api://AzureADTokenExchange/.default" }), cancellation)
                .AsTask().WaitAsync(cancellation);
            return RequireUsableToken(assertion);
        }, Configure(new ClientAssertionCredentialOptions(), budget));
    }

    private static T Configure<T>(T options, TimeSpan budget) where T : TokenCredentialOptions
    {
        options.AuthorityHost = AzureAuthorityHosts.AzurePublicCloud;
        options.Diagnostics.IsLoggingEnabled = false;
        options.Diagnostics.IsLoggingContentEnabled = false;
        options.Diagnostics.IsAccountIdentifierLoggingEnabled = false;
        options.Retry.MaxRetries = 0;
        options.Retry.NetworkTimeout = budget;
        return options;
    }

    private static string RequireUsableToken(AccessToken token)
    {
        if (!ProviderCredential.IsHeaderSafeToken(token.Token) || token.ExpiresOn <= DateTimeOffset.UtcNow.AddSeconds(60))
            throw new InvalidOperationException("provider token unavailable");
        return token.Token;
    }

    // One entry bounds credential retention; equality includes source/vault identity and resolved secret rotation.
    private sealed record CredentialEntry(ProviderTokenConfig Config, string? Secret, TokenCredential Credential)
    {
        public override string ToString() => nameof(CredentialEntry);
    }
}

// This seam lets tests run both credential flows without any authentication HTTP.
internal class ProviderCredentialFactory
{
    public virtual TokenCredential CreateClientSecret(ProviderTokenConfig config, string secret, ClientSecretCredentialOptions options) =>
        new ClientSecretCredential(config.TenantId, config.ClientId, secret, options);

    public virtual TokenCredential CreateManagedIdentity(string clientId, TokenCredentialOptions options) =>
        new ManagedIdentityCredential(clientId, options);

    public virtual TokenCredential CreateClientAssertion(ProviderTokenConfig config,
        Func<CancellationToken, Task<string>> assertion, ClientAssertionCredentialOptions options) =>
        new ClientAssertionCredential(config.TenantId, config.ClientId, assertion, options);
}
