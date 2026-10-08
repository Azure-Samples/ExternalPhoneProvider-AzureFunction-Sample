using Azure.Core;
using Azure.Identity;

namespace Epp.Otp;

public abstract class OAuthPhoneProviderBase : PhoneProviderBase
{
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromSeconds(30);
    private readonly object _credentialGate = new();
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private TokenCredential? _identity;
    private TokenCredential? _credential;
    private string? _scope;

    protected OAuthPhoneProviderBase()
        : this(
            identity => new ManagedIdentityCredential(identity, OAuthOptions()),
            (tenant, application, assertion) =>
                new ClientAssertionCredential(tenant, application, assertion, OAuthOptions()))
    {
    }

    private protected OAuthPhoneProviderBase(
        Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential)
    {
        _createIdentity = createIdentity;
        _createCredential = createCredential;
    }

    public sealed override string AuthenticationMode => "oauth";

    public sealed override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        ConfigureCredentials(config);
        await GetAssertionAsync(cancellationToken).ConfigureAwait(false);
        var token = CheckToken(await _credential!.GetTokenAsync(
            new TokenRequestContext([_scope!]),
            cancellationToken).ConfigureAwait(false));
        return new ProviderCredentials(
            AuthenticationMode,
            AccessToken: token.Token,
            ExpiresOn: token.ExpiresOn - ExpirySkew);
    }

    private void ConfigureCredentials(AppConfig config)
    {
        lock (_credentialGate)
        {
            if (_credential is not null) return;
            if (string.IsNullOrWhiteSpace(config.ProviderTenantId)
                || string.IsNullOrWhiteSpace(config.ProviderScope)
                || string.IsNullOrWhiteSpace(config.OutboundClientId)
                || string.IsNullOrWhiteSpace(config.OutboundManagedIdentityClientId))
                throw CredentialTokenService.Unavailable();
            _scope = config.ProviderScope;
            _identity = _createIdentity(config.OutboundManagedIdentityClientId);
            _credential = _createCredential(
                config.ProviderTenantId,
                config.OutboundClientId,
                async cancellation => (await GetAssertionAsync(cancellation).ConfigureAwait(false)).Token);
        }
    }

    private async Task<AccessToken> GetAssertionAsync(CancellationToken cancellationToken) =>
        CheckToken(await _identity!.GetTokenAsync(
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
