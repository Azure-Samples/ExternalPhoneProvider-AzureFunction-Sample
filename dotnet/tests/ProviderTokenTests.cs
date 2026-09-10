using Azure.Core;
using Azure.Identity;
using Xunit;

namespace Epp.Otp.Tests;

public class ProviderTokenTests
{
    private static ProviderTokenConfig Config() => new("soprano", "https://provider.example/cgpapi",
        "tenant.example", "client-id", "api://provider/.default", null, "oauth-client-secret",
        "https://vault.example", "vault-identity", 1500);

    [Fact]
    public async Task ClientSecretUsesOneSdkCredentialAndRebuildsOnConfigurationOrSecretRotation()
    {
        var secrets = new TokenSecrets();
        var factory = new TestProviderCredentialFactory();
        var acquirer = new ProviderTokenAcquirer(secrets, factory);
        var config = Config();
        Assert.Equal(nameof(ProviderTokenConfig), config.ToString());
        for (var i = 0; i < 2; i++) Assert.Equal("provider-token", await acquirer.AcquireAsync(config));
        Assert.Equal(2, Assert.Single(factory.Credentials).Requests.Count); // SDK, not a custom token cache.
        Assert.Equal("resolved-secret", Assert.Single(factory.ClientSecrets));
        Assert.All(secrets.Names, name => Assert.Equal(config.ClientSecretName, name));
        Assert.Empty(factory.ManagedIdentityIds);
        AssertOptions(Assert.Single(factory.Options), config.TimeoutMs);
        Assert.All(factory.Credentials[0].Requests, request => Assert.Equal(config.Scope, Assert.Single(request.Context.Scopes)));
        var changes = new[]
        {
            config with { Endpoint = "https://other-provider.example" },
            config with { ProviderId = "other-adapter" },
            config with { TenantId = "other-tenant.example" },
            config with { ClientId = "other-client" },
            config with { Scope = "api://other-provider/.default" },
            config with { ClientSecretName = "other-secret-name" },
            config with { KeyVaultUrl = "https://other-vault.example" },
            config with { VaultManagedIdentityClientId = "other-vault-identity" },
            config with { TimeoutMs = 2500 },
            config,
        };
        foreach (var changed in changes)
        {
            var previous = factory.Credentials.Count;
            await acquirer.AcquireAsync(changed);
            Assert.Equal(previous + 1, factory.Credentials.Count);
            AssertOptions(factory.Options.Last(), changed.TimeoutMs);
        }
        secrets.Value = "rotated-secret";
        await acquirer.AcquireAsync(config);
        Assert.Equal(changes.Length + 2, factory.Credentials.Count);
        Assert.Equal(secrets.Value, factory.ClientSecrets.Last());
    }

    [Fact]
    public async Task FederationExchangesManagedIdentityAssertionForTheConfiguredProviderScope()
    {
        var secrets = new TokenSecrets();
        var factory = new TestProviderCredentialFactory();
        var acquirer = new ProviderTokenAcquirer(secrets, factory);
        var config = Config() with { ClientSecretName = null, ManagedIdentityClientId = "federated-identity" };
        for (var i = 0; i < 2; i++) Assert.Equal("provider-token", await acquirer.AcquireAsync(config));
        Assert.Empty(secrets.Names);
        Assert.Empty(factory.ClientSecrets);
        Assert.Equal(config.ManagedIdentityClientId, Assert.Single(factory.ManagedIdentityIds));
        var provider = Assert.Single(factory.Credentials);
        Assert.Equal(2, provider.Requests.Count);
        Assert.Equal(2, factory.Identity.Requests.Count);
        for (var i = 0; i < 2; i++)
        {
            Assert.Equal(config.Scope, Assert.Single(provider.Requests[i].Context.Scopes));
            Assert.Equal("api://AzureADTokenExchange/.default", Assert.Single(factory.Identity.Requests[i].Context.Scopes));
            Assert.True(provider.Requests[i].Cancellation.CanBeCanceled);
            Assert.Equal(provider.Requests[i].Cancellation, factory.Identity.Requests[i].Cancellation);
        }
        Assert.NotEqual(provider.Requests[0].Cancellation, provider.Requests[1].Cancellation);
        Assert.All(factory.Options, options => AssertOptions(options, config.TimeoutMs));
        await acquirer.AcquireAsync(config with { ManagedIdentityClientId = "replacement-identity" });
        Assert.Equal(2, factory.ManagedIdentityIds.Count);
        Assert.Equal("replacement-identity", factory.ManagedIdentityIds.Last());
        await acquirer.AcquireAsync(Config());
        Assert.Single(factory.ClientSecrets);
        Assert.Equal(3, factory.Credentials.Count);
    }

    [Fact]
    public async Task InvalidSettingsAndUnusableTokensFailWithoutFallback()
    {
        var secrets = new TokenSecrets();
        var factory = new TestProviderCredentialFactory();
        var acquirer = new ProviderTokenAcquirer(secrets, factory);
        var config = Config();
        (config with { Scope = "resource/.default" }).CheckConfiguration(); // No URL restriction on the resource.
        foreach (var invalid in new[]
        {
            config with { TenantId = "" },
            config with { TenantId = "COMMON" },
            config with { TenantId = "tenant/other" },
            config with { ClientId = " client" },
            config with { Scope = "/.default" },
            config with { Scope = "api://provider/user.read" },
            config with { Scope = "api://one/.default api://two/.default" },
            config with { ClientSecretName = null },
            config with { ManagedIdentityClientId = "identity" },
            config with { ClientSecretName = "secret\r\n" },
            config with { ClientSecretName = null, ManagedIdentityClientId = "identit\u00e9" },
            config with { VaultManagedIdentityClientId = "identity\u007f" },
            config with { KeyVaultUrl = null },
            config with { KeyVaultUrl = "http://vault.example" },
            config with { Endpoint = "http://provider.example" },
            config with { TimeoutMs = 0 },
        })
            await Assert.ThrowsAsync<InvalidOperationException>(() => acquirer.AcquireAsync(invalid));
        var env = new TestEnv
        {
            ["EPP_PROVIDER_TENANT_ID"] = config.TenantId,
            ["EPP_PROVIDER_CLIENT_ID"] = config.ClientId,
            ["EPP_PROVIDER_SCOPE"] = config.Scope,
            ["EPP_PROVIDER_CLIENT_SECRET_NAME"] = config.ClientSecretName,
            ["KEY_VAULT_URL"] = config.KeyVaultUrl,
            ["AZURE_CLIENT_ID"] = config.VaultManagedIdentityClientId,
        };
        Assert.Equal(config, ProviderTokenConfig.Read(env, "soprano", config.Endpoint, 1500));
        foreach (var name in new[] { "EPP_PROVIDER_CLIENT_SECRET", "EPP_PROVIDER_TOKEN_EXCHANGE_AUDIENCE" })
        {
            env[name] = ""; // Presence is forbidden even when empty.
            var error = Assert.Throws<InvalidOperationException>(() => ProviderTokenConfig.Read(env, "soprano", config.Endpoint, 1500));
            Assert.Equal(name == "EPP_PROVIDER_CLIENT_SECRET" ? "plaintext provider client secret is not supported"
                : "provider token exchange audience override is not supported", error.Message);
            env.Remove(name);
        }
        Assert.Empty(secrets.Names);
        Assert.Empty(factory.Credentials);
        secrets.Value = " ";
        await Assert.ThrowsAsync<InvalidOperationException>(() => acquirer.AcquireAsync(config));
        Assert.Empty(factory.Credentials);
        secrets.Value = "resolved-secret";
        foreach (var invalid in new[]
        {
            new AccessToken("", DateTimeOffset.UtcNow.AddMinutes(10)),
            new AccessToken("unsafe\r\nheader", DateTimeOffset.UtcNow.AddMinutes(10)),
            new AccessToken("t\u00f6ken", DateTimeOffset.UtcNow.AddMinutes(10)),
            new AccessToken("expired", DateTimeOffset.UtcNow.AddSeconds(-1)),
            new AccessToken("nearly-expired", DateTimeOffset.UtcNow.AddSeconds(60)),
        })
        {
            factory.Respond = (_, _) => Task.FromResult(invalid);
            var error = await Assert.ThrowsAsync<InvalidOperationException>(() => acquirer.AcquireAsync(config));
            Assert.Equal("provider token unavailable", error.Message);
        }
        Assert.Equal(5, Assert.Single(factory.Credentials).Requests.Count);
        Assert.Empty(factory.ManagedIdentityIds);
    }

    [Fact]
    public async Task TimeoutBoundsUncancellableSecretResolutionAndBothSdkFlows()
    {
        Assert.Equal(1500, DispatchEngine.NormalizeProviderTimeoutMs(null));
        Assert.Equal(1500, DispatchEngine.NormalizeProviderTimeoutMs("invalid"));
        Assert.Equal(2500, DispatchEngine.NormalizeProviderTimeoutMs("9999999999999"));
        var stalledSecret = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var secrets = new TokenSecrets { Pending = stalledSecret.Task };
        var factory = new TestProviderCredentialFactory();
        var acquirer = new ProviderTokenAcquirer(secrets, factory);
        var config = Config() with { TimeoutMs = 50 };
        try
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => acquirer.AcquireAsync(config).WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.Empty(factory.Credentials);
        }
        finally { stalledSecret.TrySetResult("resolved-secret"); }

        secrets.Pending = null;
        var stalledToken = new TaskCompletionSource<AccessToken>(TaskCreationOptions.RunContinuationsAsynchronously);
        factory.Respond = (_, _) => stalledToken.Task;
        try
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => acquirer.AcquireAsync(config).WaitAsync(TimeSpan.FromSeconds(5)));
            Assert.True(Assert.Single(Assert.Single(factory.Credentials).Requests).Cancellation.IsCancellationRequested);
        }
        finally { stalledToken.TrySetResult(new AccessToken("unused", DateTimeOffset.UtcNow.AddMinutes(10))); }

        factory.Identity.Respond = async (_, cancellation) =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            throw new InvalidOperationException("unreachable");
        };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => acquirer.AcquireAsync(
            config with { ClientSecretName = null, ManagedIdentityClientId = "identity" }).WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.True(Assert.Single(factory.Identity.Requests).Cancellation.IsCancellationRequested);
        Assert.Equal(2, factory.Credentials.Count);
    }

    private static void AssertOptions(TokenCredentialOptions options, int timeoutMs)
    {
        Assert.Equal(AzureAuthorityHosts.AzurePublicCloud, options.AuthorityHost);
        Assert.False(options.Diagnostics.IsLoggingEnabled);
        Assert.False(options.Diagnostics.IsLoggingContentEnabled);
        Assert.False(options.Diagnostics.IsAccountIdentifierLoggingEnabled);
        Assert.Equal(0, options.Retry.MaxRetries);
        Assert.Equal(TimeSpan.FromMilliseconds(timeoutMs), options.Retry.NetworkTimeout);
    }

    private sealed class TokenSecrets : ISecretResolver
    {
        public List<string?> Names { get; } = new();
        public string Value { get; set; } = "resolved-secret";
        public Task<string>? Pending { get; set; }
        public Task<string> ResolveAsync(string? name) { Names.Add(name); return Pending ?? Task.FromResult(Value); }
    }
}

internal sealed class TestProviderCredentialFactory : ProviderCredentialFactory
{
    public List<TestTokenCredential> Credentials { get; } = new();
    public List<string> ClientSecrets { get; } = new();
    public List<string> ManagedIdentityIds { get; } = new();
    public List<TokenCredentialOptions> Options { get; } = new();
    public TestTokenCredential Identity { get; } = new((_, _) =>
        Task.FromResult(new AccessToken("identity-assertion", DateTimeOffset.UtcNow.AddMinutes(10))));
    public Func<TokenRequestContext, CancellationToken, Task<AccessToken>> Respond { get; set; } = (_, _) =>
        Task.FromResult(new AccessToken("provider-token", DateTimeOffset.UtcNow.AddMinutes(10)));

    public override TokenCredential CreateClientSecret(ProviderTokenConfig config, string secret, ClientSecretCredentialOptions options)
    {
        ClientSecrets.Add(secret);
        Options.Add(options);
        var credential = new TestTokenCredential((context, cancellation) => Respond(context, cancellation));
        Credentials.Add(credential);
        return credential;
    }

    public override TokenCredential CreateManagedIdentity(string clientId, TokenCredentialOptions options)
    {
        ManagedIdentityIds.Add(clientId); Options.Add(options);
        return Identity;
    }

    public override TokenCredential CreateClientAssertion(ProviderTokenConfig config,
        Func<CancellationToken, Task<string>> assertion, ClientAssertionCredentialOptions options)
    {
        Options.Add(options);
        var credential = new TestTokenCredential(async (context, cancellation) =>
        {
            Assert.Equal("identity-assertion", await assertion(cancellation));
            return await Respond(context, cancellation);
        });
        Credentials.Add(credential);
        return credential;
    }
}

internal sealed class TestTokenCredential(Func<TokenRequestContext, CancellationToken, Task<AccessToken>> respond) : TokenCredential
{
    public List<(TokenRequestContext Context, CancellationToken Cancellation)> Requests { get; } = new();
    public Func<TokenRequestContext, CancellationToken, Task<AccessToken>> Respond { get; set; } = respond;
    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
        throw new NotSupportedException("Use async acquisition");
    public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        Requests.Add((requestContext, cancellationToken));
        return new(Respond(requestContext, cancellationToken));
    }
}