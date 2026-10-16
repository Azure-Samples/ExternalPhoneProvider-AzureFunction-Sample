using System.Diagnostics;
using System.Net;
using System.Text;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Identity;
using Epp.Otp.Providers;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class CredentialAcquisitionTests
{
    [Fact]
    public async Task EachRequestFetchesNewCredentialsAndRetriesImmediatelyAfterFailure()
    {
        var calls = 0;
        var service = new CredentialTokenService();
        var provider = new TestProvider(_ => Task.FromResult(++calls == 3
            ? throw new InvalidOperationException("PRIVATE-SDK-FAILURE")
            : new ProviderCredentials("apiKey", Secret: "value-" + calls)));
        var config = new AppConfig();

        Assert.Equal(0, calls);
        Assert.Equal("value-1", (await service.GetCredentialsAsync(provider, config)).Secret);
        Assert.Equal("value-2", (await service.GetCredentialsAsync(provider, config)).Secret);
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.GetCredentialsAsync(provider, config));
        Assert.Equal("provider credential unavailable", error.Message);
        Assert.Null(error.InnerException);
        Assert.Equal("value-4", (await service.GetCredentialsAsync(provider, config)).Secret);
        Assert.Equal(4, calls);
    }

    [Fact]
    public async Task ConcurrentRequestsFetchIndependently()
    {
        var calls = 0;
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var provider = new TestProvider(async cancellation =>
        {
            var call = Interlocked.Increment(ref calls);
            await release.Task.WaitAsync(cancellation);
            return new("apiKey", Secret: "value-" + call);
        });
        var service = new CredentialTokenService();
        var requests = Enumerable.Range(0, 3)
            .Select(_ => service.GetCredentialsAsync(provider, new AppConfig())).ToArray();
        try { Assert.Equal(3, calls); }
        finally { release.TrySetResult(); }
        Assert.Equal(3, (await Task.WhenAll(requests)).Select(value => value.Secret).Distinct().Count());
    }

    [Fact]
    public async Task CallerCancellationCancelsOnlyItsCredentialFetch()
    {
        CancellationToken observed = default;
        var provider = new TestProvider(async cancellation =>
        {
            observed = cancellation;
            await Task.Delay(Timeout.InfiniteTimeSpan, cancellation);
            return new("apiKey", Secret: "unused");
        });
        var service = new CredentialTokenService();
        using var waiter = new CancellationTokenSource();
        var pending = service.GetCredentialsAsync(provider, new AppConfig(), waiter.Token);
        waiter.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        Assert.True(observed.IsCancellationRequested);
    }

    [Fact]
    public async Task AcquisitionDeadlineRejectsLateResultsWithoutBlockingTheNextRequest()
    {
        CancellationToken observed = default;
        var late = new TaskCompletionSource<ProviderCredentials>(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var provider = new TestProvider(cancellation =>
        {
            observed = cancellation;
            return ++calls == 1 ? late.Task : Task.FromResult(new ProviderCredentials("apiKey", Secret: "new"));
        });
        var service = new CredentialTokenService();
        var elapsed = Stopwatch.StartNew();
        try
        {
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() =>
                service.GetCredentialsAsync(provider, new AppConfig()));
            Assert.Equal("provider credential unavailable", error.Message);
            Assert.InRange(elapsed.Elapsed.TotalSeconds, 2, 8);
            Assert.True(observed.IsCancellationRequested);
        }
        finally { late.TrySetResult(new("apiKey", Secret: "late")); }
        Assert.Equal("new", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task OAuthCallsReusableSdkCredentialsForEveryRequestWithoutPrefetchingAssertions()
    {
        var identityCalls = 0;
        var providerCalls = 0;
        var identityInstances = 0;
        var credentialInstances = 0;
        var provider = new SopranoProvider(
            _ =>
            {
                identityInstances++;
                return new Token((_, _) =>
                {
                    identityCalls++;
                    return ValueTask.FromResult(new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1)));
                });
            },
            (_, _, assertion) =>
            {
                credentialInstances++;
                return new Token(async (_, cancellation) =>
                {
                    if (++providerCalls == 1) Assert.Equal("assertion", await assertion(cancellation));
                    return new("token-" + providerCalls, DateTimeOffset.UtcNow.AddHours(1));
                });
            });
        var service = new CredentialTokenService();
        Assert.Equal(0, identityInstances);
        Assert.Equal("token-1", (await service.GetCredentialsAsync(provider, OAuthConfig())).AccessToken);
        Assert.Equal("token-2", (await service.GetCredentialsAsync(provider, OAuthConfig())).AccessToken);
        Assert.Equal(2, providerCalls);
        Assert.Equal(1, identityCalls);
        Assert.Equal(1, identityInstances);
        Assert.Equal(1, credentialInstances);
    }

    [Fact]
    public async Task RealAzureIdentitySdkRetainsItsTokenCache()
    {
        var identityCalls = 0;
        using var transport = new TokenTransport();
        using var client = new HttpClient(transport);
        var provider = new SopranoProvider(
            _ => new Token((_, _) =>
            {
                identityCalls++;
                return ValueTask.FromResult(new AccessToken("synthetic-assertion", DateTimeOffset.UtcNow.AddHours(1)));
            }),
            (tenant, application, assertion) => new ClientAssertionCredential(tenant, application, assertion,
                new ClientAssertionCredentialOptions
                {
                    Transport = new HttpClientTransport(client),
                    DisableInstanceDiscovery = true,
                    Retry = { MaxRetries = 0 },
                }));
        var service = new CredentialTokenService();
        var config = OAuthConfig();
        Assert.Equal("synthetic-token", (await service.GetCredentialsAsync(provider, config)).AccessToken);
        var results = await Task.WhenAll(Enumerable.Range(0, 10)
            .Select(_ => service.GetCredentialsAsync(provider, config)));
        Assert.All(results, value => Assert.Equal("synthetic-token", value.AccessToken));
        Assert.Equal(1, transport.TokenCalls);
        Assert.Equal(1, identityCalls);
    }

    [Fact]
    public async Task InvalidConfigurationDoesNotPoisonLaterAcquisition()
    {
        var instances = 0;
        var provider = new SopranoProvider(
            _ => new Token((_, _) => throw new InvalidOperationException("Unneeded assertion")),
            (_, _, _) =>
            {
                instances++;
                return new Token((_, _) =>
                    ValueTask.FromResult(new AccessToken("provider", DateTimeOffset.UtcNow.AddHours(1))));
            });
        var service = new CredentialTokenService();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            service.GetCredentialsAsync(provider, OAuthConfig(scope: "")));
        Assert.Equal(0, instances);
        Assert.Equal("provider", (await service.GetCredentialsAsync(provider, OAuthConfig())).AccessToken);
        Assert.Equal(1, instances);
    }

    private static AppConfig OAuthConfig(string scope = "api://provider/.default") => new()
    {
        ProviderTenantId = "11111111-1111-1111-1111-111111111111",
        ProviderScope = scope,
        OutboundClientId = "22222222-2222-2222-2222-222222222222",
        OutboundManagedIdentityClientId = "33333333-3333-3333-3333-333333333333",
    };

    private sealed class TestProvider(
        Func<CancellationToken, Task<ProviderCredentials>> fetch) : PhoneProviderBase
    {
        public override string Name => "provider";
        public override string AuthenticationMode => "apiKey";
        public override Task<ProviderCredentials> FetchCredentialsAsync(
            AppConfig config, CancellationToken cancellationToken = default) => fetch(cancellationToken);
        public override Task<ProviderResult> SendOtpAsync(
            string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credentials,
            IEnv env, HttpClient client, int timeoutMs, ILogger? logger = null) =>
            throw new NotSupportedException();
    }

    private sealed class Token(
        Func<TokenRequestContext, CancellationToken, ValueTask<AccessToken>> acquire) : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken cancellation) =>
            throw new InvalidOperationException("Synchronous acquisition was not expected");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken cancellation) =>
            acquire(context, cancellation);
    }

    private sealed class TokenTransport : HttpMessageHandler
    {
        public int TokenCalls { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            string body;
            if (request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath.EndsWith("/oauth2/v2.0/token"))
            {
                TokenCalls++;
                body = """{"access_token":"synthetic-token","token_type":"Bearer","expires_in":3600}""";
            }
            else if (request.Method == HttpMethod.Get && request.RequestUri!.AbsolutePath.EndsWith("/.well-known/openid-configuration"))
            {
                body = """
                    {
                      "token_endpoint":"https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/token",
                      "authorization_endpoint":"https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/oauth2/v2.0/authorize",
                      "issuer":"https://login.microsoftonline.com/11111111-1111-1111-1111-111111111111/v2.0"
                    }
                    """;
            }
            else throw new InvalidOperationException("Unexpected SDK request");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }
}
