using System.Text.Json.Serialization;

namespace Epp.Otp;

public enum Outcome { Continue, Fail, Block, StepUp }

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

public sealed record DispatchRequest(
    string Destination,
    string? Message,
    string Channel,
    string MessageId,
    string? CorrelationId,
    string? Locale,
    TextToVoice? TextToVoice = null);

public sealed record TextToVoice(
    [property: JsonPropertyName("beforePasswordText")] string? BeforePasswordText,
    [property: JsonPropertyName("password")] string? Password,
    [property: JsonPropertyName("language")] string? Language)
{
    [JsonIgnore]
    public bool IsComplete => BeforePasswordText is not null
        && !string.IsNullOrWhiteSpace(Password) && !string.IsNullOrWhiteSpace(Language);

    public override string ToString() => nameof(TextToVoice);
}

public sealed record ProviderCredential(string Mode, string? Secret = null, string? Identity = null);

public sealed record ProviderHttpRequest(string Url, string Method, Dictionary<string, string> Headers, string Body);

public sealed record ParsedResponse(
    bool Success,
    int ProviderHttpStatus,
    string? ProviderMessageId = null,
    string? ProviderStatusName = null,
    string? ProviderStatusCode = null,
    string? ProviderStatusDescription = null)
{
    public override string ToString() => nameof(ParsedResponse);
}

public sealed record AuthConfig(string Mode, string? KeyVaultSecretName = null, string? IdentityKeyVaultSecretName = null);

public sealed record ProviderManifest(string Id, AuthConfig Auth, IReadOnlyDictionary<string, Outcome> ResponseMapping,
    bool RequiresTextToVoice = false);

public sealed record DispatchResult(int HttpStatus, object Body);

public interface IEnv { string? Get(string key); }

public sealed class ProcessEnv : IEnv
{
    public string? Get(string key) => Environment.GetEnvironmentVariable(key);
}
