using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Epp.Otp.Tests;

public class EnvelopeTests
{
    [Theory]
    [InlineData("\"channel\":1,\"mode\":2,\"ttlSeconds\":60", "sms", 2, 60)]
    [InlineData("\"channel\":\"VOICE\",\"mode\":\"Live\"", "voice", 1, null)]
    public void NumericAndNamedRoutingParse(string routing, string channel, int mode, int? ttl)
    {
        var (envelope, error) = Parse(routing);
        Assert.Null(error);
        Assert.NotNull(envelope);
        Assert.Equal(channel, EnvelopeParser.ChannelName(envelope.Channel));
        Assert.Equal(mode, envelope.Mode);
        Assert.Equal(ttl, envelope.TtlSeconds);
    }

    [Fact]
    public void InvalidEnvelopeFieldsAreRejectedWithoutCoercion()
    {
        foreach (var (field, value, error) in new[]
        {
            ("type", "\"wrong-type\"", "unsupported envelope type"),
            ("channel", "true", "unsupported channel"),
            ("mode", "null", "unsupported mode"),
            ("encryptedDeliveryContext", "\"\"", "encryptedDeliveryContext is required"),
            ("ttlSeconds", "\"60\"", "ttlSeconds must be a positive int32"),
            ("ttlSeconds", "0", "delivery context expired"),
        })
        {
            var payload = JsonNode.Parse("""
                {"type":"microsoft.mfa.otpDeliver.v1","channel":1,"mode":1,"encryptedDeliveryContext":"x"}
                """)!;
            payload[field] = JsonNode.Parse(value);
            Assert.Equal(error, EnvelopeParser.Parse(JsonSerializer.SerializeToElement(payload)).Error);
        }
    }

    [Fact]
    public void RealJweRejectsTagTamperingAndAlgorithmDowngrades()
    {
        using var keys = new TestKeys();
        var decryptor = new JweDecryptor(keys);
        var compact = Jose.JWT.Encode("{\"nonce\":\"private-nonce\"}", keys.Rsa,
            Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        var parts = compact.Split('.');
        var tag = Base64UrlEncoder.DecodeBytes(parts[4]);
        tag[0] ^= 1;
        parts[4] = Base64UrlEncoder.Encode(tag);
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(string.Join(".", parts)));
        var wrongAlg = Jose.JWT.Encode("{}", keys.Rsa, Jose.JweAlgorithm.RSA_OAEP, Jose.JweEncryption.A256GCM);
        var wrongEnc = Jose.JWT.Encode("{}", keys.Rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A128GCM);
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(wrongAlg));
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(wrongEnc));
    }

    private static (Envelope? Envelope, string? Error) Parse(string routing) =>
        EnvelopeParser.Parse(JsonSerializer.Deserialize<JsonElement>(
            "{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"encryptedDeliveryContext\":\"x\"," + routing + "}"));
}

internal sealed class TestKeys : IJweKeyProvider, IDisposable
{
    public RSA Rsa { get; } = RSA.Create(2048);
    public int Calls { get; private set; }
    public Exception? Error { get; set; }
    public RSA GetPrivateKey(string? kid)
    {
        Calls++;
        if (Error is not null) throw Error;
        return Rsa;
    }
    public void Dispose() => Rsa.Dispose();
}
