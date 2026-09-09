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
        var pending = rig.Invoke(channel: "voice");
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
        Assert.Equal(Message, body.RootElement.GetProperty("text").GetString());
        Assert.Equal(1, rig.Http.Calls);
        var log = Assert.Single(rig.Log.Messages);
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Correlation)))[..16].ToLowerInvariant();
        Assert.Contains("CorrelationId=" + hash, log);
        foreach (var value in new[] { Phone, "918273", Nonce, Correlation, "private-caller", "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, log);
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
    public async Task EvaluationValidatesSignedJwtAndJweWithoutProviderConfiguration()
    {
        using var tokens = new InboundTokens();
        var token = tokens.Issue(issuer: "https://login.microsoftonline.com/tenant/v2.0");
        foreach (var provider in new string?[] { null, "infobip", "telesign", "soprano", "sinch" })
        {
            using var rig = new HandlerRig(tokens);
            Assert.False(rig.Env.ContainsKey("EPP_PROVIDER_NAME"));
            if (provider is not null) rig.Env["EPP_PROVIDER_NAME"] = provider;
            rig.Env.Remove("EPP_EXPECTED_ISSUER");
            rig.Env["EPP_ENCRYPTION_KEY_ID"] = "configured-key-id";
            AssertAccepted(await rig.Invoke("evaluation", token, tenantId: "untrusted-body-tenant"));
            Assert.Equal("encryption_key_id_mismatch",
                Assert.Single(rig.Log.Entries, entry => entry.Level == LogLevel.Warning).Message);
            foreach (var value in new[] { Kid, "configured-key-id", Phone, "918273", Nonce, Correlation, "untrusted-body-tenant" })
                Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
            Assert.Equal((1, 0, 0), (rig.Keys.Calls, rig.Secrets.Calls, rig.Http.Calls));
        }
    }

    [Fact]
    public async Task AuthenticationRejectsWrongCallerBeforeDecryptionEvenInEvaluation()
    {
        using var tokens = new InboundTokens();
        using var rig = new HandlerRig(tokens);
        rig.Env.Remove("EPP_EXPECTED_ISSUER");
        AssertFailure(rig, await rig.Invoke("evaluation", tokens.Issue(caller: "private-caller",
            issuer: "https://login.microsoftonline.com/tenant/v2.0"),
            principalCaller: "private-caller"), 401, "unauthorized");
        AssertFailure(rig, await rig.Invoke("evaluation", tokens.Issue(
            issuer: "https://login.microsoftonline.com/untrusted-body-tenant/v2.0"),
            tenantId: "untrusted-body-tenant"), 401, "unauthorized");
        rig.Env.Remove("EPP_TENANT_ID");
        AssertFailure(rig, await rig.Invoke("evaluation", tokens.Issue(
            issuer: "https://login.microsoftonline.com/tenant/v2.0"), tenantId: "tenant"), 401, "unauthorized");
        Assert.Equal((0, 0, 0), (rig.Keys.Calls, rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task PrivateKeyErrorsStayGenericAndNeverReachTheProvider()
    {
        using var rig = new HandlerRig();
        rig.Keys.Error = new InvalidOperationException(PrivateError);
        AssertFailure(rig, await rig.Invoke(), 400, "decryption_failed");
        Assert.Equal(0, rig.Http.Calls);
    }

    private static void AssertAccepted(ObjectResult result)
    {
        Assert.Equal(200, result.StatusCode);
        Assert.Equal(JsonSerializer.Serialize(new { nonce = Nonce, correlationId = Correlation, providerStatus = "accepted" }),
            JsonSerializer.Serialize(result.Value));
    }

    private static void AssertFailure(HandlerRig rig, ObjectResult result, int status, string error = "provider_delivery_failed")
    {
        Assert.Equal(status, result.StatusCode);
        var body = JsonSerializer.SerializeToElement(result.Value);
        Assert.Equal(error, body.GetProperty("error").GetString());
        Assert.False(body.TryGetProperty("nonce", out _));
        var output = body.GetRawText() + string.Join("\n", rig.Log.Messages);
        foreach (var value in new[] { PrivateError, Phone, "918273", Nonce, "private-caller" })
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
        public HandlerRig(InboundTokens? tokens = null)
        {
            Env = tokens?.Environment() ?? new TestEnv
            {
                ["EPP_PROVIDER_NAME"] = "soprano",
                ["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/cgpapi",
                ["EPP_PROVIDER_TIMEOUT_MS"] = "2500",
            };
            var registry = new ProviderRegistry(new IProviderAdapter[]
                { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(), new SinchProvider() }, new TestEnv());
            _function = new SendOtp(new DispatchEngine(registry, Secrets, Http, Env),
                new TokenValidator(Env, tokens), new JweDecryptor(Keys), Env, Log);
        }
        public async Task<ObjectResult> Invoke(object? mode = null, string? token = null,
            string channel = "sms", string? principalCaller = null, string? tenantId = null)
        {
            var context = JsonSerializer.Serialize(new { nonce = Nonce, phoneNumber = Phone, message = Message });
            var encrypted = Jose.JWT.Encode(context, Keys.Rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM,
                extraHeaders: new Dictionary<string, object> { ["kid"] = Kid });
            using var stream = new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(new
            {
                type = EnvelopeParser.EnvelopeType, tenantId, correlationId = Correlation, channel, mode = mode ?? "live",
                ttlSeconds = 60, encryptedDeliveryContext = encrypted,
            }));
            var request = new DefaultHttpContext().Request;
            request.Method = "POST";
            request.ContentType = "application/json";
            request.Body = stream;
            if (token is not null) request.Headers.Authorization = "Bearer " + token;
            if (principalCaller is not null) request.Headers["x-ms-client-principal"] = Convert.ToBase64String(
                JsonSerializer.SerializeToUtf8Bytes(new { claims = new[] { new { typ = "azp", val = principalCaller } } }));
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
        public Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(Json(201, "{\"status\":\"ACCEPTED\"}"));
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
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
