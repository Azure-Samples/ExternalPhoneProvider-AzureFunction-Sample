using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

// HTTP trigger: POST /api/SendOtp — the SAS → External Phone Provider delivery endpoint. Validates the
// caller, parses the cleartext routing envelope, decrypts the JWE delivery context, dispatches to the
// provider, and echoes the nonce to prove decryption. Every line is tagged [EPP] so one filter pulls a
// whole delivery.
public sealed class SendOtp
{
    private const string Tag = "[EPP]";

    private readonly DispatchEngine _engine;
    private readonly TokenValidator _tokens;
    private readonly JweDecryptor _decryptor;
    private readonly IEnv _env;
    private readonly ILogger<SendOtp> _log;

    public SendOtp(DispatchEngine engine, TokenValidator tokens, JweDecryptor decryptor, IEnv env, ILogger<SendOtp> log)
    {
        _engine = engine;
        _tokens = tokens;
        _decryptor = decryptor;
        _env = env;
        _log = log;
    }

    // Easy Auth has already validated the token; this records which identity arrived.
    private static string? ReadCallerAppId(HttpRequest req)
    {
        var encoded = req.Headers["x-ms-client-principal"].FirstOrDefault();
        if (string.IsNullOrEmpty(encoded)) return null;
        try
        {
            using var doc = JsonDocument.Parse(Convert.FromBase64String(encoded));
            if (!doc.RootElement.TryGetProperty("claims", out var claims) || claims.ValueKind != JsonValueKind.Array)
                return null;
            foreach (var claim in claims.EnumerateArray())
            {
                var type = claim.TryGetProperty("typ", out var t) ? t.GetString() : null;
                if (type is "appid" or "azp")
                    return claim.TryGetProperty("val", out var v) ? v.GetString() : null;
            }
            return null;
        }
        catch
        {
            return null;
        }
    }

    // Left alone, TTS reads 641895 as "six hundred forty-one thousand...", which no user can type.
    private static string? SpacePasscodeForVoice(string? message) =>
        string.IsNullOrEmpty(message) ? message : Regex.Replace(message, @"\b\d{4,8}\b", m => string.Join(" ", m.Value.ToCharArray()));

    [Function("SendOtp")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "SendOtp")] HttpRequest req)
    {
        var started = DateTimeOffset.UtcNow;
        var requestId = Guid.NewGuid().ToString("n");
        var clientRequestId = req.Headers["x-ms-client-request-id"].FirstOrDefault() ?? requestId;
        var headerCorrelationId = req.Headers["x-ms-correlation-id"].FirstOrDefault();
        var logPlaintext = string.Equals(_env.Get("EPP_LOG_PLAINTEXT"), "true", StringComparison.OrdinalIgnoreCase);
        var expectedKeyId = _env.Get("EPP_ENCRYPTION_KEY_ID");
        var expectedClientId = _env.Get("EPP_EXPECTED_CLIENT_ID");

        void Log(string label, object? value) => _log.LogInformation("{Tag} {Label}: {Value}", Tag, label.PadRight(18), value);

        _log.LogInformation("{Tag} ======== delivery received ========", Tag);
        Log("invocation", requestId);

        string? correlationId = null;
        try
        {
            var callerAppId = ReadCallerAppId(req);
            Log("caller appid", callerAppId ?? "none (Easy Auth off, or called directly)");

            if (callerAppId is not null && !string.IsNullOrEmpty(expectedClientId) && callerAppId != expectedClientId)
            {
                _log.LogError("{Tag} caller {Caller} is not {Expected}. Easy Auth allowedApplications is not doing its job.",
                    Tag, callerAppId, expectedClientId);
                return new ObjectResult(new { error = "unexpected_caller" }) { StatusCode = 403 };
            }

            var auth = await _tokens.ValidateAsync(req.Headers.Authorization.FirstOrDefault());
            if (!auth.Ok)
            {
                _log.LogError("{Tag} token rejected: {Reason}", Tag, auth.Reason);
                return new ObjectResult(new { error = "unauthorized", reason = auth.Reason, requestId }) { StatusCode = 401 };
            }

            JsonElement payload;
            try
            {
                using var doc = await JsonDocument.ParseAsync(req.Body);
                payload = doc.RootElement.Clone();
            }
            catch
            {
                _log.LogError("{Tag} body is not JSON", Tag);
                return new BadRequestObjectResult(new { error = "bad_request", reason = "invalid JSON body", requestId });
            }

            var (envelope, envelopeError) = EnvelopeParser.Parse(payload);
            if (envelopeError is not null)
            {
                _log.LogError("{Tag} envelope rejected: {Reason}", Tag, envelopeError);
                return new BadRequestObjectResult(new { error = "bad_request", reason = envelopeError, requestId });
            }

            Log("type", envelope!.Type);
            Log("tenantId", envelope.TenantId);
            Log("correlationId", envelope.CorrelationId);
            Log("channel", envelope.Channel);
            Log("mode", envelope.Mode);
            Log("ttlSeconds", envelope.TtlSeconds);

            correlationId = envelope.CorrelationId ?? headerCorrelationId ?? requestId;

            // Surfaced rather than swallowed: the passcode expires before it can be used.
            if (envelope.TtlSeconds is <= 0)
                _log.LogWarning("{Tag} ttlSeconds is {Ttl}; the passcode has expired.", Tag, envelope.TtlSeconds);

            JweResult decrypted;
            try
            {
                decrypted = _decryptor.Decrypt(envelope.EncryptedDeliveryContext);
            }
            catch (Exception ex)
            {
                _log.LogError("{Tag} decryption failed: {Reason}", Tag, ex.Message);
                return new ObjectResult(new { error = "decryption_failed", correlationId, requestId }) { StatusCode = 400 };
            }

            var kidMatches = string.IsNullOrEmpty(expectedKeyId) || decrypted.Kid == expectedKeyId;
            Log("kid", $"{decrypted.Kid}{(kidMatches ? "" : " (DOES NOT match EPP_ENCRYPTION_KEY_ID)")}");
            Log("alg / enc", $"{decrypted.Alg} / {decrypted.Enc}");
            Log("decrypted", "OK");

            var context = decrypted.Context;
            Log("nonce", context.Nonce);

            if (logPlaintext)
            {
                // DIAGNOSTICS ONLY — writes the phone number and passcode to the log.
                Log("phoneNumber", context.PhoneNumber);
                Log("extension", context.Extension ?? "(none)");
                Log("locale", context.Locale);
                Log("message", context.Message);
                Log("riskContext", context.RiskContext.HasValue ? context.RiskContext.Value.ToString() : "(none)");
            }
            else
            {
                _log.LogInformation("{Tag} plaintext suppressed (EPP_LOG_PLAINTEXT=false)", Tag);
            }

            if (string.IsNullOrEmpty(context.Nonce) || string.IsNullOrEmpty(context.PhoneNumber) || string.IsNullOrEmpty(context.Message))
            {
                _log.LogError("{Tag} delivery context is incomplete (nonce/phoneNumber/message)", Tag);
                return new ObjectResult(new { error = "bad_request", reason = "incomplete delivery context", correlationId, requestId }) { StatusCode = 400 };
            }

            var evaluation = envelope.Mode == EnvelopeParser.ModeEvaluation;
            var channel = EnvelopeParser.ChannelName(envelope.Channel)!;

            var dispatch = new DispatchRequest(
                Destination: context.PhoneNumber!,
                Message: channel == "voice" ? SpacePasscodeForVoice(context.Message) : context.Message,
                Channel: channel,
                MessageId: clientRequestId,
                CorrelationId: correlationId,
                Locale: context.Locale);

            // Microsoft allows 3.2 s for the whole call, so the provider is called after the response.
            var deliveryCorrelationId = correlationId;
            _ = Task.Run(async () =>
            {
                try
                {
                    var result = await _engine.DispatchAsync(dispatch, null, evaluation, requestId, _log);
                    _log.LogInformation("{Tag} provider result   : httpStatus={Status} correlationId={CorrelationId}",
                        Tag, result.HttpStatus, deliveryCorrelationId);
                }
                catch (Exception ex)
                {
                    _log.LogError("{Tag} provider delivery failed: {Error}", Tag, ex.Message);
                }
            });

            // Echoing the nonce is the whole contract: a 2xx without it is treated as a failed delivery
            // and Microsoft re-sends over its own telephony, so the user gets the code twice.
            Log("responding", $"200, nonce echoed, {(DateTimeOffset.UtcNow - started).TotalMilliseconds:F0} ms");
            _log.LogInformation("{Tag} ======== done ========", Tag);

            return new ObjectResult(new { nonce = context.Nonce, correlationId, providerStatus = "accepted" })
                { StatusCode = 200 };
        }
        catch (Exception ex)
        {
            // Verbose on purpose: this endpoint exists to diagnose onboarding.
            _log.LogError("{Tag} FAILED after {Elapsed} ms: {Error}", Tag, (DateTimeOffset.UtcNow - started).TotalMilliseconds, ex.Message);
            _log.LogInformation("{Tag} ======== failed ========", Tag);
            return new ObjectResult(new { error = "delivery_failed", detail = ex.Message, correlationId }) { StatusCode = 500 };
        }
    }
}
