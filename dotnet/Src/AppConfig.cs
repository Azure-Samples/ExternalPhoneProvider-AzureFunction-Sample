namespace Epp.Otp;

public sealed class AppConfig
{
    public string? DecryptionKeyPem { get; init; }
    public string? ExpectedKeyId { get; init; }
    public string? ProviderName { get; init; }
    public string? ProviderEndpoint { get; init; }
    public string ProviderAuthMode { get; init; } = "apiKey";
    public string ProviderJwtEnabled { get; init; } = "false";
    // Keep the raw value; DispatchEngine owns timeout normalization.
    public string? ProviderTimeoutMs { get; init; }

    public static AppConfig Read(IEnv env) => new()
    {
        DecryptionKeyPem = env.Get("EPP_DECRYPTION_KEY_PEM"),
        ExpectedKeyId = env.Get("EPP_ENCRYPTION_KEY_ID"),
        ProviderName = env.Get("EPP_PROVIDER_NAME")?.Trim().ToLowerInvariant(),
        ProviderEndpoint = env.Get("EPP_PROVIDER_ENDPOINT"),
        ProviderAuthMode = env.Get("EPP_PROVIDER_AUTH_MODE")?.Trim() ?? "apiKey",
        ProviderJwtEnabled = env.Get("EPP_PROVIDER_JWT_ENABLED")?.Trim() ?? "false",
        ProviderTimeoutMs = env.Get("EPP_PROVIDER_TIMEOUT_MS"),
    };
}