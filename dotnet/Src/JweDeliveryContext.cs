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

public sealed record DecryptedPayload<T>(string? KeyId, T Value);

public sealed class JweDecryptor
{
    private const int MaxJweLength = 16384;
    private readonly IEnv _env;
    private RSA? _cachedKey;
    private string? _cachedPem;

    public JweDecryptor(IEnv env) => _env = env;

    public DecryptedPayload<T> Decrypt<T>(string encryptedContent)
    {
        AssertWellFormed(encryptedContent);
        var headers = Jose.JWT.Headers(encryptedContent);
        var keyId = headers.TryGetValue("kid", out var value) ? value?.ToString() : null;
        // Pin alg/enc so a tampered header can't downgrade the crypto.
        var plaintext = Jose.JWT.Decrypt(
            encryptedContent,
            GetPrivateKey(),
            Jose.JweAlgorithm.RSA_OAEP_256,
            Jose.JweEncryption.A256GCM);
        var payload = JsonSerializer.Deserialize<T>(plaintext)
            ?? throw new JsonException("decrypted payload is empty");
        return new DecryptedPayload<T>(keyId, payload);
    }

    private RSA GetPrivateKey()
    {
        var pem = AppConfig.Read(_env).DecryptionKeyPem;
        if (string.IsNullOrEmpty(pem))
            throw new InvalidOperationException(
                "private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)");
        if (_cachedKey is not null && _cachedPem == pem) return _cachedKey;

        var key = RSA.Create();
        key.ImportFromPem(NormalizePem(pem));
        _cachedKey = key;
        _cachedPem = pem;
        return key;
    }

    private static void AssertWellFormed(string encryptedContent)
    {
        // Reject oversized or malformed input before decoding or allocating buffers.
        if (string.IsNullOrEmpty(encryptedContent))
            throw new InvalidOperationException("malformed JWE");
        if (encryptedContent.Length > MaxJweLength)
            throw new InvalidOperationException("delivery context exceeds size limit");
        var segments = encryptedContent.Split('.');
        if (segments.Length != 5 || Array.Exists(segments, string.IsNullOrEmpty))
            throw new InvalidOperationException("malformed JWE: expected five non-empty segments");
    }

    // Base64 preserves PEM newlines in app settings; accept either form.
    private static string NormalizePem(string value) =>
        value.Contains("-----BEGIN", StringComparison.Ordinal)
            ? value
            : Encoding.UTF8.GetString(Convert.FromBase64String(value.Trim()));
}
