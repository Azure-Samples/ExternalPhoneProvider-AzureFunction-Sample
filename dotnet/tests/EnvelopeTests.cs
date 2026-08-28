using System.Security.Cryptography;
using System.Text.Json;
using Epp.Otp;
using Xunit;

namespace Epp.Otp.Tests;

// Envelope validation + JWE decryption round-trip (see docs/CONTRACT.md §1, §6).
public class EnvelopeTests
{
    private static JsonElement Payload(string json) => JsonDocument.Parse(json).RootElement;

    private sealed class FakeKeyProvider : IJweKeyProvider
    {
        private readonly RSA _rsa;
        public FakeKeyProvider(RSA rsa) => _rsa = rsa;
        public RSA GetPrivateKey(string? kid) => _rsa;
    }

    [Fact]
    public void MissingEncryptedContext_IsError()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload("{\"channel\":1,\"mode\":1}"));
        Assert.Null(envelope);
        Assert.Contains("encryptedDeliveryContext", error);
    }

    [Fact]
    public void UnsupportedChannel_IsError()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload("{\"channel\":9,\"mode\":1,\"encryptedDeliveryContext\":\"x\"}"));
        Assert.Null(envelope);
        Assert.Contains("channel", error);
    }

    [Fact]
    public void UnsupportedMode_IsError()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload("{\"channel\":1,\"mode\":5,\"encryptedDeliveryContext\":\"x\"}"));
        Assert.Null(envelope);
        Assert.Contains("mode", error);
    }

    [Fact]
    public void ValidEnvelope_Parses()
    {
        var (envelope, error) = EnvelopeParser.Parse(Payload(
            "{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"tenantId\":\"t\",\"correlationId\":\"c\",\"channel\":2,\"mode\":1,\"ttlSeconds\":60,\"encryptedDeliveryContext\":\"x\"}"));
        Assert.Null(error);
        Assert.NotNull(envelope);
        Assert.Equal(2, envelope!.Channel);
        Assert.Equal(1, envelope.Mode);
        Assert.Equal("voice", EnvelopeParser.ChannelName(envelope.Channel));
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
