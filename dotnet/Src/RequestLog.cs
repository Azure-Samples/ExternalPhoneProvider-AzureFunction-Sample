using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

// Only explicitly selected metadata enters logs; never serialize delivery/provider models.
public sealed class RequestLog
{
    private static readonly string[] ContextFields =
    {
        "functionName", "functionRequestId", "functionInvocationId",
        "x-ms-client-request-id", "x-ms-correlation-id", "msCorrelationIdSource", "omittedIdFields",
        "channel", "evaluation", "providerName",
    };
    private static readonly string[] CredentialFields =
    {
        "providerAuthMode", "providerCredentialSource", "providerTenantId",
        "functionOutboundClientId", "functionOutboundManagedIdentityClientId",
    };
    private static readonly Regex IdentifierPattern = new(@"\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z", RegexOptions.CultureInvariant);

    private readonly ILogger _logger;
    private readonly Stopwatch _started = Stopwatch.StartNew();
    private readonly Dictionary<string, object?> _data;
    private readonly List<string> _omittedIdFields = new();
    private Stopwatch? _providerStarted;
    private Stopwatch? _credentialStarted;

    public bool HasFailure => _data["failureStage"] is not null;

    public RequestLog(ILogger logger, string requestId, string? invocationId, string? msRequestId, string? msCorrelationId)
    {
        _logger = logger;
        _data = new()
        {
            ["functionName"] = "SendOtp",
            ["functionRequestId"] = requestId,
            ["functionInvocationId"] = invocationId,
            ["x-ms-client-request-id"] = null,
            ["x-ms-correlation-id"] = null,
            ["msCorrelationIdSource"] = "none",
            ["omittedIdFields"] = Array.Empty<string>(),
            ["envelopeType"] = null,
            ["ttlSeconds"] = null,
            ["channel"] = null,
            ["evaluation"] = null,
            ["encryptionKeyIdMismatch"] = false,
            ["providerName"] = null,
            ["providerAuthMode"] = null,
            ["providerCredentialSource"] = null,
            ["providerCredentialElapsedMs"] = null,
            ["providerTenantId"] = null,
            ["functionOutboundClientId"] = null,
            ["functionOutboundManagedIdentityClientId"] = null,
            ["providerHttpMethod"] = null,
            ["providerEndpoint"] = null,
            ["providerAttempted"] = false,
            ["providerHttpStatus"] = null,
            ["providerStatus"] = null,
            ["providerOutcome"] = null,
            ["providerMessageId"] = null,
            ["providerElapsedMs"] = null,
            ["providerTimeoutMs"] = null,
            ["failureStage"] = null,
            ["failureReason"] = null,
            ["responseContainsNonce"] = null,
            ["responseContainsCorrelationId"] = null,
        };
        SetIdentifier("x-ms-client-request-id", msRequestId);
        SetIdentifier("x-ms-correlation-id", msCorrelationId);
        _data["msCorrelationIdSource"] = _data["x-ms-correlation-id"] is null ? "none" : "header";
    }

    private void SetIdentifier(string field, string? value)
    {
        var valid = value is { Length: <= 128 } && IdentifierPattern.IsMatch(value);
        _data[field] = valid ? value : null;
        _omittedIdFields.Remove(field);
        if (!valid && !string.IsNullOrWhiteSpace(value)) _omittedIdFields.Add(field);
        _data["omittedIdFields"] = _omittedIdFields.ToArray();
    }

    public void Service(string eventName, Dictionary<string, object?>? details = null, LogLevel level = LogLevel.Information)
    {
        var record = new Dictionary<string, object?> { ["logType"] = "service", ["eventName"] = eventName };
        foreach (var field in ContextFields) record[field] = _data[field];
        if (details is not null)
            foreach (var (key, value) in details) record[key] = value;
        record["elapsedMs"] = _started.ElapsedMilliseconds;
        Write(level, eventName, record);
    }

    public void EnvelopeValidated(Envelope envelope, string? correlationId, string source)
    {
        _data["envelopeType"] = envelope.Type;
        _data["ttlSeconds"] = envelope.TtlSeconds;
        _data["channel"] = EnvelopeParser.ChannelName(envelope.Channel);
        _data["evaluation"] = envelope.Mode == EnvelopeParser.ModeEvaluation;
        SetIdentifier("x-ms-correlation-id", correlationId);
        _data["msCorrelationIdSource"] = _data["x-ms-correlation-id"] is null ? "none" : source;
        Service("envelope_validated", new()
        {
            ["envelopeType"] = _data["envelopeType"],
            ["ttlSeconds"] = _data["ttlSeconds"],
            ["encryptedDeliveryContextPresent"] = true,
        });
    }

    public void KeyIdMismatch()
    {
        _data["encryptionKeyIdMismatch"] = true;
        Service("encryption_key_id_mismatch", level: LogLevel.Warning);
    }

    public void ProviderSelected(ProviderManifest manifest)
    {
        _data["providerName"] = manifest.Id;
        _data["providerAuthMode"] = manifest.Auth.Mode is "apiKey" or "oauth" ? manifest.Auth.Mode : "unsupported";
        Service("provider_selected", new() { ["providerAuthMode"] = _data["providerAuthMode"] });
    }

    public void CredentialResolutionStarted(AppConfig config)
    {
        _credentialStarted = Stopwatch.StartNew();
        _data["providerCredentialSource"] = _data["providerAuthMode"] switch
        {
            "oauth" => "managed_identity_client_assertion",
            "apiKey" => "key_vault",
            _ => "unsupported",
        };
        if (Equals(_data["providerAuthMode"], "oauth"))
        {
            SetIdentifier("providerTenantId", config.ProviderTenantId);
            SetIdentifier("functionOutboundClientId", config.OutboundClientId);
            SetIdentifier("functionOutboundManagedIdentityClientId", config.OutboundManagedIdentityClientId);
        }
        Service("provider_credential_resolution_started", CredentialDetails());
    }

    private Dictionary<string, object?> CredentialDetails() =>
        CredentialFields.ToDictionary(key => key, key => _data[key]);

    private void CredentialResolutionFinished()
    {
        if (_credentialStarted is null) return;
        _data["providerCredentialElapsedMs"] = _credentialStarted.ElapsedMilliseconds;
        _credentialStarted = null;
    }

    public void CredentialResolved()
    {
        CredentialResolutionFinished();
        var details = CredentialDetails();
        details["providerCredentialElapsedMs"] = _data["providerCredentialElapsedMs"];
        Service("provider_credential_resolved", details);
    }

    public void ProviderRequestBuilt(string? method, string endpoint)
    {
        var normalized = method?.ToUpperInvariant();
        _data["providerHttpMethod"] = normalized is "GET" or "HEAD" or "POST" or "PUT" or "DELETE"
            or "CONNECT" or "OPTIONS" or "TRACE" or "PATCH" ? normalized : "other";
        var uri = new Uri(endpoint, UriKind.Absolute);
        _data["providerEndpoint"] = uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.UriEscaped) + uri.AbsolutePath;
        Service("provider_request_built", new()
        {
            ["providerHttpMethod"] = _data["providerHttpMethod"],
            ["providerEndpoint"] = _data["providerEndpoint"],
            ["providerScheme"] = "https",
            ["redirectsAllowed"] = false,
        });
    }

    public void ProviderRequestStarted(int timeoutMs)
    {
        _providerStarted = Stopwatch.StartNew();
        _data["providerAttempted"] = true;
        _data["providerTimeoutMs"] = timeoutMs;
        Service("provider_request_started", new()
        {
            ["providerTimeoutMs"] = timeoutMs,
            ["providerHttpMethod"] = _data["providerHttpMethod"],
            ["providerEndpoint"] = _data["providerEndpoint"],
        });
    }

    public void ProviderResponseReceived(int status)
    {
        _data["providerHttpStatus"] = status;
        Service("provider_response_received", new() { ["providerHttpStatus"] = status });
    }

    public void ProviderRequestFinished()
    {
        if (_providerStarted is null) return;
        _data["providerElapsedMs"] = _providerStarted.ElapsedMilliseconds;
        _providerStarted = null;
    }

    public void ProviderResponseProcessed(ProviderManifest manifest, ParsedResponse parsed, Outcome outcome, int httpStatus, bool validJson)
    {
        var status = parsed.ProviderStatusName ?? parsed.ProviderStatusCode;
        var known = status is not null && status != "default" && manifest.ResponseMapping.ContainsKey(status);
        _data["providerStatus"] = known ? status : "unmapped";
        _data["providerOutcome"] = outcome.ToString();
        SetIdentifier("providerMessageId", parsed.ProviderMessageId);
        if (outcome != Outcome.Continue)
        {
            _data["failureStage"] = "provider_response";
            _data["failureReason"] = validJson ? "provider_rejected" : "invalid_provider_json";
        }
        Service("provider_response_processed", new()
        {
            ["providerHttpStatus"] = _data["providerHttpStatus"],
            ["providerStatus"] = _data["providerStatus"],
            ["providerOutcome"] = _data["providerOutcome"],
            ["providerMessageId"] = _data["providerMessageId"],
            ["providerElapsedMs"] = _data["providerElapsedMs"],
            ["httpStatus"] = httpStatus,
            ["failureReason"] = _data["failureReason"],
        }, httpStatus >= 500 ? LogLevel.Error : httpStatus == 200 ? LogLevel.Information : LogLevel.Warning);
    }

    public void Failure(string stage, string reason, int httpStatus)
    {
        CredentialResolutionFinished();
        ProviderRequestFinished();
        _data["failureStage"] = stage;
        _data["failureReason"] = reason;
        Service(stage + "_failed", new() { ["failureReason"] = reason, ["httpStatus"] = httpStatus },
            httpStatus >= 500 ? LogLevel.Error : LogLevel.Warning);
    }

    public void ResponsePrepared(int httpStatus, bool containsNonce, bool containsCorrelationId)
    {
        _data["responseContainsNonce"] = containsNonce;
        _data["responseContainsCorrelationId"] = containsCorrelationId;
        Service("response_prepared", new()
        {
            ["httpStatus"] = httpStatus,
            ["responseContainsNonce"] = containsNonce,
            ["responseContainsCorrelationId"] = containsCorrelationId,
        });
    }

    public void Complete(int httpStatus)
    {
        CredentialResolutionFinished();
        ProviderRequestFinished();
        var record = new Dictionary<string, object?>(_data)
        {
            ["logType"] = "request",
            ["eventName"] = "request_completed",
            ["httpStatus"] = httpStatus,
            ["result"] = httpStatus == 200 ? (Equals(_data["evaluation"], true) ? "evaluated" : "accepted") : "failed",
            ["elapsedMs"] = _started.ElapsedMilliseconds,
        };
        Write(LogLevel.Information, "request_completed", record);
    }

    private void Write(LogLevel level, string eventName, Dictionary<string, object?> record) =>
        _logger.Log(level, new EventId(0, eventName), record, null,
            static (state, _) => JsonSerializer.Serialize(state));
}
