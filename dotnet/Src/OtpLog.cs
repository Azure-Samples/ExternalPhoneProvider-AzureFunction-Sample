using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

internal static partial class OtpLog
{
    private static readonly Regex IdentifierPattern = new(
        @"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z",
        RegexOptions.CultureInvariant);

    internal static string? SafeIdentifier(string? value) =>
        value is { Length: <= 128 } && IdentifierPattern.IsMatch(value) ? value : null;

    [LoggerMessage(EventId = 1000, EventName = "request_received", Level = LogLevel.Information,
        Message = "OTP request received")]
    internal static partial void RequestReceived(ILogger logger);

    [LoggerMessage(EventId = 1001, EventName = "payload_validated", Level = LogLevel.Information,
        Message = "Payload validated: type {PayloadType}, channel {Channel}, evaluation {Evaluation}, TTL {TtlSeconds}")]
    internal static partial void PayloadValidated(
        ILogger logger, string? payloadType, string? channel, bool evaluation, int? ttlSeconds);

    [LoggerMessage(EventId = 1002, EventName = "delivery_context_decrypted", Level = LogLevel.Information,
        Message = "Delivery context decrypted")]
    internal static partial void DeliveryContextDecrypted(ILogger logger);

    [LoggerMessage(EventId = 1003, EventName = "encryption_key_id_mismatch", Level = LogLevel.Warning,
        Message = "Encrypted payload key identifier did not match the configured identifier")]
    internal static partial void EncryptionKeyIdMismatch(ILogger logger);

    [LoggerMessage(EventId = 1004, EventName = "evaluation_completed", Level = LogLevel.Information,
        Message = "Evaluation request completed")]
    internal static partial void EvaluationCompleted(ILogger logger);

    [LoggerMessage(EventId = 1100, EventName = "provider_selected", Level = LogLevel.Information,
        Message = "Provider {ProviderName} selected with authentication mode {AuthenticationMode}")]
    internal static partial void ProviderSelected(
        ILogger logger, string providerName, string authenticationMode);

    [LoggerMessage(EventId = 1101, EventName = "provider_credential_resolution_started", Level = LogLevel.Information,
        Message = "Resolving {CredentialSource} credentials for provider {ProviderName}")]
    internal static partial void CredentialResolutionStarted(
        ILogger logger, string providerName, string credentialSource);

    [LoggerMessage(EventId = 1102, EventName = "provider_credential_resolved", Level = LogLevel.Information,
        Message = "Resolved credentials for provider {ProviderName} in {ElapsedMs} ms")]
    internal static partial void CredentialResolved(
        ILogger logger, string providerName, long elapsedMs);

    [LoggerMessage(EventId = 1200, EventName = "provider_request_build_started", Level = LogLevel.Information,
        Message = "Building provider request")]
    internal static partial void ProviderRequestBuildStarted(ILogger logger);

    [LoggerMessage(EventId = 1201, EventName = "provider_request_built", Level = LogLevel.Information,
        Message = "Built provider request: {HttpMethod} {ProviderEndpoint}; redirects allowed: false")]
    internal static partial void ProviderRequestBuilt(
        ILogger logger, string httpMethod, string providerEndpoint);

    [LoggerMessage(EventId = 1202, EventName = "provider_request_started", Level = LogLevel.Information,
        Message = "Sending provider request with timeout {TimeoutMs} ms")]
    internal static partial void ProviderRequestStarted(ILogger logger, int timeoutMs);

    [LoggerMessage(EventId = 1203, EventName = "provider_response_received", Level = LogLevel.Information,
        Message = "Provider returned HTTP status {ProviderHttpStatus}")]
    internal static partial void ProviderResponseReceived(ILogger logger, int providerHttpStatus);

    [LoggerMessage(EventId = 1204, EventName = "provider_response_invalid_json", Level = LogLevel.Warning,
        Message = "Provider response was not valid JSON")]
    internal static partial void ProviderResponseInvalidJson(ILogger logger);

    [LoggerMessage(EventId = 1205, EventName = "provider_response_processed",
        Message = "Processed provider response: HTTP {ProviderHttpStatus}, status {ProviderStatus}, outcome {ProviderOutcome}, elapsed {ElapsedMs} ms")]
    internal static partial void ProviderResponseProcessed(
        ILogger logger,
        LogLevel level,
        int providerHttpStatus,
        string providerStatus,
        string providerOutcome,
        long elapsedMs);

    [LoggerMessage(EventId = 1300, EventName = "request_failed",
        Message = "Request failed during {FailureStage}: {FailureReason}; HTTP status {HttpStatus}")]
    internal static partial void RequestFailed(
        ILogger logger,
        LogLevel level,
        string failureStage,
        string failureReason,
        int httpStatus);

    [LoggerMessage(EventId = 1301, EventName = "unexpected_error", Level = LogLevel.Error,
        Message = "Unexpected request failure")]
    internal static partial void UnexpectedError(ILogger logger);

    [LoggerMessage(EventId = 1400, EventName = "response_prepared", Level = LogLevel.Information,
        Message = "Response prepared: HTTP {HttpStatus}, contains nonce {ContainsNonce}, contains correlation ID {ContainsCorrelationId}")]
    internal static partial void ResponsePrepared(
        ILogger logger, int httpStatus, bool containsNonce, bool containsCorrelationId);

    [LoggerMessage(EventId = 1401, EventName = "request_completed", Level = LogLevel.Information,
        Message = "Request completed: HTTP {HttpStatus}, result {Result}, elapsed {ElapsedMs} ms")]
    internal static partial void RequestCompleted(
        ILogger logger, int httpStatus, string result, long elapsedMs);

    [LoggerMessage(EventId = 1500, EventName = "credential_refresh_failed", Level = LogLevel.Warning,
        Message = "Credential refresh failed for {CacheKind}: credential unavailable")]
    internal static partial void CredentialRefreshFailed(ILogger logger, string cacheKind);
}
