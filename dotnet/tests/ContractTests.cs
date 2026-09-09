using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Epp.Otp.Providers;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Xunit;

namespace Epp.Otp.Tests;

public class ContractTests
{
    private static DispatchRequest Request(string channel = "sms") =>
        new("+15551234567", "  Your code is 918273.\nDo not share.  ", channel, "message-id", "correlation-id", "en-US");

    [Theory]
    [InlineData("sms")]
    [InlineData("voice")]
    public void SopranoUsesExactOmnimsgContract(string channel)
    {
        var request = new SopranoProvider().BuildRequest(channel, "https://provider.example/cgpapi///", Request(channel),
            new ProviderCredential("apiKey", "test-key", "test-id"), new TestEnv());
        Assert.Equal("https://provider.example/cgpapi/messages/omnimsg", request.Url);
        Assert.Equal("POST", request.Method);
        Assert.Equal(4, request.Headers.Count);
        Assert.Equal("test-id", request.Headers["X-MEMS-API-ID"]);
        Assert.Equal("test-key", request.Headers["X-MEMS-API-Key"]);
        Assert.Equal("application/json", request.Headers["Accept"]);
        Assert.Equal("application/json", request.Headers["Content-Type"]);
        var expected = new
        {
            text = Request().Message,
            destination = "15551234567",
            messageTypes = new[] { channel },
            correlationId = "correlation-id",
            shutterMode = false,
        };
        Assert.Equal(JsonSerializer.Serialize(expected), request.Body);
    }

    [Fact]
    public void SopranoRequiresAnExplicitAcceptedStatus()
    {
        var adapter = new SopranoProvider();
        Outcome Parse(string body)
        {
            using var json = JsonDocument.Parse(body);
            return OutcomeMapper.ResolveOutcome(adapter.Manifest, adapter.ParseResponse(200, true, json.RootElement));
        }
        Assert.Equal(Outcome.Continue, Parse("[{\"id\":12,\"state\":\"enroute\"}]"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":\"FILTERED\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":\"unknown\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":123,\"state\":\"ACCEPTED\"}"));
        Assert.Equal(Outcome.Fail, Parse("{\"status\":false,\"state\":\"ACCEPTED\"}"));
    }

    [Fact]
    public void OtherProvidersKeepTheirStaticAuthenticationAndProtocols()
    {
        var env = new TestEnv { ["EPP_PROVIDER_ACCOUNT_NAME"] = "Verify" };
        var credential = new ProviderCredential("apiKey", "test-key", "test-id");
        var sms = new InfobipProvider().BuildRequest("sms", "https://provider.example", Request(), credential, env);
        Assert.Equal("App test-key", sms.Headers["Authorization"]);
        Assert.EndsWith("/sms/3/messages", sms.Url);
        using var smsJson = JsonDocument.Parse(sms.Body);
        Assert.Equal(Request().Message, smsJson.RootElement.GetProperty("messages")[0].GetProperty("content").GetProperty("text").GetString());

        var form = new TelesignProvider().BuildRequest("sms", "https://provider.example", Request(), credential, env);
        Assert.Equal("Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes("test-id:test-key")), form.Headers["Authorization"]);
        Assert.Equal("application/x-www-form-urlencoded", form.Headers["Content-Type"]);
        Assert.EndsWith("/v1/messaging", form.Url);
        Assert.Contains("message=" + Uri.EscapeDataString(Request().Message!), form.Body);

        var call = new SinchProvider().BuildRequest("voice", "https://provider.example", Request("voice"), credential, env);
        Assert.Equal("Bearer test-key", call.Headers["Authorization"]); // Static API token, not an acquired JWT.
        Assert.Equal("https://calling.api.sinch.com/calling/v1/callouts", call.Url);
        using var callJson = JsonDocument.Parse(call.Body);
        Assert.Equal(Request().Message, callJson.RootElement.GetProperty("ttsCallout").GetProperty("text").GetString());
    }

    [Fact]
    public void OutcomesMapToPublicHttpStatuses()
    {
        Assert.Equal(403, OutcomeMapper.ToHttpStatus(Outcome.Block, 200));
        Assert.Equal(409, OutcomeMapper.ToHttpStatus(Outcome.StepUp, 200));
        Assert.Equal(429, OutcomeMapper.ToHttpStatus(Outcome.Fail, 429));
    }

    [Fact]
    public async Task InboundJwtRequiresPinnedClaimsExpirationAlgorithmAndSignature()
    {
        using var tokens = new InboundTokens();
        using var stranger = new InboundTokens();
        var localEnv = new TestEnv();
        Assert.True((await new TokenValidator(localEnv, tokens).ValidateAsync(null, AppConfig.Read(localEnv))).Ok);
        var misconfigured = new TokenValidator.Result(false, "auth misconfigured");
        foreach (var marker in new[] { "WEBSITE_INSTANCE_ID", "WEBSITE_SITE_NAME", "WEBSITE_HOSTNAME" })
        {
            var env = tokens.Environment();
            env.Remove("WEBSITE_SITE_NAME");
            env["EPP_REQUIRE_AUTH"] = "false";
            var config = AppConfig.Read(env);
            env[marker] = "azure-test";
            var hostValidator = new TokenValidator(env, tokens);
            Assert.Equal(misconfigured, await hostValidator.ValidateAsync(null, config));
            Assert.Equal(misconfigured, await hostValidator.ValidateAsync(null));
            env["EPP_REQUIRE_AUTH"] = "true";
            env["EPP_EXPECTED_CLIENT_ID"] = "";
            Assert.Equal(misconfigured, await hostValidator.ValidateAsync(null, AppConfig.Read(env)));
        }
        var validator = new TokenValidator(tokens.Environment(), tokens);
        Assert.True((await validator.ValidateAsync("Bearer " + tokens.Issue(caller: "EXPECTED-APP", claimType: "appid"))).Ok);
        Assert.False((await validator.ValidateAsync(null)).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(algorithm: SecurityAlgorithms.RsaSha384))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(expires: DateTime.UtcNow.AddMinutes(-10)))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(includeExpiration: false))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(caller: "wrong-app"))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(caller: null))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(audience: "wrong-audience"))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + tokens.Issue(issuer: "https://wrong-issuer.example"))).Ok);
        Assert.False((await validator.ValidateAsync("Bearer " + stranger.Issue())).Ok);
    }
}

// Only inbound authentication uses JWTs. Keys are generated in memory; no discovery HTTP or secrets.
internal sealed class InboundTokens : IConfigurationManager<OpenIdConnectConfiguration>, IDisposable
{
    private readonly RSA _rsa = RSA.Create(2048);
    private readonly OpenIdConnectConfiguration _configuration = new();

    public InboundTokens() => _configuration.SigningKeys.Add(new RsaSecurityKey(_rsa.ExportParameters(false)) { KeyId = "local-signing-kid" });

    public TestEnv Environment() => new()
    {
        ["WEBSITE_SITE_NAME"] = "azure-test",
        ["EPP_REQUIRE_AUTH"] = "true",
        ["EPP_TENANT_ID"] = "tenant",
        ["EPP_EXPECTED_AUDIENCE"] = "audience",
        ["EPP_EXPECTED_ISSUER"] = "https://issuer.example",
        ["EPP_EXPECTED_CLIENT_ID"] = "expected-app",
    };

    public string Issue(string algorithm = SecurityAlgorithms.RsaSha256, string? caller = "expected-app",
        string issuer = "https://issuer.example", string audience = "audience", DateTime? expires = null,
        bool includeExpiration = true, string claimType = "azp")
    {
        var key = new RsaSecurityKey(_rsa) { KeyId = "local-signing-kid" };
        var claims = caller is null ? Array.Empty<Claim>() : new[] { new Claim(claimType, caller) };
        var token = new JwtSecurityToken(issuer, audience, claims, DateTime.UtcNow.AddHours(-1),
            includeExpiration ? expires ?? DateTime.UtcNow.AddMinutes(5) : null, new SigningCredentials(key, algorithm));
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public Task<OpenIdConnectConfiguration> GetConfigurationAsync(CancellationToken cancel) => Task.FromResult(_configuration);
    public void RequestRefresh() { }
    public void Dispose() => _rsa.Dispose();
}

internal sealed class TestEnv : Dictionary<string, string?>, IEnv
{
    public string? Get(string key) => TryGetValue(key, out var value) ? value : null;
}
