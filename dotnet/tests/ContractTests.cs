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
        var voice = new TextToVoice("  Your code is \n", "012345", "en-GB");
        var dispatch = Request(channel) with { TextToVoice = voice };
        Assert.True(new SopranoProvider().Manifest.RequiresTextToVoice);
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
            expected["voice"] = new { text2voice = new { beforePasswordText = voice.BeforePasswordText,
                password = voice.Password, language = voice.Language } };
        else expected["text"] = dispatch.Message;
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);

        // Header combinations run through the real handler; retain the adapter's direct safety guard.
        foreach (var token in new string?[] { null, "token\r\nInjected: value" })
        {
            Assert.Throws<InvalidOperationException>(() => new SopranoProvider().BuildRequest(channel,
                "https://provider.example", dispatch, new ProviderCredential("oauth2", Token: token), new TestEnv()));
            var optional = new SopranoProvider().BuildRequest(channel, "https://provider.example", dispatch,
                new ProviderCredential("apiKey", "key", "id", token), new TestEnv());
            Assert.Equal(4, optional.Headers.Count);
            Assert.DoesNotContain("Authorization", optional.Headers.Keys);
        }
        Assert.Equal(nameof(ProviderCredential), new ProviderCredential("oauth2", "key", "id", "token").ToString());
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

        var form = new TelesignProvider().BuildRequest("sms", "https://provider.example", Request(), credential, env);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("test-id:test-key")), form.Headers["Authorization"]);
        Assert.Equal("application/x-www-form-urlencoded", form.Headers["Content-Type"]);
        Assert.EndsWith("/v1/messaging", form.Url);
        Assert.Contains("message=" + Uri.EscapeDataString(Request().Message!), form.Body);

        var call = new SinchProvider().BuildRequest("voice", "https://provider.example", Request("voice"), credential, env);
        Assert.Equal("Bearer test-key", call.Headers["Authorization"]); // Static provider credential.
        Assert.Equal("https://calling.api.sinch.com/calling/v1/callouts", call.Url);
        using var callJson = JsonDocument.Parse(call.Body);
        Assert.Equal(Request().Message, callJson.RootElement.GetProperty("ttsCallout").GetProperty("text").GetString());
    }

}

internal sealed class TestEnv : Dictionary<string, string?>, IEnv
{
    public string? Get(string key) => TryGetValue(key, out var value) ? value : null;
}
