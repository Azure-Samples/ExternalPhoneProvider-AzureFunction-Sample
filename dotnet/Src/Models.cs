using System.Text.Json;

namespace Epp.Otp;

// Language-agnostic contract types (see /docs/CONTRACT.md).

public enum Outcome { Continue, Fail, Block, StepUp }

public sealed record DispatchRequest(
    string Destination,
    string? Message,
    string Channel,
    string MessageId,
    string? CorrelationId,
    string? Locale);

public sealed record ProviderCredential(string Mode, string? Secret = null, string? Identity = null, string? Token = null);

public sealed record ProviderHttpRequest(string Url, string Method, Dictionary<string, string> Headers, string Body);

public sealed record ParsedResponse(
    bool Success,
    int ProviderHttpStatus,
    string? ProviderMessageId = null,
    string? ProviderStatusName = null,
    string? ProviderStatusCode = null,
    string? ProviderStatusDescription = null);

public sealed record AuthConfig(string Mode, string? KeyVaultSecretName = null, string? IdentityKeyVaultSecretName = null);

public sealed record ProviderManifest(string Id, AuthConfig Auth, IReadOnlyDictionary<string, Outcome> ResponseMapping);

public sealed record DispatchResult(int HttpStatus, object Body);

// The env snapshot passed to adapters.
public interface IEnv { string? Get(string key); }

public sealed class ProcessEnv : IEnv
{
    public string? Get(string key) => Environment.GetEnvironmentVariable(key);
}
