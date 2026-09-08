using System.Text.Json;
using Epp.Otp;
using Epp.Otp.Providers;
using Xunit;

namespace Epp.Otp.Tests;

public class HardeningTests
{
    [Theory]
    [InlineData("[]")]
    [InlineData("[1]")]
    [InlineData("{}")]
    [InlineData("true")]
    [InlineData("false")]
    [InlineData("null")]
    [InlineData("\"__proto__\"")]
    [InlineData("\"constructor\"")]
    [InlineData("\"1\"")]
    public void InvalidRoutingTypesAreRejected(string value)
    {
        foreach (var field in new[] { "channel", "mode" })
        {
            var other = field == "channel" ? "mode" : "channel";
            using var doc = JsonDocument.Parse($"{{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"{field}\":{value},\"{other}\":1,\"encryptedDeliveryContext\":\"unused\"}}");
            Assert.NotNull(EnvelopeParser.Parse(doc.RootElement).Error);
        }
    }

    [Fact]
    public void TtlMayBeOmittedButNotNull()
    {
        using var valid = JsonDocument.Parse("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"encryptedDeliveryContext\":\"unused\"}");
        using var invalid = JsonDocument.Parse("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"ttlSeconds\":null,\"encryptedDeliveryContext\":\"unused\"}");
        Assert.Null(EnvelopeParser.Parse(valid.RootElement).Error);
        Assert.NotNull(EnvelopeParser.Parse(invalid.RootElement).Error);
    }

    [Theory]
    [InlineData(401, 401)]
    [InlineData(429, 429)]
    [InlineData(500, 502)]
    public void HttpFailureOverridesSuccessLookingBody(int status, int expected)
    {
        var cases = new (IProviderAdapter Adapter, string Body)[]
        {
            (new InfobipProvider(), "{\"messages\":[{\"status\":{\"name\":\"DELIVERED\"}}]}"),
            (new TelesignProvider(), "{\"status\":{\"code\":290}}"),
            (new SopranoProvider(), "{\"status\":\"ENROUTE\"}"),
            (new SinchProvider(), "{\"status\":\"Dispatched\"}"),
        };
        foreach (var (adapter, body) in cases)
        {
            using var doc = JsonDocument.Parse(body);
            var parsed = adapter.ParseResponse(status, false, doc.RootElement);
            var outcome = OutcomeMapper.ResolveOutcome(adapter.Manifest, parsed);
            Assert.Equal(Outcome.Fail, outcome);
            Assert.Equal(expected, OutcomeMapper.ToHttpStatus(outcome, status));
        }
    }

    [Fact]
    public void ExplicitBlockOutcomeIsPreserved()
    {
        var manifest = new SopranoProvider().Manifest;
        Assert.Equal(Outcome.Block, OutcomeMapper.ResolveOutcome(manifest,
            new ParsedResponse(false, 403, ProviderStatusName: "BLOCKED")));
    }
}