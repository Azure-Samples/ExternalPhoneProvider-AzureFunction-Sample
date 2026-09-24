using System.Text.Json;
using Azure.Core;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class CredentialCacheTests
{
    [Fact]
    public async Task ColdReadersShareOneFetchAndValidValuesRemainAvailableDuringRefresh()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        using var manager = new ProviderCredentials(new Secrets(async (_, _) =>
        {
            Interlocked.Increment(ref calls);
            await release.Task;
            return "value";
        }), _ => throw new Exception(), (_, _, _) => throw new Exception(), clock: clock);
        Task<ProviderCredential> Get() => manager.ResolveAsync(new("apiKey", "key"), new AppConfig());
        var readers = Enumerable.Range(0, 20).Select(_ => Get()).ToArray();
        Assert.Equal(1, calls);
        release.SetResult();
        Assert.All(await Task.WhenAll(readers), value => Assert.Equal("value", value.Secret));
        Assert.Equal(1, calls);
        Assert.Equal(1, clock.TimerCount);
        release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        clock.Advance(TimeSpan.FromMinutes(4));
        Assert.Equal(2, calls);
        Assert.Equal("value", (await Get()).Secret);
        release.SetResult();
        await Until(() => clock.TimerCount == 1);
        Assert.Equal("value", (await Get()).Secret);
        manager.Dispose();
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task RefreshFailuresDoNotExtendExpiryAndUseFixedRetryCadence()
    {
        var clock = new ManualClock();
        var fail = false;
        var calls = 0;
        var log = new CredentialLogger();
        using var manager = new ProviderCredentials(new Secrets((_, _) =>
        {
            calls++;
            if (fail) throw new InvalidOperationException("PRIVATE-ERROR");
            return Task.FromResult("first");
        }), _ => throw new Exception(), (_, _, _) => throw new Exception(), log, clock);
        Task<ProviderCredential> Get() => manager.ResolveAsync(new("apiKey", "key"), new AppConfig());
        Assert.Equal("first", (await Get()).Secret);
        fail = true;
        clock.Advance(TimeSpan.FromMinutes(4));
        Assert.Single(log.Entries);
        for (var i = 0; i < 10; i++) Assert.Equal("first", (await Get()).Secret);
        Assert.Equal(2, calls);
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(2, log.Entries.Count);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(Get);
        Assert.Equal("provider credential unavailable", error.Message);
        foreach (var delay in new[] { 30, 30, 30, 30, 30 })
        {
            var before = calls;
            clock.Advance(TimeSpan.FromSeconds(delay - 0.01));
            Assert.Equal(before, calls);
            clock.Advance(TimeSpan.FromSeconds(0.01));
            Assert.Equal(before + 1, calls);
        }
        fail = false;
        clock.Advance(TimeSpan.FromSeconds(30));
        Assert.Equal("first", (await Get()).Secret);
        Assert.Equal(9, calls);
    }

    [Fact]
    public async Task CancellingAWaiterDoesNotCancelTheSharedRefresh()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken observed = default;
        using var manager = new ProviderCredentials(new Secrets(async (_, cancellation) =>
        {
            observed = cancellation;
            await release.Task;
            return "ready";
        }), _ => throw new Exception(), (_, _, _) => throw new Exception(), clock: clock);
        using var waiter = new CancellationTokenSource();
        var first = manager.ResolveAsync(new("apiKey", "key"), new AppConfig(), waiter.Token);
        var second = manager.ResolveAsync(new("apiKey", "key"), new AppConfig());
        waiter.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        Assert.False(observed.IsCancellationRequested);
        release.SetResult();
        Assert.Equal("ready", (await second).Secret);
    }

    [Fact]
    public async Task CacheOwnedDeadlineAndShutdownPreventLatePublication()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var log = new CredentialLogger();
        CancellationToken observed = default;
        using var manager = new ProviderCredentials(new Secrets(async (_, cancellation) =>
        {
            observed = cancellation;
            await release.Task;
            return "late";
        }), _ => throw new Exception(), (_, _, _) => throw new Exception(), log, clock);
        var pending = manager.ResolveAsync(new("apiKey", "key"), new AppConfig());
        clock.Advance(TimeSpan.FromSeconds(2.5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => pending);
        Assert.True(observed.IsCancellationRequested);
        Assert.Single(log.Entries);
        manager.Dispose();
        release.SetResult();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => manager.ResolveAsync(new("apiKey", "key"), new AppConfig()));
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task ApiKeyPairIsFetchedInParallelAndPublishedAsOneBundle()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = new List<string>();
        var version = 1;
        var failIdentity = false;
        var secrets = new Secrets(async (name, _) =>
        {
            calls.Add(name!);
            await release.Task;
            if (failIdentity && name == "id") throw new InvalidOperationException("PRIVATE-ERROR");
            return name + "-" + version;
        });
        using var manager = new ProviderCredentials(secrets, _ => throw new Exception(),
            (_, _, _) => throw new Exception(), clock: clock);
        var auth = new AuthConfig("apiKey", "key", "id");
        var pending = Enumerable.Range(0, 10).Select(_ => manager.ResolveAsync(auth, new AppConfig())).ToArray();
        Assert.Equal(new[] { "key", "id" }, calls);
        release.SetResult();
        foreach (var value in await Task.WhenAll(pending))
        {
            Assert.Equal("key-1", value.Secret);
            Assert.Equal("id-1", value.Identity);
        }
        version = 2;
        failIdentity = true;
        clock.Advance(TimeSpan.FromMinutes(4));
        var old = await manager.ResolveAsync(auth, new AppConfig());
        Assert.Equal("key-1", old.Secret);
        Assert.Equal("id-1", old.Identity);
        failIdentity = false;
        clock.Advance(TimeSpan.FromSeconds(30));
        var next = await manager.ResolveAsync(auth, new AppConfig());
        Assert.Equal("key-2", next.Secret);
        Assert.Equal("id-2", next.Identity);
    }

    [Fact]
    public async Task SdkCredentialsAreReusedByOneAccessTokenCacheWithoutKeyVaultCalls()
    {
        var clock = new ManualClock();
        var identityCalls = 0;
        var providerCalls = 0;
        var credentialInstances = 0;
        using var manager = new ProviderCredentials(new Secrets((_, _) => throw new Exception("Unexpected Key Vault")),
            _ => new Token(async (_, _) =>
            {
                Interlocked.Increment(ref identityCalls);
                await Task.Yield();
                return new("PRIVATE-ASSERTION", clock.GetUtcNow().AddHours(1));
            }), (_, _, assertion) =>
            {
                credentialInstances++;
                return new Token(async (_, cancellation) =>
                {
                    Interlocked.Increment(ref providerCalls);
                    Assert.Equal("PRIVATE-ASSERTION", await assertion(cancellation));
                    Assert.Equal("PRIVATE-ASSERTION", await assertion(cancellation));
                    return new("PRIVATE-PROVIDER", clock.GetUtcNow().AddHours(1));
                });
            }, clock: clock);
        var config = Config();
        var initial = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => manager.ResolveAsync(new("oauth"), config)));
        Assert.All(initial, result => Assert.Equal("PRIVATE-PROVIDER", result.AccessToken));
        Assert.Equal(3, identityCalls);
        Assert.Equal(1, providerCalls);
        await manager.ResolveAsync(new("oauth"), config);
        Assert.Equal(1, providerCalls);
        clock.Advance(TimeSpan.FromMinutes(1));
        await Until(() => identityCalls == 6 && providerCalls == 2 && clock.TimerCount == 1);
        Assert.Equal(1, credentialInstances);
        await manager.ResolveAsync(new("oauth"), config);
        Assert.Equal(6, identityCalls);
        Assert.Equal(2, providerCalls);
        Assert.Equal(1, credentialInstances);
        manager.Dispose();
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task RepeatedSdkTokenDoesNotExtendLifetimeOrCauseATightRefreshLoop()
    {
        var clock = new ManualClock();
        var expiry = clock.GetUtcNow().AddHours(1);
        var calls = 0;
        using var manager = new ProviderCredentials(new Secrets((_, _) => throw new Exception()),
            _ => new Token((_, _) => ValueTask.FromResult(new AccessToken("assertion", expiry))),
            (_, _, _) => new Token((_, _) =>
            {
                calls++;
                return ValueTask.FromResult(new AccessToken("token", expiry));
            }), clock: clock);
        await manager.ResolveAsync(new("oauth"), Config());
        clock.Advance(TimeSpan.FromMinutes(55));
        Assert.Equal(2, calls);
        await manager.ResolveAsync(new("oauth"), Config());
        Assert.Equal(2, calls);
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(3, calls);
        clock.Advance(TimeSpan.FromSeconds(210));
        await Assert.ThrowsAsync<InvalidOperationException>(() => manager.ResolveAsync(new("oauth"), Config()));
    }

    [Fact]
    public async Task DisposingManagerIsTerminalAndCancelsPendingAcquisition()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        CancellationToken acquisition = default;
        using var manager = new ProviderCredentials(new Secrets((_, cancellation) =>
        {
            calls++;
            acquisition = cancellation;
            return release.Task;
        }), _ => throw new Exception("Unexpected managed identity"),
            (_, _, _) => throw new Exception("Unexpected OAuth"), clock: clock);
        var auth = new AuthConfig("apiKey", "key");
        var pending = manager.ResolveAsync(auth, new AppConfig());
        manager.Dispose();
        manager.Dispose();
        Assert.True(acquisition.IsCancellationRequested);
        await Assert.ThrowsAsync<InvalidOperationException>(() => pending);
        release.SetResult("PRIVATE-LATE-KEY");
        await Assert.ThrowsAsync<ObjectDisposedException>(() => manager.ResolveAsync(auth, new AppConfig()));
        await Assert.ThrowsAsync<ObjectDisposedException>(() => manager.ResolveAsync(new("oauth"), Config()));
        Assert.Equal(1, calls);
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task InvalidInitialConfigurationDoesNotCreateClientsOrStartATimer()
    {
        var clock = new ManualClock();
        var instances = 0;
        using var manager = new ProviderCredentials(new Secrets((_, _) => throw new Exception("Unexpected Key Vault")),
            _ => new Token((_, _) =>
                ValueTask.FromResult(new AccessToken("assertion", clock.GetUtcNow().AddHours(1)))),
            (_, _, assertion) =>
            {
                instances++;
                return new Token(async (_, cancellation) =>
                {
                    await assertion(cancellation);
                    return new("provider-token", clock.GetUtcNow().AddHours(1));
                });
            }, clock: clock);
        await Assert.ThrowsAsync<InvalidOperationException>(() => manager.ResolveAsync(new("oauth"), Config(scope: "")));
        Assert.Equal(0, clock.TimerCount);
        Assert.Equal(0, instances);
        Assert.Equal("provider-token", (await manager.ResolveAsync(new("oauth"), Config())).AccessToken);
        Assert.Equal(1, instances);
        Assert.Equal(1, clock.TimerCount);
    }

    [Fact]
    public async Task ApiKeyCacheReplacesOneCompleteEntryAndStops()
    {
        var clock = new ManualClock();
        var version = "first";
        using var cache = new ApiKeyCache(new Secrets((_, _) => Task.FromResult(version)), new("apiKey", "key"), clock);
        await cache.RefreshAsync(default);
        Assert.Equal("first", cache.Get()?.Secret);
        version = "second";
        clock.Advance(TimeSpan.FromMinutes(4));
        await cache.RefreshAsync(default);
        Assert.Equal("second", cache.Get()?.Secret);
        cache.Dispose();
        Assert.Null(cache.Get());
    }

    [Fact]
    public async Task RefreshFailureUsesStructuredSanitizedLogRecord()
    {
        var clock = new ManualClock();
        var logger = new CredentialLogger();
        using var manager = new ProviderCredentials(new Secrets((_, _) =>
            throw new InvalidOperationException("PRIVATE-SDK-ERROR")),
            _ => throw new Exception("Unexpected managed identity"),
            (_, _, _) => throw new Exception("Unexpected OAuth"), logger, clock);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            manager.ResolveAsync(new("apiKey", "key"), new AppConfig()));
        var entry = Assert.Single(logger.Entries);
        Assert.Equal(LogLevel.Warning, entry.Level);
        Assert.Equal("credential_refresh_failed", entry.EventId.Name);
        Assert.Null(entry.Error);
        Assert.Equal(4, entry.State.Count);
        Assert.Equal("service", entry.State["logType"]);
        Assert.Equal("credential_refresh_failed", entry.State["eventName"]);
        Assert.Equal("key_vault", entry.State["cacheKind"]);
        Assert.Equal("credential_unavailable", entry.State["failureReason"]);
        using var json = JsonDocument.Parse(entry.Message);
        Assert.Equal("key_vault", json.RootElement.GetProperty("cacheKind").GetString());
        Assert.DoesNotContain("PRIVATE", entry.Message);
    }

    private static AppConfig Config(string scope = "api://provider/.default", string application = "app") => new()
    {
        ProviderTenantId = "tenant", ProviderScope = scope, OutboundClientId = application,
        OutboundManagedIdentityClientId = "identity",
    };

    private static async Task Until(Func<bool> condition)
    {
        for (var i = 0; i < 200; i++)
        {
            if (condition()) return;
            await Task.Delay(5);
        }
        Assert.True(condition());
    }

    private sealed class Secrets(Func<string?, CancellationToken, Task<string>> resolve) : ISecretResolver
    {
        public Task<string> ResolveAsync(string? name, CancellationToken cancellationToken = default) => resolve(name, cancellationToken);
    }

    private sealed class Token(Func<TokenRequestContext, CancellationToken, ValueTask<AccessToken>> acquire) : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Synchronous acquisition was not expected");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            acquire(requestContext, cancellationToken);
    }

    private sealed record LogEntry(LogLevel Level, EventId EventId, IReadOnlyDictionary<string, object?> State,
        Exception? Error, string Message);

    private sealed class CredentialLogger : ILogger
    {
        internal List<LogEntry> Entries { get; } = new();
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel level) => true;
        public void Log<TState>(LogLevel level, EventId eventId, TState state, Exception? error,
            Func<TState, Exception?, string> formatter)
        {
            var record = Assert.IsAssignableFrom<IReadOnlyDictionary<string, object?>>(state);
            Entries.Add(new(level, eventId, record, error, formatter(state, error)));
        }
    }

    private sealed class ManualClock : TimeProvider
    {
        private readonly object _gate = new();
        private readonly List<ManualTimer> _timers = new();
        private DateTimeOffset _now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() { lock (_gate) return _now; }
        public int TimerCount { get { lock (_gate) return _timers.Count(timer => !timer.Disposed && timer.Due != DateTimeOffset.MaxValue); } }
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            lock (_gate)
            {
                var timer = new ManualTimer(this, callback, state);
                timer.Change(dueTime, period);
                _timers.Add(timer);
                return timer;
            }
        }
        public void Advance(TimeSpan duration)
        {
            ManualTimer[] due;
            lock (_gate)
            {
                _now += duration;
                due = _timers.Where(timer => !timer.Disposed && timer.Due <= _now).ToArray();
            }
            foreach (var timer in due) timer.Fire();
        }

        private sealed class ManualTimer(ManualClock clock, TimerCallback callback, object? state) : ITimer
        {
            internal bool Disposed;
            internal DateTimeOffset Due;
            private TimeSpan _period;
            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                lock (clock._gate)
                {
                    if (Disposed) return false;
                    Due = dueTime == Timeout.InfiniteTimeSpan ? DateTimeOffset.MaxValue : clock._now + dueTime;
                    _period = period;
                    return true;
                }
            }
            internal void Fire()
            {
                lock (clock._gate)
                {
                    if (Disposed) return;
                    Due = _period == Timeout.InfiniteTimeSpan ? DateTimeOffset.MaxValue : clock._now + _period;
                }
                callback(state);
            }
            public void Dispose() { lock (clock._gate) { Disposed = true; clock._timers.Remove(this); } }
            public ValueTask DisposeAsync() { Dispose(); return ValueTask.CompletedTask; }
        }
    }
}
