using System.Text;
using System.Text.Json;
using Epp.Otp.Providers;
using Xunit;

namespace Epp.Otp.Tests;

public class ContractTests
{
    private static DispatchRequest Request(string channel = "sms") =>
        new("+15551234567", "  Your code is 918273.\nDo not share.  ", channel, "message-id", "correlation-id", "en-US");

    [Theory]
    [InlineData("sms")]
    [InlineData("voice")]
    public void SopranoUsesExactOmnimsgContract(string channel)
    {
        var dispatch = Request(channel) with { TextToVoice = new TextToVoice("Your code is", "001234", "en-US") };
        var request = new SopranoProvider().BuildRequest(channel, "https://provider.example/cgpapi///", dispatch,
            new ProviderCredential("apiKey", "test-key", "test-id"), new TestEnv());
        Assert.Equal("https://provider.example/cgpapi/messages/omnimsg", request.Url);
        Assert.Equal("POST", request.Method);
        Assert.Equal(4, request.Headers.Count);
        Assert.Equal("test-id", request.Headers["X-MEMS-API-ID"]);
        Assert.Equal("test-key", request.Headers["X-MEMS-API-Key"]);
        Assert.Equal("application/json", request.Headers["Accept"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        var expected = new Dictionary<string, object?>
        {
            ["destination"] = "15551234567",
            ["messageTypes"] = new[] { channel },
            ["correlationId"] = "correlation-id",
            ["shutterMode"] = false,
        };
        if (channel == "voice")
            expected["voice"] = new { text2voice = new { beforePasswordText = "Your code is", password = "001234", language = "en-US" } };
        else
            expected["text"] = Request().Message;
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);
    }

    [Fact]
    public void ProviderStatusesMapToExpectedOutcomesAndHttpCodes()
    {
        var adapter = new SopranoProvider();
        Outcome Parse(string body)
        {
            using var json = JsonDocument.Parse(body);
            var response = adapter.ParseResponse(200, true, json.RootElement);
            Assert.Equal(nameof(ParsedResponse), response.ToString());
            return OutcomeMapper.ResolveOutcome(adapter.Manifest, response);
        }
        Assert.Equal(Outcome.Continue, Parse("[{\"id\":12,\"state\":\"enroute\"}]"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":\"FILTERED\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":\"unknown\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":123,\"state\":\"ACCEPTED\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":false,\"state\":\"ACCEPTED\"}"));
        Assert.Equal(403, OutcomeMapper.ToHttpStatus(Outcome.Block, 200));
        Assert.Equal(409, OutcomeMapper.ToHttpStatus(Outcome.StepUp, 200));
        Assert.Equal(429, OutcomeMapper.ToHttpStatus(Outcome.Fail, 429));
    }

    [Fact]
    public void OtherProvidersKeepTheirStaticAuthenticationAndProtocols()
    {
        var env = new TestEnv { ["EPP_PROVIDER_ACCOUNT_NAME"] = "Verify" };
        var credential = new ProviderCredential("apiKey", "test-key", "test-id");
        var sms = new InfobipProvider().BuildRequest("sms", "https://provider.example", Request(), credential, env);
        Assert.Equal("App test-key", sms.Headers["Authorization"]);
        Assert.EndsWith("/sms/3/messages", sms.Url);
        using var smsJson = JsonDocument.Parse(sms.Body);
        Assert.Equal(Request().Message, smsJson.RootElement.GetProperty("messages")[0].GetProperty("content").GetProperty("text").GetString());

        var call = new SinchProvider().BuildRequest("voice", "https://provider.example", Request("voice"), credential, env);
        Assert.Equal("Bearer test-key", call.Headers["Authorization"]); // Static provider credential.
        Assert.Equal("https://calling.api.sinch.com/calling/v1/callouts", call.Url);
        using var callJson = JsonDocument.Parse(call.Body);
        Assert.Equal(Request().Message, callJson.RootElement.GetProperty("ttsCallout").GetProperty("text").GetString());
    }

    [Theory]
    [InlineData("sms", "en")]
    [InlineData("voice", "en")]
    [InlineData("sms", null)]
    [InlineData("sms", "")]
    [InlineData("sms", " ")]
    public void TelesignUsesEppJsonContract(string channel, string? locale)
    {
        var dispatch = Request(channel) with { Locale = locale };
        var request = new TelesignProvider().BuildRequest(channel, "https://verify.telesign.com///", dispatch,
            new ProviderCredential("apiKey", "test-key", "test-id"), new TestEnv());
        Assert.Equal("https://verify.telesign.com/integration/msft/cyot", request.Url);
        Assert.Equal("POST", request.Method);
        Assert.Equal(3, request.Headers.Count);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("test-id:test-key")), request.Headers["Authorization"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        Assert.Equal("application/json", request.Headers["Accept"]);
        var message = new Dictionary<string, string?> { ["text"] = dispatch.Message };
        if (locale == "en") message["language"] = locale;
        var expected = new { recipient = new { phone_number = dispatch.Destination }, message,
            channels = new[] { new { channel } }, correlation_id = dispatch.CorrelationId };
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);
    }

    [Fact]
    public void TelesignValidatesRecipientAndFallsBackToMessageId()
    {
        var adapter = new TelesignProvider();
        var credential = new ProviderCredential("apiKey", "key", "id");
        foreach (var destination in new[] { "15551234567", "+0123", "+1", "+1234567890123456", "+123\n", "+123\r", "+12 34" })
            Assert.Throws<InvalidOperationException>(() => adapter.BuildRequest("sms", "https://verify.telesign.com",
                Request() with { Destination = destination }, credential, new TestEnv()));
        Assert.Throws<InvalidOperationException>(() => adapter.BuildRequest("email", "https://verify.telesign.com", Request(), credential, new TestEnv()));
        var request = adapter.BuildRequest("sms", "https://verify.telesign.com", Request() with { CorrelationId = null }, credential, new TestEnv());
        using var json = JsonDocument.Parse(request.Body);
        Assert.Equal(Request().MessageId, json.RootElement.GetProperty("correlation_id").GetString());
    }

    [Theory]
    [InlineData("{}", true, Outcome.Fail)]
    [InlineData("{\"status\":[]}", true, Outcome.Fail)]
    [InlineData("{\"status\":{\"code\":true}}", true, Outcome.Fail)]
    [InlineData("{\"status\":{\"code\":\"290\"}}", true, Outcome.Fail)]
    [InlineData("{\"status\":{\"code\":999}}", true, Outcome.Fail)]
    [InlineData("{\"status\":{\"code\":290}}", false, Outcome.Fail)]
    [InlineData("{\"status\":{\"code\":290}}", true, Outcome.Continue)]
    [InlineData("{\"status\":{\"code\":100}}", true, Outcome.Continue)]
    public void TelesignStatusFailsClosed(string payload, bool ok, Outcome expected)
    {
        var adapter = new TelesignProvider();
        using var json = JsonDocument.Parse(payload);
        var parsed = adapter.ParseResponse(ok ? 200 : 500, ok, json.RootElement);
        Assert.Equal(expected, OutcomeMapper.ResolveOutcome(adapter.Manifest, parsed));
    }

}

internal sealed class TestEnv : Dictionary<string, string?>, IEnv
{
    public string? Get(string key) => TryGetValue(key, out var value) ? value : null;
}
