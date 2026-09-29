using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Epp.Otp;

public sealed class DeliveryContext
{
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("phoneNumber")] public string? PhoneNumber { get; set; }
    [JsonPropertyName("locale")] public string? Locale { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }

    [JsonIgnore]
    public bool IsComplete => !string.IsNullOrWhiteSpace(Nonce)
        && !string.IsNullOrWhiteSpace(PhoneNumber)
        && !string.IsNullOrWhiteSpace(Message);
}

public interface IJweKeyProvider
{
    RSA GetPrivateKey(string? kid);
}

public sealed class JweDecryptor
{
    private const int MaxJweLength = 16384;
    private readonly IJweKeyProvider _keys;

    public JweDecryptor(IJweKeyProvider keys) => _keys = keys;

    public (string? Kid, DeliveryContext Context) Decrypt(string compactJwe)
    {
        AssertWellFormed(compactJwe);
        var headers = Jose.JWT.Headers(compactJwe);
        var kid = headers.TryGetValue("kid", out var kidValue) ? kidValue?.ToString() : null;
        var rsa = _keys.GetPrivateKey(kid);
        // Pin alg/enc so a tampered header can't downgrade the crypto.
        var plaintext = Jose.JWT.Decrypt(compactJwe, rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        using var payload = JsonDocument.Parse(plaintext);
        var context = ReadContext(payload.RootElement);
        return (kid, context);
    }

    private static DeliveryContext ReadContext(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object) return new();
        string? ReadString(string name) => payload.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        return new DeliveryContext
        {
            Nonce = ReadString("nonce"),
            PhoneNumber = ReadString("phoneNumber"),
            Message = ReadString("message"),
            Locale = ReadString("locale"),
        };
    }

    private static void AssertWellFormed(string compactJwe)
    {
        // Reject oversized or malformed input before decoding or allocating buffers.
        if (string.IsNullOrEmpty(compactJwe))
            throw new InvalidOperationException("malformed JWE");
        if (compactJwe.Length > MaxJweLength)
            throw new InvalidOperationException("delivery context exceeds size limit");
        var segments = compactJwe.Split('.');
        if (segments.Length != 5 || Array.Exists(segments, string.IsNullOrEmpty))
            throw new InvalidOperationException("malformed JWE: expected five non-empty segments");
    }
}

public sealed class EnvJweKeyProvider : IJweKeyProvider
{
    private readonly IEnv _env;
    private RSA? _cached;
    private string? _cachedPem;

    public EnvJweKeyProvider(IEnv env) => _env = env;

    public RSA GetPrivateKey(string? kid)
    {
        var pem = AppConfig.Read(_env).DecryptionKeyPem;
        if (string.IsNullOrEmpty(pem))
            throw new InvalidOperationException("private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)");

        if (_cached is not null && _cachedPem == pem) return _cached;

        var rsa = RSA.Create();
        rsa.ImportFromPem(NormalizePem(pem));
        _cached = rsa;
        _cachedPem = pem;
        return rsa;
    }

    // Base64 preserves PEM newlines in app settings; accept either form.
    private static string NormalizePem(string value) =>
        value.Contains("-----BEGIN", StringComparison.Ordinal)
            ? value
            : Encoding.UTF8.GetString(Convert.FromBase64String(value.Trim()));
}
