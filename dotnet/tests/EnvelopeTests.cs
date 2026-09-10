using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Xunit;

namespace Epp.Otp.Tests;

public class EnvelopeTests
{
    [Theory]
    [InlineData("\"channel\":1,\"mode\":2,\"ttlSeconds\":60", "sms", 2, 60)]
    [InlineData("\"channel\":\"VOICE\",\"mode\":\"Live\"", "voice", 1, null)]
    public async Task NumericAndNamedRoutingParse(string routing, string channel, int mode, int? ttl)
    {
        var (envelope, error) = Parse(routing);
        Assert.Null(error);
        Assert.NotNull(envelope);
        Assert.Equal(channel, EnvelopeParser.ChannelName(envelope.Channel));
        Assert.Equal(mode, envelope.Mode);
        Assert.Equal(ttl, envelope.TtlSeconds);
        using var body = new MemoryStream(Encoding.UTF8.GetBytes(Payload(routing)));
        Assert.Equal((envelope, error), await EnvelopeParser.ParseAsync(body));
        Assert.True(body.CanRead);
    }

    [Fact]
    public async Task StreamParserRejectsInvalidUtf8ButPropagatesCancellationAndReadErrors()
    {
        var bytes = Encoding.UTF8.GetBytes("{\"type\":\"private-input\"}");
        bytes[9] = 0xff;
        using var invalidUtf8 = new MemoryStream(bytes);
        var (envelope, error) = await EnvelopeParser.ParseAsync(invalidUtf8);
        Assert.Null(envelope);
        Assert.Equal("invalid JSON body", error);

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        using var body = new MemoryStream(Encoding.UTF8.GetBytes("{}"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => EnvelopeParser.ParseAsync(body, cancelled.Token));
        using var unreadable = new UnreadableBody();
        await Assert.ThrowsAsync<IOException>(() => EnvelopeParser.ParseAsync(unreadable));
    }

    [Fact]
    public void RealJweRejectsTagTamperingAndMissingSegments()
    {
        using var keys = new TestKeys();
        var decryptor = new JweDecryptor(keys);
        var compact = Jose.JWT.Encode("{\"nonce\":\"private-nonce\"}", keys.Rsa,
            Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        var parts = compact.Split('.');
        parts[4] = (parts[4][0] == 'A' ? "B" : "A") + parts[4][1..];
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(string.Join(".", parts)));
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(string.Join(".", parts.Take(4))));
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
        using var fixtures = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "contract.json")));
        var voiceFields = fixtures.RootElement.GetProperty("textToVoice");
        var plaintext = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { nonce = "test-nonce",
            phoneNumber = "+15551234567", message = "message", voice = new { text2voice = voiceFields } }));
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using var cipher = new AesGcm(key, tag.Length);
        cipher.Encrypt(iv, plaintext, ciphertext, tag, Encoding.ASCII.GetBytes(encodedHeader));
        var wrappedKey = keys.Rsa.Encrypt(key, RSAEncryptionPadding.OaepSHA256);
        var segments = new[] { encodedHeader, Encode(wrappedKey), Encode(iv), Encode(ciphertext), Encode(tag) };
        var decryptor = new JweDecryptor(keys);
        var context = decryptor.Decrypt(string.Join(".", segments)).Context;
        Assert.Equal("test-nonce", context.Nonce);
        Assert.True(context.IsComplete);
        Assert.False(JsonSerializer.SerializeToElement(context).TryGetProperty("IsComplete", out _));
        var voice = Assert.IsType<TextToVoice>(context.TextToVoice);
        Assert.True(voice.IsComplete);
        Assert.Equal("  Your code is \n", voice.BeforePasswordText);
        Assert.Equal("012345", voice.Password);
        Assert.Equal("en-GB", voice.Language);
        Assert.Equal(nameof(TextToVoice), voice.ToString());
        Assert.False(JsonSerializer.SerializeToElement(voice).TryGetProperty("IsComplete", out _));
        foreach (var prefix in new[] { "", new string(' ', 1601) })
            Assert.True((voice with { BeforePasswordText = prefix }).IsComplete);
        foreach (var changes in fixtures.RootElement.GetProperty("incompleteVoiceContexts").EnumerateArray())
            Assert.NotEqual(true, DeliveryContext.FromPayload(changes).TextToVoice?.IsComplete);
        var numeric = TextToVoice.FromPayload(JsonSerializer.SerializeToElement(new {
            beforePasswordText = "Your code is", password = 12345, language = "en-GB" }));
        Assert.Null(numeric!.Password);
        Assert.Null(new DispatchRequest("phone", "message", "sms", "id", null, null).TextToVoice);
        segments[0] = Encode(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(JsonSerializer.Deserialize<JsonElement>(header))));
        Assert.NotEqual(encodedHeader, segments[0]);
        Assert.ThrowsAny<Exception>(() => decryptor.Decrypt(string.Join(".", segments)));
    }

    private static string Payload(string routing) =>
        "{\"type\":\"microsoft.mfa.otpDeliver.v1\",\"encryptedDeliveryContext\":\"x\"," + routing + "}";

    private static (Envelope? Envelope, string? Error) Parse(string routing) =>
        EnvelopeParser.Parse(JsonSerializer.Deserialize<JsonElement>(Payload(routing)));

    private sealed class UnreadableBody : MemoryStream
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) =>
            ValueTask.FromException<int>(new IOException("private read error"));
    }
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
