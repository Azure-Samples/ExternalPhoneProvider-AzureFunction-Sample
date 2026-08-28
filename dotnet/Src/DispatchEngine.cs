using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

// Delivery pipeline: parse the cleartext SAS envelope, decrypt the JWE that carries the PII, then
// dispatch to the configured provider. Fail-closed — only a Continue outcome is "accepted".

public sealed record Envelope(
    string? Type,
    string? TenantId,
    string? CorrelationId,
    int Channel,
    int Mode,
    int? TtlSeconds,
    string EncryptedDeliveryContext);

public static class EnvelopeParser
{
    public const int ModeLive = 1;
    public const int ModeEvaluation = 2;

    private static readonly Dictionary<int, string> ChannelByCode = new() { [1] = "sms", [2] = "voice" };
    private static readonly Dictionary<string, int> ChannelByName = new(StringComparer.OrdinalIgnoreCase) { ["sms"] = 1, ["voice"] = 2 };
    private static readonly Dictionary<string, int> ModeByName = new(StringComparer.OrdinalIgnoreCase) { ["live"] = ModeLive, ["evaluation"] = ModeEvaluation };

    public static string? ChannelName(int code) => ChannelByCode.TryGetValue(code, out var name) ? name : null;

    public static (Envelope? Envelope, string? Error) Parse(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object)
            return (null, "invalid envelope");

        string? String(string name) =>
            payload.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        int? Int(string name) =>
            payload.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : null;

        int? Channel()
        {
            var code = Int("channel");
            if (code is not null) return ChannelByCode.ContainsKey(code.Value) ? code : null;
            var name = String("channel");
            return name is not null && ChannelByName.TryGetValue(name, out var mapped) ? mapped : null;
        }
        int? Mode()
        {
            var code = Int("mode");
            if (code is not null) return code is ModeLive or ModeEvaluation ? code : null;
            var name = String("mode");
            return name is not null && ModeByName.TryGetValue(name, out var mapped) ? mapped : null;
        }

        var encrypted = String("encryptedDeliveryContext");
        if (string.IsNullOrEmpty(encrypted))
            return (null, "encryptedDeliveryContext is required");

        var channel = Channel();
        if (channel is null)
            return (null, "unsupported channel");

        var mode = Mode();
        if (mode is null)
            return (null, "unsupported mode");

        return (new Envelope(String("type"), String("tenantId"), String("correlationId"),
            channel.Value, mode.Value, Int("ttlSeconds"), encrypted), null);
    }
}

// Decrypted JWE plaintext: phone + the rendered message, which includes the passcode.
public sealed class DeliveryContext
{
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("phoneNumber")] public string? PhoneNumber { get; set; }
    [JsonPropertyName("extension")] public string? Extension { get; set; }
    [JsonPropertyName("locale")] public string? Locale { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
    [JsonPropertyName("riskContext")] public JsonElement? RiskContext { get; set; }
}

public sealed record JweResult(string? Kid, string? Alg, string? Enc, DeliveryContext Context);

// Injectable so tests use a local key.
public interface IJweKeyProvider
{
    RSA GetPrivateKey(string? kid);
}

public sealed class JweDecryptor
{
    private const int MaxJweLength = 16384;
    private readonly IJweKeyProvider _keys;

    public JweDecryptor(IJweKeyProvider keys) => _keys = keys;

    public JweResult Decrypt(string compactJwe)
    {
        AssertWellFormed(compactJwe);
        var headers = Jose.JWT.Headers(compactJwe);
        var kid = headers.TryGetValue("kid", out var kidValue) ? kidValue?.ToString() : null;
        var alg = headers.TryGetValue("alg", out var algValue) ? algValue?.ToString() : null;
        var enc = headers.TryGetValue("enc", out var encValue) ? encValue?.ToString() : null;
        var rsa = _keys.GetPrivateKey(kid);
        // Pin alg/enc so a tampered header can't downgrade the crypto.
        var plaintext = Jose.JWT.Decrypt(compactJwe, rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        var context = JsonSerializer.Deserialize<DeliveryContext>(plaintext) ?? new DeliveryContext();
        return new JweResult(kid, alg, enc, context);
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

// Imported once: a per-delivery RSA import would sit inside the response budget.
public sealed class EnvJweKeyProvider : IJweKeyProvider
{
    private readonly IEnv _env;
    private RSA? _cached;
    private string? _cachedPem;

    public EnvJweKeyProvider(IEnv env) => _env = env;

    public RSA GetPrivateKey(string? kid)
    {
        var pem = _env.Get("EPP_DECRYPTION_KEY_PEM");
        if (string.IsNullOrEmpty(pem))
            throw new InvalidOperationException("private key unavailable (EPP_DECRYPTION_KEY_PEM is not set)");

        if (_cached is not null && _cachedPem == pem) return _cached;

        var rsa = RSA.Create();
        rsa.ImportFromPem(NormalizePem(pem));
        _cached = rsa;
        _cachedPem = pem;
        return rsa;
    }

    // The setup script stores the key as base64 over the PEM so its newlines survive being carried as
    // an app setting, so accept either form.
    private static string NormalizePem(string value) =>
        value.Contains("-----BEGIN", StringComparison.Ordinal)
            ? value
            : Encoding.UTF8.GetString(Convert.FromBase64String(value.Trim()));
}

public sealed class DispatchEngine
{
    private const int DefaultTimeoutMs = 1500;
    private readonly ProviderRegistry _registry;
    private readonly ISecretResolver _secrets;
    private readonly IHttpClientFactory _httpFactory;
    private readonly IEnv _env;

    public DispatchEngine(ProviderRegistry registry, ISecretResolver secrets, IHttpClientFactory httpFactory, IEnv? env = null)
    {
        _registry = registry;
        _secrets = secrets;
        _httpFactory = httpFactory;
        _env = env ?? new ProcessEnv();
    }

    public async Task<DispatchResult> DispatchAsync(DispatchRequest dispatch, string? requestProvider, bool shutter, string requestId, ILogger log)
    {
        var adapter = _registry.Resolve(requestProvider);
        if (adapter is null)
        {
            log.LogWarning("[DISPATCH_ERROR] requestId={RequestId} unknown provider={Provider}", requestId, requestProvider ?? "n/a");
            return new DispatchResult(400, new { status = "error", reason = "unknown provider", requestId });
        }

        var manifest = adapter.Manifest;
        var providerId = manifest.Id;
        var channel = (dispatch.Channel ?? "sms").ToLowerInvariant();

        if (!OutcomeMapper.DefaultChannels.Contains(channel))
            return new DispatchResult(400, new { status = "error", provider = providerId, reason = $"channel '{channel}' not supported", requestId });

        // Credential (fail closed 502 if missing) — this is our credential, not the caller's token.
        ProviderCredential? credential = null;
        try { credential = await ResolveCredentialAsync(manifest.Auth); }
        catch (Exception ex) { log.LogError("[DISPATCH_ERROR] requestId={RequestId} provider={Provider} credential error={Error}", requestId, providerId, ex.Message); }

        var identityRequired = credential is { Mode: "apiKey" } && !string.IsNullOrEmpty(manifest.Auth.IdentityKeyVaultSecretName);
        var credentialUnavailable = credential is null
            || (credential.Mode == "oauth2" && string.IsNullOrEmpty(credential.Token))
            || (credential.Mode == "apiKey" && string.IsNullOrEmpty(credential.Secret))
            || (identityRequired && string.IsNullOrEmpty(credential.Identity));
        if (credentialUnavailable)
            return new DispatchResult(502, FailBody(providerId, channel, "provider credential unavailable", dispatch, requestId));

        var endpoint = ResolveEndpoint(manifest, _env);
        if (string.IsNullOrEmpty(endpoint))
            return new DispatchResult(502, FailBody(providerId, channel, "provider endpoint not configured", dispatch, requestId));

        var req = adapter.BuildRequest(channel, endpoint, dispatch, credential!, _env);
        log.LogInformation("[DISPATCH] requestId={RequestId} provider={Provider} channel={Channel} shutter={Shutter}", requestId, providerId, channel, shutter);

        if (shutter)
            return new DispatchResult(200, new { status = "accepted", shutterProcessed = true, provider = providerId, channel, correlationId = dispatch.CorrelationId, messageId = dispatch.MessageId, requestId });

        var timeoutMs = int.TryParse(_env.Get("EPP_PROVIDER_TIMEOUT_MS"), out var parsedTimeout) ? parsedTimeout : DefaultTimeoutMs;
        HttpResponseMessage resp;
        string body;
        try
        {
            (resp, body) = await SendAsync(req, timeoutMs);
        }
        catch (OperationCanceledException)
        {
            log.LogWarning("[DISPATCH_TIMEOUT] requestId={RequestId} provider={Provider}", requestId, providerId);
            return new DispatchResult(504, FailBody(providerId, channel, $"endpoint timeout after {timeoutMs}ms", dispatch, requestId));
        }
        catch (Exception ex)
        {
            log.LogError("[DISPATCH_ERROR] requestId={RequestId} provider={Provider} reason={Reason}", requestId, providerId, ex.Message);
            return new DispatchResult(502, FailBody(providerId, channel, ex.Message, dispatch, requestId));
        }

        JsonElement json;
        try { using var responseDocument = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body); json = responseDocument.RootElement.Clone(); }
        catch { using var emptyDocument = JsonDocument.Parse("{}"); json = emptyDocument.RootElement.Clone(); }

        var parsed = adapter.ParseResponse((int)resp.StatusCode, resp.IsSuccessStatusCode, json);
        var outcome = OutcomeMapper.ResolveOutcome(manifest, parsed);
        var httpStatus = OutcomeMapper.ToHttpStatus(outcome, parsed.ProviderHttpStatus);

        log.LogInformation("[DISPATCH_RESULT] requestId={RequestId} provider={Provider} channel={Channel} outcome={Outcome} providerStatus={Status} httpStatus={Http}",
            requestId, providerId, channel, outcome, parsed.ProviderStatusName ?? parsed.ProviderStatusCode ?? "n/a", httpStatus);

        return new DispatchResult(httpStatus, new
        {
            status = outcome == Outcome.Continue ? "accepted" : "failed",
            outcome = outcome.ToString(),
            provider = providerId,
            channel,
            messageId = dispatch.MessageId,
            correlationId = dispatch.CorrelationId,
            providerMessageId = parsed.ProviderMessageId,
            providerStatus = parsed.ProviderStatusName ?? parsed.ProviderStatusCode,
            providerStatusDescription = parsed.ProviderStatusDescription,
            requestId,
        });
    }

    private async Task<ProviderCredential> ResolveCredentialAsync(AuthConfig auth)
    {
        if (auth.Mode == "oauth2") return new ProviderCredential("oauth2", Token: null); // not wired -> fails closed
        var secret = await _secrets.ResolveAsync(auth.KeyVaultSecretName);
        var identity = string.IsNullOrEmpty(auth.IdentityKeyVaultSecretName) ? string.Empty : await _secrets.ResolveAsync(auth.IdentityKeyVaultSecretName);
        return new ProviderCredential("apiKey", Secret: secret, Identity: identity);
    }

    // Base URL from app settings: one provider is active per deployment, so the endpoint is a single
    // EPP_PROVIDER_ENDPOINT rather than a per-provider key.
    private static string? ResolveEndpoint(ProviderManifest manifest, IEnv env) => env.Get("EPP_PROVIDER_ENDPOINT");

    private async Task<(HttpResponseMessage, string)> SendAsync(ProviderHttpRequest req, int timeoutMs)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        var client = _httpFactory.CreateClient();
        using var message = new HttpRequestMessage(new HttpMethod(req.Method), req.Url)
        {
            Content = new StringContent(req.Body, Encoding.UTF8, req.Headers.TryGetValue("Content-Type", out var ct) ? ct : "application/json"),
        };
        foreach (var (k, v) in req.Headers)
        {
            if (k.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) continue;
            if (!message.Headers.TryAddWithoutValidation(k, v)) message.Content.Headers.TryAddWithoutValidation(k, v);
        }
        var resp = await client.SendAsync(message, cts.Token);
        var body = await resp.Content.ReadAsStringAsync(cts.Token);
        return (resp, body);
    }

    private static object FailBody(string provider, string channel, string reason, DispatchRequest d, string requestId) =>
        new { status = "failed", outcome = "Fail", provider, channel, reason, correlationId = d.CorrelationId, messageId = d.MessageId, requestId };
}
