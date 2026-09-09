using System.Text;
using System.Text.Json;
using Epp.Otp;
using Epp.Otp.Providers;
using Xunit;

namespace Epp.Otp.Tests;

public class ContractTests
{
    private sealed class FakeEnv : Dictionary<string, string?>, IEnv
    {
        public string? Get(string key) => TryGetValue(key, out var v) ? v : null;
    }

    private static DispatchRequest Disp(string channel = "sms", string? message = null) =>
        new("+15551234567", message, channel, "m", "c", null);

    [Fact]
    public void ExpectedCallerIsCaseInsensitiveButRequired()
    {
        Assert.True(TokenValidator.IsExpectedCaller("EXPECTED-APP", "expected-app"));
        Assert.False(TokenValidator.IsExpectedCaller(null, "expected-app"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AuthCanBeDisabledLocallyButFailsClosedInAzure(bool onAzure)
    {
        var env = new FakeEnv
        {
            ["EPP_REQUIRE_AUTH"] = "false",
            ["WEBSITE_INSTANCE_ID"] = onAzure ? "instance" : null,
        };
        var result = await new TokenValidator(env).ValidateAsync(null);
        Assert.Equal(!onAzure, result.Ok);
        if (onAzure) Assert.Contains("EPP_REQUIRE_AUTH", result.Reason);
    }

    [Fact]
    public void BlockStepUpAndClientErrorsKeepTheirMappings()
    {
        Assert.Equal(Outcome.Block, OutcomeMapper.ResolveOutcome(new SopranoProvider().Manifest,
            new ParsedResponse(false, 403, ProviderStatusName: "BLOCKED")));
        Assert.Equal(403, OutcomeMapper.ToHttpStatus(Outcome.Block, 200));
        Assert.Equal(409, OutcomeMapper.ToHttpStatus(Outcome.StepUp, 200));
        Assert.Equal(401, OutcomeMapper.ToHttpStatus(Outcome.Fail, 403));
        Assert.Equal(400, OutcomeMapper.ToHttpStatus(Outcome.Fail, 422));
    }

    [Fact]
    public void TelesignUsesBasicAuthAndVoiceMapping()
    {
        var env = new FakeEnv();
        var req = new TelesignProvider().BuildRequest("sms", "https://rest-api.telesign.com",
            Disp(message: "code 918273"), new ProviderCredential("apiKey", Secret: "key", Identity: "cust"), env);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("cust:key")), req.Headers["Authorization"]);
        Assert.EndsWith("/v1/messaging", req.Url);

        var m = new TelesignProvider().Manifest;
        Assert.Equal(Outcome.Continue, OutcomeMapper.ResolveOutcome(m, new ParsedResponse(true, 200, ProviderStatusCode: "100")));
    }

    [Theory]
    [InlineData("sms")]
    [InlineData("voice")]
    public void SopranoPostsTheOmnimsgPayload(string channel)
    {
        var req = new SopranoProvider().BuildRequest(channel, "https://qa.example.com/cgpapi",
            Disp(channel, "code 918273"), new ProviderCredential("apiKey", Secret: "k", Identity: "id"), new FakeEnv());

        Assert.Equal("id", req.Headers["X-MEMS-API-ID"]);
        Assert.Equal("k", req.Headers["X-MEMS-API-Key"]);
        Assert.EndsWith("/messages/omnimsg", req.Url);
        using var body = JsonDocument.Parse(req.Body);
        Assert.Equal(channel, body.RootElement.GetProperty("messageTypes")[0].GetString());
        Assert.Equal("15551234567", body.RootElement.GetProperty("destination").GetString());
        Assert.Contains("918273", body.RootElement.GetProperty("text").GetString());
    }

    [Fact]
    public void SinchUsesBearerAuthForSms()
    {
        var env = new FakeEnv { ["SINCH_SERVICE_PLAN_ID"] = "plan" };
        var req = new SinchProvider().BuildRequest("sms", "https://sms.api.sinch.com",
            Disp(message: "code 918273"), new ProviderCredential("apiKey", Secret: "token"), env);
        Assert.Equal("Bearer token", req.Headers["Authorization"]);
        Assert.EndsWith("/xms/v1/plan/batches", req.Url);
    }
}
