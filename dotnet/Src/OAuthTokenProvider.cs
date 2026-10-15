using Azure.Core;
using Azure.Identity;

namespace Epp.Otp;

internal sealed class OAuthTokenProvider
{
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromSeconds(30);
    private readonly object _credentialGate = new();
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private (TokenCredential Identity, TokenCredential Credential, string Scope)? _credentials;

    public OAuthTokenProvider()
        : this(
            identity => new ManagedIdentityCredential(identity, OAuthOptions()),
            (tenant, application, assertion) =>
                new ClientAssertionCredential(tenant, application, assertion, OAuthOptions()))
    {
    }

    internal OAuthTokenProvider(
        Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential)
    {
        _createIdentity = createIdentity;
        _createCredential = createCredential;
    }

    public async Task<ProviderCredentials> FetchAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        var (identity, credential, scope) = ConfigureCredentials(config);
        await GetAssertionAsync(identity, cancellationToken).ConfigureAwait(false);
        var token = CheckToken(await credential.GetTokenAsync(
            new TokenRequestContext([scope]),
            cancellationToken).ConfigureAwait(false));
        return new ProviderCredentials(
            "oauth",
            AccessToken: token.Token,
            ExpiresOn: token.ExpiresOn - ExpirySkew);
    }

    private (TokenCredential Identity, TokenCredential Credential, string Scope) ConfigureCredentials(AppConfig config)
    {
        var cacheEnabled = CredentialTokenService.IsCacheEnabled("oauth", config);
        lock (_credentialGate)
        {
            if (cacheEnabled && _credentials is { } cached) return cached;
            if (string.IsNullOrWhiteSpace(config.ProviderTenantId)
                || string.IsNullOrWhiteSpace(config.ProviderScope)
                || string.IsNullOrWhiteSpace(config.OutboundClientId)
                || string.IsNullOrWhiteSpace(config.OutboundManagedIdentityClientId))
                throw CredentialTokenService.Unavailable();
            var identity = _createIdentity(config.OutboundManagedIdentityClientId);
            var credential = _createCredential(
                config.ProviderTenantId,
                config.OutboundClientId,
                async cancellation => (await GetAssertionAsync(identity, cancellation).ConfigureAwait(false)).Token);
            var configured = (identity, credential, config.ProviderScope);
            if (cacheEnabled) _credentials = configured;
            return configured;
        }
    }

    private static async Task<AccessToken> GetAssertionAsync(TokenCredential identity, CancellationToken cancellationToken) =>
        CheckToken(await identity.GetTokenAsync(
            new TokenRequestContext(["api://AzureADTokenExchange/.default"]),
            cancellationToken).ConfigureAwait(false));

    private static AccessToken CheckToken(AccessToken token)
    {
        if (string.IsNullOrWhiteSpace(token.Token)
            || token.ExpiresOn <= DateTimeOffset.UtcNow + ExpirySkew)
            throw CredentialTokenService.Unavailable();
        return token;
    }

    private static ClientAssertionCredentialOptions OAuthOptions() => new()
    {
        AuthorityHost = AzureAuthorityHosts.AzurePublicCloud,
        Retry =
        {
            MaxRetries = 0,
            NetworkTimeout = CredentialTokenService.AcquisitionTimeout,
        },
        Diagnostics =
        {
            IsLoggingEnabled = false,
            IsLoggingContentEnabled = false,
        },
    };
}
