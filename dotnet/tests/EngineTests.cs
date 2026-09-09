using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Epp.Otp;
using Epp.Otp.Providers;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class EngineTests
{
    private const string Phone = "+15551234567";
    private const string Code = "918273";
    private const string Nonce = "private-nonce-value";
    private const string Token = "eyJhbGciOiJSUzI1NiJ9.private-jwt.signature";
    private const string Key = "private-provider-key";
    private const string Kid = "private-jwe-key-id";
    private const string BadCorrelation = "untrusted-correlation/\r\nforged-trace";
    private const string BadClientId = "untrusted-client-request-id";
    private const string TraceId = "A1234567890B1234C567890D123456EF";
    private const string GuidCorrelation = "a1234567-890b-1234-c567-890d123456ef";
    private static string SensitiveText => $"{Phone} {Code} {Nonce} {Token} {Key}";

    private sealed class FakeEnv : Dictionary<string, string?>, IEnv
    {
        public string? ThrowOnKey { get; set; }
        public string? Get(string key) => key == ThrowOnKey ? throw new InvalidOperationException(SensitiveText)
            : TryGetValue(key, out var value) ? value : null;
    }

    private sealed class FakeSecretResolver(string secret) : ISecretResolver
    {
        public Task<string> ResolveAsync(string? secretName) => Task.FromResult(secret);
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler, IHttpClientFactory
    {
        public string? LastBody;
        public string? LastAuthorization;
        public string? LastUrl;
        public int Calls;
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            LastAuthorization = request.Headers.Authorization?.ToString();
            LastUrl = request.RequestUri?.AbsoluteUri;
            if (request.Content != null) LastBody = await request.Content.ReadAsStringAsync(cancellationToken);
            return responder(request);
        }
    }

    private sealed class FakeTokenAcquirer(string? token) : IProviderTokenAcquirer
    {
        public Task<string> AcquireAsync(CancellationToken cancellationToken = default) => Task.FromResult(token!);
    }

    private sealed class CapturingLogger : ILogger<SendOtp>
    {
        public string Text = "";
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
        {
            Text += formatter(state, exception) + "\n" + exception + "\n";
            if (state is IEnumerable<KeyValuePair<string, object?>> fields)
                Text += string.Join("\n", fields.Select(pair => $"{pair.Key}={pair.Value}")) + "\n";
        }
    }

    private static FakeEnv DefaultEnv() => new()
    {
        ["EPP_PROVIDER_NAME"] = "infobip",
        ["EPP_PROVIDER_ENDPOINT"] = "https://api.infobip.com",
        ["EPP_REQUIRE_AUTH"] = "false",
    };

    private static DispatchEngine Engine(StubHandler handler, FakeEnv? env = null, string secret = Key,
        IProviderTokenAcquirer? tokenAcquirer = null)
    {
        env ??= DefaultEnv();
        var registry = new ProviderRegistry(new IProviderAdapter[] { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(), new SinchProvider() }, env);
        return new DispatchEngine(registry, new FakeSecretResolver(secret), handler, env, tokenAcquirer);
    }

    private static DispatchRequest Disp(string channel = "sms") => new(Phone, "Your code is 918273", channel, "m", "c", null);

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private static HttpResponseMessage ProviderReply(HttpStatusCode status = HttpStatusCode.OK, bool knownStatus = true) =>
        Json(status, JsonSerializer.Serialize(new
        {
            messages = new[] { new { status = new { groupName = knownStatus ? "DELIVERED" : SensitiveText,
                name = SensitiveText, description = SensitiveText }, messageId = SensitiveText } },
        }));

    private static void AssertNoSecrets(string text, params string[] additional)
    {
        foreach (var secret in new[] { Phone, Phone.TrimStart('+'), Phone[^10..], Code, Nonce, Token, Key, Kid }.Concat(additional))
            Assert.DoesNotContain(secret, text, StringComparison.OrdinalIgnoreCase);
    }

    private static void AssertPrivate(CapturingLogger logger, params string[] additional)
    {
        Assert.NotEmpty(logger.Text);
        AssertNoSecrets(logger.Text, additional.Concat(new[] { BadCorrelation, BadClientId }).ToArray());
    }

    [Fact]
    public void TraceIds_NormalizeGuidsOrUseLabeledHash()
    {
        Assert.Equal(GuidCorrelation, DispatchEngine.SafeTraceId(TraceId));
        Assert.Equal("unknown", DispatchEngine.SafeTraceId(null));
        Assert.Equal("sha256:ba7816bf8f01cfea414140de", DispatchEngine.SafeTraceId("abc"));
    }

    [Fact]
    public async Task MissingCredential_DoesNotSend()
    {
        var handler = new StubHandler(_ => throw new Exception("must not send"));
        var failed = await Engine(handler, secret: "")
            .DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, failed.HttpStatus);
        Assert.Equal(0, handler.Calls);
        Assert.Equal("provider credential unavailable", JsonSerializer.SerializeToElement(failed.Body).GetProperty("reason").GetString());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ConfiguredAndAlternateEndpoints_MustBeHttps(bool alternate)
    {
        var handler = new StubHandler(_ => throw new Exception("insecure URL must not be called"));
        var env = new FakeEnv
        {
            ["EPP_PROVIDER_ENDPOINT"] = alternate ? "https://sms.api.sinch.com" : "http://api.example.com",
            ["SINCH_VOICE_ENDPOINT"] = "http://localhost:8080",
        };
        var result = await Engine(handler, env)
            .DispatchAsync(Disp(alternate ? "voice" : "sms"), alternate ? "sinch" : "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
        Assert.Equal(0, handler.Calls);
    }

    [Theory]
    [InlineData(401, true, 401)]
    [InlineData(429, true, 429)]
    [InlineData(500, true, 502)]
    [InlineData(200, false, 502)]
    public async Task HandlerProviderFailure_MapsStatusWithoutLeakingDiagnostics(int httpStatus, bool knownStatus, int expected)
    {
        using var rsa = RSA.Create(2048);
        var jwe = EncryptContext(rsa);
        var stub = new StubHandler(_ => ProviderReply((HttpStatusCode)httpStatus, knownStatus));
        var logger = new CapturingLogger();
        var response = await RunHandler(JsonSerializer.Serialize(EnvelopePayload(jwe)), rsa, DefaultEnv(), stub, logger);
        Assert.Equal(expected, response.StatusCode);
        Assert.Equal(1, stub.Calls);
        var body = JsonSerializer.SerializeToElement(response.Value);
        Assert.Equal("delivery_failed", body.GetProperty("error").GetString());
        Assert.Equal("provider delivery failed", body.GetProperty("reason").GetString());
        Assert.Equal(BadCorrelation, body.GetProperty("correlationId").GetString());
        var requestId = body.GetProperty("requestId").GetString()!;
        Assert.True(Guid.TryParseExact(requestId, "N", out var id));
        Assert.Contains($"RequestId={id:D}", logger.Text);
        Assert.DoesNotContain(requestId, logger.Text);
        AssertNoSecrets(body.ToString(), jwe, BadClientId);
        AssertPrivate(logger, jwe);
    }

    [Theory]
    [InlineData(true, 504, "endpoint timeout after 1500ms")]
    [InlineData(false, 502, "provider request failed")]
    public async Task TransportFailure_IsPrivateAndNotRetried(bool timeout, int status, string reason)
    {
        var logger = new CapturingLogger();
        var handler = new StubHandler(_ => throw (timeout ? (Exception)new TaskCanceledException(SensitiveText) : new HttpRequestException(SensitiveText)));
        var result = await Engine(handler: handler).DispatchAsync(Disp(), "infobip", false, "r", logger);
        Assert.Equal(status, result.HttpStatus);
        Assert.Equal(1, handler.Calls);
        var body = JsonSerializer.SerializeToElement(result.Body);
        Assert.Equal(reason, body.GetProperty("reason").GetString());
        AssertNoSecrets(body.ToString());
        AssertPrivate(logger);
    }

    [Theory]
    [InlineData(Token, 200)]
    [InlineData(null, 502)]
    public async Task OAuthMode_SendsOnlyWithMintedBearer(string? token, int status)
    {
        var handler = new StubHandler(_ => Json(HttpStatusCode.Created, "{\"status\":\"ENROUTE\"}"));
        var env = new FakeEnv { ["EPP_PROVIDER_ENDPOINT"] = "https://api.soprano.com", ["EPP_PROVIDER_AUTH_MODE"] = "oauth2" };
        var logger = new CapturingLogger();
        var result = await Engine(handler, env, tokenAcquirer: new FakeTokenAcquirer(token))
            .DispatchAsync(Disp(), "soprano", false, "r", logger);

        Assert.Equal(status, result.HttpStatus);
        Assert.Equal(status == 200 ? 1 : 0, handler.Calls);
        if (status == 200)
        {
            Assert.Equal($"Bearer {Token}", handler.LastAuthorization);
            Assert.EndsWith("/messages/omnimsg", handler.LastUrl);
        }
        AssertNoSecrets(JsonSerializer.Serialize(result.Body));
        AssertPrivate(logger);
    }

    private static string EncryptContext(RSA rsa, string? message = "Your code is 918273") =>
        Jose.JWT.Encode(JsonSerializer.Serialize(new { nonce = Nonce, phoneNumber = Phone, message, locale = "en-US" }),
            rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM,
            extraHeaders: new Dictionary<string, object> { ["kid"] = Kid });

    private static Dictionary<string, object?> EnvelopePayload(string jwe) => new()
    {
        ["type"] = EnvelopeParser.EnvelopeType, ["channel"] = 1, ["mode"] = 1,
        ["correlationId"] = BadCorrelation, ["tenantId"] = "private-tenant-id", ["encryptedDeliveryContext"] = jwe,
    };

    private static async Task<ObjectResult> RunHandler(string body, RSA rsa, FakeEnv env, StubHandler stub,
        CapturingLogger logger, Exception? keyFailure = null)
    {
        var req = new DefaultHttpContext().Request;
        req.Method = "POST";
        req.ContentType = "application/json";
        req.Body = new MemoryStream(Encoding.UTF8.GetBytes(body));
        req.Headers.Authorization = $"Bearer {Token}";
        req.Headers["x-ms-correlation-id"] = GuidCorrelation;
        req.Headers["x-ms-client-request-id"] = BadClientId;
        req.Headers["x-ms-client-principal"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            claims = new[] { new { typ = "appid", val = "private-caller-id" } },
        })));
        var handler = new SendOtp(Engine(stub, env), new TokenValidator(env),
            new JweDecryptor(new EnvelopeTests.FakeKeyProvider(rsa, keyFailure)), env, logger);
        using var stream = req.Body;
        return Assert.IsType<ObjectResult>(await handler.Run(req));
    }

    [Theory]
    [InlineData("sms", false)]
    [InlineData("sms", true)]
    [InlineData("voice", false)]
    public async Task HandlerSuccess_PreservesCallerRenderedMessageAndWireValues(string channel, bool evaluation)
    {
        var message = channel == "voice"
            ? "Your code is 9 1 8 2 7 3; reference 123456, year 2026. Call +1 (555) 123-4567!"
            : "Your code is 918273";
        using var rsa = RSA.Create(2048);
        var jwe = EncryptContext(rsa, message);
        var payload = EnvelopePayload(jwe);
        payload["channel"] = channel == "voice" ? 2 : 1;
        payload["mode"] = evaluation ? 2 : 1;
        var env = DefaultEnv();
        if (evaluation)
        {
            payload.Remove("correlationId");
            env.Remove("EPP_PROVIDER_ENDPOINT");
            env.ThrowOnKey = "EPP_PROVIDER_AUTH_MODE";
        }
        var logger = new CapturingLogger();
        var stub = new StubHandler(_ => ProviderReply());
        var response = await RunHandler(JsonSerializer.Serialize(payload), rsa, env, stub, logger);
        Assert.Equal(200, response.StatusCode);
        var body = JsonSerializer.SerializeToElement(response.Value);
        var correlation = evaluation ? GuidCorrelation : BadCorrelation;
        Assert.All(body.EnumerateObject(), property => Assert.Contains(property.Name, new[] { "nonce", "correlationId", "providerStatus" }));
        Assert.Equal(Nonce, body.GetProperty("nonce").GetString());
        Assert.Equal(correlation, body.GetProperty("correlationId").GetString());
        Assert.Equal("accepted", body.GetProperty("providerStatus").GetString());
        Assert.Equal(evaluation ? 0 : 1, stub.Calls);
        if (!evaluation)
        {
            Assert.Equal($"App {Key}", stub.LastAuthorization);
            using var sent = JsonDocument.Parse(stub.LastBody!);
            var sentMessage = sent.RootElement.GetProperty("messages")[0];
            var destination = sentMessage.GetProperty("destinations")[0];
            Assert.Equal(Phone, destination.GetProperty("to").GetString());
            Assert.Equal(correlation, destination.GetProperty("messageId").GetString());
            var content = channel == "voice" ? sentMessage : sentMessage.GetProperty("content");
            Assert.Equal(message, content.GetProperty("text").GetString());
            Assert.EndsWith(channel == "voice" ? "/tts/3/advanced" : "/sms/3/messages", stub.LastUrl);
        }
        Assert.Contains($"CorrelationId={DispatchEngine.SafeTraceId(correlation)}", logger.Text);
        AssertPrivate(logger, jwe, message, "9 1 8 2 7 3", "private-tenant-id", "private-caller-id", rsa.ExportRSAPrivateKeyPem());
    }

    [Theory]
    [InlineData("unexpected_caller", 403, "unexpected_caller")]
    [InlineData("unauthorized", 401, "unauthorized")]
    [InlineData("invalid_json", 400, "bad_request")]
    [InlineData("decryption_failed", 400, "decryption_failed")]
    [InlineData("incomplete_context", 400, "bad_request")]
    [InlineData("internal_failure", 500, "delivery_failed")]
    public async Task HandlerFailure_ReturnsPrivateErrorWithoutSending(string reason, int status, string error)
    {
        using var rsa = RSA.Create(2048);
        var jwe = EncryptContext(rsa, reason == "incomplete_context" ? null : "Your code is 918273");
        var payload = EnvelopePayload(jwe);
        var env = DefaultEnv();
        switch (reason)
        {
            case "unexpected_caller": env["EPP_EXPECTED_CLIENT_ID"] = "private-expected-id"; break;
            case "unauthorized": env["EPP_REQUIRE_AUTH"] = "true"; break; // No audience/tenant: reject without OIDC traffic.
            case "internal_failure": env.ThrowOnKey = "EPP_PROVIDER_ACCOUNT_NAME"; break;
        }
        var logger = new CapturingLogger();
        var stub = new StubHandler(_ => throw new Exception("must not send"));
        var keyFailure = reason == "decryption_failed" ? new InvalidOperationException(SensitiveText) : null;
        var requestBody = reason == "invalid_json" ? "not-json " + SensitiveText : JsonSerializer.Serialize(payload);
        var response = await RunHandler(requestBody, rsa, env, stub, logger, keyFailure: keyFailure);
        Assert.Equal(status, response.StatusCode);
        var body = JsonSerializer.SerializeToElement(response.Value);
        Assert.Equal(error, body.GetProperty("error").GetString());
        Assert.All(body.EnumerateObject(), property => Assert.Contains(property.Name, new[] { "error", "reason", "correlationId", "requestId" }));
        AssertNoSecrets(body.ToString(), jwe, BadClientId, "private-caller-id", "private-expected-id");
        if (reason == "internal_failure") Assert.False(body.TryGetProperty("reason", out _));
        Assert.Equal(0, stub.Calls);
        AssertPrivate(logger, jwe, "private-tenant-id", "private-caller-id", "private-expected-id");
    }
}
