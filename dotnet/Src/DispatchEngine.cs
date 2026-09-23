using Azure.Core;
using Azure.Identity;
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
    public const string EnvelopeType = "microsoft.mfa.otpDeliver.v1";
    public const int ModeLive = 1;
    public const int ModeEvaluation = 2;

    private static readonly Dictionary<int, string> ChannelByCode = new() { [1] = "sms", [2] = "voice" };
    private static readonly Dictionary<string, int> ChannelByName = new(StringComparer.OrdinalIgnoreCase) { ["sms"] = 1, ["voice"] = 2 };
    private static readonly Dictionary<string, int> ModeByName = new(StringComparer.OrdinalIgnoreCase) { ["live"] = ModeLive, ["evaluation"] = ModeEvaluation };

    public static string? ChannelName(int code) => ChannelByCode.TryGetValue(code, out var name) ? name : null;

    public static async Task<(Envelope? Envelope, string? Error)> ParseAsync(Stream body, CancellationToken cancellationToken = default)
    {
        try
        {
            using var document = await JsonDocument.ParseAsync(body, cancellationToken: cancellationToken);
            return Parse(document.RootElement);
        }
        catch (Exception error) when (error is JsonException or DecoderFallbackException
            || error is InvalidOperationException { InnerException: DecoderFallbackException })
        {
            return (null, "invalid JSON body");
        }
    }

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

        if (String("type") != EnvelopeType)
            return (null, "unsupported envelope type");

        var encrypted = String("encryptedDeliveryContext");
        if (string.IsNullOrWhiteSpace(encrypted))
            return (null, "encryptedDeliveryContext is required");

        var channel = Channel();
        if (channel is null)
            return (null, "unsupported channel");

        var mode = Mode();
        if (mode is null)
            return (null, "unsupported mode");

        int? ttlSeconds = null;
        if (payload.TryGetProperty("ttlSeconds", out var ttl))
        {
            if (ttl.ValueKind != JsonValueKind.Number || !ttl.TryGetInt32(out var seconds))
                return (null, "invalid ttlSeconds");
            if (seconds <= 0)
                return (null, "ttlSeconds expired");
            ttlSeconds = seconds;
        }

        return (new Envelope(String("type"), String("tenantId"), String("correlationId"),
            channel.Value, mode.Value, ttlSeconds, encrypted), null);
    }
}

public sealed class DeliveryContext
{
    [JsonPropertyName("nonce")] public string? Nonce { get; set; }
    [JsonPropertyName("phoneNumber")] public string? PhoneNumber { get; set; }
    [JsonPropertyName("extension")] public string? Extension { get; set; }
    [JsonPropertyName("locale")] public string? Locale { get; set; }
    [JsonPropertyName("message")] public string? Message { get; set; }
    [JsonPropertyName("riskContext")] public JsonElement? RiskContext { get; set; }
    [JsonPropertyName("textToVoice")] public TextToVoice? TextToVoice { get; set; }

    [JsonIgnore]
    public bool IsComplete => !string.IsNullOrWhiteSpace(Nonce)
        && !string.IsNullOrWhiteSpace(PhoneNumber)
        && !string.IsNullOrWhiteSpace(Message);

    public static DeliveryContext FromPayload(JsonElement payload)
    {
        if (payload.ValueKind != JsonValueKind.Object) return new();
        string? ReadString(string name) => payload.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
        TextToVoice? voice = null;
        if (payload.TryGetProperty("textToVoice", out var speech) && speech.ValueKind == JsonValueKind.Object)
        {
            string? ReadVoiceString(string name) => speech.TryGetProperty(name, out var value)
                && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
            voice = new TextToVoice(ReadVoiceString("beforePasswordText"), ReadVoiceString("password"), ReadVoiceString("language"));
        }
        return new()
        {
            Nonce = ReadString("nonce"),
            PhoneNumber = ReadString("phoneNumber"),
            Message = ReadString("message"),
            Extension = ReadString("extension"),
            Locale = ReadString("locale"),
            RiskContext = payload.TryGetProperty("riskContext", out var risk) ? risk.Clone() : null,
            TextToVoice = voice,
        };
    }
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
        // Pin alg/enc so a tampered header can't downgrade the crypto.
        var plaintext = Jose.JWT.Decrypt(compactJwe, rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        using var payload = JsonDocument.Parse(plaintext);
        var context = DeliveryContext.FromPayload(payload.RootElement);
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

public sealed class DispatchEngine : IDisposable
{
    public const string ProviderHttpClientName = "otp-provider";
    private const int DefaultTimeoutMs = 1500;
    private const int MaxTimeoutMs = 2500;
    private readonly ProviderRegistry _registry;
    private readonly IHttpClientFactory _httpFactory;
    private readonly IEnv _env;
    private readonly ProviderCredentials _credentials;

    public DispatchEngine(ProviderRegistry registry, ISecretResolver secrets, IHttpClientFactory httpFactory,
        IEnv? env = null, ILogger<DispatchEngine>? log = null)
        : this(registry, secrets, httpFactory, env,
            identity => new ManagedIdentityCredential(identity, OAuthOptions()),
            (tenant, application, assertion) => new ClientAssertionCredential(tenant, application, assertion, OAuthOptions()), log) { }

    internal DispatchEngine(ProviderRegistry registry, ISecretResolver secrets, IHttpClientFactory httpFactory, IEnv? env,
        Func<string, TokenCredential> createManagedIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createOAuthCredential,
        ILogger? log = null, TimeProvider? clock = null)
    {
        _registry = registry;
        _httpFactory = httpFactory;
        _env = env ?? new ProcessEnv();
        _credentials = new ProviderCredentials(secrets, _env, createManagedIdentity, createOAuthCredential, log, clock);
    }

    private static ClientAssertionCredentialOptions OAuthOptions()
    {
        var options = new ClientAssertionCredentialOptions { AuthorityHost = AzureAuthorityHosts.AzurePublicCloud };
        options.Retry.MaxRetries = 0;
        options.Retry.NetworkTimeout = CredentialCachePolicy.AcquisitionTimeout;
        options.Diagnostics.IsLoggingEnabled = false;
        options.Diagnostics.IsLoggingContentEnabled = false;
        return options;
    }

    public async Task StartCredentialRefreshAsync(CancellationToken cancellation = default)
    {
        var config = AppConfig.Read(_env);
        if (string.IsNullOrWhiteSpace(config.ProviderName)) return;
        var adapter = _registry.Get(config.ProviderName);
        if (adapter is null || (!string.IsNullOrEmpty(config.ProviderAuthMode) && config.ProviderAuthMode != adapter.Manifest.Auth.Mode))
        {
            _credentials.ReportFailure("configuration");
            return;
        }
        try { await _credentials.ResolveAsync(adapter.Manifest.Auth, config, cancellation).ConfigureAwait(false); }
        catch (Exception) { _credentials.ReportFailure("initialization"); }
    }

    public void Dispose() => _credentials.Dispose();

    public async Task<DispatchResult> DispatchAsync(DispatchRequest dispatch, string requestId, RequestLog? log = null)
    {
        DispatchResult Failure(int status, string stage, string reason, object body)
        {
            log?.Failure(stage, reason, status);
            return new DispatchResult(status, body);
        }

        var config = AppConfig.Read(_env);
        var adapter = _registry.Get(config.ProviderName);
        if (adapter is null)
            return Failure(400, "provider_selection", "unknown_provider",
                new { status = "error", reason = "unknown provider", requestId });

        var manifest = adapter.Manifest;
        log?.ProviderSelected(manifest);
        var providerId = manifest.Id;
        var channel = (dispatch.Channel ?? "sms").ToLowerInvariant();

        if (!OutcomeMapper.DefaultChannels.Contains(channel))
            return Failure(400, "provider_configuration", "unsupported_channel",
                new { status = "error", provider = providerId, reason = "unsupported channel", requestId });

        if (channel == "voice" && manifest.RequiresTextToVoice && dispatch.TextToVoice?.IsComplete != true)
            return Failure(400, "provider_request_build", "incomplete_voice_context",
                FailBody(providerId, channel, "incomplete voice context", dispatch, requestId));

        if (!string.IsNullOrEmpty(config.ProviderChannel) && config.ProviderChannel != channel)
            return Failure(400, "provider_configuration", "channel_not_configured",
                new { status = "error", provider = providerId, reason = "channel not configured", requestId });
        if (!string.IsNullOrEmpty(config.ProviderAuthMode) && config.ProviderAuthMode != manifest.Auth.Mode)
            return Failure(502, "provider_configuration", "authentication_mode_mismatch",
                FailBody(providerId, channel, "provider authentication mismatch", dispatch, requestId));

        ProviderCredential credential;
        try
        {
            log?.CredentialResolutionStarted(config);
            credential = await ResolveCredentialAsync(manifest.Auth, config);
        }
        catch
        {
            return Failure(502, "provider_credentials", "credential_unavailable",
                FailBody(providerId, channel, "provider credential unavailable", dispatch, requestId));
        }

        var identityRequired = credential.Mode == "apiKey" && !string.IsNullOrEmpty(manifest.Auth.IdentityKeyVaultSecretName);
        var credentialUnavailable = credential.Mode switch
        {
            "apiKey" => string.IsNullOrEmpty(credential.Secret)
                || (identityRequired && string.IsNullOrEmpty(credential.Identity)),
            "oauth" => string.IsNullOrEmpty(credential.AccessToken),
            _ => true,
        };
        if (credentialUnavailable)
            return Failure(502, "provider_credentials", "credential_unavailable",
                FailBody(providerId, channel, "provider credential unavailable", dispatch, requestId));
        log?.CredentialResolved();

        var endpoint = config.ProviderEndpoint;
        if (!IsHttpsEndpoint(endpoint))
            return Failure(502, "provider_configuration", "invalid_provider_endpoint",
                FailBody(providerId, channel, "provider endpoint invalid or not configured", dispatch, requestId));

        var timeoutMs = NormalizeProviderTimeoutMs(config.ProviderTimeoutMs);
        var stage = "provider_request_build";
        try
        {
            log?.Service("provider_request_build_started");
            var req = adapter.BuildRequest(channel, endpoint!, dispatch, credential, _env);
            if (!IsHttpsEndpoint(req.Url))
                return Failure(502, "provider_request_build", "invalid_provider_request_url",
                    FailBody(providerId, channel, "provider request endpoint invalid", dispatch, requestId));
            log?.ProviderRequestBuilt(req.Method, req.Url);

            stage = "provider_transport";
            var (providerHttpStatus, success, body) = await SendAsync(req, timeoutMs, log);
            stage = "provider_response";
            JsonElement json;
            var validJson = true;
            try { using var responseDocument = JsonDocument.Parse(body); json = responseDocument.RootElement.Clone(); }
            catch (JsonException)
            {
                validJson = false;
                log?.Service("provider_response_invalid_json", level: LogLevel.Warning);
                using var emptyDocument = JsonDocument.Parse("{}");
                json = emptyDocument.RootElement.Clone();
            }

            var parsed = adapter.ParseResponse(providerHttpStatus, success, json);
            var outcome = OutcomeMapper.ResolveOutcome(manifest, parsed);
            var httpStatus = OutcomeMapper.ToHttpStatus(outcome, parsed.ProviderHttpStatus);
            log?.ProviderResponseProcessed(manifest, parsed, outcome, httpStatus, validJson);

            return new DispatchResult(httpStatus, new
            {
                status = outcome == Outcome.Continue ? "accepted" : "failed",
                outcome = outcome.ToString(),
                provider = providerId,
                channel,
                messageId = dispatch.MessageId,
                correlationId = dispatch.CorrelationId,
                requestId,
            });
        }
        catch (OperationCanceledException)
        {
            return Failure(504, stage, "provider_timeout",
                FailBody(providerId, channel, $"endpoint timeout after {timeoutMs}ms", dispatch, requestId));
        }
        catch
        {
            var reason = stage switch
            {
                "provider_request_build" => "request_build_failed",
                "provider_response" => "response_parse_failed",
                _ => "provider_network_error",
            };
            return Failure(502, stage, reason, FailBody(providerId, channel, "provider request failed", dispatch, requestId));
        }
    }

    private Task<ProviderCredential> ResolveCredentialAsync(AuthConfig auth, AppConfig config) =>
        _credentials.ResolveAsync(auth, config);

    internal static int NormalizeProviderTimeoutMs(string? value)
    {
        var text = value?.Trim();
        if (string.IsNullOrEmpty(text)) return DefaultTimeoutMs;

        // Saturate while scanning every character: arbitrarily large decimal values are valid,
        // but signs, exponents, hex, non-ASCII digits and invalid suffixes are not.
        var timeout = 0;
        foreach (var digit in text)
        {
            if (digit < '0' || digit > '9') return DefaultTimeoutMs;
            timeout = Math.Min(MaxTimeoutMs, timeout * 10 + digit - '0');
        }
        return timeout > 0 ? timeout : DefaultTimeoutMs;
    }

    internal static bool IsHttpsEndpoint(string? endpoint) =>
        Uri.TryCreate(endpoint, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps
        && !string.IsNullOrEmpty(uri.Host)
        && uri.Port > 0
        && string.IsNullOrEmpty(uri.UserInfo)
        && string.IsNullOrEmpty(uri.Fragment);

    private async Task<(int HttpStatus, bool Success, string Body)> SendAsync(ProviderHttpRequest req, int timeoutMs, RequestLog? log)
    {
        using var cts = new CancellationTokenSource(timeoutMs);
        using var client = _httpFactory.CreateClient(ProviderHttpClientName);
        using var message = new HttpRequestMessage(new HttpMethod(req.Method), req.Url)
        {
            Content = new StringContent(req.Body, Encoding.UTF8, req.Headers.TryGetValue("Content-Type", out var ct) ? ct : "application/json"),
        };
        foreach (var (k, v) in req.Headers)
        {
            if (k.Equals("Content-Type", StringComparison.OrdinalIgnoreCase)) continue;
            if (!message.Headers.TryAddWithoutValidation(k, v)) message.Content.Headers.TryAddWithoutValidation(k, v);
        }
        log?.ProviderRequestStarted(timeoutMs);
        try
        {
            using var resp = await client.SendAsync(message, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            log?.ProviderResponseReceived((int)resp.StatusCode);
            using var stream = await resp.Content.ReadAsStreamAsync(cts.Token);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            var text = await reader.ReadToEndAsync(cts.Token);
            return ((int)resp.StatusCode, resp.IsSuccessStatusCode, text);
        }
        finally
        {
            log?.ProviderRequestFinished();
        }
    }

    private static object FailBody(string provider, string channel, string reason, DispatchRequest d, string requestId) =>
        new { status = "failed", outcome = "Fail", provider, channel, reason, correlationId = d.CorrelationId, messageId = d.MessageId, requestId };
}
