using System.Diagnostics;
using System.Net;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Identity;
using Epp.Otp.Providers;
using Microsoft.Extensions.Logging;
using Microsoft.Identity.Client;
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
        var error = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
            service.GetCredentialsAsync(provider, config));
        Assert.Equal("provider credential unavailable", error.Message);
        Assert.Equal("key_vault", error.CredentialStage);
        Assert.Equal("credential_unavailable", error.CredentialFailure);
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
            var error = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
                service.GetCredentialsAsync(provider, new AppConfig()));
            Assert.Equal("provider credential unavailable", error.Message);
            Assert.InRange(elapsed.Elapsed.TotalSeconds, 2, 8);
            Assert.Equal("key_vault", error.CredentialStage);
            Assert.Equal("timeout", error.CredentialFailure);
            Assert.True(observed.IsCancellationRequested);
        }
        finally { late.TrySetResult(new("apiKey", Secret: "late")); }
        Assert.Equal("new", (await service.GetCredentialsAsync(provider, new AppConfig())).Secret);
        Assert.Equal(2, calls);
    }

    [Theory]
    [InlineData("soprano")]
    [InlineData("infobip")]
    public async Task OAuthCallsReusableSdkCredentialsForEveryRequestWithoutPrefetchingAssertions(string providerName)
    {
        var identityCalls = 0;
        var providerCalls = 0;
        var identityInstances = 0;
        var credentialInstances = 0;
        var provider = CreateOAuthProvider(providerName,
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

    [Theory]
    [InlineData("soprano")]
    [InlineData("infobip")]
    public async Task RealAzureIdentitySdkRetainsItsTokenCache(string providerName)
    {
        var identityCalls = 0;
        using var transport = new TokenTransport();
        using var client = new HttpClient(transport);
        var provider = CreateOAuthProvider(providerName,
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

    [Theory]
    [InlineData("soprano")]
    [InlineData("infobip")]
    public async Task InvalidConfigurationDoesNotPoisonLaterAcquisition(string providerName)
    {
        var instances = 0;
        var provider = CreateOAuthProvider(providerName,
            _ => new Token((_, _) => throw new InvalidOperationException("Unneeded assertion")),
            (_, _, _) =>
            {
                instances++;
                return new Token((_, _) =>
                    ValueTask.FromResult(new AccessToken("provider", DateTimeOffset.UtcNow.AddHours(1))));
            });
        var service = new CredentialTokenService();
        var failure = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
            service.GetCredentialsAsync(provider, OAuthConfig(scope: "")));
        Assert.Equal("configuration", failure.CredentialStage);
        Assert.Equal("configuration_invalid", failure.CredentialFailure);
        Assert.Equal(0, instances);
        Assert.Equal("provider", (await service.GetCredentialsAsync(provider, OAuthConfig())).AccessToken);
        Assert.Equal(1, instances);
    }

    [Theory]
    [InlineData("70025", "federated_credential_missing")]
    [InlineData("70021", "federated_credential_mismatch")]
    [InlineData("700016", "provider_application_not_found")]
    public async Task RealSdkErrorsKeepOnlyTheirSafeDiagnostic(string code, string expected)
    {
        using var transport = new TokenTransport { FailureCode = code };
        using var client = new HttpClient(transport);
        var provider = CreateOAuthProvider("soprano",
            _ => new Token((_, _) => ValueTask.FromResult(new AccessToken("PRIVATE-ASSERTION", DateTimeOffset.UtcNow.AddHours(1)))),
            (tenant, application, assertion) => new ClientAssertionCredential(tenant, application, assertion,
                new ClientAssertionCredentialOptions
                {
                    Transport = new HttpClientTransport(client), DisableInstanceDiscovery = true,
                    Retry = { MaxRetries = 0 }, Diagnostics = { IsLoggingEnabled = false },
                }));
        var error = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
            new CredentialTokenService().GetCredentialsAsync(provider, OAuthConfig()));
        Assert.Equal("provider_token_exchange", error.CredentialStage);
        Assert.Equal(expected, error.CredentialFailure);
        Assert.Equal(code, error.AadstsCode);
        Assert.Null(error.InnerException);
        Assert.Empty(error.Data);
        Assert.DoesNotContain("PRIVATE", error.ToString());
        Assert.Equal(1, transport.TokenCalls);
    }

    [Fact]
    public void ClassificationIsBoundedAndDoesNotExposeUnrecognizedValues()
    {
        var sdk = new MsalServiceException("invalid_client", "AADSTS700016: PRIVATE")
        {
            ResponseBody = """{"error_codes":[70025],"error_description":"PRIVATE"}""",
        };
        var failure = CredentialResolutionException.From(new Exception("AADSTS700016: PRIVATE", sdk), CredentialStage.ProviderTokenExchange);
        Assert.Equal("federated_credential_missing", failure.CredentialFailure);
        Assert.Equal("70025", failure.AadstsCode);
        foreach (var text in new[] { "PRIVATE", "70025", "AADSTS999999: PRIVATE", "AADSTS700211: PRIVATE", "AADSTS70025suffix" })
        {
            var unknown = CredentialResolutionException.From(new Exception(text), CredentialStage.ProviderTokenExchange);
            Assert.Equal("credential_unavailable", unknown.CredentialFailure);
            Assert.Null(unknown.AadstsCode);
        }
        var identity = CredentialResolutionException.From(new Exception("AADSTS700016: PRIVATE"), CredentialStage.ManagedIdentity);
        Assert.Equal("credential_unavailable", identity.CredentialFailure);
        Assert.Same(identity, CredentialResolutionException.From(new Exception("wrapper", identity)));
        Exception deep = new Exception("AADSTS70025: PRIVATE");
        for (var i = 0; i < 10; i++) deep = new Exception("wrapper", deep);
        Assert.Null(CredentialResolutionException.From(deep, CredentialStage.ProviderTokenExchange).AadstsCode);
    }

    [Fact]
    public async Task ParallelFailuresKeepIndependentIdentityAndExchangeStages()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        var provider = CreateOAuthProvider("infobip",
            _ => new Token(async (_, _) =>
            {
                if (Interlocked.Increment(ref calls) == 1)
                {
                    await release.Task;
                    throw new AuthenticationFailedException("PRIVATE-IDENTITY-ERROR");
                }
                return new("PRIVATE-ASSERTION", DateTimeOffset.UtcNow.AddHours(1));
            }),
            (_, _, assertion) => new Token(async (_, cancellation) =>
            {
                await assertion(cancellation);
                throw new AuthenticationFailedException("AADSTS70025: PRIVATE-EXCHANGE-ERROR");
            }));
        var service = new CredentialTokenService();
        var first = service.GetCredentialsAsync(provider, OAuthConfig());
        try
        {
            var exchange = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
                service.GetCredentialsAsync(provider, OAuthConfig()));
            Assert.Equal("provider_token_exchange", exchange.CredentialStage);
            Assert.Equal("federated_credential_missing", exchange.CredentialFailure);
        }
        finally { release.TrySetResult(); }
        var identity = await Assert.ThrowsAsync<CredentialResolutionException>(() => first);
        Assert.Equal("managed_identity", identity.CredentialStage);
        Assert.Equal("credential_unavailable", identity.CredentialFailure);
        Assert.Null(identity.AadstsCode);
    }

    [Theory]
    [InlineData(true, "managed_identity")]
    [InlineData(false, "provider_token_exchange")]
    public async Task DeadlineKeepsTheBlockedCredentialHop(bool blockIdentity, string expectedStage)
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var provider = CreateOAuthProvider("soprano",
            _ => new Token(async (_, _) =>
            {
                if (blockIdentity) await release.Task;
                return new("PRIVATE-ASSERTION", DateTimeOffset.UtcNow.AddHours(1));
            }),
            (_, _, assertion) => new Token(async (_, cancellation) =>
            {
                await assertion(cancellation);
                if (!blockIdentity) await release.Task;
                return new("PRIVATE-TOKEN", DateTimeOffset.UtcNow.AddHours(1));
            }));
        try
        {
            var error = await Assert.ThrowsAsync<CredentialResolutionException>(() =>
                new CredentialTokenService().GetCredentialsAsync(provider, OAuthConfig()));
            Assert.Equal(expectedStage, error.CredentialStage);
            Assert.Equal("timeout", error.CredentialFailure);
            Assert.Null(error.AadstsCode);
        }
        finally { release.TrySetResult(); }
    }

    private static PhoneProviderBase CreateOAuthProvider(
        string name, Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential) => name switch
    {
        "soprano" => new SopranoProvider(createIdentity, createCredential),
        "infobip" => new InfobipProvider(createIdentity, createCredential),
        _ => throw new ArgumentException("Unexpected OAuth provider", nameof(name)),
    };

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
        public string? FailureCode { get; init; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            string body;
            var status = HttpStatusCode.OK;
            if (request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath.EndsWith("/oauth2/v2.0/token"))
            {
                TokenCalls++;
                body = """{"access_token":"synthetic-token","token_type":"Bearer","expires_in":3600}""";
                if (FailureCode is { } code)
                {
                    status = HttpStatusCode.BadRequest;
                    body = JsonSerializer.Serialize(new
                    {
                        error = "invalid_client", error_codes = new[] { int.Parse(code) },
                        error_description = $"AADSTS{code}: PRIVATE-RESPONSE PRIVATE-ASSERTION PRIVATE-TOKEN",
                    });
                }
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
            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            });
        }
    }
}
