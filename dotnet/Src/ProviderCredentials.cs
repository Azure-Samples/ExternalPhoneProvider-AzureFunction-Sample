using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Internal;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using static Epp.Otp.ProviderCredentials;

namespace Epp.Otp;

internal interface ICredentialCache : IDisposable
{
    string Stage { get; }
    ProviderCredential? Get();
    Task RefreshAsync(CancellationToken cancellation);
}

internal sealed class ApiKeyCache(ISecretResolver secrets, AuthConfig auth, TimeProvider clock) : ICredentialCache
{
    private const string BundleKey = "bundle";
    private static readonly TimeSpan Ttl = TimeSpan.FromMinutes(5);
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(4);
    private readonly object _gate = new();
    // The fixed key bounds the cache; a size limit can reject replacement before removing the old entry.
    private readonly MemoryCache _values = new(new MemoryCacheOptions { Clock = new CacheClock(clock) });
    private DateTimeOffset _refreshAt;
    private bool _closed;
    public string Stage => "key_vault";

    private sealed class CacheClock(TimeProvider time) : ISystemClock
    {
        public DateTimeOffset UtcNow => time.GetUtcNow();
    }

    public ProviderCredential? Get()
    {
        lock (_gate) return _closed ? null : _values.Get<ProviderCredential>(BundleKey);
    }
    public async Task RefreshAsync(CancellationToken cancellation)
    {
        lock (_gate)
        {
            if (_closed) throw Unavailable();
            if (Get() is not null && _refreshAt > clock.GetUtcNow()) return;
        }
        if (string.IsNullOrWhiteSpace(auth.KeyVaultSecretName)) throw Unavailable();
        var key = secrets.ResolveAsync(auth.KeyVaultSecretName, cancellation);
        var identity = string.IsNullOrWhiteSpace(auth.IdentityKeyVaultSecretName)
            ? Task.FromResult("") : secrets.ResolveAsync(auth.IdentityKeyVaultSecretName, cancellation);
        await Task.WhenAll(key, identity).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key.Result) ||
            (!string.IsNullOrWhiteSpace(auth.IdentityKeyVaultSecretName) && string.IsNullOrWhiteSpace(identity.Result))) throw Unavailable();
        lock (_gate)
        {
            cancellation.ThrowIfCancellationRequested();
            if (_closed) throw Unavailable();
            _values.Set(BundleKey, new ProviderCredential(ApiKeyMode, Secret: key.Result, Identity: identity.Result),
                new MemoryCacheEntryOptions { AbsoluteExpiration = clock.GetUtcNow() + Ttl });
            _refreshAt = clock.GetUtcNow() + RefreshInterval;
        }
    }
    public void Dispose()
    {
        lock (_gate) { _closed = true; _values.Dispose(); }
    }
}

internal sealed class AccessTokenCache : ICredentialCache
{
    private const string ExchangeScope = "api://AzureADTokenExchange/.default";
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromSeconds(30);
    private readonly object _gate = new();
    private readonly TokenCredential _identity, _credential;
    private readonly string _scope;
    private readonly TimeProvider _clock;
    private AccessToken? _token;
    private bool _closed;
    public string Stage { get; private set; } = "provider_token";

    internal AccessTokenCache(AppConfig config, Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(config.ProviderTenantId) || string.IsNullOrWhiteSpace(config.ProviderScope)
            || string.IsNullOrWhiteSpace(config.OutboundClientId) || string.IsNullOrWhiteSpace(config.OutboundManagedIdentityClientId)) throw Unavailable();
        _clock = clock;
        _scope = config.ProviderScope;
        _identity = createIdentity(config.OutboundManagedIdentityClientId);
        _credential = createCredential(config.ProviderTenantId, config.OutboundClientId,
            async cancellation => (await Assertion(cancellation).ConfigureAwait(false)).Token);
    }
    public ProviderCredential? Get()
    {
        lock (_gate) return !_closed && _token is { } token && token.ExpiresOn > _clock.GetUtcNow() + ExpirySkew
            ? new(OAuthMode, AccessToken: token.Token) : null;
    }
    private AccessToken Check(AccessToken token)
    {
        if (string.IsNullOrWhiteSpace(token.Token) || token.ExpiresOn <= _clock.GetUtcNow() + ExpirySkew) throw Unavailable();
        return token;
    }
    private async Task<AccessToken> Assertion(CancellationToken cancellation) =>
        Check(await _identity.GetTokenAsync(new TokenRequestContext(new[] { ExchangeScope }), cancellation).ConfigureAwait(false));

    public async Task RefreshAsync(CancellationToken cancellation)
    {
        lock (_gate) { if (_closed) throw Unavailable(); }
        Stage = "managed_identity";
        await Assertion(cancellation).ConfigureAwait(false);
        Stage = "provider_token";
        var token = Check(await _credential.GetTokenAsync(new TokenRequestContext(new[] { _scope }), cancellation).ConfigureAwait(false));
        lock (_gate)
        {
            cancellation.ThrowIfCancellationRequested();
            if (_closed) throw Unavailable();
            _token = token;
        }
    }
    public void Dispose()
    {
        lock (_gate) { _closed = true; _token = null; }
    }
}

// One selected cache and one periodic refresh; configuration changes require a worker restart.
internal sealed class ProviderCredentials : IDisposable
{
    internal const string ApiKeyMode = "apiKey";
    internal const string OAuthMode = "oauth";
    internal static readonly TimeSpan AcquisitionTimeout = TimeSpan.FromSeconds(2.5);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(30);
    private readonly object _gate = new();
    private readonly ISecretResolver _secrets;
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private readonly ILogger _log;
    private readonly TimeProvider _clock;
    private ICredentialCache? _cache;
    private Task<ProviderCredential>? _pending;
    private CancellationTokenSource? _acquisition;
    private ITimer? _timer;
    private DateTimeOffset _nextAttempt;
    private bool _disposed;

    internal ProviderCredentials(ISecretResolver secrets, Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential,
        ILogger? log = null, TimeProvider? clock = null)
    {
        _secrets = secrets;
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
            ["logType"] = "service", ["eventName"] = eventName,
            ["cacheKind"] = kind, ["failureReason"] = "credential_unavailable",
        };
        _log.Log(LogLevel.Warning, new EventId(0, eventName), record, null,
            static (state, _) => JsonSerializer.Serialize(state));
    }
    internal Task<ProviderCredential> ResolveAsync(AuthConfig auth, AppConfig config, CancellationToken cancellation = default)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_cache is null)
            {
                try
                {
                    _cache = auth.Mode switch
                    {
                        ApiKeyMode => new ApiKeyCache(_secrets, auth, _clock),
                        OAuthMode => new AccessTokenCache(config, _createIdentity, _createCredential, _clock),
                        _ => throw Unavailable(),
                    };
                    _timer = _clock.CreateTimer(_ => Tick(), null, PollInterval, PollInterval);
                }
                catch (Exception) { ReportFailure("configuration"); return Task.FromException<ProviderCredential>(Unavailable()); }
            }
            var cached = _cache.Get();
            if (cached is not null) return Task.FromResult(cached);
            var pending = Refresh();
            return cancellation.CanBeCanceled ? pending.WaitAsync(cancellation) : pending;
        }
    }
    private void Tick()
    {
        lock (_gate) { if (!_disposed) _ = ObserveAsync(Refresh()); }
    }
    private static async Task ObserveAsync(Task task) => await task.ConfigureAwait(ConfigureAwaitOptions.SuppressThrowing);
    private Task<ProviderCredential> Refresh()
    {
        if (_pending is not null) return _pending;
        if (_disposed || _cache is null || _nextAttempt > _clock.GetUtcNow())
            return Task.FromException<ProviderCredential>(Unavailable());
        _nextAttempt = _clock.GetUtcNow() + PollInterval;
        var completion = new TaskCompletionSource<ProviderCredential>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending = completion.Task;
        var cancellation = _acquisition = new CancellationTokenSource(AcquisitionTimeout, _clock);
        _ = RunAsync(_cache, completion, cancellation);
        return completion.Task;
    }
    private async Task RunAsync(ICredentialCache cache, TaskCompletionSource<ProviderCredential> completion, CancellationTokenSource cancellation)
    {
        ProviderCredential? value = null;
        try
        {
            await cache.RefreshAsync(cancellation.Token).WaitAsync(cancellation.Token).ConfigureAwait(false);
            value = cache.Get();
        }
        catch (Exception) { /* Report only the sanitized failure below. */ }
        lock (_gate)
        {
            if (_disposed || cancellation.IsCancellationRequested) value = null;
            _pending = null;
            _acquisition = null;
            cancellation.Dispose();
            if (value is null)
            {
                if (!_disposed) ReportFailure(cache.Stage);
                completion.TrySetException(Unavailable());
            }
            else completion.TrySetResult(value);
        }
    }
    internal static InvalidOperationException Unavailable() => new("provider credential unavailable");
    public void Dispose()
    {
        lock (_gate)
        {
            _disposed = true;
            _timer?.Dispose();
            _acquisition?.Cancel();
            _cache?.Dispose();
        }
    }
}
