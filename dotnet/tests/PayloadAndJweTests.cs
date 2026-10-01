using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Epp.Otp.Tests;

public class PayloadAndJweTests
{
    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(false, false)]
    public void KeyVaultPemCertificateBundleDecrypts(bool certificateFirst, bool base64Encoded)
    {
        using var rsa = RSA.Create(2048);
        var request = new CertificateRequest("CN=EPP-test", rsa, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var certificate = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-1), DateTimeOffset.UtcNow.AddDays(1));
        var publicPem = certificate.ExportCertificatePem();
        var privatePem = rsa.ExportPkcs8PrivateKeyPem();
        var bundle = certificateFirst ? $"{publicPem}\n{privatePem}" : $"{privatePem}\n{publicPem}";
        var env = new TestEnv
        {
            ["EPP_DECRYPTION_KEY_PEM"] = base64Encoded ? Convert.ToBase64String(Encoding.UTF8.GetBytes(bundle)) : bundle
        };
        var decryptor = new JweDecryptor(env);
        var compact = Jose.JWT.Encode("{\"nonce\":\"test-nonce\"}", rsa,
            Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        Assert.Equal(
            "test-nonce",
            decryptor.Decrypt<DeliveryContext>(compact).Value.Nonce);
        Assert.Equal(
            "test-nonce",
            decryptor.Decrypt<DeliveryContext>(compact).Value.Nonce);
    }

    [Theory]
    [InlineData("1", "2", EntraOtpChannel.Sms, EntraOtpMode.Evaluation, 60)]
    [InlineData("\"VOICE\"", "\"Live\"", EntraOtpChannel.Voice, EntraOtpMode.Live, null)]
    [InlineData("\"1\"", "\"2\"", EntraOtpChannel.Sms, EntraOtpMode.Evaluation, null)]
    public void NumericAndNamedRoutingDeserialize(
        string channelJson, string modeJson, EntraOtpChannel channel, EntraOtpMode mode, int? ttl)
    {
        var ttlJson = ttl is null ? "" : $",\"ttlSeconds\":{ttl}";
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(
            $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"encryptedDeliveryContext\":\"x\","
            + $"\"channel\":{channelJson},\"mode\":{modeJson}{ttlJson}}}");
        Assert.NotNull(payload);
        Assert.Equal(channel, payload.Channel);
        Assert.Equal(mode, payload.Mode);
        Assert.Equal(ttl, payload.TtlSeconds);
        Assert.Equal(channel == EntraOtpChannel.Sms ? "sms" : "voice", payload.ChannelName);
        Assert.Equal(mode == EntraOtpMode.Evaluation, payload.IsEvaluation);
        Assert.Null(payload.Validate());
    }

    [Theory]
    [InlineData("channel", "\"email\"")]
    [InlineData("channel", "true")]
    [InlineData("channel", "null")]
    [InlineData("channel", "1.5")]
    [InlineData("channel", "{}")]
    [InlineData("mode", "\"diagnostic\"")]
    [InlineData("mode", "false")]
    [InlineData("mode", "null")]
    [InlineData("mode", "1.5")]
    [InlineData("mode", "[]")]
    public void RoutingConvertersRejectUnsupportedTokens(string property, string value)
    {
        var channel = property == "channel" ? value : "1";
        var mode = property == "mode" ? value : "1";
        var json = $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"encryptedDeliveryContext\":\"x\","
            + $"\"channel\":{channel},\"mode\":{mode}}}";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<EntraSendOtpPayload>(json));
    }

    [Theory]
    [InlineData(0, 1, "unsupported channel")]
    [InlineData(3, 1, "unsupported channel")]
    [InlineData(1, 0, "unsupported mode")]
    [InlineData(1, 3, "unsupported mode")]
    public void UndefinedNumericRoutingValuesFailSemanticValidation(
        int channel, int mode, string expected)
    {
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(
            $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"encryptedDeliveryContext\":\"x\","
            + $"\"channel\":{channel},\"mode\":{mode}}}");
        Assert.NotNull(payload);
        Assert.Equal(expected, payload.Validate());
    }

    [Theory]
    [InlineData("\"60\"")]
    [InlineData("true")]
    [InlineData("1.5")]
    [InlineData("2147483648")]
    public void TtlConverterRejectsNonIntegerValues(string value)
    {
        var json = $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"encryptedDeliveryContext\":\"x\","
            + $"\"channel\":1,\"mode\":1,\"ttlSeconds\":{value}}}";
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<EntraSendOtpPayload>(json));
    }

    [Fact]
    public void ExplicitNullTtlIsEquivalentToOmittedTtl()
    {
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(
            $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"encryptedDeliveryContext\":\"x\","
            + "\"channel\":1,\"mode\":1,\"ttlSeconds\":null}");
        Assert.NotNull(payload);
        Assert.Null(payload.TtlSeconds);
        Assert.Null(payload.Validate());
    }

    [Theory]
    [InlineData("{\"channel\":1,\"mode\":1,\"encryptedDeliveryContext\":\"x\"}", "unsupported payload type")]
    [InlineData("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"encryptedDeliveryContext\":\" \"}", "encryptedDeliveryContext is required")]
    [InlineData("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"mode\":1,\"encryptedDeliveryContext\":\"x\"}", "unsupported channel")]
    [InlineData("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"encryptedDeliveryContext\":\"x\"}", "unsupported mode")]
    [InlineData("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"ttlSeconds\":0,\"encryptedDeliveryContext\":\"x\"}", "ttlSeconds expired")]
    [InlineData("{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"channel\":1,\"mode\":1,\"ttlSeconds\":-1,\"encryptedDeliveryContext\":\"x\"}", "ttlSeconds expired")]
    public void BoundPayloadPreservesSemanticValidation(string json, string expected)
    {
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(json);
        Assert.NotNull(payload);
        Assert.Equal(expected, payload.Validate());
    }

    [Fact]
    public void BoundPayloadAllowsOptionalTtlAndIgnoresUnknownFields()
    {
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(
            $"{{\"type\":\"{EntraSendOtpPayload.SupportedType}\",\"channel\":\"SMS\",\"mode\":\"EVALUATION\","
            + "\"encryptedDeliveryContext\":\"x\",\"tenantId\":\"tenant\",\"diagnosticData\":{\"token\":\"private\"}}");
        Assert.NotNull(payload);
        Assert.Null(payload.Validate());
        Assert.Null(payload.TtlSeconds);
        Assert.Equal("tenant", payload.TenantId);
    }

    [Fact]
    public void RealJweRejectsTagTamperingAndMissingSegments()
    {
        using var keys = new TestKeys();
        var decryptor = new JweDecryptor(keys.Env);
        var compact = Jose.JWT.Encode("{\"nonce\":\"private-nonce\"}", keys.Rsa,
            Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        var parts = compact.Split('.');
        parts[4] = (parts[4][0] == 'A' ? "B" : "A") + parts[4][1..];
        Assert.ThrowsAny<Exception>(() =>
            decryptor.Decrypt<DeliveryContext>(string.Join(".", parts)));
        Assert.ThrowsAny<Exception>(() =>
            decryptor.Decrypt<DeliveryContext>(string.Join(".", parts.Take(4))));
    }

    [Fact]
    public void JweAuthenticatesOriginalProtectedHeaderBytes()
    {
        using var keys = new TestKeys();
        const string header = "{ \"kid\" : \"test-key\", \"enc\" : \"A256GCM\", \"alg\" : \"RSA-OAEP-256\" }";
        static string Encode(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var encodedHeader = Encode(Encoding.UTF8.GetBytes(header));
        var key = RandomNumberGenerator.GetBytes(32);
        var iv = RandomNumberGenerator.GetBytes(12);
        var plaintext = Encoding.UTF8.GetBytes("{\"nonce\":\"test-nonce\",\"phoneNumber\":\"+15551234567\",\"message\":\"message\"}");
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using var cipher = new AesGcm(key, tag.Length);
        cipher.Encrypt(iv, plaintext, ciphertext, tag, Encoding.ASCII.GetBytes(encodedHeader));
        var wrappedKey = keys.Rsa.Encrypt(key, RSAEncryptionPadding.OaepSHA256);
        var segments = new[] { encodedHeader, Encode(wrappedKey), Encode(iv), Encode(ciphertext), Encode(tag) };
        var decryptor = new JweDecryptor(keys.Env);
        var context = decryptor.Decrypt<DeliveryContext>(string.Join(".", segments)).Value;
        Assert.Equal("test-nonce", context.Nonce);
        Assert.True(context.IsComplete);
        Assert.False(JsonSerializer.SerializeToElement(context).TryGetProperty("IsComplete", out _));
        segments[0] = Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(JsonSerializer.Deserialize<JsonElement>(header))));
        Assert.NotEqual(encodedHeader, segments[0]);
        Assert.ThrowsAny<Exception>(() =>
            decryptor.Decrypt<DeliveryContext>(string.Join(".", segments)));
    }

}

internal sealed class TestKeys : IDisposable
{
    public RSA Rsa { get; } = RSA.Create(2048);
    public TestEnv Env { get; }

    public TestKeys()
    {
        Env = new TestEnv
        {
            ["EPP_DECRYPTION_KEY_PEM"] = Rsa.ExportPkcs8PrivateKeyPem(),
        };
    }

    public void Dispose() => Rsa.Dispose();
}
