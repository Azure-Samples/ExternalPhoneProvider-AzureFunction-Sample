using System.Net;
using System.Diagnostics;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using WorkerFromBody = Microsoft.Azure.Functions.Worker.Http.FromBodyAttribute;

namespace Epp.Otp;

// Echo the nonce only on acceptance; keep structured service events PII-safe.
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
        var started = Stopwatch.StartNew();
        var requestId = Guid.NewGuid().ToString("n");
        var msRequestId = OtpLog.SafeIdentifier(
            req.Headers["x-ms-client-request-id"].FirstOrDefault());
        var headerCorrelationId = OtpLog.SafeIdentifier(
            req.Headers["x-ms-correlation-id"].FirstOrDefault());
        var payloadError = payload?.Validate();
        var payloadCorrelationId = payloadError is null
            ? OtpLog.SafeIdentifier(payload?.CorrelationId)
            : null;
        using var scope = _log.BeginScope(new Dictionary<string, object?>
        {
            ["FunctionName"] = "SendOtp",
            ["FunctionRequestId"] = requestId,
            ["FunctionInvocationId"] = functionContext?.InvocationId,
            ["MsClientRequestId"] = msRequestId,
            ["MsCorrelationId"] = payloadCorrelationId ?? headerCorrelationId,
            ["MsCorrelationIdSource"] = payloadCorrelationId is not null
                ? "payload"
                : headerCorrelationId is not null ? "header" : "none",
        });
        int statusCode;
        object body;

        try
        {
            OtpLog.RequestReceived(_log);
            body = await ProcessAsync(
                payload, payloadError, requestId, msRequestId, headerCorrelationId).ConfigureAwait(false);
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
            OtpLog.UnexpectedError(_log);
            statusCode = exception is HttpRequestException { StatusCode: { } status }
                && (int)status >= 500
                    ? (int)status
                    : 500;
            body = new EndpointErrorResponse(
                statusCode == 500 ? "delivery_failed" : "provider_delivery_failed",
                requestId,
                CorrelationId: payload?.CorrelationId ?? headerCorrelationId ?? requestId);
        }

        var containsNonce = body is EndpointSuccessResponse;
        var containsCorrelationId =
            body is EndpointSuccessResponse or EndpointErrorResponse { CorrelationId: not null };
        OtpLog.ResponsePrepared(
            _log,
            statusCode,
            containsNonce,
            containsCorrelationId);
        OtpLog.RequestCompleted(
            _log,
            statusCode,
            statusCode == 200
                ? payload?.IsEvaluation == true ? "evaluated" : "accepted"
                : "failed",
            started.ElapsedMilliseconds);
        return new ObjectResult(body) { StatusCode = statusCode };
    }

    private async Task<EndpointSuccessResponse> ProcessAsync(
        EntraSendOtpPayload? payload,
        string? payloadError,
        string requestId,
        string? msRequestId,
        string? headerCorrelationId)
    {
        var config = AppConfig.Read(_env);
        var clientRequestId = msRequestId ?? requestId;

        if (payload is null)
        {
            const string error = "invalid payload";
            OtpLog.RequestFailed(
                _log, LogLevel.Warning, "request_validation", error, 400);
            throw new InvalidRequestException(400, "bad_request", error);
        }
        if (payloadError is not null)
        {
            OtpLog.RequestFailed(
                _log, LogLevel.Warning, "request_validation", payloadError, 400);
            throw new InvalidRequestException(400, "bad_request", payloadError);
        }

        var correlationId = payload.CorrelationId ?? headerCorrelationId ?? requestId;
        OtpLog.PayloadValidated(
            _log,
            payload.Type,
            payload.ChannelName,
            payload.IsEvaluation,
            payload.TtlSeconds);

        DecryptedPayload<DeliveryContext> decrypted;
        try
        {
            decrypted = _decryptor.Decrypt<DeliveryContext>(
                payload.EncryptedDeliveryContext!);
        }
        catch
        {
            OtpLog.RequestFailed(
                _log, LogLevel.Warning, "decryption", "decryption_failed", 400);
            throw new InvalidRequestException(
                400, "decryption_failed", correlationId: correlationId);
        }
        OtpLog.DeliveryContextDecrypted(_log);

        if (!string.IsNullOrEmpty(config.ExpectedKeyId)
            && !string.Equals(config.ExpectedKeyId, decrypted.KeyId, StringComparison.Ordinal))
            OtpLog.EncryptionKeyIdMismatch(_log);

        var context = decrypted.Value;
        if (!context.IsComplete)
        {
            OtpLog.RequestFailed(
                _log,
                LogLevel.Warning,
                "delivery_context_validation",
                "incomplete delivery context",
                400);
            throw new InvalidRequestException(
                400,
                "bad_request",
                "incomplete delivery context",
                correlationId);
        }

        // Evaluation proves validation/decryption without requiring any provider configuration.
        if (payload.IsEvaluation)
        {
            OtpLog.EvaluationCompleted(_log);
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
        var providerStatus = await SendToProviderAsync(delivery).ConfigureAwait(false);
        if (providerStatus >= 400)
            throw new InvalidRequestException(
                providerStatus, "provider_delivery_failed", correlationId: correlationId);

        return new EndpointSuccessResponse(context.Nonce!, correlationId);
    }

    private async Task<int> SendToProviderAsync(OtpDelivery delivery)
    {
        int Failure(int status, string stage, string reason)
        {
            OtpLog.RequestFailed(
                _log,
                status >= 500 ? LogLevel.Error : LogLevel.Warning,
                stage,
                reason,
                status);
            return status;
        }

        var config = AppConfig.Read(_env);
        var provider = SelectProvider(config.ProviderName);
        if (provider is null)
            return Failure(400, "provider_selection", "unknown_provider");

        OtpLog.ProviderSelected(_log, provider.Name, provider.AuthenticationMode);
        var channel = (delivery.Channel ?? "sms").ToLowerInvariant();

        if (channel is not ("sms" or "voice"))
            return Failure(400, "provider_configuration", "unsupported_channel");

        if (!string.IsNullOrEmpty(config.ProviderChannel) && config.ProviderChannel != channel)
            return Failure(400, "provider_configuration", "channel_not_configured");
        if (!string.IsNullOrEmpty(config.ProviderAuthMode) && config.ProviderAuthMode != provider.AuthenticationMode)
            return Failure(502, "provider_configuration", "authentication_mode_mismatch");

        ProviderCredentials credential;
        var credentialStarted = Stopwatch.StartNew();
        try
        {
            OtpLog.CredentialResolutionStarted(
                _log,
                provider.Name,
                provider.AuthenticationMode == "oauth"
                    ? "managed_identity_client_assertion"
                    : "key_vault");
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
        OtpLog.CredentialResolved(
            _log,
            provider.Name,
            credentialStarted.ElapsedMilliseconds);

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
                _log).ConfigureAwait(false);
            var status = PhoneProviderBase.ToEndpointHttpStatus(result);
            if (status >= 400)
                Failure(
                    status,
                    "provider_response",
                    result.StatusRecognized
                    || result.ProviderStatusCode is not null
                    || result.ProviderStatusName is not null
                        ? "provider_rejected"
                        : "invalid_provider_json");
            return status;
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
