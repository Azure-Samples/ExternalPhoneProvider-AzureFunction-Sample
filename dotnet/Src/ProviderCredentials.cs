using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Epp.Otp;

internal sealed class ProviderCredentials : IDisposable
{
    private readonly object _gate = new();
    private readonly ISecretResolver _secrets;
    private readonly IEnv _env;
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private readonly ILogger _log;
    private readonly TimeProvider _clock;
    private string? _key;
    private RefreshingCache<ProviderCredential>? _bundle;
    private RefreshingCache<AccessToken>? _assertion;
    private TokenCredential? _credential;
    private readonly Dictionary<string, RefreshingCache<AccessToken>> _tokens = new();
    private bool _disposed;

    internal ProviderCredentials(ISecretResolver secrets, IEnv env,
        Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential,
        ILogger? log = null, TimeProvider? clock = null)
    {
        _secrets = secrets;
        _env = env;
        _createIdentity = createIdentity;
        _createCredential = createCredential;
        _log = log ?? NullLogger.Instance;
        _clock = clock ?? TimeProvider.System;
    }

    internal void ReportFailure(string kind)
    {
        const string eventName = "credential_refresh_failed";
        var record = new Dictionary<string, object?>
        {
            ["logType"] = "service",
            ["eventName"] = eventName,
            ["cacheKind"] = kind,
            ["failureReason"] = "credential_unavailable",
        };
        _log.Log(LogLevel.Warning, new EventId(0, eventName), record, null,
            static (state, _) => JsonSerializer.Serialize(state));
    }

    private RefreshingCache<T> Cache<T>(string kind, Func<CancellationToken, Task<CredentialCacheEntry<T>>> load) =>
        new(load, () => ReportFailure(kind), _clock);

    internal async Task<ProviderCredential> ResolveAsync(AuthConfig auth, AppConfig config, CancellationToken cancellation = default)
    {
        RefreshingCache<ProviderCredential>? bundle;
        RefreshingCache<AccessToken>? tokenCache = null;
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (auth.Mode == "oauth" && (string.IsNullOrWhiteSpace(config.ProviderTenantId)
                || string.IsNullOrWhiteSpace(config.ProviderScope) || string.IsNullOrWhiteSpace(config.OutboundClientId)
                || string.IsNullOrWhiteSpace(config.OutboundManagedIdentityClientId)))
            {
                Clear();
                throw new InvalidOperationException("provider OAuth token unavailable");
            }
            if (auth.Mode is not ("apiKey" or "oauth"))
            {
                Clear();
                throw new InvalidOperationException("provider credential unavailable");
            }
            string key;
            if (auth.Mode == "apiKey")
            {
                key = JsonSerializer.Serialize(new[]
                {
                    auth.Mode, _env.Get("KEY_VAULT_URL"), _env.Get("AZURE_CLIENT_ID"),
                    auth.KeyVaultSecretName, auth.IdentityKeyVaultSecretName,
                });
            }
            else
            {
                key = JsonSerializer.Serialize(new[]
                {
                    auth.Mode, config.ProviderTenantId, config.OutboundClientId, config.OutboundManagedIdentityClientId,
                });
            }
            if (_key != key)
            {
                Clear();
                if (auth.Mode == "apiKey") _bundle = CreateBundle(auth);
                else CreateOAuth(config);
                _key = key;
            }
            bundle = _bundle;
            if (auth.Mode == "oauth")
            {
                var scope = config.ProviderScope ?? throw new InvalidOperationException("provider OAuth token unavailable");
                if (!_tokens.TryGetValue(scope, out tokenCache))
                {
                    var credential = _credential ?? throw new InvalidOperationException("provider OAuth token unavailable");
                    tokenCache = Cache("provider_token", async ct =>
                        TokenEntry(await credential.GetTokenAsync(new TokenRequestContext(new[] { scope }), ct).ConfigureAwait(false)));
                    _tokens.Add(scope, tokenCache);
                }
            }
        }
        if (bundle is not null) return await bundle.GetAsync(cancellation).ConfigureAwait(false);
        if (tokenCache is null) throw new InvalidOperationException("provider credential unavailable");
        var token = await tokenCache.GetAsync(cancellation).ConfigureAwait(false);
        return new ProviderCredential("oauth", AccessToken: token.Token);
    }

    private RefreshingCache<ProviderCredential> CreateBundle(AuthConfig auth) => Cache("key_vault", async cancellation =>
    {
        if (string.IsNullOrWhiteSpace(auth.KeyVaultSecretName)) throw new InvalidOperationException("provider credential unavailable");
        var secretTask = _secrets.ResolveAsync(auth.KeyVaultSecretName, cancellation);
        var identityTask = string.IsNullOrWhiteSpace(auth.IdentityKeyVaultSecretName)
            ? Task.FromResult(string.Empty) : _secrets.ResolveAsync(auth.IdentityKeyVaultSecretName, cancellation);
        await Task.WhenAll(secretTask, identityTask).ConfigureAwait(false);
        var secret = await secretTask.ConfigureAwait(false);
        var identity = await identityTask.ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(secret) || (!string.IsNullOrEmpty(auth.IdentityKeyVaultSecretName) && string.IsNullOrWhiteSpace(identity)))
            throw new InvalidOperationException("provider credential unavailable");
        var now = _clock.GetUtcNow();
        return new CredentialCacheEntry<ProviderCredential>(new("apiKey", Secret: secret, Identity: identity),
            now + CredentialCachePolicy.SecretTtl, now + CredentialCachePolicy.SecretRefreshInterval);
    });

    private void CreateOAuth(AppConfig config)
    {
        var identity = _createIdentity(config.OutboundManagedIdentityClientId!);
        var assertion = Cache("managed_identity", async cancellation =>
            TokenEntry(await identity.GetTokenAsync(
                new TokenRequestContext(new[] { "api://AzureADTokenExchange/.default" }), cancellation).ConfigureAwait(false)));
        _assertion = assertion;
        _credential = _createCredential(config.ProviderTenantId!, config.OutboundClientId!,
            async cancellation => (await assertion.GetAsync(cancellation).ConfigureAwait(false)).Token);
    }

    private CredentialCacheEntry<AccessToken> TokenEntry(AccessToken token)
    {
        var now = _clock.GetUtcNow();
        if (string.IsNullOrWhiteSpace(token.Token) || token.ExpiresOn <= now + CredentialCachePolicy.TokenExpirySkew)
            throw new InvalidOperationException("provider credential unavailable");
        var expires = token.ExpiresOn - CredentialCachePolicy.TokenExpirySkew;
        var refresh = token.ExpiresOn - CredentialCachePolicy.TokenRefreshLead;
        if (token.RefreshOn is { } hint && hint < refresh) refresh = hint;
        if (refresh <= now)
        {
            var delay = Math.Clamp((expires - now).TotalSeconds / 2,
                CredentialCachePolicy.MinRefreshDelay.TotalSeconds, CredentialCachePolicy.MaxRefreshDelay.TotalSeconds);
            refresh = now.AddSeconds(delay);
        }
        return new(token, expires, refresh);
    }

    private void Clear()
    {
        _bundle?.Dispose();
        _assertion?.Dispose();
        foreach (var cache in _tokens.Values) cache.Dispose();
        _tokens.Clear();
        _bundle = null;
        _assertion = null;
        _credential = null;
        _key = null;
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            Clear();
        }
    }
}
