using System.Text.Json.Serialization;

namespace Epp.Otp;

public enum Outcome { Continue, Fail, Block }

public sealed record EndpointSuccessResponse(
    [property: JsonPropertyName("nonce")] string Nonce,
    [property: JsonPropertyName("correlationId")] string CorrelationId,
    [property: JsonPropertyName("providerStatus")] string ProviderStatus = "accepted")
{
    public override string ToString() => nameof(EndpointSuccessResponse);
}

public sealed record EndpointErrorResponse(
    [property: JsonPropertyName("error")] string Error,
    [property: JsonPropertyName("requestId"), JsonPropertyOrder(1)] string RequestId,
    [property: JsonPropertyName("reason"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Reason = null,
    [property: JsonPropertyName("correlationId"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? CorrelationId = null);

public sealed record OtpDelivery(
    string PhoneNumber,
    string? Message,
    string Channel,
    string MessageId,
    string? CorrelationId,
    string? Locale);

public sealed record ProviderCredentials(
    string Mode,
    string? Secret = null,
    string? Identity = null,
    [property: JsonIgnore] string? AccessToken = null,
    [property: JsonIgnore] DateTimeOffset ExpiresOn = default)
{
    public override string ToString() => nameof(ProviderCredentials);
}

public sealed record ProviderResult(
    Outcome Outcome,
    bool StatusRecognized,
    int ProviderHttpStatus,
    string? ProviderMessageId = null,
    string? ProviderStatusName = null,
    string? ProviderStatusCode = null,
    string? ProviderStatusDescription = null)
{
    public string? FailureReason { get; init; }
    public override string ToString() => nameof(ProviderResult);
}

public interface IEnv { string? Get(string key); }

public sealed class ProcessEnv : IEnv
{
    public string? Get(string key) => Environment.GetEnvironmentVariable(key);
}
