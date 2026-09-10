using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

// Echo the nonce only on acceptance; log one PII-safe summary per invocation.
public sealed class SendOtp
{
    private readonly DispatchEngine _engine;
    private readonly JweDecryptor _decryptor;
    private readonly IEnv _env;
    private readonly ILogger<SendOtp> _log;

    public SendOtp(DispatchEngine engine, JweDecryptor decryptor, IEnv env, ILogger<SendOtp> log)
    {
        _engine = engine;
        _decryptor = decryptor;
        _env = env;
        _log = log;
    }

    // Anonymous at the Functions layer; EasyAuth must remain enabled and require authentication in the cloud.
    [Function("SendOtp")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "SendOtp")] HttpRequest req)
    {
        var started = Stopwatch.StartNew();
        var requestId = Guid.NewGuid().ToString("n");
        var correlationId = requestId;
        var httpStatus = 500;
        var evaluation = false;

        ObjectResult Reply(int status, object body)
        {
            httpStatus = status;
            return new ObjectResult(body) { StatusCode = status };
        }

        try
        {
            var config = AppConfig.Read(_env);
            var clientRequestId = req.Headers["x-ms-client-request-id"].FirstOrDefault() ?? requestId;
            correlationId = req.Headers["x-ms-correlation-id"].FirstOrDefault() ?? requestId;

            var (envelope, envelopeError) = await EnvelopeParser.ParseAsync(req.Body, req.HttpContext.RequestAborted);
            if (envelopeError is not null)
                return Reply(400, new EndpointErrorResponse("bad_request", requestId, Reason: envelopeError));

            correlationId = envelope!.CorrelationId ?? correlationId;
            evaluation = envelope.Mode == EnvelopeParser.ModeEvaluation;

            JweResult decrypted;
            try
            {
                decrypted = _decryptor.Decrypt(envelope.EncryptedDeliveryContext);
            }
            catch
            {
                return Reply(400, new EndpointErrorResponse("decryption_failed", requestId, CorrelationId: correlationId));
            }

            if (!string.IsNullOrEmpty(config.ExpectedKeyId)
                && !string.Equals(config.ExpectedKeyId, decrypted.Kid, StringComparison.Ordinal))
                _log.LogWarning("encryption_key_id_mismatch");

            var context = decrypted.Context;
            if (!context.IsComplete)
                return Reply(400, new EndpointErrorResponse("bad_request", requestId, Reason: "incomplete delivery context", CorrelationId: correlationId));

            // Evaluation proves validation/decryption without requiring any provider configuration.
            if (evaluation)
                return Reply(200, new EndpointSuccessResponse(context.Nonce!, correlationId));

            var channel = EnvelopeParser.ChannelName(envelope.Channel)!;

            var dispatch = new DispatchRequest(
                Destination: context.PhoneNumber!,
                Message: context.Message,
                Channel: channel,
                MessageId: clientRequestId,
                CorrelationId: correlationId,
                Locale: context.Locale);

            // A nonce acknowledges delivery, not just decryption. Wait for the bounded provider call.
            var result = await _engine.DispatchAsync(dispatch, requestId);
            if (result.HttpStatus != 200)
                return Reply(result.HttpStatus, new EndpointErrorResponse("provider_delivery_failed", requestId, CorrelationId: correlationId));

            return Reply(200, new EndpointSuccessResponse(context.Nonce!, correlationId));
        }
        catch
        {
            return Reply(500, new EndpointErrorResponse("delivery_failed", requestId, CorrelationId: correlationId));
        }
        finally
        {
            var correlationHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(correlationId)))[..16].ToLowerInvariant();
            _log.LogInformation("[EPP] RequestId={RequestId} CorrelationId={CorrelationId} HttpStatus={HttpStatus} ElapsedMs={ElapsedMs} Evaluation={Evaluation}",
                requestId, correlationHash, httpStatus, started.ElapsedMilliseconds, evaluation);
        }
    }
}
