using Azure.Core;
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
        using var cache = new RefreshingCache<string>(async _ =>
        {
            Interlocked.Increment(ref calls);
            await release.Task;
            var now = clock.GetUtcNow();
            return new("value", now.AddMinutes(5), now.AddMinutes(4));
        }, () => Assert.Fail("Unexpected refresh failure"), clock);
        var readers = Enumerable.Range(0, 20).Select(_ => cache.GetAsync()).ToArray();
        Assert.Equal(1, calls);
        release.SetResult();
        Assert.All(await Task.WhenAll(readers), value => Assert.Equal("value", value));
        Assert.Equal(1, calls);
        Assert.Equal(1, clock.TimerCount);
        release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        clock.Advance(TimeSpan.FromMinutes(4));
        Assert.Equal(2, calls);
        Assert.Equal("value", await cache.GetAsync());
        release.SetResult();
        await Until(() => clock.TimerCount == 1);
        Assert.Equal("value", await cache.GetAsync());
        cache.Dispose();
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task RefreshFailuresDoNotExtendExpiryAndUseBackoff()
    {
        var clock = new ManualClock();
        var fail = false;
        var calls = 0;
        var failures = 0;
        using var cache = new RefreshingCache<string>(_ =>
        {
            calls++;
            if (fail) throw new InvalidOperationException("PRIVATE-ERROR");
            var now = clock.GetUtcNow();
            return Task.FromResult(new CredentialCacheEntry<string>("first", now.AddMinutes(5), now.AddMinutes(4)));
        }, () => failures++, clock, () => 0);
        Assert.Equal("first", await cache.GetAsync());
        fail = true;
        clock.Advance(TimeSpan.FromMinutes(4));
        Assert.Equal(1, failures);
        for (var i = 0; i < 10; i++) Assert.Equal("first", await cache.GetAsync());
        Assert.Equal(2, calls);
        clock.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(2, failures);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync());
        Assert.Equal("provider credential unavailable", error.Message);
        fail = false;
        clock.Advance(TimeSpan.FromSeconds(10));
        Assert.Equal("first", await cache.GetAsync());
        Assert.Equal(4, calls);
    }

    [Fact]
    public async Task CancellingAWaiterDoesNotCancelTheSharedRefresh()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationToken observed = default;
        using var cache = new RefreshingCache<string>(async cancellation =>
        {
            observed = cancellation;
            await release.Task;
            return new("ready", clock.GetUtcNow().AddMinutes(5), clock.GetUtcNow().AddMinutes(4));
        }, () => Assert.Fail("Unexpected refresh failure"), clock);
        using var waiter = new CancellationTokenSource();
        var first = cache.GetAsync(waiter.Token);
        var second = cache.GetAsync();
        waiter.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => first);
        Assert.False(observed.IsCancellationRequested);
        release.SetResult();
        Assert.Equal("ready", await second);
    }

    [Fact]
    public async Task CacheOwnedDeadlineAndShutdownPreventLatePublication()
    {
        var clock = new ManualClock();
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var errors = 0;
        CancellationToken observed = default;
        using var cache = new RefreshingCache<string>(async cancellation =>
        {
            observed = cancellation;
            await release.Task;
            return new("late", clock.GetUtcNow().AddMinutes(5), clock.GetUtcNow().AddMinutes(4));
        }, () => errors++, clock);
        var pending = cache.GetAsync();
        clock.Advance(TimeSpan.FromSeconds(2.5));
        await Assert.ThrowsAsync<InvalidOperationException>(() => pending);
        Assert.True(observed.IsCancellationRequested);
        Assert.Equal(1, errors);
        cache.Dispose();
        release.SetResult();
        await Assert.ThrowsAsync<InvalidOperationException>(() => cache.GetAsync());
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
        using var manager = new ProviderCredentials(secrets, new TestEnv(), _ => throw new Exception(),
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
        clock.Advance(TimeSpan.FromSeconds(7));
        var next = await manager.ResolveAsync(auth, new AppConfig());
        Assert.Equal("key-2", next.Secret);
        Assert.Equal("id-2", next.Identity);
    }

    [Fact]
    public async Task ManagedIdentityAndEntraTokensAreCachedRefreshedAndIsolatedByConfiguration()
    {
        var clock = new ManualClock();
        var identityCalls = 0;
        var providerCalls = 0;
        var credentialInstances = 0;
        using var manager = new ProviderCredentials(new Secrets((_, _) => throw new Exception("Unexpected Key Vault")),
            new TestEnv(), _ => new Token(async (_, _) =>
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
        Assert.Equal(1, identityCalls);
        Assert.Equal(1, providerCalls);
        await manager.ResolveAsync(new("oauth"), config);
        Assert.Equal(1, providerCalls);
        clock.Advance(TimeSpan.FromMinutes(55));
        await Until(() => identityCalls == 2 && providerCalls == 2 && clock.TimerCount == 2);
        await manager.ResolveAsync(new("oauth"), Config(scope: "api://second/.default"));
        Assert.Equal(2, identityCalls);
        Assert.Equal(3, providerCalls);
        Assert.Equal(1, credentialInstances);
        await manager.ResolveAsync(new("oauth"), Config(application: "different"));
        Assert.Equal(3, identityCalls);
        Assert.Equal(2, credentialInstances);
        manager.Dispose();
        Assert.Equal(0, clock.TimerCount);
    }

    [Fact]
    public async Task RepeatedSdkTokenDoesNotExtendLifetimeOrCauseATightRefreshLoop()
    {
        var clock = new ManualClock();
        var expiry = clock.GetUtcNow().AddHours(1);
        var calls = 0;
        using var manager = new ProviderCredentials(new Secrets((_, _) => throw new Exception()), new TestEnv(),
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
