using System.Text.Json;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Epp.Otp;

public sealed class CredentialTokenService : IHostedService, IDisposable
{
    internal static readonly TimeSpan AcquisitionTimeout = TimeSpan.FromSeconds(2.5);

    private readonly IReadOnlyList<PhoneProviderBase> _providers;
    private readonly IEnv? _env;
    private readonly ILogger _log;
    private readonly MemoryCache _cache = new(new MemoryCacheOptions());
    private bool _disposed;

    public CredentialTokenService(
        IEnumerable<PhoneProviderBase> providers,
        IEnv env,
        ILoggerFactory loggerFactory)
        : this(providers, env, loggerFactory.CreateLogger("Epp.Otp.DispatchEngine"))
    {
    }

    internal CredentialTokenService(
        IEnumerable<PhoneProviderBase>? providers = null,
        IEnv? env = null,
        ILogger? log = null)
    {
        _providers = providers?.ToArray() ?? [];
        _env = env;
        _log = log ?? NullLogger.Instance;
    }

    public async Task<ProviderCredentials> GetCredentialsAsync(
        PhoneProviderBase provider,
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        try
        {
            var value = await _cache.GetOrCreateAsync(provider.Name, async entry =>
            {
                using var acquisition = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                acquisition.CancelAfter(AcquisitionTimeout);
                var credentials = await provider.FetchCredentialsAsync(
                    config, acquisition.Token).ConfigureAwait(false);
                if (credentials.ExpiresOn <= DateTimeOffset.UtcNow)
                    throw Unavailable();
                entry.AbsoluteExpiration = credentials.ExpiresOn;
                return credentials;
            }).ConfigureAwait(false);
            return value ?? throw Unavailable();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            ReportFailure(provider.Name);
            throw Unavailable();
        }
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_env is null) return;
        var config = AppConfig.Read(_env);
        if (string.IsNullOrWhiteSpace(config.ProviderName)) return;
        var provider = _providers.FirstOrDefault(candidate =>
            string.Equals(candidate.Name, config.ProviderName, StringComparison.OrdinalIgnoreCase));
        if (provider is null || (!string.IsNullOrEmpty(config.ProviderAuthMode)
            && config.ProviderAuthMode != provider.AuthenticationMode))
        {
            ReportFailure("configuration");
            return;
        }
        try
        {
            await GetCredentialsAsync(provider, config, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            ReportFailure("initialization");
        }
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;

    private void ReportFailure(string kind)
    {
        const string eventName = "credential_refresh_failed";
        var record = new Dictionary<string, object?>
        {
            ["logType"] = "service",
            ["eventName"] = eventName,
            ["cacheKind"] = kind,
            ["failureReason"] = "credential_unavailable",
        };
        _log.Log(
            LogLevel.Warning,
            new EventId(0, eventName),
            record,
            null,
            static (state, _) => JsonSerializer.Serialize(state));
    }

    internal static InvalidOperationException Unavailable() =>
        new("provider credential unavailable");

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _cache.Dispose();
    }
}
