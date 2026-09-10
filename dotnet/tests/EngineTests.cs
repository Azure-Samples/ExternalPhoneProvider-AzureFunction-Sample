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
        var pending = rig.Invoke(channel: "voice", deliveryOverrides: ValidVoiceContext());
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
        AssertVoiceBody(body.RootElement);
        Assert.Equal(1, rig.Http.Calls);
        var log = Assert.Single(rig.Log.Messages);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Correlation)))[..16].ToLowerInvariant();
        Assert.Contains("CorrelationId=" + hash, log);
        foreach (var value in new[] { Phone, "918273", Nonce, Correlation, "private-api-key", "private-api-id",
            "012345", "en-GB", "Your code is" })
            Assert.DoesNotContain(value, log);
    }

    [Fact]
    public async Task FailedHttpCannotAcknowledgeLeakProviderTextOrResendWithoutJwt()
    {
        using var rig = new HandlerRig();
        rig.EnableOAuth("apiKey");
        foreach (var status in new[] { 401, 503 })
        {
            var calls = rig.Http.Calls;
            rig.Http.Respond = _ => Task.FromResult(Json(status,
                JsonSerializer.Serialize(new { status = "ACCEPTED", description = PrivateError })));
            AssertFailure(rig, await rig.Invoke(), status == 401 ? 401 : 502);
            Assert.Equal(calls + 1, rig.Http.Calls);
            Assert.Equal("Bearer provider-token", rig.Http.Authorization);
            Assert.Equal(("private-api-id", "private-api-key"), (rig.Http.ApiId, rig.Http.ApiKey));
        }
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
    public async Task MissingOrUnsafeApiKeysFailBeforeOptionalTokensOrHttp()
    {
        using var rig = new HandlerRig();
        rig.EnableOAuth("apiKey");
        foreach (var (key, id) in new[] { ("", "id"), ("key", ""), ("unsafe\r\nkey", "id"), ("key", " ") })
        {
            rig.Secrets.Secret = key;
            rig.Secrets.Identity = id;
            AssertFailure(rig, await rig.Invoke(), 502);
        }
        Assert.Equal(0, rig.Http.Calls);
        Assert.DoesNotContain("oauth-client-secret", rig.Secrets.Names);
        Assert.Empty(rig.Credentials.Credentials);
        Assert.Empty(rig.Credentials.ManagedIdentityIds);
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
        AssertAccepted(await rig.Invoke("evaluation", channel: "voice", tenantId: "untrusted-body-tenant"));
        Assert.Equal("encryption_key_id_mismatch",
            Assert.Single(rig.Log.Entries, entry => entry.Level == LogLevel.Warning).Message);
        foreach (var value in new[] { Kid, "configured-key-id", Phone, "918273", Nonce, Correlation, "untrusted-body-tenant" })
            Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
        Assert.Equal((1, 0, 0), (rig.Keys.Calls, rig.Secrets.Calls, rig.Http.Calls));
        Assert.Empty(rig.Credentials.Credentials);
    }

    [Theory]
    [InlineData(null, null, 200, false)]
    [InlineData(" aPiKeY ", " FaLsE ", 200, false)]
    [InlineData("apiKey", "true", 200, true)]
    [InlineData("oauth2", "false", 502, false)]
    [InlineData("OAuth2", " TrUe ", 200, true)]
    [InlineData("apiKey", "true", 502, false, "infobip")]
    [InlineData("oauth2", "true", 502, false, "telesign")]
    [InlineData("apiKey", "true", 502, false, "sinch")]
    [InlineData("unknown", "false", 502, false)]
    [InlineData("", "true", 502, false)]
    [InlineData("apiKey", "", 502, false)]
    [InlineData("oauth2", "yes", 502, false)]
    public async Task AuthModeAndJwtGateControlHeadersWithoutChangingSmsOrVoice(string? mode, string? flag,
        int status, bool hasToken, string provider = "soprano")
    {
        using var rig = new HandlerRig();
        rig.EnableOAuth(mode);
        rig.Env["EPP_PROVIDER_NAME"] = provider;
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = flag;
        var apiKey = !string.Equals(mode?.Trim(), "oauth2", StringComparison.OrdinalIgnoreCase);
        if (!hasToken && status == 200)
        {
            // Disabled JWT must ignore even explicitly forbidden OAuth settings.
            rig.Env["EPP_PROVIDER_TENANT_ID"] = "common";
            rig.Env["EPP_PROVIDER_CLIENT_SECRET"] = "";
        }
        if (!apiKey) rig.Secrets.Secret = rig.Secrets.Identity = "";
        AssertAccepted(await rig.Invoke("evaluation", channel: "voice"));
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
        Assert.Empty(rig.Credentials.Credentials);
        Assert.Empty(rig.Credentials.ManagedIdentityIds);
        foreach (var channel in new[] { "sms", "voice" })
        {
            var response = await rig.Invoke(channel: channel, deliveryOverrides: ValidVoiceContext());
            if (status != 200)
            {
                AssertFailure(rig, response, status);
                continue;
            }
            AssertAccepted(response);
            Assert.Equal(hasToken ? "Bearer provider-token" : null, rig.Http.Authorization);
            Assert.Equal(apiKey ? "private-api-id" : null, rig.Http.ApiId);
            Assert.Equal(apiKey ? "private-api-key" : null, rig.Http.ApiKey);
            using var body = JsonDocument.Parse(rig.Http.Body!);
            if (channel == "voice") AssertVoiceBody(body.RootElement);
            else
            {
                Assert.Equal(Message, body.RootElement.GetProperty("text").GetString());
                Assert.False(body.RootElement.TryGetProperty("voice", out _));
            }
            Assert.Equal(channel, body.RootElement.GetProperty("messageTypes")[0].GetString());
        }
        Assert.Equal(status == 200 ? 2 : 0, rig.Http.Calls);
        if (hasToken) Assert.Equal(2, Assert.Single(rig.Credentials.Credentials).Requests.Count);
        else Assert.Empty(rig.Credentials.Credentials);
        var names = status != 200 ? Array.Empty<string>() : apiKey
            ? hasToken ? new[] { "soprano-api-key", "soprano-api-id", "oauth-client-secret" }
                : new[] { "soprano-api-key", "soprano-api-id" }
            : new[] { "oauth-client-secret" };
        Assert.Equal(names.Concat(names), rig.Secrets.Names);
        Assert.Empty(rig.Credentials.ManagedIdentityIds);
        Assert.DoesNotContain("provider-token", string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public async Task VoiceCapabilityFailsBeforeCredentialsAndIgnoresOuterVoiceButNotOtherProviders()
    {
        using var rig = new HandlerRig();
        using var fixtures = ReadContractFixtures();
        var outerVoice = ValidVoiceContext().GetProperty("voice");
        rig.EnableOAuth();
        foreach (var changes in fixtures.RootElement.GetProperty("incompleteVoiceContexts").EnumerateArray())
        {
            var response = await rig.Invoke(channel: "voice", deliveryOverrides: changes, outerVoice: outerVoice);
            AssertFailure(rig, response, 400);
            Assert.Equal(3, JsonSerializer.SerializeToElement(response.Value).EnumerateObject().Count());
        }
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
        Assert.Empty(rig.Credentials.Credentials);
        Assert.Empty(rig.Credentials.Identity.Requests);
        rig.Env["EPP_PROVIDER_AUTH_MODE"] = "apiKey";
        rig.Env["EPP_PROVIDER_JWT_ENABLED"] = "false";
        var invalid = JsonSerializer.SerializeToElement(new { voice = new { text2voice = new { password = 12345 } } });
        foreach (var (provider, channel) in new[] { ("soprano", "sms"), ("sinch", "voice") })
        {
            rig.Env["EPP_PROVIDER_NAME"] = provider;
            AssertAccepted(await rig.Invoke(channel: channel, deliveryOverrides: invalid));
            var body = JsonSerializer.Deserialize<JsonElement>(rig.Http.Body!);
            Assert.False(body.TryGetProperty("voice", out _));
            Assert.Equal(Message, (channel == "sms" ? body : body.GetProperty("ttsCallout")).GetProperty("text").GetString());
        }
        Assert.Equal(2, rig.Http.Calls);
    }

    [Theory]
    [InlineData("apiKey")]
    [InlineData("oauth2")]
    public async Task TokenFailuresFallBackOnlyWhenOptionalWithoutLeakingOrResending(string mode)
    {
        using var rig = new HandlerRig();
        rig.EnableOAuth(mode);
        var jwtRequired = mode == "oauth2";
        async Task Check(int requiredStatus)
        {
            var calls = rig.Http.Calls;
            var result = await rig.Invoke().WaitAsync(TimeSpan.FromSeconds(5));
            if (jwtRequired) AssertFailure(rig, result, requiredStatus);
            else
            {
                AssertAccepted(result);
                Assert.Null(rig.Http.Authorization);
                Assert.Equal("private-api-id", rig.Http.ApiId);
                Assert.Equal("private-api-key", rig.Http.ApiKey);
            }
            Assert.Equal(calls + (jwtRequired ? 0 : 1), rig.Http.Calls);
        }
        rig.Env.Remove("EPP_PROVIDER_TENANT_ID");
        await Check(502);
        Assert.Empty(rig.Credentials.Credentials);
        Assert.DoesNotContain("oauth-client-secret", rig.Secrets.Names);
        rig.Env["EPP_PROVIDER_TENANT_ID"] = "tenant.example";
        rig.Credentials.Respond = (_, _) => Task.FromException<AccessToken>(new InvalidOperationException(PrivateError));
        await Check(502);
        rig.Credentials.Respond = (_, _) => Task.FromResult(new AccessToken("unsafe\r\nheader", DateTimeOffset.UtcNow.AddMinutes(10)));
        await Check(502);
        rig.Env["EPP_PROVIDER_TIMEOUT_MS"] = "50";
        rig.Credentials.Respond = async (_, cancellation) =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            throw new InvalidOperationException("unreachable");
        };
        await Check(504);
        if (jwtRequired) Assert.All(rig.Secrets.Names, name => Assert.Equal("oauth-client-secret", name));
        Assert.Equal(3, rig.Credentials.Credentials.Sum(credential => credential.Requests.Count));
        Assert.Empty(rig.Credentials.ManagedIdentityIds);
        foreach (var value in new[] { PrivateError, "unsafe", "private-oauth-secret", "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public async Task PrivateKeyErrorsStayGenericAndNeverReachTheProvider()
    {
        using var rig = new HandlerRig();
        rig.Keys.Error = new InvalidOperationException(PrivateError);
        AssertFailure(rig, await rig.Invoke(), 400, "decryption_failed");
        Assert.Equal(0, rig.Http.Calls);
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

    private static JsonElement ValidVoiceContext()
    {
        using var fixtures = ReadContractFixtures();
        return JsonSerializer.SerializeToElement(new { voice = new { text2voice = fixtures.RootElement.GetProperty("textToVoice") } });
    }

    private static void AssertVoiceBody(JsonElement body)
    {
        Assert.False(body.TryGetProperty("text", out _));
        Assert.Equal(ValidVoiceContext().GetProperty("voice").GetRawText(), body.GetProperty("voice").GetRawText());
    }

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
        foreach (var value in new[] { PrivateError, Phone, "918273", Nonce, "012345", "en-GB", "Your code is" })
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
        public TestProviderCredentialFactory Credentials { get; } = new();
        public HandlerRig()
        {
            Env = new TestEnv
            {
                ["EPP_PROVIDER_NAME"] = "soprano",
                ["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/cgpapi",
                ["EPP_PROVIDER_TIMEOUT_MS"] = "2500",
            };
            var registry = new ProviderRegistry(new IProviderAdapter[]
                { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(), new SinchProvider() });
            _function = new SendOtp(new DispatchEngine(registry, Secrets, Http, Env, new ProviderTokenAcquirer(Secrets, Credentials)),
                new JweDecryptor(Keys), Env, Log);
        }
        public void EnableOAuth(string? mode = "OAuth2")
        {
            Env["EPP_PROVIDER_AUTH_MODE"] = mode;
            Env["EPP_PROVIDER_JWT_ENABLED"] = "true";
            Env["EPP_PROVIDER_TENANT_ID"] = "tenant.example";
            Env["EPP_PROVIDER_CLIENT_ID"] = "client-id";
            Env["EPP_PROVIDER_SCOPE"] = "api://provider/.default";
            Env["EPP_PROVIDER_CLIENT_SECRET_NAME"] = "oauth-client-secret";
            Env["KEY_VAULT_URL"] = "https://vault.example";
        }
        public async Task<ObjectResult> Invoke(object? mode = null, string channel = "sms", string? tenantId = null,
            Jose.JweAlgorithm algorithm = Jose.JweAlgorithm.RSA_OAEP_256,
            Jose.JweEncryption encryption = Jose.JweEncryption.A256GCM, JsonElement? deliveryOverrides = null,
            JsonElement? outerVoice = null)
        {
            var context = new Dictionary<string, object?> { ["nonce"] = Nonce, ["phoneNumber"] = Phone, ["message"] = Message };
            if (deliveryOverrides is { } changes)
                foreach (var property in changes.EnumerateObject()) context[property.Name] = property.Value;
            var encrypted = Jose.JWT.Encode(JsonSerializer.Serialize(context), Keys.Rsa, algorithm, encryption,
                extraHeaders: new Dictionary<string, object> { ["kid"] = Kid });
            return await InvokeRaw(JsonSerializer.Serialize(new
            {
                type = EnvelopeParser.EnvelopeType, tenantId, correlationId = Correlation, channel, mode = mode ?? "live",
                ttlSeconds = 60, encryptedDeliveryContext = encrypted, voice = outerVoice,
            }));
        }
        public async Task<ObjectResult> InvokeRaw(string body)
        {
            using var stream = new MemoryStream(Encoding.UTF8.GetBytes(body));
            var request = new DefaultHttpContext().Request;
            request.Method = "POST";
            request.ContentType = "application/json";
            request.Headers.Authorization = "Bearer caller-token-not-for-provider";
            request.Body = stream;
            return Assert.IsAssignableFrom<ObjectResult>(await _function.Run(request));
        }
        public void Dispose() { Keys.Dispose(); Http.Dispose(); }
    }

    private sealed class TestSecrets : ISecretResolver
    {
        public int Calls { get; private set; }
        public List<string?> Names { get; } = new();
        public string Secret { get; set; } = "private-api-key";
        public string Identity { get; set; } = "private-api-id";
        public Task<string> ResolveAsync(string? name)
        {
            Calls++;
            Names.Add(name);
            return Task.FromResult(name == "soprano-api-id" ? Identity : name == "oauth-client-secret" ? "private-oauth-secret" : Secret);
        }
    }

    private sealed class TestHttp : HttpMessageHandler, IHttpClientFactory
    {
        public int Calls { get; private set; }
        public string? Body { get; private set; }
        public string? Authorization { get; private set; }
        public string? ApiId { get; private set; }
        public string? ApiKey { get; private set; }
        public Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(Json(201, "{\"status\":\"ACCEPTED\"}"));
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Authorization = request.Headers.Authorization?.ToString();
            ApiId = request.Headers.TryGetValues("X-MEMS-API-ID", out var ids) ? Assert.Single(ids) : null;
            ApiKey = request.Headers.TryGetValues("X-MEMS-API-Key", out var keys) ? Assert.Single(keys) : null;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
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
