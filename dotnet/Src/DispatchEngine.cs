using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

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
    public const string EnvelopeType = "microsoft.mfa.otpDeliver.v1";

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

        var type = String("type");
        if (type != EnvelopeType)
            return (null, "unsupported type");

        var encrypted = String("encryptedDeliveryContext");
        if (string.IsNullOrEmpty(encrypted))
            return (null, "encryptedDeliveryContext is required");

        var channel = Channel();
        if (channel is null)
            return (null, "unsupported channel");

        var mode = Mode();
        if (mode is null)
            return (null, "unsupported mode");

        int? ttlSeconds = null;
        if (payload.TryGetProperty("ttlSeconds", out var ttlElement))
        {
            if (ttlElement.ValueKind != JsonValueKind.Number
                || !ttlElement.TryGetInt32(out var ttlValue))
                return (null, "ttlSeconds must be a positive integer");
            if (ttlValue <= 0)
                return (null, "passcode has expired");
            ttlSeconds = ttlValue;
        }

        return (new Envelope(type, String("tenantId"), String("correlationId"),
            channel.Value, mode.Value, ttlSeconds, encrypted), null);
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
        // Pin alg/enc so a tampered header cannot downgrade the encryption.
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

// Cache the imported key: re-importing RSA on every delivery would eat the response budget.
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

    // The key may arrive as a PEM or as base64 over the PEM (the setup script uses base64 so newlines
    // survive being stored as an app setting); accept either form.
    private static string NormalizePem(string value) =>
        value.Contains("-----BEGIN", StringComparison.Ordinal)
            ? value
            : Encoding.UTF8.GetString(Convert.FromBase64String(value.Trim()));
}

public sealed class DispatchEngine
{
    private const int DefaultTimeoutMs = 1500;
    private const int MaxProviderTimeoutMs = 2500;
    private readonly ProviderRegistry _registry;
    private readonly ISecretResolver _secrets;
    private readonly IHttpClientFactory _httpFactory;
    private readonly IEnv _env;
    private readonly IProviderTokenAcquirer _tokenAcquirer;

    public DispatchEngine(ProviderRegistry registry, ISecretResolver secrets, IHttpClientFactory httpFactory, IEnv? env = null, IProviderTokenAcquirer? tokenAcquirer = null)
    {
        _registry = registry;
        _secrets = secrets;
        _httpFactory = httpFactory;
        _env = env ?? new ProcessEnv();
        _tokenAcquirer = tokenAcquirer ?? new ProviderTokenAcquirer(_env, _secrets);
    }

    public async Task<DispatchResult> DispatchAsync(DispatchRequest dispatch, string? requestProvider, bool shutter, string requestId, ILogger log)
    {
        var traceRequestId = SafeTraceId(requestId);
        var traceCorrelationId = SafeTraceId(dispatch.CorrelationId);
        var traceProvider = SafeProvider(requestProvider);
        var traceChannel = SafeChannel(dispatch.Channel ?? "sms");

        DispatchResult Complete(int status, object body, Outcome outcome = Outcome.Fail)
        {
            log.LogInformation("[DISPATCH_RESULT] requestId={RequestId} correlationId={CorrelationId} provider={Provider} channel={Channel} outcome={Outcome} httpStatus={HttpStatus} shutterProcessed={ShutterProcessed}",
                traceRequestId, traceCorrelationId, traceProvider, traceChannel, outcome, status, shutter && status == 200);
            return new DispatchResult(status, body);
        }

        var adapter = _registry.Resolve(requestProvider);
        if (adapter is null)
            return Complete(400, new { status = "error", reason = "unknown provider", requestId });

        var manifest = adapter.Manifest;
        var providerId = manifest.Id;
        traceProvider = SafeProvider(providerId);
        var channel = (dispatch.Channel ?? "sms").ToLowerInvariant();

        if (!OutcomeMapper.DefaultChannels.Contains(channel))
            return Complete(400, new { status = "error", provider = providerId, reason = "unsupported channel", requestId });

        if (shutter)
            return Complete(200, new { status = "accepted", shutterProcessed = true, provider = providerId, channel, correlationId = dispatch.CorrelationId, messageId = dispatch.MessageId, requestId }, Outcome.Continue);

        ProviderCredential? credential = null;
        try { credential = await ResolveCredentialAsync(manifest.Auth); }
        catch { /* Credential failures are reported below without SDK exception details. */ }

        var identityRequired = credential is { Mode: "apiKey" } && !string.IsNullOrEmpty(manifest.Auth.IdentityKeyVaultSecretName);
        var credentialUnavailable = credential is null
            || (credential.Mode == "oauth2" && string.IsNullOrEmpty(credential.Token))
            || (credential.Mode == "apiKey" && string.IsNullOrEmpty(credential.Secret))
            || (identityRequired && string.IsNullOrEmpty(credential.Identity));
        if (credentialUnavailable)
            return Complete(502, FailBody(providerId, channel, "provider credential unavailable", dispatch, requestId));

        var endpoint = _env.Get("EPP_PROVIDER_ENDPOINT");
        if (!IsValidProviderEndpoint(endpoint))
            return Complete(502, FailBody(providerId, channel, "provider endpoint must be an absolute HTTPS URL", dispatch, requestId));

        var req = adapter.BuildRequest(channel, endpoint!, dispatch, credential!, _env);
        if (!IsValidProviderEndpoint(req.Url))
            return Complete(502, FailBody(providerId, channel, "provider request URL must be absolute HTTPS", dispatch, requestId));

        var timeoutMs = NormalizeProviderTimeoutMs(_env.Get("EPP_PROVIDER_TIMEOUT_MS"));
        int providerStatusCode;
        bool providerRequestSucceeded;
        string body;
        try
        {
            (providerStatusCode, providerRequestSucceeded, body) = await SendAsync(req, timeoutMs);
        }
        catch (OperationCanceledException)
        {
            return Complete(504, FailBody(providerId, channel, $"endpoint timeout after {timeoutMs}ms", dispatch, requestId));
        }
        catch
        {
            return Complete(502, FailBody(providerId, channel, "provider request failed", dispatch, requestId));
        }

        JsonElement json;
        try { using var responseDocument = JsonDocument.Parse(string.IsNullOrWhiteSpace(body) ? "{}" : body); json = responseDocument.RootElement.Clone(); }
        catch { using var emptyDocument = JsonDocument.Parse("{}"); json = emptyDocument.RootElement.Clone(); }

        var parsed = adapter.ParseResponse(providerStatusCode, providerRequestSucceeded, json);
        var outcome = OutcomeMapper.ResolveOutcome(manifest, parsed);
        var httpStatus = OutcomeMapper.ToHttpStatus(outcome, parsed.ProviderHttpStatus);

        // Provider diagnostics may echo delivery secrets, even on a success-looking response.
        return Complete(httpStatus, new
        {
            status = outcome == Outcome.Continue ? "accepted" : "failed",
            outcome = outcome.ToString(),
            reason = outcome == Outcome.Continue ? null : "provider delivery failed",
            provider = providerId,
            channel,
            messageId = dispatch.MessageId,
            correlationId = dispatch.CorrelationId,
            requestId,
        }, outcome);
    }

    // Log projection only: never replace IDs on the dispatch or response wire.
    internal static string SafeTraceId(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "unknown";
        if (Guid.TryParse(value, out var id)) return id.ToString("D");
        // A labeled 96-bit SHA256 prefix preserves correlation without logging arbitrary text.
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(value));
        return "sha256:" + Convert.ToHexString(hash.AsSpan(0, 12)).ToLowerInvariant();
    }

    internal static string SafeProvider(string? value) => value?.ToLowerInvariant() switch
    {
        "infobip" => "infobip",
        "telesign" => "telesign",
        "sinch" => "sinch",
        "soprano" => "soprano",
        _ => "unknown",
    };

    internal static string SafeChannel(string? value) => value?.ToLowerInvariant() switch
    {
        "sms" => "sms",
        "voice" => "voice",
        _ => "unknown",
    };

    private async Task<ProviderCredential> ResolveCredentialAsync(AuthConfig auth)
    {
        var mode = _env.Get("EPP_PROVIDER_AUTH_MODE");
        if (string.IsNullOrEmpty(mode)) mode = auth.Mode;
        if (string.Equals(mode, "oauth2", StringComparison.OrdinalIgnoreCase))
        {
            var token = await _tokenAcquirer.AcquireAsync();
            return new ProviderCredential("oauth2", Token: token);
        }
        var secret = await _secrets.ResolveAsync(auth.KeyVaultSecretName);
        var identity = string.IsNullOrEmpty(auth.IdentityKeyVaultSecretName) ? string.Empty : await _secrets.ResolveAsync(auth.IdentityKeyVaultSecretName);
        return new ProviderCredential("apiKey", Secret: secret, Identity: identity);
    }

    private static bool IsValidProviderEndpoint(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps
        && !string.IsNullOrEmpty(uri.Host);

    internal static int NormalizeProviderTimeoutMs(string? value) =>
        int.TryParse(value, out var parsed) && parsed > 0
            ? Math.Min(parsed, MaxProviderTimeoutMs)
            : DefaultTimeoutMs;

    private async Task<(int StatusCode, bool IsSuccessStatusCode, string Body)> SendAsync(ProviderHttpRequest req, int timeoutMs)
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
        // Do not retry an OTP delivery: SAS/the provider own resends and duplicate suppression.
        using var resp = await client.SendAsync(message, cts.Token);
        var body = await resp.Content.ReadAsStringAsync(cts.Token);
        return ((int)resp.StatusCode, resp.IsSuccessStatusCode, body);
    }

    private static object FailBody(string provider, string channel, string reason, DispatchRequest d, string requestId) =>
        new { status = "failed", outcome = "Fail", provider, channel, reason, correlationId = d.CorrelationId, messageId = d.MessageId, requestId };
}
