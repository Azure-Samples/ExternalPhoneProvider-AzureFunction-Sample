using System.Diagnostics;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

public sealed class SendOtp
{
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

    // Easy Auth has already validated the token; check its caller against the configured app.
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

    [Function("SendOtp")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "SendOtp")] HttpRequest req)
    {
        var started = Stopwatch.StartNew();
        var requestId = Guid.NewGuid().ToString("n");
        string? correlationId = null;
        var evaluation = false;
        var provider = "unknown";
        var logChannel = "unknown";
        var mode = "unknown";
        var status = 500;
        var outcome = Outcome.Fail;
        var nonceEcho = false;
        var shutterProcessed = false;

        IActionResult Reply(int httpStatus, object body)
        {
            status = httpStatus;
            return new ObjectResult(body) { StatusCode = httpStatus };
        }

        try
        {
            var clientRequestId = req.Headers["x-ms-client-request-id"].FirstOrDefault() ?? requestId;
            correlationId = req.Headers["x-ms-correlation-id"].FirstOrDefault() ?? requestId;
            provider = DispatchEngine.SafeProvider(_env.Get("EPP_PROVIDER_NAME"));
            var expectedClientId = _env.Get("EPP_EXPECTED_CLIENT_ID");
            var callerAppId = ReadCallerAppId(req);

            if (callerAppId is not null && !string.IsNullOrEmpty(expectedClientId) && callerAppId != expectedClientId)
                return Reply(403, new { error = "unexpected_caller" });

            var auth = await _tokens.ValidateAsync(req.Headers.Authorization.FirstOrDefault());
            if (!auth.Ok)
                return Reply(401, new { error = "unauthorized", requestId });

            JsonElement payload;
            try
            {
                using var doc = await JsonDocument.ParseAsync(req.Body);
                payload = doc.RootElement.Clone();
            }
            catch
            {
                return Reply(400, new { error = "bad_request", reason = "invalid JSON body", requestId });
            }

            var (envelope, envelopeError) = EnvelopeParser.Parse(payload);
            if (envelopeError is not null)
                return Reply(400, new { error = "bad_request", reason = envelopeError, requestId });

            correlationId = envelope!.CorrelationId ?? correlationId;
            evaluation = envelope.Mode == EnvelopeParser.ModeEvaluation;
            var channel = EnvelopeParser.ChannelName(envelope.Channel)!;
            logChannel = DispatchEngine.SafeChannel(channel);
            mode = envelope.Mode switch
            {
                EnvelopeParser.ModeLive => "live",
                EnvelopeParser.ModeEvaluation => "evaluation",
                _ => "unknown",
            };

            JweResult decrypted;
            try
            {
                decrypted = _decryptor.Decrypt(envelope.EncryptedDeliveryContext);
            }
            catch
            {
                return Reply(400, new { error = "decryption_failed", correlationId, requestId });
            }

            var context = decrypted.Context;

            if (string.IsNullOrEmpty(context.Nonce) || string.IsNullOrEmpty(context.PhoneNumber) || string.IsNullOrEmpty(context.Message))
                return Reply(400, new { error = "bad_request", reason = "incomplete delivery context", correlationId, requestId });

            var dispatch = new DispatchRequest(
                Destination: context.PhoneNumber!,
                Message: context.Message,
                Channel: channel,
                MessageId: clientRequestId,
                CorrelationId: correlationId,
                Locale: context.Locale);

            var providerResult = await _engine.DispatchAsync(dispatch, null, evaluation, requestId, _log);
            outcome = providerResult.HttpStatus switch
            {
                200 => Outcome.Continue,
                403 => Outcome.Block,
                409 => Outcome.StepUp,
                _ => Outcome.Fail,
            };

            if (providerResult.HttpStatus != 200)
                return Reply(providerResult.HttpStatus, new { error = "delivery_failed", reason = "provider delivery failed", correlationId, requestId });

            // A 2xx without the nonce triggers SAS fallback and risks duplicate delivery.
            nonceEcho = true;
            shutterProcessed = evaluation;
            return Reply(200, new { nonce = context.Nonce, correlationId, providerStatus = "accepted" });
        }
        catch
        {
            outcome = Outcome.Fail;
            return Reply(500, new { error = "delivery_failed", correlationId, requestId });
        }
        finally
        {
            _log.LogInformation("[EPP_RESULT] requestId={RequestId} correlationId={CorrelationId} provider={Provider} channel={Channel} mode={Mode} httpStatus={HttpStatus} outcome={Outcome} nonceEcho={NonceEcho} shutterProcessed={ShutterProcessed} elapsedMs={ElapsedMs}",
                DispatchEngine.SafeTraceId(requestId), DispatchEngine.SafeTraceId(correlationId), provider, logChannel, mode,
                status, outcome, nonceEcho, shutterProcessed, started.ElapsedMilliseconds);
        }
    }
}
