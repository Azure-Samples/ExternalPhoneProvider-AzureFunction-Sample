using System.Text.Json;
using Azure.Core;
using Azure.Identity;

namespace Epp.Otp.Providers;

public sealed class SopranoProvider : IProviderAdapter
{
    private readonly Func<string, TokenCredential> _createManagedIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private readonly object _credentialLock = new();
    private TokenCredential? _credential;
    private (string Tenant, string Application, string Identity) _credentialSettings;

    public SopranoProvider() : this(identity => new ManagedIdentityCredential(identity, CredentialOptions()),
        (tenant, applicationId, assertion) => new ClientAssertionCredential(tenant, applicationId, assertion, CredentialOptions())) { }

    private static ClientAssertionCredentialOptions CredentialOptions()
    {
        var options = new ClientAssertionCredentialOptions { AuthorityHost = AzureAuthorityHosts.AzurePublicCloud };
        options.Retry.MaxRetries = 0;
        options.Retry.NetworkTimeout = TimeSpan.FromSeconds(2.5);
        options.Diagnostics.IsLoggingEnabled = false;
        options.Diagnostics.IsLoggingContentEnabled = false;
        return options;
    }

    internal SopranoProvider(Func<string, TokenCredential> createManagedIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential)
    {
        _createManagedIdentity = createManagedIdentity;
        _createCredential = createCredential;
    }

    private static bool JwtEnabled(IEnv env) =>
        string.Equals(env.Get("EPP_PROVIDER_JWT_ENABLED")?.Trim(), "true", StringComparison.OrdinalIgnoreCase);

    public async Task<string?> AcquireTokenAsync(IEnv env)
    {
        if (!JwtEnabled(env)) return null;
        var scope = env.Get("EPP_PROVIDER_SCOPE")?.Trim();
        var tenant = env.Get("EPP_PROVIDER_TENANT_ID")?.Trim();
        var applicationId = env.Get("EPP_PROVIDER_APPLICATION_ID")?.Trim();
        var identity = env.Get("EPP_PROVIDER_MI_CLIENT_ID")?.Trim();
        if (string.IsNullOrEmpty(scope) || string.IsNullOrEmpty(tenant)
            || string.IsNullOrEmpty(applicationId) || string.IsNullOrEmpty(identity)) return null;
        try
        {
            TokenCredential credential;
            lock (_credentialLock)
            {
                var settings = (tenant, applicationId, identity);
                if (_credential is null || _credentialSettings != settings)
                {
                    var managedIdentity = _createManagedIdentity(identity);
                    _credential = _createCredential(tenant, applicationId, async cancellation =>
                    {
                        var assertion = await managedIdentity.GetTokenAsync(
                            new TokenRequestContext(new[] { "api://AzureADTokenExchange/.default" }), cancellation);
                        if (assertion.ExpiresOn <= DateTimeOffset.UtcNow.AddSeconds(30) || string.IsNullOrWhiteSpace(assertion.Token))
                            throw new InvalidOperationException("managed identity assertion unavailable");
                        return assertion.Token;
                    });
                    _credentialSettings = settings;
                }
                credential = _credential;
            }
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(2.5));
            var result = await credential.GetTokenAsync(new TokenRequestContext(new[] { scope }), cancellation.Token);
            return result.ExpiresOn > DateTimeOffset.UtcNow.AddSeconds(30) && !string.IsNullOrWhiteSpace(result.Token) ? result.Token : null;
        }
        catch
        {
            return null;
        }
    }

    public ProviderManifest Manifest { get; } = new(
        Id: "soprano",
        Auth: new AuthConfig("apiKey", KeyVaultSecretName: "soprano-api-key", IdentityKeyVaultSecretName: "soprano-api-id"),
        ResponseMapping: new Dictionary<string, Outcome>
        {
            ["ENROUTE"] = Outcome.Continue,
            ["ACCEPTED"] = Outcome.Continue,
            ["SUBMITTED"] = Outcome.Continue,
            ["SENT"] = Outcome.Continue,
            ["DELIVERED"] = Outcome.Continue,
            ["QUEUED"] = Outcome.Continue,
            ["FAILED"] = Outcome.Fail,
            ["REJECTED"] = Outcome.Fail,
            ["FILTERED"] = Outcome.Fail,
            ["BLOCKED"] = Outcome.Block,
            ["default"] = Outcome.Fail,
        },
        RequiresTextToVoice: true);

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var headers = new Dictionary<string, string>
        {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["X-MEMS-API-ID"] = credential.Identity ?? string.Empty,
            ["X-MEMS-API-Key"] = credential.Secret ?? string.Empty,
        };
        if (JwtEnabled(env) && !string.IsNullOrWhiteSpace(credential.Token)) headers["Authorization"] = "Bearer " + credential.Token;
        var body = new Dictionary<string, object?>
        {
            ["destination"] = dispatch.Destination.TrimStart('+'),
            ["messageTypes"] = new[] { channel == "voice" ? "voice" : "sms" },
            ["correlationId"] = dispatch.CorrelationId ?? dispatch.MessageId,
            ["shutterMode"] = false,
        };
        if (channel == "voice")
        {
            var voice = dispatch.TextToVoice;
            if (voice?.IsComplete != true) throw new InvalidOperationException("incomplete voice context");
            body["voice"] = new { text2voice = voice };
        }
        else
        {
            body["text"] = dispatch.Message;
        }

        return new ProviderHttpRequest($"{endpoint.TrimEnd('/')}/messages/omnimsg", "POST", headers, JsonSerializer.Serialize(body));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        var payload = json.ValueKind == JsonValueKind.Array && json.GetArrayLength() > 0 ? json[0] : json;
        string? id = null, status = null;
        if (payload.ValueKind == JsonValueKind.Object)
        {
            if (payload.TryGetProperty("id", out var idElement)) id = idElement.ToString();
            else if (payload.TryGetProperty("messageId", out var messageIdElement)) id = messageIdElement.ToString();
            if (!payload.TryGetProperty("status", out var statusElement) || statusElement.ValueKind == JsonValueKind.Null)
                payload.TryGetProperty("state", out statusElement);
            if (statusElement.ValueKind == JsonValueKind.String) status = statusElement.GetString();
        }
        status = string.IsNullOrWhiteSpace(status) ? "UNKNOWN" : status.ToUpperInvariant();
        return new ParsedResponse(ok, httpStatus, id, status);
    }
}
