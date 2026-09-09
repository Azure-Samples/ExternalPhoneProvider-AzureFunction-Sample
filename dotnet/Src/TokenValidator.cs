using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;

namespace Epp.Otp;

// In-process Entra validation is mandatory on Azure; bypass is local-only.
public sealed class TokenValidator
{
    private readonly JwtSecurityTokenHandler _handler = new();
    private readonly IEnv _env;
    private IConfigurationManager<OpenIdConnectConfiguration>? _configManager;

    public TokenValidator(IEnv? env = null, IConfigurationManager<OpenIdConnectConfiguration>? configurationManager = null)
    {
        _env = env ?? new ProcessEnv();
        _configManager = configurationManager;
    }

    // azp is the v2 caller claim, appid the v1 one.
    public static bool IsExpectedCaller(string? callerAppId, string? expectedClientId) =>
        string.IsNullOrEmpty(expectedClientId)
        || string.Equals(callerAppId, expectedClientId, StringComparison.OrdinalIgnoreCase);

    public sealed record Result(bool Ok, string? Reason = null, string? CallerObjectId = null);

    public async Task<Result> ValidateAsync(string? authorizationHeader, AppConfig? config = null)
    {
        config ??= AppConfig.Read(_env);
        // Azure platform metadata prevents supplied configuration from enabling the local-only auth bypass.
        var isAzureHost = !string.IsNullOrEmpty(_env.Get("WEBSITE_INSTANCE_ID"))
            || !string.IsNullOrEmpty(_env.Get("WEBSITE_SITE_NAME"))
            || !string.IsNullOrEmpty(_env.Get("WEBSITE_HOSTNAME"));
        if (!config.RequireAuth)
            return isAzureHost ? new Result(false, "auth misconfigured") : new Result(true);

        if (isAzureHost && string.IsNullOrWhiteSpace(config.ExpectedClientId))
            return new Result(false, "auth misconfigured");

        var tenantId = config.TenantId;
        if (string.IsNullOrEmpty(config.ExpectedAudience) || string.IsNullOrEmpty(tenantId))
            return new Result(false, "auth misconfigured");

        if (string.IsNullOrEmpty(authorizationHeader) || !authorizationHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return new Result(false, "missing bearer token");

        var token = authorizationHeader["Bearer ".Length..].Trim();
        var authority = $"https://login.microsoftonline.com/{tenantId}/v2.0";
        _configManager ??= new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{authority}/.well-known/openid-configuration", new OpenIdConnectConfigurationRetriever());

        try
        {
            var discovery = await _configManager.GetConfigurationAsync(CancellationToken.None);
            // EPP_EXPECTED_ISSUER pins one issuer; otherwise accept both the v2 and v1 forms.
            var pinnedIssuer = config.ExpectedIssuer;
            var validIssuers = string.IsNullOrEmpty(pinnedIssuer)
                ? new[] { $"https://login.microsoftonline.com/{tenantId}/v2.0", $"https://sts.windows.net/{tenantId}/" }
                : new[] { pinnedIssuer };
            var parameters = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidIssuers = validIssuers,
                ValidateAudience = true,
                ValidAudience = config.ExpectedAudience,
                ValidateLifetime = true,
                RequireExpirationTime = true,
                IssuerSigningKeys = discovery.SigningKeys,
                ValidateIssuerSigningKey = true,
                ValidAlgorithms = new[] { SecurityAlgorithms.RsaSha256 },
            };
            var principal = _handler.ValidateToken(token, parameters, out _);

            var callerAppId = principal.FindFirst("azp")?.Value ?? principal.FindFirst("appid")?.Value;
            if (!IsExpectedCaller(callerAppId, config.ExpectedClientId))
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
