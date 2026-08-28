using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;

namespace Epp.Otp;

// Validates the Entra JWT when EPP_REQUIRE_AUTH=true (aud/issuer/JWKS, RS256). No-op pass-through
// otherwise — Easy Auth is the primary gate; this is the backstop.
public sealed class TokenValidator
{
    private readonly JwtSecurityTokenHandler _handler = new();
    private readonly IEnv _env;
    private ConfigurationManager<OpenIdConnectConfiguration>? _configManager;

    public TokenValidator(IEnv? env = null) => _env = env ?? new ProcessEnv();

    // azp is the v2 caller claim, appid the v1 one.
    public static bool IsExpectedCaller(string? callerAppId, string? expectedClientId) =>
        string.IsNullOrEmpty(expectedClientId)
        || string.Equals(callerAppId, expectedClientId, StringComparison.OrdinalIgnoreCase);

    public sealed record Result(bool Ok, string? Reason = null, string? CallerObjectId = null);

    public async Task<Result> ValidateAsync(string? authorizationHeader)
    {
        if (!string.Equals(_env.Get("EPP_REQUIRE_AUTH"), "true", StringComparison.OrdinalIgnoreCase))
            return new Result(true);

        var audience = _env.Get("EPP_EXPECTED_AUDIENCE");
        var tenantId = _env.Get("EPP_TENANT_ID");
        if (string.IsNullOrEmpty(audience) || string.IsNullOrEmpty(tenantId))
            return new Result(false, "auth misconfigured");

        if (string.IsNullOrEmpty(authorizationHeader) || !authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return new Result(false, "missing bearer token");

        var token = authorizationHeader["Bearer ".Length..].Trim();
        var authority = $"https://login.microsoftonline.com/{tenantId}/v2.0";
        _configManager ??= new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{authority}/.well-known/openid-configuration", new OpenIdConnectConfigurationRetriever());

        try
        {
            var config = await _configManager.GetConfigurationAsync();
            // EPP_EXPECTED_ISSUER pins one issuer; otherwise accept both the v2 and v1 forms.
            var pinnedIssuer = _env.Get("EPP_EXPECTED_ISSUER");
            var validIssuers = string.IsNullOrEmpty(pinnedIssuer)
                ? new[] { $"https://login.microsoftonline.com/{tenantId}/v2.0", $"https://sts.windows.net/{tenantId}/" }
                : new[] { pinnedIssuer };
            var parameters = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidIssuers = validIssuers,
                ValidateAudience = true,
                ValidAudience = audience,
                ValidateLifetime = true,
                IssuerSigningKeys = config.SigningKeys,
                ValidateIssuerSigningKey = true,
            };
            var principal = _handler.ValidateToken(token, parameters, out _);

            var callerAppId = principal.FindFirst("azp")?.Value ?? principal.FindFirst("appid")?.Value;
            if (!IsExpectedCaller(callerAppId, _env.Get("EPP_EXPECTED_CLIENT_ID")))
                return new Result(false, "unexpected caller");

            var oid = principal.FindFirst("oid")?.Value ?? principal.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value;
            return new Result(true, CallerObjectId: oid);
        }
        catch
        {
            return new Result(false, "token validation failed");
        }
    }
}
