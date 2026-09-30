using System.Text.Json;
using Azure.Core;
using Epp.Otp.Providers;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class CredentialTokenServiceTests
{
    [Fact]
    public async Task CachedCredentialsAreReusedUntilExpiration()
    {
        var calls = 0;
        using var service = CreateService();
        Task<ProviderCredentials> Fetch(CancellationToken cancellation)
        {
            Interlocked.Increment(ref calls);
            return Task.FromResult(ApiKey("value"));
        }
        var provider = new TestProvider("provider", Fetch);

        Assert.Equal("value", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        Assert.Equal("value", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        Assert.Equal(1, calls);
    }

    [Fact]
    public async Task MemoryCacheExpiresCredentialsAndFetchesAReplacement()
    {
        var calls = 0;
        using var service = CreateService();
        Task<ProviderCredentials> Fetch(CancellationToken cancellation) =>
            Task.FromResult(ApiKey("value-" + Interlocked.Increment(ref calls), TimeSpan.FromMilliseconds(50)));
        var provider = new TestProvider("provider", Fetch);

        Assert.Equal("value-1", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        Assert.Equal("value-1", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        await Task.Delay(100);
        Assert.Equal("value-2", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
    }

    [Fact]
    public async Task CallerCancellationCancelsItsCredentialFetch()
    {
        CancellationToken observed = default;
        using var service = CreateService();
        async Task<ProviderCredentials> Fetch(CancellationToken cancellation)
        {
            observed = cancellation;
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
            return ApiKey("ready");
        }
        var provider = new TestProvider("provider", Fetch);

        using var waiter = new CancellationTokenSource();
        var pending = service.GetCredentialsAsync(provider, new AppConfig(), waiter.Token);
        waiter.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.True(observed.IsCancellationRequested);
    }

    [Fact]
    public async Task DisposalPreventsFurtherUse()
    {
        using var service = CreateService();
        service.Dispose();
        var provider = new TestProvider("provider", _ => Task.FromResult(ApiKey("unused")));
        await Assert.ThrowsAsync<ObjectDisposedException>(() =>
            service.GetCredentialsAsync(provider, new AppConfig()));
    }

    [Fact]
    public async Task OAuthUsesManagedIdentityAssertionAndCachesTheProviderToken()
    {
        var identityCalls = 0;
        var providerCalls = 0;
        var credentialInstances = 0;
        var provider = new SopranoProvider(
            _ => new Token(async (_, _) =>
            {
                Interlocked.Increment(ref identityCalls);
                await Task.Yield();
                return new("PRIVATE-ASSERTION", DateTimeOffset.UtcNow.AddHours(1));
            }),
            (_, _, assertion) =>
            {
                credentialInstances++;
                return new Token(async (_, cancellation) =>
                {
                    Interlocked.Increment(ref providerCalls);
                    Assert.Equal("PRIVATE-ASSERTION", await assertion(cancellation));
                    return new("PRIVATE-PROVIDER", DateTimeOffset.UtcNow.AddHours(1));
                });
            });
        using var service = CreateService();
        var config = OAuthConfig();

        var initial = await service.GetCredentialsAsync(provider, config);
        Assert.Equal("PRIVATE-PROVIDER", initial.AccessToken);
        await service.GetCredentialsAsync(provider, config);
        Assert.Equal(2, identityCalls);
        Assert.Equal(1, providerCalls);
        Assert.Equal(1, credentialInstances);
    }

    [Fact]
    public async Task InvalidOAuthConfigurationDoesNotCreateSdkCredentials()
    {
        var instances = 0;
        var provider = new SopranoProvider(
            _ => new Token((_, _) =>
                ValueTask.FromResult(new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1)))),
            (_, _, _) =>
            {
                instances++;
                return new Token((_, _) =>
                    ValueTask.FromResult(new AccessToken("provider", DateTimeOffset.UtcNow.AddHours(1))));
            });
        using var service = CreateService();

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.GetCredentialsAsync(provider, OAuthConfig(scope: "")));
        Assert.Equal(0, instances);
    }

    [Fact]
    public async Task FetchFailureUsesStructuredSanitizedLogRecord()
    {
        var logger = new CredentialLogger();
        using var service = new CredentialTokenService(log: logger);
        var provider = new TestProvider(
            "provider",
            _ => throw new InvalidOperationException("PRIVATE-SDK-ERROR"));

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.GetCredentialsAsync(provider, new AppConfig()));
        var entry = Assert.Single(logger.Entries);
        Assert.Equal(LogLevel.Warning, entry.Level);
        Assert.Equal("credential_refresh_failed", entry.EventId.Name);
        Assert.Null(entry.Error);
        Assert.Equal("provider", entry.State["CacheKind"]);
        Assert.Contains("credential unavailable", entry.Message);
        Assert.DoesNotContain("PRIVATE", entry.Message);
    }

    private static CredentialTokenService CreateService() =>
        new();

    private static ProviderCredentials ApiKey(string value, TimeSpan? lifetime = null) =>
        new(
            "apiKey",
            Secret: value,
            ExpiresOn: DateTimeOffset.UtcNow + (lifetime ?? TimeSpan.FromMinutes(5)));

    private static AppConfig OAuthConfig(string scope = "api://provider/.default") => new()
    {
        ProviderTenantId = "tenant",
        ProviderScope = scope,
        OutboundClientId = "application",
        OutboundManagedIdentityClientId = "identity",
    };

    private sealed class TestProvider(
        string name,
        Func<CancellationToken, Task<ProviderCredentials>> fetch) : PhoneProviderBase
    {
        public override string Name => name;
        public override string AuthenticationMode => "test";
        public override Task<ProviderCredentials> FetchCredentialsAsync(
            AppConfig config,
            CancellationToken cancellationToken = default) =>
            fetch(cancellationToken);
        public override Task<ProviderResult> SendOtpAsync(
            string channel,
            string endpoint,
            OtpDelivery delivery,
            ProviderCredentials credentials,
            IEnv env,
            HttpClient client,
            int timeoutMs,
            ILogger? logger = null) =>
            throw new NotSupportedException();
    }

    private sealed class Token(
        Func<TokenRequestContext, CancellationToken, ValueTask<AccessToken>> acquire) : TokenCredential
    {
        public override AccessToken GetToken(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Synchronous acquisition was not expected");

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken) =>
            acquire(requestContext, cancellationToken);
    }

    private sealed record LogEntry(
        LogLevel Level,
        EventId EventId,
        IReadOnlyDictionary<string, object?> State,
        Exception? Error,
        string Message);

    private sealed class CredentialLogger : ILogger
    {
        internal List<LogEntry> Entries { get; } = new();
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(
            LogLevel level,
            EventId eventId,
            TState state,
            Exception? error,
            Func<TState, Exception?, string> formatter)
        {
            var record = Assert.IsAssignableFrom<IEnumerable<KeyValuePair<string, object?>>>(state)
                .Where(pair => pair.Key != "{OriginalFormat}")
                .ToDictionary(pair => pair.Key, pair => pair.Value);
            Entries.Add(new(level, eventId, record, error, formatter(state, error)));
        }
    }
}
