using System.Net;
using System.Text;
using Epp.Otp;
using Epp.Otp.Providers;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

// Engine-level conformance tests (CONTRACT.md §6) with a fake Key Vault, HTTP client, and env.
public class EngineTests
{
    private sealed class FakeEnv : Dictionary<string, string?>, IEnv
    {
        public string? Get(string key) => TryGetValue(key, out var value) ? value : null;
    }

    private sealed class FakeSecretResolver : ISecretResolver
    {
        private readonly IReadOnlyDictionary<string, string> _values;
        public FakeSecretResolver(IReadOnlyDictionary<string, string> values) => _values = values;
        public Task<string> ResolveAsync(string? secretName) =>
            Task.FromResult(secretName != null && _values.TryGetValue(secretName, out var value) ? value : string.Empty);
    }

    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;
        public string? LastBody;
        public StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) => _responder = responder;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Content != null) LastBody = await request.Content.ReadAsStringAsync(cancellationToken);
            return _responder(request);
        }
    }

    private sealed class FakeHttpClientFactory : IHttpClientFactory
    {
        private readonly HttpMessageHandler _handler;
        public FakeHttpClientFactory(HttpMessageHandler handler) => _handler = handler;
        public HttpClient CreateClient(string name) => new(_handler);
    }

    private sealed class FakeTokenAcquirer : IProviderTokenAcquirer
    {
        private readonly string? _token;
        private readonly Exception? _throw;
        public FakeTokenAcquirer(string? token = null, Exception? throwOnAcquire = null) { _token = token; _throw = throwOnAcquire; }
        public Task<string> AcquireAsync(CancellationToken cancellationToken = default) =>
            _throw != null ? throw _throw : Task.FromResult(_token!);
    }

    private sealed class CapturingLogger : ILogger
    {
        public readonly List<string> Lines = new();
        public IDisposable BeginScope<TState>(TState state) where TState : notnull => NullScope.Instance;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel logLevel, EventId eventId, TState state, Exception? exception, Func<TState, Exception?, string> formatter)
            => Lines.Add(formatter(state, exception));
        private sealed class NullScope : IDisposable { public static readonly NullScope Instance = new(); public void Dispose() { } }
    }

    private static readonly Dictionary<string, string> DefaultSecrets = new()
    {
        ["infobip-api-key"] = "ib",
        ["telesign-api-key"] = "ts", ["telesign-customer-id"] = "cust",
    };

    private static FakeEnv DefaultEnv() => new()
    {
        ["EPP_PROVIDER_ENDPOINT"] = "https://api.infobip.com",
    };

    private static DispatchEngine Engine(HttpResponseMessage? response = null, Exception? throwOnSend = null,
        IReadOnlyDictionary<string, string>? secrets = null, FakeEnv? env = null, StubHandler? handler = null,
        IProviderTokenAcquirer? tokenAcquirer = null)
    {
        var registry = new ProviderRegistry(new IProviderAdapter[] { new InfobipProvider(), new TelesignProvider(), new SopranoProvider(), new SinchProvider() });
        var stub = handler ?? new StubHandler(_ => throwOnSend != null ? throw throwOnSend : response!);
        return new DispatchEngine(registry, new FakeSecretResolver(secrets ?? DefaultSecrets), new FakeHttpClientFactory(stub), env ?? DefaultEnv(), tokenAcquirer);
    }

    private static DispatchRequest Disp(string channel = "sms", string? message = "Your code is 918273") =>
        new("+15551234567", message, channel, "m", "c", null);

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    [Theory]
    [InlineData(null, 1500)]
    [InlineData("invalid", 1500)]
    [InlineData("0", 1500)]
    [InlineData("-1", 1500)]
    [InlineData("2000", 2000)]
    [InlineData("999999", 2500)]
    public void ProviderTimeout_IsDefaultedAndCapped(string? value, int expected) =>
        Assert.Equal(expected, DispatchEngine.NormalizeProviderTimeoutMs(value));

    [Fact]
    public async Task UnknownProvider_400()
    {
        var result = await Engine(Json(HttpStatusCode.OK, "{}")).DispatchAsync(Disp(), "nope", false, "r", new CapturingLogger());
        Assert.Equal(400, result.HttpStatus);
    }

    [Fact]
    public async Task MissingCredential_502()
    {
        var result = await Engine(Json(HttpStatusCode.OK, "{}"), secrets: new Dictionary<string, string>()).DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
    }

    [Fact]
    public async Task MissingEndpoint_502()
    {
        var result = await Engine(Json(HttpStatusCode.OK, "{}"), env: new FakeEnv()).DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
    }

    [Theory]
    [InlineData("http://api.example.com")]
    [InlineData("not-a-url")]
    public async Task InsecureOrMalformedEndpoint_502(string endpoint)
    {
        var env = new FakeEnv { ["EPP_PROVIDER_ENDPOINT"] = endpoint };
        var result = await Engine(Json(HttpStatusCode.OK, "{}"), env: env)
            .DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
    }

    [Fact]
    public async Task AlternateProviderRequestUrl_MustAlsoBeHttps()
    {
        var handler = new StubHandler(_ => throw new Exception("insecure URL must not be called"));
        var env = new FakeEnv
        {
            ["EPP_PROVIDER_ENDPOINT"] = "https://sms.api.sinch.com",
            ["SINCH_VOICE_ENDPOINT"] = "http://localhost:8080",
        };
        var result = await Engine(handler: handler, env: env,
            secrets: new Dictionary<string, string> { ["sinch-api-token"] = "st" })
            .DispatchAsync(Disp(channel: "voice"), "sinch", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
        Assert.Null(handler.LastBody);
    }

    [Fact]
    public async Task Shutter_DoesNotSend_200()
    {
        var handler = new StubHandler(_ => throw new Exception("should not send"));
        var result = await Engine(handler: handler, secrets: new Dictionary<string, string>(), env: new FakeEnv())
            .DispatchAsync(Disp(), "infobip", true, "r", new CapturingLogger());
        Assert.Equal(200, result.HttpStatus);
        Assert.Null(handler.LastBody);
    }

    [Fact]
    public async Task Success_RendersCode_AndKeepsPrivacy()
    {
        var handler = new StubHandler(_ => Json(HttpStatusCode.OK, "{\"messages\":[{\"status\":{\"name\":\"DELIVERED\"},\"messageId\":\"x\"}]}"));
        var logger = new CapturingLogger();
        var result = await Engine(handler: handler).DispatchAsync(Disp(), "infobip", false, "r", logger);

        Assert.Equal(200, result.HttpStatus);
        Assert.Contains("918273", handler.LastBody);                                  // message (with the code) IS sent to the provider
        var bodyJson = System.Text.Json.JsonSerializer.Serialize(result.Body);
        Assert.DoesNotContain("918273", bodyJson);                                     // never in the response body
        Assert.DoesNotContain("5551234567", bodyJson);
        Assert.All(logger.Lines, line => Assert.DoesNotContain("918273", line));       // never logged
        Assert.All(logger.Lines, line => Assert.DoesNotContain("5551234567", line));
    }

    [Fact]
    public async Task UnknownStatus_FailsClosed()
    {
        var result = await Engine(Json(HttpStatusCode.OK, "{\"messages\":[{\"status\":{\"name\":\"WATWAT\"}}]}")).DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus); // Fail on HTTP 200 -> 502
    }

    [Fact]
    public async Task Timeout_504()
    {
        var result = await Engine(throwOnSend: new TaskCanceledException()).DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(504, result.HttpStatus);
    }

    [Fact]
    public async Task NetworkError_502()
    {
        var result = await Engine(throwOnSend: new HttpRequestException("dns")).DispatchAsync(Disp(), "infobip", false, "r", new CapturingLogger());
        Assert.Equal(502, result.HttpStatus);
        var body = System.Text.Json.JsonSerializer.Serialize(result.Body);
        Assert.Contains("provider request failed", body);
        Assert.DoesNotContain("dns", body);
    }

    [Fact]
    public async Task OAuthMode_SendsMintedBearer()
    {
        var handler = new StubHandler(_ => Json(HttpStatusCode.Created, "{\"status\":\"ENROUTE\"}"));
        // EPP_PROVIDER_AUTH_MODE forces oauth2 over soprano's apiKey manifest default.
        var env = new FakeEnv { ["EPP_PROVIDER_ENDPOINT"] = "https://api.soprano.com", ["EPP_PROVIDER_AUTH_MODE"] = "oauth2" };
        var result = await Engine(handler: handler, env: env, tokenAcquirer: new FakeTokenAcquirer(token: "JWT"))
            .DispatchAsync(Disp(), "soprano", false, "r", new CapturingLogger());

        Assert.Equal(200, result.HttpStatus);
        Assert.Contains("918273", handler.LastBody);
    }

    [Fact]
    public async Task OAuthMode_FailsClosed_WhenTokenUnavailable()
    {
        var handler = new StubHandler(_ => throw new Exception("should not send without a token"));
        var env = new FakeEnv { ["EPP_PROVIDER_ENDPOINT"] = "https://api.soprano.com", ["EPP_PROVIDER_AUTH_MODE"] = "oauth2" };
        var acquirer = new FakeTokenAcquirer(throwOnAcquire: new InvalidOperationException("oauth2 config missing"));
        var result = await Engine(handler: handler, env: env, tokenAcquirer: acquirer)
            .DispatchAsync(Disp(), "soprano", false, "r", new CapturingLogger());

        Assert.Equal(502, result.HttpStatus);
    }
}
