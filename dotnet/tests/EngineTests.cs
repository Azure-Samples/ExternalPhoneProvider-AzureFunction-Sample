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
    private const string ProviderToken = "eyJhbGciOiJSUzI1NiJ9.eyJ2ZXIiOiIyLjAifQ.c2lnbmF0dXJl";

    [Fact]
    public async Task HandlerUsesInjectedConfigAwaitsAcceptanceAndKeepsLogsPrivate()
    {
        using var rig = new HandlerRig();
        Assert.Equal("soprano", AppConfig.Read(rig.Env).ProviderName);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Http.Respond = cancellation =>
        {
            entered.TrySetResult();
            return release.Task.WaitAsync(cancellation);
        };
        var voice = new { beforePasswordText = " Your code is ", password = "001234", language = "en-US" };
        var pending = rig.Invoke(channel: "voice", deliveryOverrides: JsonSerializer.SerializeToElement(new { textToVoice = voice }));
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(pending.IsCompleted);
        }
        finally
        {
            release.TrySetResult(Json(201, "{\"status\":\"ENROUTE\"}"));
        }
        AssertAccepted(await pending);
        using var body = JsonDocument.Parse(rig.Http.Body!);
        Assert.False(body.RootElement.TryGetProperty("text", out _));
        Assert.Equal(JsonSerializer.Serialize(voice), body.RootElement.GetProperty("voice").GetProperty("text2voice").GetRawText());
        Assert.Equal("voice", body.RootElement.GetProperty("messageTypes")[0].GetString());
        Assert.Equal("private-api-id", rig.Http.Headers["X-MEMS-API-ID"]);
        Assert.Equal("private-api-key", rig.Http.Headers["X-MEMS-API-Key"]);
        Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        Assert.Equal(1, rig.Http.Calls);
        var log = Assert.Single(rig.Log.Messages);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Correlation)))[..16].ToLowerInvariant();
        Assert.Contains("CorrelationId=" + hash, log);
        foreach (var value in new[] { Phone, "918273", "001234", Nonce, Correlation, "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, log);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{}")]
    [InlineData("{\"beforePasswordText\":\"\",\"password\":123,\"language\":\"en\"}")]
    [InlineData("{\"beforePasswordText\":null,\"password\":\"001234\",\"language\":\"en\"}")]
    [InlineData("{\"beforePasswordText\":\"\",\"password\":\"001234\",\"language\":\" \"}")]
    public async Task IncompleteVoiceFailsBeforeSecretsOrHttp(string speech)
    {
        using var rig = new HandlerRig();
        var overrides = JsonSerializer.SerializeToElement(new { textToVoice = JsonSerializer.Deserialize<JsonElement>(speech) });
        AssertFailure(rig, await rig.Invoke(channel: "voice", deliveryOverrides: overrides), 400);
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public void VoiceAllowsEmptyIntroAndKeepsDebugOutputPrivate()
    {
        var voice = new TextToVoice("", "001234", "en-US");
        Assert.True(voice.IsComplete);
        Assert.Equal("TextToVoice", voice.ToString());
    }

    [Theory]
    [InlineData("sms", "true")]
    [InlineData("voice", " TRUE ")]
    public async Task OptionalProviderJwtKeepsApiKeysAndStaysOutOfBodyAndLogs(string channel, string? flag)
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = flag;
        var changes = JsonSerializer.SerializeToElement(new { providerJwt = "FORGED-PAYLOAD",
            textToVoice = new { beforePasswordText = "Code", password = "001234", language = "en-US" } });
        AssertAccepted(await rig.Invoke(channel: channel, deliveryOverrides: changes));
        Assert.Equal("private-api-id", rig.Http.Headers["X-MEMS-API-ID"]);
        Assert.Equal("private-api-key", rig.Http.Headers["X-MEMS-API-Key"]);
        Assert.Equal("Bearer " + ProviderToken, rig.Http.Headers["Authorization"]);
        Assert.DoesNotContain(ProviderToken, rig.Http.Body! + string.Join("", rig.Log.Messages));
        Assert.DoesNotContain("FORGED-PAYLOAD", rig.Http.Body!);
        Assert.DoesNotContain("FORGED-INBOUND", JsonSerializer.Serialize(rig.Http.Headers));
        var context = DeliveryContext.FromPayload(changes);
        Assert.DoesNotContain("FORGED-PAYLOAD", JsonSerializer.Serialize(context));
        var credential = new ProviderCredential("apiKey", "key", "id", ProviderToken);
        Assert.DoesNotContain(ProviderToken, credential.ToString() + JsonSerializer.Serialize(credential));
        if (rig.Tokens.Calls > 0)
        {
            Assert.Equal(rig.Env["EPP_PROVIDER_SCOPE"], Assert.Single(rig.Tokens.Scopes!));
            Assert.True(rig.Tokens.HasCancellation);
        }
        Assert.Equal(2, rig.Secrets.Calls);
    }

    [Fact]
    public async Task DisabledJwtIgnoresInboundTokenAndOtherProviders()
    {
        using var rig = new HandlerRig();
        foreach (var flag in new string?[] { null, "false", "1", "yes" })
        {
            rig.Env["EPP_PROVIDER_JWT_ENABLED"] = flag;
            AssertAccepted(await rig.Invoke(deliveryOverrides: JsonSerializer.SerializeToElement(new { providerJwt = "not-a-jwt" })));
            Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        }
        rig.Env["EPP_PROVIDER_NAME"] = "infobip";
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
        rig.Http.Respond = _ => Task.FromResult(Json(200, "{\"messages\":[{\"status\":{\"groupName\":\"PENDING\"}}]}"));
        AssertAccepted(await rig.Invoke(deliveryOverrides: JsonSerializer.SerializeToElement(new { providerJwt = "not-a-jwt" })));
        Assert.Equal("App private-api-key", rig.Http.Headers["Authorization"]);
        Assert.DoesNotContain("not-a-jwt", rig.Http.Body!);
        Assert.Equal(0, rig.Tokens.Calls);
    }

    [Fact]
    public async Task ManagedIdentitySelectionReusesCredentialsWithoutClientSecrets()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
        AssertAccepted(await rig.Invoke());
        Assert.Equal(rig.Env["EPP_PROVIDER_MI_CLIENT_ID"], Assert.Single(rig.TokenIdentities));
        Assert.Equal("api://AzureADTokenExchange/.default", Assert.Single(rig.Assertions.Scopes!));
        Assert.True(rig.Assertions.HasCancellation);
        AssertAccepted(await rig.Invoke());
        Assert.Single(rig.TokenIdentities);
        rig.Env["EPP_PROVIDER_MI_CLIENT_ID"] = "44444444-4444-4444-8444-444444444444";
        AssertAccepted(await rig.Invoke());
        Assert.Equal(2, rig.TokenIdentities.Count);
        Assert.Equal(rig.Env["EPP_PROVIDER_MI_CLIENT_ID"], rig.TokenIdentities[1]);
        rig.Env["EPP_PROVIDER_SCOPE"] = "api://another-provider/.default";
        AssertAccepted(await rig.Invoke());
        Assert.Equal(2, rig.TokenIdentities.Count);
        Assert.Equal(rig.Env["EPP_PROVIDER_SCOPE"], Assert.Single(rig.Tokens.Scopes!));
        Assert.Equal(8, rig.Secrets.Calls);
        Assert.DoesNotContain("private-exchange-assertion", rig.Http.Body! + string.Join("", rig.Http.Headers.Values) + string.Join("", rig.Log.Messages));
    }

    [Fact]
    public async Task MissingFederationSettingsAndUnavailableAssertionsNeverAttachAToken()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
        foreach (var name in new[] { "EPP_PROVIDER_SCOPE", "EPP_PROVIDER_TENANT_ID", "EPP_PROVIDER_APPLICATION_ID", "EPP_PROVIDER_MI_CLIENT_ID" })
        {
            var saved = rig.Env[name];
            rig.Env[name] = " ";
            AssertAccepted(await rig.Invoke());
            Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
            rig.Env[name] = saved;
        }
        Assert.Empty(rig.TokenIdentities);
        rig.Assertions.Token = "";
        AssertAccepted(await rig.Invoke());
        Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        rig.Assertions.Token = "private-exchange-assertion";
        rig.Assertions.ExpiresOn = DateTimeOffset.UtcNow.AddSeconds(-1);
        AssertAccepted(await rig.Invoke());
        Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        rig.Assertions.Error = new InvalidOperationException("PRIVATE-ASSERTION-ERROR");
        AssertAccepted(await rig.Invoke());
        Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        Assert.DoesNotContain("PRIVATE-ASSERTION-ERROR", string.Join("", rig.Log.Messages));
    }

    [Fact]
    public async Task UnavailableAcquiredTokensFallBackAndEvaluationSkipsEntra()
    {
        using var rig = new HandlerRig();
        foreach (var token in new[] { "", " " })
        {
            rig.Tokens.Token = token;
            var changes = JsonSerializer.SerializeToElement(new { providerJwt = ProviderToken });
            rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
            var calls = rig.Http.Calls;
            var secretCalls = rig.Secrets.Calls;
            var tokenCalls = rig.Tokens.Calls;
            AssertAccepted(await rig.Invoke("evaluation", deliveryOverrides: changes));
            Assert.Equal(secretCalls, rig.Secrets.Calls);
            Assert.Equal(tokenCalls, rig.Tokens.Calls);
            AssertAccepted(await rig.Invoke(deliveryOverrides: changes));
            Assert.Equal(calls + 1, rig.Http.Calls);
            Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
            rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "false";
            AssertAccepted(await rig.Invoke(deliveryOverrides: changes));
            Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        }
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
        rig.Tokens.Token = "opaque-access-token-from-entra";
        AssertAccepted(await rig.Invoke());
        Assert.Equal("Bearer opaque-access-token-from-entra", rig.Http.Headers["Authorization"]);
        rig.Tokens.Token = ProviderToken;
        rig.Tokens.ExpiresOn = DateTimeOffset.UtcNow.AddSeconds(-10);
        AssertAccepted(await rig.Invoke());
        Assert.False(rig.Http.Headers.ContainsKey("Authorization"));
        rig.Tokens.Error = new InvalidOperationException("PRIVATE-TOKEN-ERROR");
        AssertAccepted(await rig.Invoke());
        Assert.DoesNotContain("PRIVATE-TOKEN-ERROR", string.Join("", rig.Log.Messages));
    }

    [Fact]
    public async Task ProviderJwtCannotReplaceMissingKeysAndAuthFailureDoesNotRetry()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
        var changes = JsonSerializer.SerializeToElement(new { providerJwt = ProviderToken });
        rig.Secrets.Identity = "";
        AssertFailure(rig, await rig.Invoke(deliveryOverrides: changes), 502);
        rig.Secrets.Identity = "private-api-id";
        rig.Secrets.Secret = "";
        AssertFailure(rig, await rig.Invoke(deliveryOverrides: changes), 502);
        Assert.Equal(0, rig.Http.Calls);
        rig.Secrets.Secret = "private-api-key";
        rig.Http.Respond = _ => Task.FromResult(Json(401, "{\"status\":\"REJECTED\"}"));
        AssertFailure(rig, await rig.Invoke(deliveryOverrides: changes), 401);
        Assert.Equal(1, rig.Http.Calls);
        Assert.DoesNotContain(ProviderToken, string.Join("", rig.Log.Messages));
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
        public TestTokenCredential Tokens { get; } = new();
        public TestTokenCredential Assertions { get; } = new() { Token = "private-exchange-assertion" };
        public List<string?> TokenIdentities { get; } = new();
        public CapturingLogger Log { get; } = new();
        public HandlerRig()
        {
            Env = new TestEnv
            {
                ["EPP_PROVIDER_NAME"] = "soprano",
                ["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/cgpapi",
                ["EPP_PROVIDER_TIMEOUT_MS"] = "2500",
                ["EPP_PROVIDER_SCOPE"] = "api://provider-application-id/.default",
                ["EPP_PROVIDER_TENANT_ID"] = "11111111-1111-4111-8111-111111111111",
                ["EPP_PROVIDER_APPLICATION_ID"] = "22222222-2222-4222-8222-222222222222",
                ["EPP_PROVIDER_MI_CLIENT_ID"] = "33333333-3333-4333-8333-333333333333",
            };
            var registry = new ProviderRegistry(new IProviderAdapter[]
                { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(identity =>
                    {
                        TokenIdentities.Add(identity);
                        return Assertions;
                    }, (tenant, applicationId, assertion) =>
                    {
                        Assert.Equal(Env["EPP_PROVIDER_TENANT_ID"], tenant);
                        Assert.Equal(Env["EPP_PROVIDER_APPLICATION_ID"], applicationId);
                        Tokens.GetAssertion = assertion;
                        return Tokens;
                    }), new SinchProvider() });
            _function = new SendOtp(new DispatchEngine(registry, Secrets, Http, Env),
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
            request.Headers.Authorization = "Bearer FORGED-INBOUND";
            return Assert.IsAssignableFrom<ObjectResult>(await _function.Run(request));
        }
        public void Dispose() { Keys.Dispose(); Http.Dispose(); }
    }

    private sealed class TestTokenCredential : TokenCredential
    {
        public int Calls { get; private set; }
        public string Token { get; set; } = ProviderToken;
        public DateTimeOffset ExpiresOn { get; set; } = DateTimeOffset.UtcNow.AddHours(1);
        public string[]? Scopes { get; private set; }
        public bool HasCancellation { get; private set; }
        public Exception? Error { get; set; }
        public Func<CancellationToken, Task<string>>? GetAssertion { get; set; }
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken cancellation)
        {
            Calls++;
            Scopes = context.Scopes;
            HasCancellation = cancellation.CanBeCanceled;
            if (Error is not null) throw Error;
            return new AccessToken(Token, ExpiresOn);
        }
        public override async ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken cancellation)
        {
            if (GetAssertion is not null) Assert.Equal("private-exchange-assertion", await GetAssertion(cancellation));
            return GetToken(context, cancellation);
        }
    }

    private sealed class TestSecrets : ISecretResolver
    {
        public int Calls { get; private set; }
        public string Secret { get; set; } = "private-api-key";
        public string Identity { get; set; } = "private-api-id";
        public Task<string> ResolveAsync(string? name)
        {
            Calls++;
            return Task.FromResult(name == "soprano-api-id" ? Identity : Secret);
        }
    }

    private sealed class TestHttp : HttpMessageHandler, IHttpClientFactory
    {
        public int Calls { get; private set; }
        public string? Body { get; private set; }
        public Dictionary<string, string> Headers { get; private set; } = new(StringComparer.OrdinalIgnoreCase);
        public Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(Json(201, "{\"status\":\"ACCEPTED\"}"));
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
