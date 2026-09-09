using System.Security.Cryptography;
using System.Text.Json;
using Epp.Otp;
using Xunit;

namespace Epp.Otp.Tests;

public class EnvelopeTests
{
    private static JsonElement Payload(string json)
    {
        using var document = JsonDocument.Parse(json);
        return document.RootElement.Clone();
    }

    internal sealed class FakeKeyProvider(RSA rsa, Exception? failure = null) : IJweKeyProvider
    {
        public RSA GetPrivateKey(string? kid) => failure is not null ? throw failure : rsa;
    }

    [Fact]
    public void MissingEncryptedContext_IsError()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1}"));
        Assert.Null(envelope);
        Assert.Contains("encryptedDeliveryContext", error);
    }

    [Theory]
    [InlineData("type", "\"phone=+15551234567 code=918273 token=private\"")]
    [InlineData("channel", "9")]
    [InlineData("mode", "true")]
    public void InvalidRouting_IsRejectedWithoutEchoingInput(string field, string value)
    {
        var payload = new Dictionary<string, object?>
        {
            ["type"] = EnvelopeParser.EnvelopeType, ["channel"] = 1, ["mode"] = 1,
            ["encryptedDeliveryContext"] = "x",
        };
        payload[field] = Payload(value);
        var (envelope, error) = EnvelopeParser.Parse(JsonSerializer.SerializeToElement(payload));
        Assert.Null(envelope);
        Assert.Equal($"unsupported {field}", error);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void ValidEnvelope_ParsesWithOptionalTtl(bool includeTtl)
    {
        var ttl = includeTtl ? ",\"ttlSeconds\":60" : "";
        var (envelope, error) = EnvelopeParser.Parse(Payload(
            $"{{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"tenantId\":\"t\",\"correlationId\":\"c\",\"channel\":2,\"mode\":1,\"encryptedDeliveryContext\":\"x\"{ttl}}}"));
        Assert.Null(error);
        Assert.NotNull(envelope);
        Assert.Equal(2, envelope.Channel);
        Assert.Equal(1, envelope.Mode);
        Assert.Equal(includeTtl ? (int?)60 : null, envelope.TtlSeconds);
        Assert.Equal("voice", EnvelopeParser.ChannelName(envelope.Channel));
    }

    [Theory]
    [InlineData("\"0\"")]
    [InlineData("0.5")]
    [InlineData("null")]
    public void MalformedTtl_IsError(string ttlJson)
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload(
            $"{{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"ttlSeconds\":{ttlJson},\"encryptedDeliveryContext\":\"x\"}}"));
        Assert.Null(envelope);
        Assert.Contains("positive integer", error);
    }

    [Fact]
    public void ExpiredTtl_IsError()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload(
            "{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"ttlSeconds\":0,\"encryptedDeliveryContext\":\"x\"}"));
        Assert.Null(envelope);
        Assert.Contains("expired", error);
    }

    [Fact]
    public void Jwe_RoundTrips_ToDeliveryContext()
    {
        using var rsa = RSA.Create(2048);
        var contextJson = JsonSerializer.Serialize(new
        {
            nonce = "nonce-1",
            phoneNumber = "+14255551234",
            message = "Your code is 123456",
            locale = "en-US",
        });
        var jwe = Jose.JWT.Encode(contextJson, rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM,
            extraHeaders: new Dictionary<string, object> { ["kid"] = "test-key" });

        var decrypted = new JweDecryptor(new FakeKeyProvider(rsa)).Decrypt(jwe);
        Assert.Equal("test-key", decrypted.Kid);
        Assert.Equal("RSA-OAEP-256", decrypted.Alg);
        Assert.Equal("A256GCM", decrypted.Enc);
        var context = decrypted.Context;
        Assert.Equal("nonce-1", context.Nonce);
        Assert.Equal("+14255551234", context.PhoneNumber);
        Assert.Equal("Your code is 123456", context.Message);
        Assert.Equal("en-US", context.Locale);
    }
}
