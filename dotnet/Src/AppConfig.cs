namespace Epp.Otp;

public sealed class AppConfig
{
    public string? ExpectedAudience { get; init; }
    public string? ExpectedClientId { get; init; }
    public string? ExpectedIssuer { get; init; }
    public string? TenantId { get; init; }
    public bool RequireAuth { get; init; }
    public string? DecryptionKeyPem { get; init; }
    public string? ExpectedKeyId { get; init; }
    public string? ProviderName { get; init; }
    public string? ProviderEndpoint { get; init; }
    // Keep the raw value; DispatchEngine owns timeout normalization.
    public string? ProviderTimeoutMs { get; init; }

    public static AppConfig Read(IEnv env) => new()
    {
        ExpectedAudience = env.Get("EPP_EXPECTED_AUDIENCE")?.Trim(),
        ExpectedClientId = env.Get("EPP_EXPECTED_CLIENT_ID")?.Trim(),
        ExpectedIssuer = env.Get("EPP_EXPECTED_ISSUER")?.Trim(),
        TenantId = env.Get("EPP_TENANT_ID")?.Trim(),
        RequireAuth = string.Equals(env.Get("EPP_REQUIRE_AUTH")?.Trim(), "true", StringComparison.OrdinalIgnoreCase),
        DecryptionKeyPem = env.Get("EPP_DECRYPTION_KEY_PEM"),
        ExpectedKeyId = env.Get("EPP_ENCRYPTION_KEY_ID"),
        ProviderName = env.Get("EPP_PROVIDER_NAME")?.Trim().ToLowerInvariant(),
        ProviderEndpoint = env.Get("EPP_PROVIDER_ENDPOINT"),
        ProviderTimeoutMs = env.Get("EPP_PROVIDER_TIMEOUT_MS"),
    };
}