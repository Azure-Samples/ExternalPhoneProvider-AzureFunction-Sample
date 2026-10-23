using Azure.Core;
using Azure.Identity;

namespace Epp.Otp;

internal sealed class OAuthCredentialSource
{
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromSeconds(30);
    private readonly object _credentialGate = new();
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private (TokenCredential Credential, string Scope)? _credentials;

    public OAuthCredentialSource()
        : this(
            identity => new ManagedIdentityCredential(identity, OAuthOptions()),
            (tenant, application, assertion) =>
                new ClientAssertionCredential(tenant, application, assertion, OAuthOptions()))
    {
    }

    internal OAuthCredentialSource(
        Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential)
    {
        _createIdentity = createIdentity;
        _createCredential = createCredential;
    }

    public async Task<ProviderCredentials> FetchAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        var (credential, scope) = ConfigureCredentials(config);
        var token = CheckToken(await credential.GetTokenAsync(
            new TokenRequestContext([scope]),
            cancellationToken).ConfigureAwait(false));
        return new ProviderCredentials("oauth", AccessToken: token.Token);
    }

    private (TokenCredential Credential, string Scope) ConfigureCredentials(AppConfig config)
    {
        lock (_credentialGate)
        {
            if (_credentials is { } configured) return configured;
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
            _credentials = (credential, config.ProviderScope);
            return _credentials.Value;
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

    private static ClientAssertionCredentialOptions OAuthOptions()
    {
        var options = new ClientAssertionCredentialOptions
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
        return options;
    }
}
