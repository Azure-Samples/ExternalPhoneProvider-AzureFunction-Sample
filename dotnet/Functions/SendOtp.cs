using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using WorkerFromBody = Microsoft.Azure.Functions.Worker.Http.FromBodyAttribute;

namespace Epp.Otp;

// Echo the nonce only on acceptance; keep service events and the request summary PII-safe.
public sealed class SendOtp
{
    public const string ProviderHttpClientName = "otp-provider";
    private const int DefaultTimeoutMs = 1500;
    private const int MaxTimeoutMs = 2500;
    private readonly IReadOnlyList<PhoneProviderBase> _providers;
    private readonly CredentialTokenService _credentials;
    private readonly IHttpClientFactory _httpFactory;
    private readonly JweDecryptor _decryptor;
    private readonly IEnv _env;
    private readonly ILogger<SendOtp> _log;

    public SendOtp(IEnumerable<PhoneProviderBase> providers, CredentialTokenService credentials,
        IHttpClientFactory httpFactory, JweDecryptor decryptor, IEnv env, ILogger<SendOtp> log)
    {
        _providers = providers.ToArray();
        _credentials = credentials;
        _httpFactory = httpFactory;
        _decryptor = decryptor;
        _env = env;
        _log = log;
    }

    // Anonymous at the Functions layer; EasyAuth must remain enabled and require authentication in the cloud.
    [Function("SendOtp")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "SendOtp")] HttpRequest req,
        [WorkerFromBody] EntraSendOtpPayload payload,
        FunctionContext? functionContext = null)
    {
        var requestId = Guid.NewGuid().ToString("n");
        var msRequestId = req.Headers["x-ms-client-request-id"].FirstOrDefault();
        var headerCorrelationId = req.Headers["x-ms-correlation-id"].FirstOrDefault();
        var log = new RequestLog(_log, requestId, functionContext?.InvocationId, msRequestId, headerCorrelationId);
        int statusCode;
        object body;

        try
        {
            body = await ProcessAsync(
                payload, requestId, msRequestId, headerCorrelationId, log).ConfigureAwait(false);
            statusCode = 200;
        }
        catch (InvalidRequestException exception)
        {
            statusCode = exception.StatusCode;
            body = new EndpointErrorResponse(
                exception.Error,
                requestId,
                exception.Reason,
                exception.CorrelationId);
        }
        catch (Exception exception)
        {
            if (!log.HasFailure) log.Failure("handler", "unexpected_error", 500);
            statusCode = exception is HttpRequestException { StatusCode: { } status }
                && (int)status >= 500
                    ? (int)status
                    : 500;
            body = new EndpointErrorResponse(
                statusCode == 500 ? "delivery_failed" : "provider_delivery_failed",
                requestId,
                CorrelationId: payload?.CorrelationId ?? headerCorrelationId ?? requestId);
        }

        log.ResponsePrepared(
            statusCode,
            body is EndpointSuccessResponse,
            body is EndpointSuccessResponse or EndpointErrorResponse { CorrelationId: not null });
        log.Complete(statusCode);
        return new ObjectResult(body) { StatusCode = statusCode };
    }

    private async Task<EndpointSuccessResponse> ProcessAsync(
        EntraSendOtpPayload? payload,
        string requestId,
        string? msRequestId,
        string? headerCorrelationId,
        RequestLog log)
    {
        log.Service("request_received");
        var config = AppConfig.Read(_env);
        var clientRequestId = msRequestId ?? requestId;

        if (payload is null)
        {
            const string error = "invalid payload";
            log.Failure("request_validation", error, 400);
            throw new InvalidRequestException(400, "bad_request", error);
        }
        var payloadError = payload.Validate();
        if (payloadError is not null)
        {
            log.Failure("request_validation", payloadError, 400);
            throw new InvalidRequestException(400, "bad_request", payloadError);
        }

        var correlationId = payload.CorrelationId ?? headerCorrelationId ?? requestId;
        log.PayloadValidated(payload, payload.CorrelationId ?? headerCorrelationId,
            payload.CorrelationId is not null ? "payload" : "header");

        (string? Kid, DeliveryContext Context) decrypted;
        try
        {
            decrypted = _decryptor.Decrypt(payload.EncryptedDeliveryContext!);
        }
        catch
        {
            log.Failure("decryption", "decryption_failed", 400);
            throw new InvalidRequestException(
                400, "decryption_failed", correlationId: correlationId);
        }
        log.Service("delivery_context_decrypted");

        if (!string.IsNullOrEmpty(config.ExpectedKeyId)
            && !string.Equals(config.ExpectedKeyId, decrypted.Kid, StringComparison.Ordinal))
            log.KeyIdMismatch();

        var context = decrypted.Context;
        if (!context.IsComplete)
        {
            log.Failure("delivery_context_validation", "incomplete delivery context", 400);
            throw new InvalidRequestException(
                400,
                "bad_request",
                "incomplete delivery context",
                correlationId);
        }

        // Evaluation proves validation/decryption without requiring any provider configuration.
        if (payload.IsEvaluation)
        {
            log.Service("evaluation_completed");
            return new EndpointSuccessResponse(context.Nonce!, correlationId);
        }

        var delivery = new OtpDelivery(
            PhoneNumber: context.PhoneNumber!,
            Message: context.Message,
            Channel: payload.ChannelName,
            MessageId: clientRequestId,
            CorrelationId: correlationId,
            Locale: context.Locale);

        // A nonce acknowledges delivery, not just decryption. Wait for the bounded provider call.
        var providerStatus = await SendToProviderAsync(delivery, log).ConfigureAwait(false);
        if (providerStatus is >= 400 and < 500)
            throw new InvalidRequestException(
                providerStatus, "provider_delivery_failed", correlationId: correlationId);
        if (providerStatus >= 500)
            throw new HttpRequestException(
                "provider_delivery_failed",
                inner: null,
                (HttpStatusCode)providerStatus);

        return new EndpointSuccessResponse(context.Nonce!, correlationId);
    }

    private async Task<int> SendToProviderAsync(OtpDelivery delivery, RequestLog? log = null)
    {
        int Failure(int status, string stage, string reason)
        {
            log?.Failure(stage, reason, status);
            return status;
        }

        var config = AppConfig.Read(_env);
        var provider = SelectProvider(config.ProviderName);
        if (provider is null)
            return Failure(400, "provider_selection", "unknown_provider");

        log?.ProviderSelected(provider.Name, provider.AuthenticationMode);
        var channel = (delivery.Channel ?? "sms").ToLowerInvariant();

        if (channel is not ("sms" or "voice"))
            return Failure(400, "provider_configuration", "unsupported_channel");

        if (!string.IsNullOrEmpty(config.ProviderChannel) && config.ProviderChannel != channel)
            return Failure(400, "provider_configuration", "channel_not_configured");
        if (!string.IsNullOrEmpty(config.ProviderAuthMode) && config.ProviderAuthMode != provider.AuthenticationMode)
            return Failure(502, "provider_configuration", "authentication_mode_mismatch");

        ProviderCredentials credential;
        try
        {
            log?.CredentialResolutionStarted(config);
            credential = await _credentials.GetCredentialsAsync(provider, config);
        }
        catch
        {
            return Failure(502, "provider_credentials", "credential_unavailable");
        }

        var credentialUnavailable = credential.Mode switch
        {
            "apiKey" => string.IsNullOrEmpty(credential.Secret),
            "oauth" => string.IsNullOrEmpty(credential.AccessToken),
            _ => true,
        };
        if (credentialUnavailable)
            return Failure(502, "provider_credentials", "credential_unavailable");
        log?.CredentialResolved();

        var endpoint = config.ProviderEndpoint;
        if (!PhoneProviderBase.IsHttpsEndpoint(endpoint))
            return Failure(502, "provider_configuration", "invalid_provider_endpoint");

        using var client = _httpFactory.CreateClient(ProviderHttpClientName);
        try
        {
            var result = await provider.SendOtpAsync(
                channel,
                endpoint!,
                delivery,
                credential,
                _env,
                client,
                NormalizeProviderTimeoutMs(config.ProviderTimeoutMs),
                log).ConfigureAwait(false);
            return PhoneProviderBase.ToEndpointHttpStatus(result);
        }
        catch (PhoneProviderBase.ProviderSendException exception)
        {
            return exception.StatusCode;
        }
    }

    // Replace this method body when provider choice depends on country, tenant, or other deployment policy.
    private PhoneProviderBase? SelectProvider(string? configuredName) =>
        _providers.FirstOrDefault(provider =>
            string.Equals(provider.Name, configuredName, StringComparison.OrdinalIgnoreCase));

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

    private sealed class InvalidRequestException(
        int statusCode,
        string error,
        string? reason = null,
        string? correlationId = null) : Exception(error)
    {
        public int StatusCode { get; } = statusCode;
        public string Error { get; } = error;
        public string? Reason { get; } = reason;
        public string? CorrelationId { get; } = correlationId;
    }
}
