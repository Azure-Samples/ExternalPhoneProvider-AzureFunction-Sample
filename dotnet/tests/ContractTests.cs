using System.Net;
using System.Text;
using System.Text.Json;
using Epp.Otp.Providers;
using Xunit;

namespace Epp.Otp.Tests;

public class ContractTests
{
    private static OtpDelivery Delivery(string channel = "sms") =>
        new("+15551234567", "  Your code is 918273.\nDo not share.  ", channel, "message-id", "correlation-id", "en-US");

    [Theory]
    [InlineData("sms")]
    [InlineData("voice")]
    public async Task SopranoUsesSelectedEndpointOAuthAndExactJson(string channel)
    {
        var delivery = Delivery(channel) with
        {
            Locale = channel == "voice" ? "fr-FR" : "en-US",
        };
        var request = await new SopranoProvider().CaptureRequestAsync(
            channel,
            "https://provider.example/oauth/messages",
            delivery,
            new ProviderCredentials("oauth", AccessToken: "provider-token"),
            new TestEnv());

        AssertJsonRequest(request, "https://provider.example/oauth/messages", "Bearer provider-token");
        var expected = new Dictionary<string, object?>
        {
            ["destination"] = "15551234567",
            ["messageTypes"] = new[] { channel },
            ["correlationId"] = "correlation-id",
            ["shutterMode"] = false,
        };
        if (channel == "voice")
            expected["voice"] = new
            {
                text2voice = new
                {
                    beforePasswordText = "  Your code is ",
                    password = "918273",
                    afterPasswordText = ".\nDo not share.  ",
                    language = "fr-FR",
                    gender = 1,
                    loop = 2,
                },
            };
        else
            expected["text"] = Delivery().Message;
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    public async Task SopranoVoiceDefaultsLanguageWithoutLocale(string? locale)
    {
        var request = await new SopranoProvider().CaptureRequestAsync(
            "voice",
            "https://provider.example/oauth/messages",
            Delivery("voice") with { Locale = locale },
            new ProviderCredentials("oauth", AccessToken: "provider-token"),
            new TestEnv());
        using var body = JsonDocument.Parse(request.Body);
        Assert.Equal("en-US", body.RootElement.GetProperty("voice").GetProperty("text2voice")
            .GetProperty("language").GetString());
    }

    [Fact]
    public async Task SopranoVoiceRequiresSixDigitPasscode()
    {
        var delivery = Delivery("voice") with { Message = "Your code is unavailable." };
        var error = await Assert.ThrowsAsync<PhoneProviderBase.ProviderSendException>(
            () => new SopranoProvider().CaptureRequestAsync(
                "voice",
                "https://provider.example/oauth/messages",
                delivery,
                new ProviderCredentials("oauth", AccessToken: "provider-token"),
                new TestEnv()));
        Assert.Equal(502, error.StatusCode);
    }

    [Theory]
    [InlineData("{\"id\":12,\"state\":\"enroute\"}", "12", "ENROUTE", Outcome.Continue, true)]
    [InlineData("[{\"messageId\":\"provider-id\",\"status\":\"accepted\"}]", "provider-id", "ACCEPTED", Outcome.Continue, true)]
    [InlineData("{\"status\":\"FILTERED\"}", null, "FILTERED", Outcome.Fail, true)]
    [InlineData("{\"status\":\"unknown\"}", null, "UNKNOWN", Outcome.Fail, false)]
    [InlineData("{\"status\":123,\"state\":\"ACCEPTED\"}", null, "UNKNOWN", Outcome.Fail, false)]
    [InlineData("{\"status\":false,\"state\":\"ACCEPTED\"}", null, "UNKNOWN", Outcome.Fail, false)]
    [InlineData("[]", null, "UNKNOWN", Outcome.Fail, false)]
    public async Task SopranoTypedResponseSupportsObjectAndArrayAndFailsClosed(
        string body, string? messageId, string status, Outcome expected, bool recognized)
    {
        var provider = new SopranoProvider();
        using var response = JsonResponse(200, body);
        var result = await provider.SendResponseAsync(response, default);
        Assert.Equal(nameof(ProviderResult), result.ToString());
        Assert.Equal(messageId, result.ProviderMessageId);
        Assert.Equal(status, result.ProviderStatusName);
        Assert.Equal(expected, result.Outcome);
        Assert.Equal(recognized, result.StatusRecognized);
    }

    [Theory]
    [InlineData("ENROUTE", Outcome.Continue)]
    [InlineData("ACCEPTED", Outcome.Continue)]
    [InlineData("SUBMITTED", Outcome.Continue)]
    [InlineData("SENT", Outcome.Continue)]
    [InlineData("DELIVERED", Outcome.Continue)]
    [InlineData("QUEUED", Outcome.Continue)]
    [InlineData("BLOCKED", Outcome.Block)]
    [InlineData("FAILED", Outcome.Fail)]
    [InlineData("REJECTED", Outcome.Fail)]
    [InlineData("FILTERED", Outcome.Fail)]
    public async Task SopranoOwnsEveryRecognizedStatusMapping(string status, Outcome expected)
    {
        using var response = JsonResponse(200, JsonSerializer.Serialize(new { status }));
        var result = await new SopranoProvider().SendResponseAsync(response, default);
        Assert.Equal(expected, result.Outcome);
        Assert.True(result.StatusRecognized);
    }

    [Fact]
    public async Task InfobipRequestsKeepExactSmsAndVoiceWireContracts()
    {
        var env = new TestEnv { ["EPP_PROVIDER_ACCOUNT_NAME"] = "Verify" };
        var credential = new ProviderCredentials("apiKey", "test-key", "test-id");

        var sms = await new InfobipProvider().CaptureRequestAsync(
            "sms", "https://provider.example", Delivery(), credential, env);
        AssertJsonRequest(sms, "https://provider.example/sms/3/messages", "App test-key");
        var expectedSms = new
        {
            messages = new[]
            {
                new
                {
                    sender = "Verify",
                    destinations = new[] { new { to = Delivery().PhoneNumber, messageId = "correlation-id" } },
                    content = new { text = Delivery().Message },
                },
            },
        };
        Assert.Equal(JsonSerializer.Serialize(expectedSms), sms.Body);

        var voice = await new InfobipProvider().CaptureRequestAsync(
            "voice", "https://provider.example", Delivery("voice"), credential, env);
        AssertJsonRequest(voice, "https://provider.example/tts/3/advanced", "App test-key");
        var expectedVoice = new
        {
            messages = new[]
            {
                new
                {
                    from = "Verify",
                    destinations = new[] { new { to = Delivery().PhoneNumber, messageId = "correlation-id" } },
                    text = Delivery().Message,
                    language = "en-US",
                    voice = new { name = "Joanna", gender = "female" },
                },
            },
        };
        Assert.Equal(JsonSerializer.Serialize(expectedVoice), voice.Body);
    }

    [Fact]
    public async Task SinchRequestsKeepExactSmsAndVoiceWireContracts()
    {
        var env = new TestEnv
        {
            ["EPP_PROVIDER_ACCOUNT_NAME"] = "Verify",
            ["SINCH_SERVICE_PLAN_ID"] = "service-plan",
            ["SINCH_VOICE_ENDPOINT"] = "https://calling.example",
        };
        var credential = new ProviderCredentials("apiKey", "test-key", "test-id");

        var sms = await new SinchProvider().CaptureRequestAsync(
            "sms", "https://provider.example", Delivery(), credential, env);
        AssertJsonRequest(
            sms,
            "https://provider.example/xms/v1/service-plan/batches",
            "******");
        Assert.Equal(
            JsonSerializer.Serialize(new
            {
                from = "Verify",
                to = new[] { Delivery().PhoneNumber },
                body = Delivery().Message,
                client_reference = "correlation-id",
            }),
            sms.Body);

        var voice = await new SinchProvider().CaptureRequestAsync(
            "voice", "https://provider.example", Delivery("voice"), credential, env);
        AssertJsonRequest(voice, "https://calling.example/calling/v1/callouts", "******");
        Assert.Equal(
            JsonSerializer.Serialize(new
            {
                method = "ttsCallout",
                ttsCallout = new
                {
                    destination = new { type = "number", endpoint = Delivery().PhoneNumber },
                    text = Delivery().Message,
                    locale = "en-US",
                    custom = "correlation-id",
                },
            }),
            voice.Body);
    }

    [Theory]
    [InlineData("sms", "en")]
    [InlineData("voice", "en")]
    [InlineData("sms", null)]
    [InlineData("sms", "")]
    [InlineData("sms", " ")]
    public async Task TelesignUsesExactEppJsonContract(string channel, string? locale)
    {
        var delivery = Delivery(channel) with { Locale = locale };
        var request = await new TelesignProvider().CaptureRequestAsync(
            channel,
            $"https://verify.telesign.com/epp/{channel}",
            delivery,
            new ProviderCredentials("apiKey", "test-key", "test-id"),
            new TestEnv());
        AssertJsonRequest(
            request,
            $"https://verify.telesign.com/epp/{channel}",
            "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("test-id:test-key")));
        var expectedText = channel == "voice"
            ? "  Your code is 9, 1, 8, 2, 7, 3.\nDo not share.   "
              + "  Your code is 9, 1, 8, 2, 7, 3.\nDo not share.  "
            : delivery.Message;
        var message = new Dictionary<string, string?> { ["text"] = expectedText };
        if (locale == "en") message["language"] = locale;
        var expected = new
        {
            recipient = new { phone_number = delivery.PhoneNumber },
            message,
            channels = new[] { new { channel } },
            correlation_id = delivery.CorrelationId,
        };
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);
    }

    [Fact]
    public async Task TelesignVoicePacesOnlySixDigitNumericRunsAndRepeatsMessage()
    {
        var delivery = Delivery("voice") with { Message = "Code 001234; ref 1234567; alternate 654321." };
        var request = await new TelesignProvider().CaptureRequestAsync(
            "voice",
            "https://verify.telesign.com/epp/voice",
            delivery,
            new ProviderCredentials("apiKey", "test-key", "test-id"),
            new TestEnv());
        using var body = JsonDocument.Parse(request.Body);
        Assert.Equal(
            "Code 0, 0, 1, 2, 3, 4; ref 1234567; alternate 6, 5, 4, 3, 2, 1. "
            + "Code 0, 0, 1, 2, 3, 4; ref 1234567; alternate 6, 5, 4, 3, 2, 1.",
            body.RootElement.GetProperty("message").GetProperty("text").GetString());
    }

    [Fact]
    public async Task TelesignValidatesRecipientAndFallsBackToMessageId()
    {
        var provider = new TelesignProvider();
        var credential = new ProviderCredentials("apiKey", "key", "id");
        foreach (var phoneNumber in new[] { "15551234567", "+0123", "+1", "+1234567890123456", "+123\n", "+123\r", "+12 34" })
        {
            var error = await Assert.ThrowsAsync<PhoneProviderBase.ProviderSendException>(
                () => provider.CaptureRequestAsync(
                    "sms",
                    "https://verify.telesign.com",
                    Delivery() with { PhoneNumber = phoneNumber },
                    credential,
                    new TestEnv()));
            Assert.Equal(502, error.StatusCode);
        }
        var channelError = await Assert.ThrowsAsync<PhoneProviderBase.ProviderSendException>(
            () => provider.CaptureRequestAsync(
                "email", "https://verify.telesign.com", Delivery(), credential, new TestEnv()));
        Assert.Equal(502, channelError.StatusCode);
        var request = await provider.CaptureRequestAsync(
            "sms",
            "https://verify.telesign.com",
            Delivery() with { CorrelationId = null },
            credential,
            new TestEnv());
        using var json = JsonDocument.Parse(request.Body);
        Assert.Equal(Delivery().MessageId, json.RootElement.GetProperty("correlation_id").GetString());
    }

    [Theory]
    [InlineData("{}", true, Outcome.Fail, false)]
    [InlineData("{\"status\":{\"code\":999}}", true, Outcome.Fail, false)]
    [InlineData("{\"status\":{\"code\":290}}", false, Outcome.Fail, true)]
    [InlineData("{\"status\":{\"code\":290}}", true, Outcome.Continue, true)]
    [InlineData("{\"status\":{\"code\":100}}", true, Outcome.Continue, true)]
    [InlineData("{\"status\":{\"code\":3001}}", true, Outcome.Continue, true)]
    [InlineData("{\"status\":{\"code\":3001}}", false, Outcome.Fail, true)]
    public async Task TelesignMapsTypedStatus(
        string payload, bool ok, Outcome expected, bool recognized)
    {
        var provider = new TelesignProvider();
        using var response = JsonResponse(ok ? 200 : 500, payload);
        var result = await provider.SendResponseAsync(response, default);
        Assert.Equal(expected, result.Outcome);
        Assert.Equal(recognized, result.StatusRecognized);
    }

    [Theory]
    [InlineData("{\"status\":[]}")]
    [InlineData("{\"status\":{\"code\":true}}")]
    [InlineData("{\"status\":{\"code\":\"290\"}}")]
    public async Task TelesignRejectsWronglyTypedStatus(string payload)
    {
        using var response = JsonResponse(200, payload);
        var error = await Assert.ThrowsAsync<PhoneProviderBase.ProviderSendException>(
            async () => await new TelesignProvider().SendResponseAsync(response, default));
        Assert.Equal(502, error.StatusCode);
    }

    [Theory]
    [InlineData(200)]
    [InlineData(203)]
    [InlineData(290)]
    [InlineData(291)]
    [InlineData(292)]
    [InlineData(100)]
    [InlineData(101)]
    [InlineData(102)]
    [InlineData(103)]
    [InlineData(3001)]
    public async Task TelesignOwnsEveryContinueStatusMapping(int status)
    {
        using var response = JsonResponse(200, JsonSerializer.Serialize(new { status = new { code = status } }));
        var result = await new TelesignProvider().SendResponseAsync(response, default);
        Assert.Equal(Outcome.Continue, result.Outcome);
        Assert.True(result.StatusRecognized);
    }

    [Theory]
    [InlineData("ACCEPTED", Outcome.Continue)]
    [InlineData("PENDING", Outcome.Continue)]
    [InlineData("DELIVERED", Outcome.Continue)]
    [InlineData("REJECTED", Outcome.Fail)]
    [InlineData("EXPIRED", Outcome.Fail)]
    [InlineData("UNDELIVERABLE", Outcome.Fail)]
    public async Task InfobipOwnsEveryRecognizedStatusMapping(string status, Outcome expected)
    {
        using var response = JsonResponse(200, JsonSerializer.Serialize(new
        {
            messages = new[] { new { messageId = "provider-id", status = new { groupName = status } } },
        }));
        var result = await new InfobipProvider().SendResponseAsync(response, default);
        Assert.Equal(expected, result.Outcome);
        Assert.True(result.StatusRecognized);
    }

    [Theory]
    [InlineData("Dispatched", Outcome.Continue)]
    [InlineData("Delivered", Outcome.Continue)]
    [InlineData("Queued", Outcome.Continue)]
    [InlineData("Failed", Outcome.Fail)]
    [InlineData("Rejected", Outcome.Fail)]
    public async Task SinchOwnsEveryRecognizedStatusMapping(string status, Outcome expected)
    {
        using var response = JsonResponse(200, JsonSerializer.Serialize(new { id = "provider-id", status }));
        var result = await new SinchProvider().SendResponseAsync(response, default);
        Assert.Equal(expected, result.Outcome);
        Assert.True(result.StatusRecognized);
    }

    [Fact]
    public async Task TypedProviderResponsesNormalizeIdsStatusesAndDescriptions()
    {
        var cases = new (PhoneProviderBase Provider, string Json, string Id, string Status, string Description)[]
        {
            (
                new InfobipProvider(),
                "{\"messages\":[{\"messageId\":\"infobip-id\",\"status\":{\"name\":\"pending\",\"description\":\"queued\"}}]}",
                "infobip-id",
                "PENDING",
                "queued"),
            (
                new SinchProvider(),
                "{\"callId\":\"sinch-id\",\"text\":\"queued\"}",
                "sinch-id",
                "Dispatched",
                "queued"),
            (
                new TelesignProvider(),
                "{\"reference_id\":\"telesign-id\",\"status\":{\"code\":3001,\"description\":\"queued\"}}",
                "telesign-id",
                "3001",
                "queued"),
        };

        foreach (var item in cases)
        {
            using var response = JsonResponse(200, item.Json);
            var result = await item.Provider.SendResponseAsync(response, default);
            Assert.Equal(item.Id, result.ProviderMessageId);
            Assert.Equal(item.Status, result.ProviderStatusName ?? result.ProviderStatusCode);
            Assert.Equal(item.Description, result.ProviderStatusDescription);
            Assert.Equal(Outcome.Continue, result.Outcome);
            Assert.True(result.StatusRecognized);
        }
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("null")]
    public async Task MissingProviderResponseDataFailsClosed(string payload)
    {
        PhoneProviderBase[] providers =
        [
            new InfobipProvider(),
            new SinchProvider(),
            new TelesignProvider(),
            new SopranoProvider(),
        ];
        foreach (var provider in providers)
        {
            using var response = JsonResponse(200, payload);
            var result = await provider.SendResponseAsync(response, default);
            Assert.Equal(Outcome.Fail, result.Outcome);
            Assert.False(result.StatusRecognized);
        }
    }

    [Fact]
    public async Task MalformedAndValidButUnbindableProviderJsonReturnProviderFailures()
    {
        var provider = new InfobipProvider();
        using var malformed = JsonResponse(200, "{\"messages\":[");
        var malformedResult = await provider.SendResponseAsync(malformed, default);
        Assert.Equal(Outcome.Fail, malformedResult.Outcome);
        Assert.False(malformedResult.StatusRecognized);

        using var wrongType = JsonResponse(
            200,
            "{\"messages\":[{\"messageId\":123,\"status\":{\"groupName\":\"PENDING\"}}]}");
        var wrongTypeError = await Assert.ThrowsAsync<PhoneProviderBase.ProviderSendException>(
            async () => await provider.SendResponseAsync(wrongType, default));
        Assert.Equal(502, wrongTypeError.StatusCode);
    }

    [Theory]
    [InlineData("{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":123}}]}")]
    [InlineData("{\"messages\":[{\"messageId\":\"id\",\"status\":[]}]}")]
    [InlineData("{\"id\":\"id\",\"status\":123}")]
    public async Task WronglyTypedProviderStatusesFailClosed(string payload)
    {
        PhoneProviderBase provider = payload.Contains("\"messages\"", StringComparison.Ordinal)
            ? new InfobipProvider()
            : new SinchProvider();
        using var response = JsonResponse(200, payload);
        var result = await provider.SendResponseAsync(response, default);
        Assert.Equal(Outcome.Fail, result.Outcome);
        Assert.False(result.StatusRecognized);
    }

    [Fact]
    public async Task HttpFailureCannotBecomeSuccessFromProviderBody()
    {
        var cases = new (PhoneProviderBase Provider, string Body)[]
        {
            (new InfobipProvider(), "{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":\"PENDING\"}}]}"),
            (new SopranoProvider(), "{\"messageId\":\"id\",\"status\":\"ACCEPTED\"}"),
            (new TelesignProvider(), "{\"reference_id\":\"id\",\"status\":{\"code\":290}}"),
            (new SinchProvider(), "{\"id\":\"id\",\"status\":\"Delivered\"}"),
        };

        foreach (var item in cases)
        {
            using var response = JsonResponse(503, item.Body);
            var result = await item.Provider.SendResponseAsync(response, default);
            Assert.Equal(Outcome.Fail, result.Outcome);
            Assert.True(result.StatusRecognized);
        }
    }

    private static void AssertJsonRequest(
        CapturedRequest request, string expectedUrl, string expectedAuthorization)
    {
        Assert.Equal(HttpMethod.Post, request.Method);
        Assert.Equal(expectedUrl, request.Url);
        Assert.Equal(expectedAuthorization, request.Authorization);
        Assert.Equal("application/json", request.Accept);
        Assert.Equal(
            new[] { "Accept", "Authorization" },
            request.HeaderNames);
        Assert.Equal("application/json", request.ContentType);
        Assert.Equal(
            new[] { "Content-Type" },
            request.ContentHeaderNames);
    }

    private static HttpResponseMessage JsonResponse(int status, string body) =>
        new((HttpStatusCode)status)
        {
            Content = new StringContent(body, Encoding.UTF8, "application/json"),
        };
}

internal sealed class TestEnv : Dictionary<string, string?>, IEnv
{
    public string? Get(string key) => TryGetValue(key, out var value) ? value : null;
}

internal static class PhoneProviderTestExtensions
{
    public static async Task<CapturedRequest> CaptureRequestAsync(
        this PhoneProviderBase provider,
        string channel,
        string endpoint,
        OtpDelivery delivery,
        ProviderCredentials credentials,
        IEnv env)
    {
        var handler = new CapturingRequestHandler();
        using var client = new HttpClient(handler);
        await provider.SendOtpAsync(
            channel,
            endpoint,
            delivery,
            credentials,
            env,
            client,
            1500);
        return handler.Request ?? throw new InvalidOperationException("Provider did not send a request.");
    }

    public static async ValueTask<ProviderResult> SendResponseAsync(
        this PhoneProviderBase provider,
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var body = await response.Content.ReadAsStringAsync(cancellationToken);
        using var client = new HttpClient(new ResponseHandler(
            () => new HttpResponseMessage(response.StatusCode)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json"),
            }));
        var env = new TestEnv
        {
            ["EPP_PROVIDER_ACCOUNT_NAME"] = "Verify",
            ["SINCH_SERVICE_PLAN_ID"] = "service-plan",
        };
        var endpoint = provider.Name switch
        {
            "infobip" => "https://provider.example",
            "sinch" => "https://provider.example",
            "telesign" => "https://verify.telesign.com/epp/sms",
            _ => "https://provider.example/oauth/messages",
        };
        var credentials = provider.AuthenticationMode == "oauth"
            ? new ProviderCredentials("oauth", AccessToken: "provider-token")
            : new ProviderCredentials("apiKey", "provider-secret", "provider-identity");
        return await provider.SendOtpAsync(
            "sms",
            endpoint,
            new OtpDelivery(
                "+15551234567",
                "Your code is 918273.",
                "sms",
                "message-id",
                "correlation-id",
                "en-US"),
            credentials,
            env,
            client,
            1500);
    }

    private sealed class CapturingRequestHandler : HttpMessageHandler
    {
        public CapturedRequest? Request { get; private set; }

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Request = new CapturedRequest(
                request.Method,
                request.RequestUri?.AbsoluteUri,
                Assert.Single(request.Headers.GetValues("Authorization")),
                Assert.Single(request.Headers.Accept).MediaType,
                request.Headers.Select(header => header.Key).OrderBy(name => name).ToArray(),
                request.Content?.Headers.ContentType?.MediaType,
                request.Content?.Headers.Select(header => header.Key).OrderBy(name => name).ToArray() ?? [],
                request.Content is null
                    ? string.Empty
                    : await request.Content.ReadAsStringAsync(cancellationToken));
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{}", Encoding.UTF8, "application/json"),
            };
        }
    }

    private sealed class ResponseHandler(Func<HttpResponseMessage> createResponse) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(createResponse());
    }
}

internal sealed record CapturedRequest(
    HttpMethod Method,
    string? Url,
    string Authorization,
    string? Accept,
    IReadOnlyList<string> HeaderNames,
    string? ContentType,
    IReadOnlyList<string> ContentHeaderNames,
    string Body);
