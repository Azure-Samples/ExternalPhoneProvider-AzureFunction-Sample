using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

// Echo the nonce only on acceptance; keep service events and the request summary PII-safe.
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
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "SendOtp")] HttpRequest req,
        FunctionContext? functionContext = null)
    {
        var requestId = Guid.NewGuid().ToString("n");
        var msRequestId = req.Headers["x-ms-client-request-id"].FirstOrDefault();
        var headerCorrelationId = req.Headers["x-ms-correlation-id"].FirstOrDefault();
        var log = new RequestLog(_log, requestId, functionContext?.InvocationId, msRequestId, headerCorrelationId);
        var correlationId = headerCorrelationId ?? requestId;
        var httpStatus = 500;
        var evaluation = false;

        ObjectResult Reply(int status, object body)
        {
            var response = new ObjectResult(body) { StatusCode = status };
            httpStatus = status;
            log.ResponsePrepared(status, body is EndpointSuccessResponse,
                body is EndpointSuccessResponse or EndpointErrorResponse { CorrelationId: not null });
            return response;
        }

        try
        {
            log.Service("request_received");
            var config = AppConfig.Read(_env);
            var clientRequestId = msRequestId ?? requestId;

            var (envelope, envelopeError) = await EnvelopeParser.ParseAsync(req.Body, req.HttpContext.RequestAborted);
            if (envelopeError is not null)
            {
                log.Failure("request_validation", envelopeError, 400);
                return Reply(400, new EndpointErrorResponse("bad_request", requestId, Reason: envelopeError));
            }

            correlationId = envelope!.CorrelationId ?? correlationId;
            evaluation = envelope.Mode == EnvelopeParser.ModeEvaluation;
            log.EnvelopeValidated(envelope, envelope.CorrelationId ?? headerCorrelationId,
                envelope.CorrelationId is not null ? "envelope" : "header");

            JweResult decrypted;
            try
            {
                decrypted = _decryptor.Decrypt(envelope.EncryptedDeliveryContext);
            }
            catch
            {
                log.Failure("decryption", "decryption_failed", 400);
                return Reply(400, new EndpointErrorResponse("decryption_failed", requestId, CorrelationId: correlationId));
            }
            log.Service("delivery_context_decrypted");

            if (!string.IsNullOrEmpty(config.ExpectedKeyId)
                && !string.Equals(config.ExpectedKeyId, decrypted.Kid, StringComparison.Ordinal))
                log.KeyIdMismatch();

            var context = decrypted.Context;
            if (!context.IsComplete)
            {
                log.Failure("delivery_context_validation", "incomplete delivery context", 400);
                return Reply(400, new EndpointErrorResponse("bad_request", requestId, Reason: "incomplete delivery context", CorrelationId: correlationId));
            }

            // Evaluation proves validation/decryption without requiring any provider configuration.
            if (evaluation)
            {
                log.Service("evaluation_completed");
                return Reply(200, new EndpointSuccessResponse(context.Nonce!, correlationId));
            }

            var channel = EnvelopeParser.ChannelName(envelope.Channel)!;

            var dispatch = new DispatchRequest(
                Destination: context.PhoneNumber!,
                Message: context.Message,
                Channel: channel,
                MessageId: clientRequestId,
                CorrelationId: correlationId,
                Locale: context.Locale,
                TextToVoice: context.TextToVoice);

            // A nonce acknowledges delivery, not just decryption. Wait for the bounded provider call.
            var result = await _engine.DispatchAsync(dispatch, requestId, log);
            if (result.HttpStatus != 200)
                return Reply(result.HttpStatus, new EndpointErrorResponse("provider_delivery_failed", requestId, CorrelationId: correlationId));

            return Reply(200, new EndpointSuccessResponse(context.Nonce!, correlationId));
        }
        catch
        {
            if (!log.HasFailure) log.Failure("handler", "unexpected_error", 500);
            return Reply(500, new EndpointErrorResponse("delivery_failed", requestId, CorrelationId: correlationId));
        }
        finally
        {
            log.Complete(httpStatus);
        }
    }
}
