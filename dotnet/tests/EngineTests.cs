using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Epp.Otp.Providers;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class EngineTests
{
    private const string Phone = "+15551234567";
    private const string Message = "  Your code is 918273.\nDo not share.  ";
    private const string Nonce = "private-ack-nonce";
    private const string Kid = "private-jwe-kid";
    private const string Correlation = "private-correlation";
    private const string PrivateError = "private key/provider error: +15551234567 code 918273";

    private static void ConfigureSoprano(HandlerRig rig)
    {
        rig.Env["EPP_PROVIDER_NAME"] = "soprano";
        rig.Env["EPP_PROVIDER_AUTH_MODE"] = "oauth";
        rig.Env["EPP_PROVIDER_CHANNEL"] = "sms";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/full/send/";
        rig.Env["EPP_PROVIDER_TENANT_ID"] = "provider-tenant";
        rig.Env["EPP_PROVIDER_SCOPE"] = "api://provider/.default";
        rig.Env["EPP_OUTBOUND_CLIENT_ID"] = "calling-application";
        rig.Env["EPP_OUTBOUND_MI_CLIENT_ID"] = "outbound-identity";
        rig.Env["AZURE_CLIENT_ID"] = "different-vault-identity";
        rig.Http.Respond = _ => Task.FromResult(Json(201, "{\"status\":\"ENROUTE\"}"));
    }

    [Fact]
    public async Task SopranoOAuthUsesSetupIdentitiesScopeAndOneBoundedExchange()
    {
        var scopes = new List<string>();
        var identities = new List<string>();
        var applications = new List<(string Tenant, string Application)>();
        CancellationToken outerCancellation = default;
        using var rig = new HandlerRig(identity =>
        {
            identities.Add(identity);
            return new TestTokenCredential((context, cancellation) =>
            {
                Assert.Equal("api://AzureADTokenExchange/.default", Assert.Single(context.Scopes));
                Assert.Equal(outerCancellation, cancellation);
                return ValueTask.FromResult(new AccessToken("private-assertion", DateTimeOffset.UtcNow.AddHours(1)));
            });
        }, (tenant, application, assertion) =>
        {
            applications.Add((tenant, application));
            return new TestTokenCredential(async (context, cancellation) =>
            {
                Assert.True(cancellation.CanBeCanceled);
                outerCancellation = cancellation;
                scopes.Add(Assert.Single(context.Scopes));
                Assert.Equal("private-assertion", await assertion(cancellation));
                return new AccessToken("private-provider-token", DateTimeOffset.UtcNow.AddHours(1));
            });
        });
        ConfigureSoprano(rig);
        AssertAccepted(await rig.Invoke("evaluation"));
        Assert.Empty(applications);
        foreach (var channel in new[] { "sms", "voice" })
        {
            rig.Env["EPP_PROVIDER_CHANNEL"] = channel;
            AssertAccepted(await rig.Invoke(channel: channel, deliveryOverrides: JsonSerializer.SerializeToElement(new
            {
                providerJwt = "FORGED-PAYLOAD", locale = "fr-FR",
                textToVoice = new { beforePasswordText = "ignored", password = "001234", language = "override" },
            })));
            Assert.Equal("Bearer private-provider-token", rig.Http.Headers["Authorization"]);
            Assert.DoesNotContain("X-MEMS-API-ID", rig.Http.Headers.Keys);
            Assert.DoesNotContain("X-MEMS-API-Key", rig.Http.Headers.Keys);
            Assert.DoesNotContain("FORGED", rig.Http.Body!);
            if (channel == "voice")
            {
                using var body = JsonDocument.Parse(rig.Http.Body!);
                var speech = body.RootElement.GetProperty("voice").GetProperty("text2voice");
                Assert.Equal("  Your code is ", speech.GetProperty("beforePasswordText").GetString());
                Assert.Equal("918273", speech.GetProperty("password").GetString());
                Assert.Equal(".\nDo not share.  ", speech.GetProperty("afterPasswordText").GetString());
                Assert.Equal("fr-FR", speech.GetProperty("language").GetString());
                Assert.Equal(1, speech.GetProperty("gender").GetInt32());
                Assert.Equal(2, speech.GetProperty("loop").GetInt32());
            }
        }
        rig.Env["EPP_PROVIDER_CHANNEL"] = "sms";
        rig.Env["EPP_PROVIDER_SCOPE"] = "api://second/.default";
        AssertAccepted(await rig.Invoke());
        Assert.Single(applications);
        Assert.Equal(new[] { "api://provider/.default", "api://provider/.default", "api://second/.default" }, scopes);
        rig.Env["EPP_OUTBOUND_CLIENT_ID"] = "second-application";
        AssertAccepted(await rig.Invoke());
        Assert.Equal(new[] { ("provider-tenant", "calling-application"), ("provider-tenant", "second-application") }, applications);
        Assert.All(identities, identity => Assert.Equal("outbound-identity", identity));
        Assert.Equal(4, rig.Http.Calls);
        Assert.Equal(0, rig.Secrets.Calls);
        Assert.DoesNotContain("private-provider-token", string.Join("\n", rig.Log.Messages));
        var credential = new ProviderCredential("oauth", AccessToken: "private-provider-token");
        Assert.DoesNotContain("private-provider-token", JsonSerializer.Serialize(credential) + credential);
    }

    [Theory]
    [InlineData(true, "", 3600)]
    [InlineData(true, "private-assertion", 5)]
    [InlineData(false, " ", 3600)]
    [InlineData(false, "private-token", -1)]
    public async Task SopranoOAuthRejectsUnusableTokensBeforeProviderIo(bool invalidAssertion, string token, int lifetime)
    {
        var invalid = new AccessToken(token, DateTimeOffset.UtcNow.AddSeconds(lifetime));
        using var rig = new HandlerRig(_ => new TestTokenCredential((_, _) => ValueTask.FromResult(invalidAssertion
            ? invalid : new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1)))),
            (_, _, assertion) => new TestTokenCredential(async (_, cancellation) =>
            {
                await assertion(cancellation);
                return invalid;
            }));
        ConfigureSoprano(rig);
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal((0, 0), (rig.Http.Calls, rig.Secrets.Calls));
    }

    [Fact]
    public async Task SopranoOAuthCancellationAndRejectionNeverFallBackOrRetry()
    {
        CancellationToken observed = default;
        var waitForCancellation = true;
        using var rig = new HandlerRig(_ => new TestTokenCredential(async (_, cancellation) =>
        {
            if (waitForCancellation)
            {
                observed = cancellation;
                await Task.Delay(Timeout.Infinite, cancellation);
            }
            return new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1));
        }), (_, _, assertion) => new TestTokenCredential(async (_, cancellation) =>
        {
            await assertion(cancellation);
            return new AccessToken("token", DateTimeOffset.UtcNow.AddHours(1));
        }));
        ConfigureSoprano(rig);
        AssertFailure(rig, await rig.Invoke().WaitAsync(TimeSpan.FromSeconds(10)), 502);
        Assert.True(observed.IsCancellationRequested);
        Assert.Equal((0, 0), (rig.Http.Calls, rig.Secrets.Calls));
        waitForCancellation = false;
        rig.Http.Respond = _ => Task.FromResult(Json(401, "{\"status\":\"REJECTED\"}"));
        AssertFailure(rig, await rig.Invoke(), 401);
        Assert.Equal((1, 0), (rig.Http.Calls, rig.Secrets.Calls));
    }

    private sealed class TestTokenCredential(Func<TokenRequestContext, CancellationToken, ValueTask<AccessToken>> acquire) : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken cancellation) =>
            throw new InvalidOperationException("Synchronous acquisition not expected");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken cancellation) => acquire(context, cancellation);
    }

    [Fact]
    public async Task HandlerUsesInjectedConfigAwaitsAcceptanceAndKeepsLogsPrivate()
    {
        using var rig = new HandlerRig();
        Assert.Equal("infobip", AppConfig.Read(rig.Env).ProviderName);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Http.Respond = cancellation =>
        {
            entered.TrySetResult();
            return release.Task.WaitAsync(cancellation);
        };
        var pending = rig.Invoke(channel: "sms");
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(pending.IsCompleted);
        }
        finally
        {
            release.TrySetResult(Json(200, "{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":\"PENDING\"}}]}"));
        }
        AssertAccepted(await pending);
        using var body = JsonDocument.Parse(rig.Http.Body!);
        Assert.Equal(Message, body.RootElement.GetProperty("messages")[0].GetProperty("content").GetProperty("text").GetString());
        Assert.Equal(1, rig.Http.Calls);
        var log = Assert.Single(rig.Log.Messages);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Correlation)))[..16].ToLowerInvariant();
        Assert.Contains("CorrelationId=" + hash, log);
        foreach (var value in new[] { Phone, "918273", "001234", Nonce, Correlation, "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, log);
    }

    [Fact]
    public void VoiceAllowsEmptyIntroAndKeepsDebugOutputPrivate()
    {
        var voice = new TextToVoice("", "001234", "en-US");
        Assert.True(voice.IsComplete);
        Assert.Equal("TextToVoice", voice.ToString());
    }

    [Fact]
    public async Task FailedHttpCannotAcknowledgeAnAcceptedBodyOrLeakProviderText()
    {
        using var rig = new HandlerRig();
        rig.Http.Respond = _ => Task.FromResult(Json(503,
            JsonSerializer.Serialize(new { status = "ACCEPTED", description = PrivateError })));
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal(1, rig.Http.Calls);
    }

    [Fact]
    public async Task ResponseBodyTimeoutCancelsWithoutRetryOrSuccessNonce()
    {
        using var rig = new HandlerRig();
        using var body = new SlowBody();
        rig.Env["EPP_PROVIDER_TIMEOUT_MS"] = "200";
        rig.Http.Respond = _ => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) });
        AssertFailure(rig, await rig.Invoke().WaitAsync(TimeSpan.FromSeconds(5)), 504);
        Assert.True(body.SawCancellationToken);
        Assert.Equal(1, rig.Http.Calls);
    }

    [Fact]
    public async Task MissingIdentityOrKeyFailsClosedBeforeHttp()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "telesign";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://verify.telesign.com/epp/sms";
        rig.Env["EPP_PROVIDER_AUTH_MODE"] = "apiKey";
        rig.Secrets.Identity = "";
        AssertFailure(rig, await rig.Invoke(), 502);
        rig.Secrets.Identity = "private-api-id";
        rig.Secrets.Secret = "";
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal(0, rig.Http.Calls);
    }

    [Fact]
    public async Task BaseAndFinalVoiceUrlsMustBeHttpsBeforeHttp()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "sinch";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "http://provider.example";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example:0";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example";
        rig.Env["SINCH_VOICE_ENDPOINT"] = "http://voice.example";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        Assert.Equal(0, rig.Http.Calls);
    }

    [Fact]
    public async Task EvaluationValidatesRealJweWithoutProviderConfiguration()
    {
        using var rig = new HandlerRig();
        rig.Env.Clear();
        rig.Env["EPP_ENCRYPTION_KEY_ID"] = "configured-key-id";
        AssertAccepted(await rig.Invoke("evaluation", tenantId: "untrusted-body-tenant"));
        Assert.Equal("encryption_key_id_mismatch",
            Assert.Single(rig.Log.Entries, entry => entry.Level == LogLevel.Warning).Message);
        foreach (var value in new[] { Kid, "configured-key-id", Phone, "918273", Nonce, Correlation, "untrusted-body-tenant" })
            Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
        Assert.Equal((1, 0, 0), (rig.Keys.Calls, rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task PrivateKeyErrorsStayGenericAndNeverReachTheProvider()
    {
        using var rig = new HandlerRig();
        rig.Keys.Error = new InvalidOperationException(PrivateError);
        AssertFailure(rig, await rig.Invoke(), 400, "decryption_failed");
        Assert.Equal(0, rig.Http.Calls);
    }

    [Theory]
    [InlineData("{", "decryption_failed", null)]
    [InlineData("null", "bad_request", "incomplete delivery context")]
    [InlineData("[]", "bad_request", "incomplete delivery context")]
    [InlineData("{\"nonce\":123,\"phoneNumber\":\"phone\",\"message\":\"message\"}", "bad_request", "incomplete delivery context")]
    [InlineData("{\"nonce\":\"nonce\",\"phoneNumber\":false,\"message\":\"message\"}", "bad_request", "incomplete delivery context")]
    [InlineData("{\"nonce\":\"nonce\",\"phoneNumber\":\"phone\",\"message\":{}}", "bad_request", "incomplete delivery context")]
    public async Task AuthenticatedPlaintextDistinguishesInvalidJsonFromIncompleteContext(string plaintext, string error, string? reason)
    {
        using var rig = new HandlerRig();
        var result = await rig.Invoke(plaintext: plaintext);
        AssertFailure(rig, result, 400, error);
        var body = JsonSerializer.SerializeToElement(result.Value);
        if (reason is null) Assert.False(body.TryGetProperty("reason", out _));
        else Assert.Equal(reason, body.GetProperty("reason").GetString());
        Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
        Assert.Equal((1, 0, 0), (rig.Keys.Calls, rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task SharedInvalidRequestsReturnSafeReasonsBeforeProviderIo()
    {
        using var rig = new HandlerRig();
        using var fixtures = ReadContractFixtures();
        foreach (var fixture in fixtures.RootElement.GetProperty("badRequests").EnumerateArray())
        {
            var payload = new Dictionary<string, object?>
            {
                ["type"] = EnvelopeParser.EnvelopeType, ["channel"] = 1, ["mode"] = 1,
                ["encryptedDeliveryContext"] = "unused", ["ttlSeconds"] = 60,
            };
            if (fixture.TryGetProperty("overrides", out var overrides))
                foreach (var property in overrides.EnumerateObject()) payload[property.Name] = property.Value;
            var raw = fixture.TryGetProperty("rawBody", out var rawBody) ? rawBody.GetString()! : JsonSerializer.Serialize(payload);
            var result = await rig.InvokeRaw(raw);
            AssertFailure(rig, result, 400, "bad_request");
            var body = JsonSerializer.SerializeToElement(result.Value);
            Assert.False(string.IsNullOrEmpty(body.GetProperty("requestId").GetString()));
            Assert.Equal(3, body.EnumerateObject().Count());
            Assert.Equal(fixture.GetProperty("reason").GetString(), body.GetProperty("reason").GetString());
        }
        Assert.Equal(0, rig.Keys.Calls);
        foreach (var changes in fixtures.RootElement.GetProperty("incompleteContexts").EnumerateArray())
        {
            var result = await rig.Invoke("evaluation", deliveryOverrides: changes);
            AssertFailure(rig, result, 400, "bad_request");
            var body = JsonSerializer.SerializeToElement(result.Value);
            Assert.Equal(4, body.EnumerateObject().Count());
            Assert.Equal("incomplete delivery context", body.GetProperty("reason").GetString());
            Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
        }
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task SharedJwePolicyPermitsOnlyRsaOaep256WithA256Gcm()
    {
        using var rig = new HandlerRig();
        using var fixtures = ReadContractFixtures();
        foreach (var fixture in fixtures.RootElement.GetProperty("jwe").EnumerateArray())
        {
            var alg = Enum.Parse<Jose.JweAlgorithm>(fixture.GetProperty("alg").GetString()!.Replace('-', '_'));
            var enc = Enum.Parse<Jose.JweEncryption>(fixture.GetProperty("enc").GetString()!.Replace('-', '_'));
            var accepted = fixture.GetProperty("accepted").GetBoolean();
            var result = await rig.Invoke("evaluation", algorithm: alg, encryption: enc);
            if (accepted) AssertAccepted(result);
            else
            {
                AssertFailure(rig, result, 400, "decryption_failed");
                var body = JsonSerializer.SerializeToElement(result.Value);
                Assert.Equal(3, body.EnumerateObject().Count());
                Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
            }
        }
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    private static JsonDocument ReadContractFixtures() =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "contract.json")));

    private static void AssertAccepted(ObjectResult result)
    {
        Assert.Equal(200, result.StatusCode);
        Assert.IsType<EndpointSuccessResponse>(result.Value);
        Assert.Equal(JsonSerializer.Serialize(new { nonce = Nonce, correlationId = Correlation, providerStatus = "accepted" }),
            JsonSerializer.Serialize(result.Value));
    }

    private static void AssertFailure(HandlerRig rig, ObjectResult result, int status, string error = "provider_delivery_failed")
    {
        Assert.Equal(status, result.StatusCode);
        Assert.IsType<EndpointErrorResponse>(result.Value);
        var body = JsonSerializer.SerializeToElement(result.Value);
        Assert.Equal(error, body.GetProperty("error").GetString());
        Assert.False(body.TryGetProperty("nonce", out _));
        var output = body.GetRawText() + string.Join("\n", rig.Log.Messages);
        foreach (var value in new[] { PrivateError, Phone, "918273", Nonce })
            Assert.DoesNotContain(value, output);
    }

    private static HttpResponseMessage Json(int status, string body) =>
        new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private sealed class HandlerRig : IDisposable
    {
        private readonly SendOtp _function;
        public TestEnv Env { get; }
        public TestSecrets Secrets { get; } = new();
        public TestHttp Http { get; } = new();
        public TestKeys Keys { get; } = new();
        public CapturingLogger Log { get; } = new();
        public HandlerRig(Func<string, TokenCredential>? createIdentity = null,
            Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential>? createOAuth = null)
        {
            Env = new TestEnv
            {
                ["EPP_PROVIDER_NAME"] = "infobip",
                ["EPP_PROVIDER_ENDPOINT"] = "https://provider.example",
                ["EPP_PROVIDER_TIMEOUT_MS"] = "2500",
            };
            var registry = new ProviderRegistry(new IProviderAdapter[]
                { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(), new SinchProvider() });
            var engine = createIdentity is null ? new DispatchEngine(registry, Secrets, Http, Env)
                : new DispatchEngine(registry, Secrets, Http, Env, createIdentity, createOAuth!);
            _function = new SendOtp(engine,
                new JweDecryptor(Keys), Env, Log);
        }
        public async Task<ObjectResult> Invoke(object? mode = null, string channel = "sms", string? tenantId = null,
            Jose.JweAlgorithm algorithm = Jose.JweAlgorithm.RSA_OAEP_256,
            Jose.JweEncryption encryption = Jose.JweEncryption.A256GCM, JsonElement? deliveryOverrides = null,
            string? plaintext = null)
        {
            var context = new Dictionary<string, object?> { ["nonce"] = Nonce, ["phoneNumber"] = Phone, ["message"] = Message };
            if (deliveryOverrides is { } changes)
                foreach (var property in changes.EnumerateObject()) context[property.Name] = property.Value;
            var encrypted = Jose.JWT.Encode(plaintext ?? JsonSerializer.Serialize(context), Keys.Rsa, algorithm, encryption,
                extraHeaders: new Dictionary<string, object> { ["kid"] = Kid });
            return await InvokeRaw(JsonSerializer.Serialize(new
            {
                type = EnvelopeParser.EnvelopeType, tenantId, correlationId = Correlation, channel, mode = mode ?? "live",
                ttlSeconds = 60, encryptedDeliveryContext = encrypted,
            }));
        }
        public async Task<ObjectResult> InvokeRaw(string body)
        {
            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(body));
            var request = new DefaultHttpContext().Request;
            request.Method = "POST";
            request.ContentType = "application/json";
            request.Body = stream;
            return Assert.IsAssignableFrom<ObjectResult>(await _function.Run(request));
        }
        public void Dispose() { Keys.Dispose(); Http.Dispose(); }
    }

    private sealed class TestSecrets : ISecretResolver
    {
        public int Calls { get; private set; }
        public string Secret { get; set; } = "private-api-key";
        public string Identity { get; set; } = "private-api-id";
        public Task<string> ResolveAsync(string? name)
        {
            Calls++;
            return Task.FromResult(name == "telesign-customer-id" ? Identity : Secret);
        }
    }

    private sealed class TestHttp : HttpMessageHandler, IHttpClientFactory
    {
        public int Calls { get; private set; }
        public string? Body { get; private set; }
        public Dictionary<string, string> Headers { get; private set; } = new(StringComparer.OrdinalIgnoreCase);
        public Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(Json(200, "{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":\"PENDING\"}}]}"));
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Headers = request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase);
            return await Respond(cancellationToken);
        }
    }

    private sealed class CapturingLogger : ILogger<SendOtp>
    {
        public List<(LogLevel Level, string Message)> Entries { get; } = new();
        public IEnumerable<string> Messages => Entries.Select(entry => entry.Message);
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? error, Func<TState, Exception?, string> formatter) =>
            Entries.Add((level, formatter(state, error) + (error?.ToString() ?? "")));
    }

    // Headers arrive immediately; only reading the response body stalls until cancellation.
    private sealed class SlowBody : MemoryStream
    {
        public bool SawCancellationToken { get; private set; }
        public SlowBody() : base(new byte[] { 0 }) { }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            SawCancellationToken = cancellationToken.CanBeCanceled;
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }
    }
}
