namespace Epp.Otp;

internal static class CredentialCachePolicy
{
    internal static readonly TimeSpan AcquisitionTimeout = TimeSpan.FromSeconds(2.5);
    internal static readonly TimeSpan SecretTtl = TimeSpan.FromMinutes(5);
    internal static readonly TimeSpan SecretRefreshInterval = TimeSpan.FromMinutes(4);
    internal static readonly TimeSpan TokenExpirySkew = TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan TokenRefreshLead = TimeSpan.FromMinutes(5);
    internal static readonly TimeSpan MinRefreshDelay = TimeSpan.FromSeconds(1);
    internal static readonly TimeSpan MaxRefreshDelay = TimeSpan.FromSeconds(60);
    internal static readonly TimeSpan InitialRetryDelay = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan MaxRetryDelay = TimeSpan.FromSeconds(60);
    internal static readonly TimeSpan MaxTimerDelay = TimeSpan.FromMilliseconds(int.MaxValue);
    internal const int MaxRetryExponent = 4;
    internal const double RetryJitterRatio = 0.2;
}

internal sealed record CredentialCacheEntry<T>(T Value, DateTimeOffset ExpiresAt, DateTimeOffset RefreshAt)
{
    public override string ToString() => nameof(CredentialCacheEntry<T>);
}

internal sealed class RefreshingCache<T> : IDisposable
{
    private readonly object _gate = new();
    private readonly Func<CancellationToken, Task<CredentialCacheEntry<T>>> _load;
    private readonly TimeProvider _clock;
    private readonly Func<double> _random;
    private readonly Action _onFailure;
    private CredentialCacheEntry<T>? _entry;
    private Task<T>? _inFlight;
    private CancellationTokenSource? _acquisition;
    private ITimer? _timer;
    private DateTimeOffset _retryAt;
    private int _failures;
    private bool _closed;

    internal RefreshingCache(Func<CancellationToken, Task<CredentialCacheEntry<T>>> load,
        Action onFailure, TimeProvider? clock = null, Func<double>? random = null)
    {
        _load = load;
        _onFailure = onFailure;
        _clock = clock ?? TimeProvider.System;
        _random = random ?? Random.Shared.NextDouble;
    }

    private static Exception Unavailable() => new InvalidOperationException("provider credential unavailable");

    internal Task<T> GetAsync(CancellationToken cancellationToken = default)
    {
        Task<T> pending;
        lock (_gate)
        {
            if (_closed) return Task.FromException<T>(Unavailable());
            var now = _clock.GetUtcNow();
            if (_entry is not null && _entry.ExpiresAt > now)
            {
                if (_entry.RefreshAt <= now && _retryAt <= now) _ = ObserveAsync(StartRefresh());
                return Task.FromResult(_entry.Value);
            }
            if (_inFlight is null && _retryAt > now) return Task.FromException<T>(Unavailable());
            pending = StartRefresh();
        }
        return cancellationToken.CanBeCanceled ? pending.WaitAsync(cancellationToken) : pending;
    }

    internal Task<T> RefreshAsync()
    {
        lock (_gate)
        {
            if (_closed || _retryAt > _clock.GetUtcNow()) return Task.FromException<T>(Unavailable());
            return StartRefresh();
        }
    }

    private Task<T> StartRefresh()
    {
        if (_inFlight is not null) return _inFlight;
        _timer?.Dispose();
        _timer = null;
        var completion = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        _inFlight = completion.Task;
        _acquisition = new CancellationTokenSource(CredentialCachePolicy.AcquisitionTimeout, _clock);
        _ = RunRefreshAsync(completion, _acquisition);
        return completion.Task;
    }

    private async Task RunRefreshAsync(TaskCompletionSource<T> completion, CancellationTokenSource cancellation)
    {
        CredentialCacheEntry<T>? entry = null;
        try
        {
            entry = await _load(cancellation.Token).WaitAsync(cancellation.Token).ConfigureAwait(false);
            if (entry.ExpiresAt <= _clock.GetUtcNow()) entry = null;
        }
        catch (Exception)
        {
            // Emit only the fixed failure below; SDK exceptions may contain credentials.
        }
        lock (_gate)
        {
            _inFlight = null;
            _acquisition = null;
            if (_closed || cancellation.IsCancellationRequested) entry = null;
            cancellation.Dispose();
            if (!_closed)
            {
                if (entry is null)
                {
                    _failures++;
                    var exponent = Math.Min(_failures - 1, CredentialCachePolicy.MaxRetryExponent);
                    var backoff = Math.Min(CredentialCachePolicy.MaxRetryDelay.TotalSeconds,
                        CredentialCachePolicy.InitialRetryDelay.TotalSeconds * Math.Pow(2, exponent));
                    _retryAt = _clock.GetUtcNow().AddSeconds(backoff * (1 + _random() * CredentialCachePolicy.RetryJitterRatio));
                    _onFailure();
                }
                else
                {
                    _entry = entry;
                    _failures = 0;
                    _retryAt = default;
                }
                var next = entry is null ? _retryAt : entry.RefreshAt;
                var wait = Math.Clamp((next - _clock.GetUtcNow()).TotalMilliseconds,
                    CredentialCachePolicy.MinRefreshDelay.TotalMilliseconds, CredentialCachePolicy.MaxTimerDelay.TotalMilliseconds);
                _timer = _clock.CreateTimer(_ => ScheduledRefresh(), null, TimeSpan.FromMilliseconds(wait), Timeout.InfiniteTimeSpan);
            }
            if (entry is null) completion.TrySetException(Unavailable());
            else completion.TrySetResult(entry.Value);
        }
    }

    private void ScheduledRefresh()
    {
        lock (_gate)
        {
            _timer?.Dispose();
            _timer = null;
            if (!_closed) _ = ObserveAsync(StartRefresh());
        }
    }

    private static async Task ObserveAsync(Task<T> task)
    {
        // Refresh failures are already reported; a timer has no request awaiting the result.
        try { await task.ConfigureAwait(false); }
        catch (Exception) { }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            _closed = true;
            _timer?.Dispose();
            _timer = null;
            _acquisition?.Cancel();
            _entry = null;
        }
    }
}
