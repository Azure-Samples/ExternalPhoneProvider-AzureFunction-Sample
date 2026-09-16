namespace Epp.Otp;

public sealed class AppConfig
{
    public string? DecryptionKeyPem { get; init; }
    public string? ExpectedKeyId { get; init; }
    public string? ProviderName { get; init; }
    public string? ProviderEndpoint { get; init; }
    public string? ProviderChannel { get; init; }
    public string? ProviderAuthMode { get; init; }
    public string? ProviderTenantId { get; init; }
    public string? ProviderScope { get; init; }
    public string? OutboundClientId { get; init; }
    public string? OutboundManagedIdentityClientId { get; init; }
    // Keep the raw value; DispatchEngine owns timeout normalization.
    public string? ProviderTimeoutMs { get; init; }

    public static AppConfig Read(IEnv env) => new()
    {
        DecryptionKeyPem = env.Get("EPP_DECRYPTION_KEY_PEM"),
        ExpectedKeyId = env.Get("EPP_ENCRYPTION_KEY_ID"),
        ProviderName = env.Get("EPP_PROVIDER_NAME")?.Trim().ToLowerInvariant(),
        ProviderEndpoint = env.Get("EPP_PROVIDER_ENDPOINT"),
        ProviderChannel = env.Get("EPP_PROVIDER_CHANNEL")?.Trim().ToLowerInvariant(),
        ProviderAuthMode = env.Get("EPP_PROVIDER_AUTH_MODE")?.Trim(),
        ProviderTenantId = env.Get("EPP_PROVIDER_TENANT_ID")?.Trim(),
        ProviderScope = env.Get("EPP_PROVIDER_SCOPE")?.Trim(),
        OutboundClientId = env.Get("EPP_OUTBOUND_CLIENT_ID")?.Trim(),
        OutboundManagedIdentityClientId = env.Get("EPP_OUTBOUND_MI_CLIENT_ID")?.Trim(),
        ProviderTimeoutMs = env.Get("EPP_PROVIDER_TIMEOUT_MS"),
    };
}