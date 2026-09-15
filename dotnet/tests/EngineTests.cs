using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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
        public CapturingLogger Log { get; } = new();
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
