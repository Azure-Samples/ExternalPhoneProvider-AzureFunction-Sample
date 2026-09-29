using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Azure.Core;
using Epp.Otp.Providers;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging;
using Xunit;

namespace Epp.Otp.Tests;

public class SendOtpTests
{
    private const string Phone = "+15551234567";
    private const string Message = "  Your code is 918273.\nDo not share.  ";
    private const string Nonce = "private-ack-nonce";
    private const string Kid = "private-jwe-kid";
    private const string Correlation = "private-correlation";
    private const string PrivateError = "private key/provider error: +15551234567 code 918273";
    private static readonly string[] LiveEvents =
    [
        "request_received", "payload_validated", "delivery_context_decrypted", "provider_selected",
        "provider_credential_resolution_started", "provider_credential_resolved",
        "provider_request_build_started", "provider_request_built", "provider_request_started",
        "provider_response_received", "provider_response_processed", "response_prepared", "request_completed",
    ];
    private static readonly string[] EvaluationEvents =
    [
        "request_received", "payload_validated", "delivery_context_decrypted",
        "evaluation_completed", "response_prepared", "request_completed",
    ];
    private static readonly string[] SummaryFields =
    [
        "logType", "eventName", "functionName", "functionRequestId", "functionInvocationId",
        "x-ms-client-request-id", "x-ms-correlation-id", "msCorrelationIdSource", "omittedIdFields",
        "channel", "evaluation", "payloadType", "ttlSeconds", "encryptionKeyIdMismatch",
        "providerName", "providerAuthMode", "providerAttempted", "providerCredentialSource",
        "providerCredentialElapsedMs", "providerTenantId", "functionOutboundClientId",
        "functionOutboundManagedIdentityClientId", "providerHttpMethod", "providerEndpoint",
        "providerHttpStatus", "providerStatus", "providerOutcome", "providerMessageId",
        "providerElapsedMs", "providerTimeoutMs", "failureStage", "failureReason", "httpStatus",
        "result", "elapsedMs", "responseContainsNonce", "responseContainsCorrelationId",
    ];

    private static void ConfigureSoprano(HandlerRig rig)
    {
        rig.Env["EPP_PROVIDER_NAME"] = "soprano";
        rig.Env["EPP_PROVIDER_AUTH_MODE"] = "oauth";
        rig.Env["EPP_PROVIDER_CHANNEL"] = "sms";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/full/send/";
        rig.Env["EPP_PROVIDER_TENANT_ID"] = "provider-tenant";
        rig.Env["EPP_PROVIDER_SCOPE"] = "api://provider/.default";
        rig.Env["EPP_OUTBOUND_CLIENT_ID"] = "calling-application";
        rig.Env["EPP_OUTBOUND_MI_CLIENT_ID"] = "outbound-identity";
        rig.Env["AZURE_CLIENT_ID"] = "different-vault-identity";
        rig.Http.Respond = _ => Task.FromResult(Json(201, "{\"status\":\"ENROUTE\"}"));
    }

    [Fact]
    public async Task StartupPreparesOnlyCredentialsAndWarmRequestsReuseTheBundle()
    {
        using var rig = new HandlerRig();
        await rig.Credentials.StartAsync(default);
        Assert.Equal(1, rig.Secrets.Calls);
        Assert.Equal(0, rig.Http.Calls);
        AssertAccepted(await rig.Invoke("evaluation"));
        Assert.Equal(1, rig.Secrets.Calls);
        Assert.Equal(0, rig.Http.Calls);
        AssertAccepted(await rig.Invoke());
        Assert.Equal(1, rig.Secrets.Calls);
        Assert.Equal(1, rig.Http.Calls);
    }

    [Fact]
    public async Task StartupWithoutProviderConfigurationKeepsEvaluationIndependent()
    {
        using var rig = new HandlerRig();
        rig.Env.Clear();
        rig.Env["EPP_DECRYPTION_KEY_PEM"] = rig.Keys.Rsa.ExportPkcs8PrivateKeyPem();
        await rig.Credentials.StartAsync(default);
        Assert.Equal(0, rig.Secrets.Calls);
        Assert.Equal(0, rig.Http.Calls);
        AssertAccepted(await rig.Invoke("evaluation"));
    }

    [Theory]
    [InlineData("api://provider/.default")]
    [InlineData("api://second/.default")]
    public async Task SopranoOAuthUsesSetupIdentitiesScopeAndOneBoundedExchange(string scope)
    {
        var scopes = new List<string>();
        var identities = new List<string>();
        var applications = new List<(string Tenant, string Application)>();
        using var rig = new HandlerRig(identity =>
        {
            identities.Add(identity);
            return new TestTokenCredential((context, cancellation) =>
            {
                Assert.Equal("api://AzureADTokenExchange/.default", Assert.Single(context.Scopes));
                Assert.True(cancellation.CanBeCanceled);
                return ValueTask.FromResult(new AccessToken("private-assertion", DateTimeOffset.UtcNow.AddHours(1)));
            });
        }, (tenant, application, assertion) =>
        {
            applications.Add((tenant, application));
            return new TestTokenCredential(async (context, cancellation) =>
            {
                Assert.True(cancellation.CanBeCanceled);
                scopes.Add(Assert.Single(context.Scopes));
                Assert.Equal("private-assertion", await assertion(cancellation));
                return new AccessToken("private-provider-token", DateTimeOffset.UtcNow.AddHours(1));
            });
        });
        ConfigureSoprano(rig);
        rig.Env["EPP_PROVIDER_SCOPE"] = scope;
        AssertAccepted(await rig.Invoke("evaluation"));
        Assert.Empty(applications);
        foreach (var channel in new[] { "sms", "voice" })
        {
            rig.Env["EPP_PROVIDER_CHANNEL"] = channel;
            AssertAccepted(await rig.Invoke(channel: channel, deliveryOverrides: JsonSerializer.SerializeToElement(new
            {
                providerJwt = "FORGED-PAYLOAD", locale = "fr-FR",
                textToVoice = new { beforePasswordText = "ignored", password = "001234", language = "override" },
            })));
            Assert.Equal("Bearer private-provider-token", rig.Http.Headers["Authorization"]);
            Assert.DoesNotContain("X-MEMS-API-ID", rig.Http.Headers.Keys);
            Assert.DoesNotContain("X-MEMS-API-Key", rig.Http.Headers.Keys);
            Assert.DoesNotContain("FORGED", rig.Http.Body!);
            if (channel == "voice")
            {
                using var body = JsonDocument.Parse(rig.Http.Body!);
                var speech = body.RootElement.GetProperty("voice").GetProperty("text2voice");
                Assert.Equal("  Your code is ", speech.GetProperty("beforePasswordText").GetString());
                Assert.Equal("918273", speech.GetProperty("password").GetString());
                Assert.Equal(".\nDo not share.  ", speech.GetProperty("afterPasswordText").GetString());
                Assert.Equal("fr-FR", speech.GetProperty("language").GetString());
                Assert.Equal(1, speech.GetProperty("gender").GetInt32());
                Assert.Equal(2, speech.GetProperty("loop").GetInt32());
            }
        }
        rig.Env["EPP_PROVIDER_CHANNEL"] = "sms";
        AssertAccepted(await rig.Invoke());
        Assert.Single(applications);
        Assert.Equal(new[] { scope }, scopes);
        Assert.Equal(new[] { ("provider-tenant", "calling-application") }, applications);
        Assert.All(identities, identity => Assert.Equal("outbound-identity", identity));
        Assert.Equal(3, rig.Http.Calls);
        Assert.Equal(0, rig.Secrets.Calls);
        Assert.DoesNotContain("private-provider-token", string.Join("\n", rig.Log.Messages));
        var credential = new ProviderCredentials("oauth", AccessToken: "private-provider-token");
        Assert.DoesNotContain("private-provider-token", JsonSerializer.Serialize(credential) + credential);
    }

    [Theory]
    [InlineData(true, "", 3600)]
    [InlineData(true, "private-assertion", 5)]
    [InlineData(false, " ", 3600)]
    [InlineData(false, "private-token", -1)]
    public async Task SopranoOAuthRejectsUnusableTokensBeforeProviderIo(bool invalidAssertion, string token, int lifetime)
    {
        var invalid = new AccessToken(token, DateTimeOffset.UtcNow.AddSeconds(lifetime));
        using var rig = new HandlerRig(_ => new TestTokenCredential((_, _) => ValueTask.FromResult(invalidAssertion
            ? invalid : new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1)))),
            (_, _, assertion) => new TestTokenCredential(async (_, cancellation) =>
            {
                await assertion(cancellation);
                return invalid;
            }));
        ConfigureSoprano(rig);
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal((0, 0), (rig.Http.Calls, rig.Secrets.Calls));
    }

    [Fact]
    public async Task SopranoOAuthCancellationAndRejectionNeverFallBackOrRetry()
    {
        CancellationToken observed = default;
        var waitForCancellation = true;
        TokenCredential CreateIdentity(string _) => new TestTokenCredential(async (_, cancellation) =>
        {
            if (waitForCancellation)
            {
                observed = cancellation;
                await Task.Delay(Timeout.Infinite, cancellation);
            }
            return new AccessToken("assertion", DateTimeOffset.UtcNow.AddHours(1));
        });
        TokenCredential CreateProvider(string tenant, string application, Func<CancellationToken, Task<string>> assertion) =>
            new TestTokenCredential(async (_, cancellation) =>
        {
            await assertion(cancellation);
            return new AccessToken("token", DateTimeOffset.UtcNow.AddHours(1));
        });
        using var rig = new HandlerRig(CreateIdentity, CreateProvider);
        ConfigureSoprano(rig);
        AssertFailure(rig, await rig.Invoke().WaitAsync(TimeSpan.FromSeconds(10)), 502);
        Assert.True(observed.IsCancellationRequested);
        Assert.Equal((0, 0), (rig.Http.Calls, rig.Secrets.Calls));
        waitForCancellation = false;
        rig.Credentials.Dispose();
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal((0, 0), (rig.Http.Calls, rig.Secrets.Calls));
        using var replacement = new HandlerRig(CreateIdentity, CreateProvider);
        ConfigureSoprano(replacement);
        replacement.Http.Respond = _ => Task.FromResult(Json(401, "{\"status\":\"REJECTED\"}"));
        AssertFailure(replacement, await replacement.Invoke(), 401);
        Assert.Equal((1, 0), (replacement.Http.Calls, replacement.Secrets.Calls));
    }

    private sealed class TestTokenCredential(Func<TokenRequestContext, CancellationToken, ValueTask<AccessToken>> acquire) : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext context, CancellationToken cancellation) =>
            throw new InvalidOperationException("Synchronous acquisition not expected");
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext context, CancellationToken cancellation) => acquire(context, cancellation);
    }

    [Fact]
    public async Task HandlerUsesInjectedConfigAwaitsAcceptanceAndKeepsLogsPrivate()
    {
        using var rig = new HandlerRig();
        Assert.Equal("infobip", AppConfig.Read(rig.Env).ProviderName);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        rig.Http.Respond = cancellation =>
        {
            entered.TrySetResult();
            return release.Task.WaitAsync(cancellation);
        };
        var pending = rig.Invoke(channel: "sms");
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(pending.IsCompleted);
            Assert.DoesNotContain(rig.Log.Records, record => record.GetProperty("logType").GetString() == "request");
            Assert.Equal("provider_request_started", rig.Log.Records.Last().GetProperty("eventName").GetString());
        }
        finally
        {
            release.TrySetResult(Json(200, "{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":\"PENDING\"}}]}"));
        }
        AssertAccepted(await pending);
        using var body = JsonDocument.Parse(rig.Http.Body!);
        Assert.Equal(Message, body.RootElement.GetProperty("messages")[0].GetProperty("content").GetProperty("text").GetString());
        Assert.Equal(1, rig.Http.Calls);
        var summary = Summary(rig);
        Assert.Equal(LiveEvents, rig.Log.Records.Select(record => record.GetProperty("eventName").GetString()));
        Assert.Equal("infobip", summary.GetProperty("providerName").GetString());
        Assert.Equal("apiKey", summary.GetProperty("providerAuthMode").GetString());
        Assert.Equal(200, summary.GetProperty("providerHttpStatus").GetInt32());
        Assert.Equal("PENDING", summary.GetProperty("providerStatus").GetString());
        Assert.Equal("Continue", summary.GetProperty("providerOutcome").GetString());
        Assert.True(summary.GetProperty("providerAttempted").GetBoolean());
        Assert.Equal("id", summary.GetProperty("providerMessageId").GetString());
        Assert.Equal(2500, summary.GetProperty("providerTimeoutMs").GetInt32());
        Assert.InRange(summary.GetProperty("providerElapsedMs").GetInt64(), 0, summary.GetProperty("elapsedMs").GetInt64());
        var log = string.Join("\n", rig.Log.Messages);
        Assert.Equal(Correlation, summary.GetProperty("x-ms-correlation-id").GetString());
        foreach (var value in new[] { Phone, "918273", "001234", Nonce, "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, log);
    }

    [Fact]
    public async Task FailedHttpCannotAcknowledgeAnAcceptedBodyOrLeakProviderText()
    {
        using var rig = new HandlerRig();
        rig.Http.Respond = _ => Task.FromResult(Json(503,
            JsonSerializer.Serialize(new { status = "ACCEPTED", description = PrivateError })));
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal(1, rig.Http.Calls);
    }

    [Theory]
    [InlineData(Outcome.Continue, 503, 200)]
    [InlineData(Outcome.Block, 200, 403)]
    [InlineData(Outcome.Fail, 429, 429)]
    [InlineData(Outcome.Fail, 401, 401)]
    [InlineData(Outcome.Fail, 403, 401)]
    [InlineData(Outcome.Fail, 400, 400)]
    [InlineData(Outcome.Fail, 499, 400)]
    [InlineData(Outcome.Fail, 200, 502)]
    [InlineData(Outcome.Fail, 503, 502)]
    public void FinalProviderOutcomeMapsToEndpointStatus(
        Outcome outcome, int providerHttpStatus, int expected)
    {
        var result = new ProviderResult(outcome, true, providerHttpStatus);
        Assert.Equal(expected, PhoneProviderBase.ToEndpointHttpStatus(result));
    }

    [Fact]
    public async Task ResponseBodyTimeoutCancelsWithoutRetryOrSuccessNonce()
    {
        using var rig = new HandlerRig();
        using var body = new SlowBody();
        rig.Env["EPP_PROVIDER_TIMEOUT_MS"] = "200";
        rig.Http.Respond = _ => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(body) });
        AssertFailure(rig, await rig.Invoke().WaitAsync(TimeSpan.FromSeconds(5)), 504);
        Assert.True(body.SawCancellationToken);
        Assert.Equal(1, rig.Http.Calls);
        var summary = Summary(rig);
        Assert.Equal("provider_transport", summary.GetProperty("failureStage").GetString());
        Assert.Equal("provider_timeout", summary.GetProperty("failureReason").GetString());
        Assert.Equal(200, summary.GetProperty("providerHttpStatus").GetInt32());
        Assert.Equal(200, summary.GetProperty("providerTimeoutMs").GetInt32());
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerStatus").ValueKind);
        Assert.InRange(summary.GetProperty("providerElapsedMs").GetInt64(), 0, summary.GetProperty("elapsedMs").GetInt64());
    }

    [Fact]
    public async Task MissingIdentityOrKeyFailsClosedBeforeHttp()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "telesign";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://verify.telesign.com/epp/sms";
        rig.Env["EPP_PROVIDER_AUTH_MODE"] = "apiKey";
        rig.Secrets.Identity = "";
        AssertFailure(rig, await rig.Invoke(), 502);
        rig.Secrets.Identity = "private-api-id";
        rig.Secrets.Secret = "";
        AssertFailure(rig, await rig.Invoke(), 502);
        Assert.Equal(0, rig.Http.Calls);
    }

    [Fact]
    public async Task BaseAndFinalVoiceUrlsMustBeHttpsBeforeHttp()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "sinch";
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "http://provider.example";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example:0";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example";
        rig.Env["SINCH_VOICE_ENDPOINT"] = "http://voice.example";
        AssertFailure(rig, await rig.Invoke(channel: "voice"), 502);
        Assert.Equal(0, rig.Http.Calls);
    }

    [Fact]
    public async Task EvaluationValidatesRealJweWithoutProviderConfiguration()
    {
        using var rig = new HandlerRig();
        rig.Env.Clear();
        rig.Env["EPP_DECRYPTION_KEY_PEM"] = rig.Keys.Rsa.ExportPkcs8PrivateKeyPem();
        rig.Env["EPP_ENCRYPTION_KEY_ID"] = "configured-key-id";
        AssertAccepted(await rig.Invoke("evaluation", tenantId: "untrusted-body-tenant"));
        Assert.Equal("encryption_key_id_mismatch",
            JsonSerializer.Deserialize<JsonElement>(Assert.Single(rig.Log.Entries, entry => entry.Level == LogLevel.Warning).Message)
                .GetProperty("eventName").GetString());
        var summary = Summary(rig);
        Assert.True(summary.GetProperty("encryptionKeyIdMismatch").GetBoolean());
        Assert.True(summary.GetProperty("evaluation").GetBoolean());
        Assert.Equal("evaluated", summary.GetProperty("result").GetString());
        Assert.False(summary.GetProperty("providerAttempted").GetBoolean());
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerName").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerHttpStatus").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerElapsedMs").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerCredentialSource").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerCredentialElapsedMs").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerEndpoint").ValueKind);
        Assert.Equal(EvaluationEvents,
            rig.Log.Records.Select(record => record.GetProperty("eventName").GetString()).Where(name => name != "encryption_key_id_mismatch"));
        foreach (var value in new[] { Kid, "configured-key-id", Phone, "918273", Nonce, "untrusted-body-tenant" })
            Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task PrivateKeyErrorsStayGenericAndNeverReachTheProvider()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_DECRYPTION_KEY_PEM"] = PrivateError;
        AssertFailure(rig, await rig.Invoke(), 400, "decryption_failed");
        Assert.Equal(0, rig.Http.Calls);
    }

    [Theory]
    [InlineData("{", "decryption_failed", null)]
    [InlineData("null", "decryption_failed", null)]
    [InlineData("[]", "decryption_failed", null)]
    [InlineData("{\"nonce\":123,\"phoneNumber\":\"phone\",\"message\":\"message\"}", "decryption_failed", null)]
    [InlineData("{\"nonce\":\"nonce\",\"phoneNumber\":false,\"message\":\"message\"}", "decryption_failed", null)]
    [InlineData("{\"nonce\":\"nonce\",\"phoneNumber\":\"phone\",\"message\":{}}", "decryption_failed", null)]
    [InlineData("{\"nonce\":\"nonce\"}", "bad_request", "incomplete delivery context")]
    public async Task AuthenticatedPlaintextUsesTypedDeliveryContextValidation(
        string plaintext, string error, string? reason)
    {
        using var rig = new HandlerRig();
        var result = await rig.Invoke(plaintext: plaintext);
        AssertFailure(rig, result, 400, error);
        var body = JsonSerializer.SerializeToElement(result.Value);
        if (reason is null) Assert.False(body.TryGetProperty("reason", out _));
        else Assert.Equal(reason, body.GetProperty("reason").GetString());
        Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task SharedInvalidRequestsReturnSafeReasonsBeforeProviderIo()
    {
        using var rig = new HandlerRig();
        using var fixtures = ReadContractFixtures();
        var semanticCases = 0;
        foreach (var fixture in fixtures.RootElement.GetProperty("badRequests").EnumerateArray())
        {
            var bodyValues = new Dictionary<string, object?>
            {
                ["type"] = EntraSendOtpPayload.SupportedType, ["channel"] = 1, ["mode"] = 1,
                ["encryptedDeliveryContext"] = "unused", ["ttlSeconds"] = 60,
            };
            if (fixture.TryGetProperty("overrides", out var overrides))
                foreach (var property in overrides.EnumerateObject()) bodyValues[property.Name] = property.Value;
            var raw = fixture.TryGetProperty("rawBody", out var rawBody)
                ? rawBody.GetString()!
                : JsonSerializer.Serialize(bodyValues);
            EntraSendOtpPayload? payload;
            try { payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(raw); }
            catch (JsonException) { continue; }
            if (payload is null) continue;
            var validationError = payload.Validate();
            if (validationError is null) continue;
            semanticCases++;
            var expectedReason = fixture.GetProperty("name").GetString() == "wrong version"
                ? "unsupported payload type"
                : fixture.GetProperty("reason").GetString();
            Assert.Equal(expectedReason, validationError);
            var result = await rig.InvokePayload(payload);
            AssertFailure(rig, result, 400, "bad_request");
            var body = JsonSerializer.SerializeToElement(result.Value);
            Assert.False(string.IsNullOrEmpty(body.GetProperty("requestId").GetString()));
            Assert.Equal(3, body.EnumerateObject().Count());
            Assert.Equal(validationError, body.GetProperty("reason").GetString());
        }
        Assert.True(semanticCases > 0);
        foreach (var changes in fixtures.RootElement.GetProperty("incompleteContexts").EnumerateArray())
        {
            var result = await rig.Invoke("evaluation", deliveryOverrides: changes);
            var wrongType = changes.TryGetProperty("nonce", out var nonce)
                && nonce.ValueKind == JsonValueKind.Number;
            AssertFailure(rig, result, 400, wrongType ? "decryption_failed" : "bad_request");
            var body = JsonSerializer.SerializeToElement(result.Value);
            Assert.Equal(wrongType ? 3 : 4, body.EnumerateObject().Count());
            if (!wrongType)
                Assert.Equal("incomplete delivery context", body.GetProperty("reason").GetString());
            Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
        }
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task SharedJwePolicyPermitsOnlyRsaOaep256WithA256Gcm()
    {
        using var rig = new HandlerRig();
        using var fixtures = ReadContractFixtures();
        foreach (var fixture in fixtures.RootElement.GetProperty("jwe").EnumerateArray())
        {
            var alg = Enum.Parse<Jose.JweAlgorithm>(fixture.GetProperty("alg").GetString()!.Replace('-', '_'));
            var enc = Enum.Parse<Jose.JweEncryption>(fixture.GetProperty("enc").GetString()!.Replace('-', '_'));
            var accepted = fixture.GetProperty("accepted").GetBoolean();
            var result = await rig.Invoke("evaluation", algorithm: alg, encryption: enc);
            if (accepted) AssertAccepted(result);
            else
            {
                AssertFailure(rig, result, 400, "decryption_failed");
                var body = JsonSerializer.SerializeToElement(result.Value);
                Assert.Equal(3, body.EnumerateObject().Count());
                Assert.Equal(Correlation, body.GetProperty("correlationId").GetString());
            }
        }
        Assert.Equal((0, 0), (rig.Secrets.Calls, rig.Http.Calls));
    }

    [Fact]
    public async Task MicrosoftIdentifiersHaveExplicitSourcesWithoutSyntheticMicrosoftIds()
    {
        var headers = new Dictionary<string, string>
        {
            ["x-ms-client-request-id"] = "ms-request-id",
            ["x-ms-correlation-id"] = "ms-header-correlation-id",
        };
        foreach (var correlation in new[] { "ms-payload-correlation-id", null })
        {
            using var rig = new HandlerRig();
            var result = await rig.Invoke(correlationId: correlation, headers: headers);
            Assert.Equal(200, result.StatusCode);
            var summary = Summary(rig);
            Assert.Equal(headers["x-ms-client-request-id"], summary.GetProperty("x-ms-client-request-id").GetString());
            Assert.Equal(correlation ?? headers["x-ms-correlation-id"], summary.GetProperty("x-ms-correlation-id").GetString());
            Assert.Equal(correlation is null ? "header" : "payload", summary.GetProperty("msCorrelationIdSource").GetString());
            Assert.Equal("header", rig.Log.Records.First().GetProperty("msCorrelationIdSource").GetString());
            Assert.Equal(JsonValueKind.Null, summary.GetProperty("functionInvocationId").ValueKind);
            Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
        }
        using var missing = new HandlerRig();
        var response = await missing.Invoke(correlationId: null);
        var missingSummary = Summary(missing);
        Assert.Equal(missingSummary.GetProperty("functionRequestId").GetString(),
            Assert.IsType<EndpointSuccessResponse>(response.Value).CorrelationId);
        Assert.Equal(JsonValueKind.Null, missingSummary.GetProperty("x-ms-client-request-id").ValueKind);
        Assert.Equal(JsonValueKind.Null, missingSummary.GetProperty("x-ms-correlation-id").ValueKind);
        Assert.Equal("none", missingSummary.GetProperty("msCorrelationIdSource").GetString());
    }

    [Fact]
    public void FunctionInvocationIdIsSeparateFromMicrosoftAndProviderIdentifiersInLogState()
    {
        var logger = new CapturingLogger();
        var log = new RequestLog(logger, "function-request", "function-invocation", "ms-request-id", "ms-header-correlation-id");
        var provider = new TelesignProvider();
        log.ProviderSelected(provider.Name, provider.AuthenticationMode);
        log.ProviderRequestStarted(1500);
        log.ProviderResponseReceived(200);
        log.ProviderRequestFinished();
        log.ProviderResponseProcessed(new ProviderResult(Outcome.Continue, true, 200, "provider-reference-id",
            ProviderStatusCode: "3001", ProviderStatusDescription: PrivateError), 200, true);
        log.Complete(200);
        var summary = logger.States.Last();
        Assert.Equal("function-request", summary["functionRequestId"]);
        Assert.Equal("function-invocation", summary["functionInvocationId"]);
        Assert.Equal("ms-request-id", summary["x-ms-client-request-id"]);
        Assert.Equal("ms-header-correlation-id", summary["x-ms-correlation-id"]);
        Assert.Equal("provider-reference-id", summary["providerMessageId"]);
        Assert.Equal("3001", summary["providerStatus"]);
        Assert.DoesNotContain("PRIVATE", string.Join("\n", logger.Messages));
        Assert.DoesNotContain(PrivateError, string.Join("\n", logger.Messages));
    }

    [Theory]
    [InlineData("invalid_payload", 400, "request_validation", "unsupported payload type", false)]
    [InlineData("decryption", 400, "decryption", "decryption_failed", false)]
    [InlineData("incomplete_context", 400, "delivery_context_validation", "incomplete delivery context", false)]
    [InlineData("unknown_provider", 400, "provider_selection", "unknown_provider", false)]
    [InlineData("wrong_channel", 400, "provider_configuration", "channel_not_configured", false)]
    [InlineData("authentication_mismatch", 502, "provider_configuration", "authentication_mode_mismatch", false)]
    [InlineData("invalid_endpoint", 502, "provider_configuration", "invalid_provider_endpoint", false)]
    [InlineData("credentials", 502, "provider_credentials", "credential_unavailable", false)]
    [InlineData("request_build", 502, "provider_request_build", "request_build_failed", false)]
    [InlineData("network", 502, "provider_transport", "provider_network_error", true)]
    [InlineData("response_parse", 502, "provider_response", "response_parse_failed", true)]
    [InlineData("http_rejection", 429, "provider_response", "provider_rejected", true)]
    public async Task FailuresEmitSeparateServiceEventsAndCompleteSummaries(string scenario, int status, string stage, string reason, bool attempted)
    {
        using var rig = new HandlerRig();
        JsonElement? delivery = null;
        switch (scenario)
        {
            case "decryption": rig.Env["EPP_DECRYPTION_KEY_PEM"] = PrivateError; break;
            case "incomplete_context": delivery = JsonSerializer.SerializeToElement(new { nonce = "" }); break;
            case "unknown_provider": rig.Env["EPP_PROVIDER_NAME"] = "PRIVATE-UNKNOWN-PROVIDER"; break;
            case "wrong_channel": rig.Env["EPP_PROVIDER_CHANNEL"] = "voice"; break;
            case "authentication_mismatch": rig.Env["EPP_PROVIDER_AUTH_MODE"] = "oauth"; break;
            case "invalid_endpoint": rig.Env["EPP_PROVIDER_ENDPOINT"] = "http://PRIVATE-ENDPOINT"; break;
            case "credentials": rig.Secrets.Error = new InvalidOperationException(PrivateError); break;
            case "request_build":
                rig.Env["EPP_PROVIDER_NAME"] = "telesign";
                delivery = JsonSerializer.SerializeToElement(new { phoneNumber = "PRIVATE-INVALID-PHONE" });
                break;
            case "network":
                rig.Http.Respond = _ => Task.FromException<HttpResponseMessage>(new HttpRequestException(PrivateError));
                break;
            case "response_parse":
                rig.Http.Respond = _ => Task.FromResult(Json(
                    200,
                    "{\"messages\":[{\"messageId\":123,\"status\":{\"groupName\":\"PENDING\"}}]}"));
                break;
            case "http_rejection":
                rig.Http.Respond = _ => Task.FromResult(Json(429, "{\"messages\":[{\"status\":{\"groupName\":\"PENDING\"}}]}"));
                break;
        }
        var headers = new Dictionary<string, string>
        {
            ["x-ms-client-request-id"] = "ms-request-id",
            ["x-ms-correlation-id"] = "ms-header-correlation-id",
        };
        var result = scenario switch
        {
            "invalid_payload" => await rig.Invoke(type: "wrong", headers: headers),
            _ => await rig.Invoke(deliveryOverrides: delivery, headers: headers),
        };
        Assert.Equal(status, result.StatusCode);
        var summary = Summary(rig);
        Assert.Equal(Assert.IsType<EndpointErrorResponse>(result.Value).RequestId, summary.GetProperty("functionRequestId").GetString());
        Assert.Equal(status, summary.GetProperty("httpStatus").GetInt32());
        Assert.Equal(stage, summary.GetProperty("failureStage").GetString());
        Assert.Equal(reason, summary.GetProperty("failureReason").GetString());
        Assert.Equal("failed", summary.GetProperty("result").GetString());
        Assert.Equal(headers["x-ms-client-request-id"], summary.GetProperty("x-ms-client-request-id").GetString());
        Assert.Equal(stage == "request_validation" ? "header" : "payload", summary.GetProperty("msCorrelationIdSource").GetString());
        Assert.Equal(stage == "request_validation" ? headers["x-ms-correlation-id"] : Correlation,
            summary.GetProperty("x-ms-correlation-id").GetString());
        Assert.Equal(attempted, summary.GetProperty("providerAttempted").GetBoolean());
        Assert.Equal(attempted ? 1 : 0, rig.Http.Calls);
        Assert.Equal(scenario == "http_rejection" ? "provider_response_processed" : stage + "_failed",
            rig.Log.Records.ElementAt(rig.Log.Entries.Count - 3).GetProperty("eventName").GetString());
        Assert.False(summary.GetProperty("responseContainsNonce").GetBoolean());
        Assert.Equal(stage != "request_validation", summary.GetProperty("responseContainsCorrelationId").GetBoolean());
        if (scenario == "credentials")
        {
            Assert.Equal("key_vault", summary.GetProperty("providerCredentialSource").GetString());
            Assert.InRange(summary.GetProperty("providerCredentialElapsedMs").GetInt64(), 0, summary.GetProperty("elapsedMs").GetInt64());
            Assert.DoesNotContain(rig.Log.Records, record => record.GetProperty("eventName").GetString() == "provider_credential_resolved");
        }
        Assert.Contains(rig.Log.Entries, entry => entry.Level == (status >= 500 ? LogLevel.Error : LogLevel.Warning));
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public async Task SuccessfulLifecycleLogsAllowedBodyMetadataRawOAuthIdsAndEndpointWithoutQuery()
    {
        using var rig = new HandlerRig(_ => new TestTokenCredential((_, _) =>
            ValueTask.FromResult(new AccessToken("PRIVATE-ASSERTION", DateTimeOffset.UtcNow.AddHours(1)))),
            (_, _, assertion) => new TestTokenCredential(async (_, cancellation) =>
            {
                Assert.Equal("PRIVATE-ASSERTION", await assertion(cancellation));
                return new AccessToken("PRIVATE-TOKEN", DateTimeOffset.UtcNow.AddHours(1));
            }));
        ConfigureSoprano(rig);
        rig.Env["EPP_PROVIDER_ENDPOINT"] = "https://provider.example/api/send?key=PRIVATE-QUERY";
        rig.Env["EPP_PROVIDER_TENANT_ID"] = "provider-tenant-id";
        rig.Env["EPP_OUTBOUND_CLIENT_ID"] = "outbound-client-id";
        rig.Env["EPP_OUTBOUND_MI_CLIENT_ID"] = "outbound-mi-client-id";
        AssertAccepted(await rig.Invoke(tenantId: "PRIVATE-INBOUND-TENANT",
            deliveryOverrides: JsonSerializer.SerializeToElement(new { diagnosticData = "PRIVATE-UNKNOWN-FIELD" })));
        var summary = Summary(rig);
        var records = rig.Log.Records.ToArray();
        var validated = Assert.Single(records, record => record.GetProperty("eventName").GetString() == "payload_validated");
        Assert.Equal(EntraSendOtpPayload.SupportedType, validated.GetProperty("payloadType").GetString());
        Assert.Equal(EntraSendOtpPayload.SupportedType, summary.GetProperty("payloadType").GetString());
        Assert.Equal(60, validated.GetProperty("ttlSeconds").GetInt32());
        Assert.Equal(60, summary.GetProperty("ttlSeconds").GetInt32());
        Assert.True(validated.GetProperty("encryptedDeliveryContextPresent").GetBoolean());
        var credentials = records.Where(record => record.GetProperty("eventName").GetString()
            is "provider_credential_resolution_started" or "provider_credential_resolved").ToArray();
        Assert.Equal(2, credentials.Length);
        foreach (var record in credentials.Append(summary))
        {
            Assert.Equal("managed_identity_client_assertion", record.GetProperty("providerCredentialSource").GetString());
            Assert.Equal(rig.Env["EPP_PROVIDER_TENANT_ID"]!, record.GetProperty("providerTenantId").GetString());
            Assert.Equal(rig.Env["EPP_OUTBOUND_CLIENT_ID"]!, record.GetProperty("functionOutboundClientId").GetString());
            Assert.Equal(rig.Env["EPP_OUTBOUND_MI_CLIENT_ID"]!, record.GetProperty("functionOutboundManagedIdentityClientId").GetString());
        }
        Assert.InRange(summary.GetProperty("providerCredentialElapsedMs").GetInt64(), 0, summary.GetProperty("elapsedMs").GetInt64());
        var outbound = records.Where(record => record.GetProperty("eventName").GetString()
            is "provider_request_built" or "provider_request_started");
        foreach (var record in outbound.Append(summary))
        {
            Assert.Equal("POST", record.GetProperty("providerHttpMethod").GetString());
            Assert.Equal("https://provider.example/api/send", record.GetProperty("providerEndpoint").GetString());
        }
        var built = Assert.Single(records, record => record.GetProperty("eventName").GetString() == "provider_request_built");
        Assert.Equal("https", built.GetProperty("providerScheme").GetString());
        Assert.False(built.GetProperty("redirectsAllowed").GetBoolean());
        Assert.True(summary.GetProperty("responseContainsNonce").GetBoolean());
        Assert.True(summary.GetProperty("responseContainsCorrelationId").GetBoolean());
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
        Assert.Equal(LiveEvents, records.Select(record => record.GetProperty("eventName").GetString()));
    }

    [Fact]
    public async Task ApiKeyLifecycleIdentifiesKeyVaultWithoutLoggingCredentials()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "telesign";
        rig.Http.Respond = _ => Task.FromResult(Json(200, "{\"status\":{\"code\":3001}}"));
        AssertAccepted(await rig.Invoke());
        var summary = Summary(rig);
        Assert.Equal("key_vault", summary.GetProperty("providerCredentialSource").GetString());
        Assert.Equal("apiKey", summary.GetProperty("providerAuthMode").GetString());
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("providerTenantId").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("functionOutboundClientId").ValueKind);
        Assert.Equal(JsonValueKind.Null, summary.GetProperty("functionOutboundManagedIdentityClientId").ValueKind);
        Assert.InRange(summary.GetProperty("providerCredentialElapsedMs").GetInt64(), 0, summary.GetProperty("elapsedMs").GetInt64());
        Assert.Equal(2, rig.Secrets.Calls);
        Assert.Equal(LiveEvents, rig.Log.Records.Select(record => record.GetProperty("eventName").GetString()));
    }

    [Fact]
    public async Task RequestPreparationLogsTheAdapterFinalUrlNotTheConfiguredBase()
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "sinch";
        rig.Env["SINCH_VOICE_ENDPOINT"] = "https://different-provider.example/api/final";
        rig.Http.Respond = _ => Task.FromResult(Json(200, "{\"callId\":\"sinch-call-id\"}"));
        AssertAccepted(await rig.Invoke(channel: "voice"));
        var summary = Summary(rig);
        var expected = rig.Env["SINCH_VOICE_ENDPOINT"] + "/calling/v1/callouts";
        Assert.Equal(expected, summary.GetProperty("providerEndpoint").GetString());
        Assert.NotEqual(rig.Env["EPP_PROVIDER_ENDPOINT"]!, summary.GetProperty("providerEndpoint").GetString());
        Assert.Equal("POST", summary.GetProperty("providerHttpMethod").GetString());
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public void RequestPreparationDoesNotLogArbitraryHttpMethods()
    {
        var logger = new CapturingLogger();
        var log = new RequestLog(logger, "function-request", null, null, null);
        log.ProviderRequestBuilt(new HttpMethod("PRIVATE-METHOD"), new Uri("https://provider.example/api/send"));
        var record = Assert.Single(logger.Records);
        Assert.Equal("other", record.GetProperty("providerHttpMethod").GetString());
        Assert.DoesNotContain("PRIVATE", string.Join("\n", logger.Messages));
    }

    [Fact]
    public async Task BoundPayloadWithOptionalTtlAndUnknownFieldsKeepsSafeMetadata()
    {
        using var rig = new HandlerRig();
        var encrypted = Jose.JWT.Encode(JsonSerializer.Serialize(new { nonce = Nonce, phoneNumber = Phone, message = Message }),
            rig.Keys.Rsa, Jose.JweAlgorithm.RSA_OAEP_256, Jose.JweEncryption.A256GCM);
        var payload = JsonSerializer.Deserialize<EntraSendOtpPayload>(JsonSerializer.Serialize(new
        {
            type = EntraSendOtpPayload.SupportedType,
            channel = 1,
            mode = 2,
            correlationId = Correlation,
            encryptedDeliveryContext = encrypted,
            diagnosticData = new { token = "PRIVATE-UNKNOWN-FIELD" },
        }));
        Assert.NotNull(payload);
        AssertAccepted(await rig.InvokePayload(payload));
        Assert.Equal(JsonValueKind.Null, Summary(rig).GetProperty("ttlSeconds").ValueKind);
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task UnknownStatusesAndMalformedResponsesStayOutOfLogs(bool validJson)
    {
        using var rig = new HandlerRig();
        rig.Env["EPP_PROVIDER_NAME"] = "telesign";
        var body = validJson
            ? "{\"reference_id\":\"provider-reference-id\",\"status\":{\"code\":999,\"description\":\"PRIVATE-STATUS\"}}"
            : "<html>PRIVATE-RESPONSE</html>";
        rig.Http.Respond = _ => Task.FromResult(Json(200, body));
        AssertFailure(rig, await rig.Invoke(), 502);
        var summary = Summary(rig);
        Assert.Equal("unmapped", summary.GetProperty("providerStatus").GetString());
        Assert.Equal("Fail", summary.GetProperty("providerOutcome").GetString());
        Assert.Equal(validJson ? "provider_rejected" : "invalid_provider_json", summary.GetProperty("failureReason").GetString());
        Assert.Equal(
            !validJson,
            rig.Log.Records.Any(record =>
                record.GetProperty("eventName").GetString() == "provider_response_invalid_json"));
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public async Task InterleavedInvocationsKeepSeparateLogContexts()
    {
        using var rig = new HandlerRig();
        rig.Http.Respond = async cancellation =>
        {
            await Task.Delay(20, cancellation);
            return Json(200, "{\"messages\":[{\"status\":{\"groupName\":\"PENDING\"}}]}");
        };
        var results = await Task.WhenAll(rig.Invoke(correlationId: "correlation-first"), rig.Invoke(correlationId: "correlation-second"));
        Assert.All(results, result => Assert.Equal(200, result.StatusCode));
        var summaries = rig.Log.Records.Where(record => record.GetProperty("logType").GetString() == "request").ToArray();
        Assert.Equal(2, summaries.Length);
        Assert.Equal(2, summaries.Select(record => record.GetProperty("functionRequestId").GetString()).Distinct().Count());
        foreach (var summary in summaries)
        {
            var id = summary.GetProperty("functionRequestId").GetString();
            var events = rig.Log.Records.Where(record => record.GetProperty("functionRequestId").GetString() == id).ToArray();
            Assert.Equal(LiveEvents, events.Select(record => record.GetProperty("eventName").GetString()));
            Assert.All(events.Skip(1), record => Assert.Equal(summary.GetProperty("x-ms-correlation-id").GetString(),
                record.GetProperty("x-ms-correlation-id").GetString()));
        }
        Assert.DoesNotContain("PRIVATE", string.Join("\n", rig.Log.Messages));
    }

    [Fact]
    public void SharedIdCasesPreserveRawValuesOrExplicitlyOmitInvalidMetadata()
    {
        using var fixtures = ReadContractFixtures();
        var fields = new[] { "x-ms-client-request-id", "x-ms-correlation-id", "providerTenantId",
            "functionOutboundClientId", "functionOutboundManagedIdentityClientId", "providerMessageId" };
        var provider = new SopranoProvider();
        foreach (var fixture in fixtures.RootElement.GetProperty("logging").GetProperty("identifiers").EnumerateArray())
        {
            var value = fixture.TryGetProperty("length", out var length)
                ? new string('A', length.GetInt32()) : fixture.GetProperty("value").GetString();
            var logger = new CapturingLogger();
            var log = new RequestLog(logger, "function-request", null, value, value);
            log.ProviderSelected(provider.Name, provider.AuthenticationMode);
            log.CredentialResolutionStarted(new AppConfig
            {
                ProviderTenantId = value, OutboundClientId = value, OutboundManagedIdentityClientId = value,
            });
            log.ProviderResponseProcessed(
                new ProviderResult(Outcome.Continue, true, 200, value, "ENROUTE"), 200, true);
            log.Complete(200);
            var summary = logger.Records.Last();
            foreach (var field in fields)
                Assert.Equal(fixture.GetProperty("accepted").GetBoolean() ? value : null, summary.GetProperty(field).GetString());
            var expectedOmissions = fixture.TryGetProperty("omitted", out var omitted) && omitted.GetBoolean() ? fields : Array.Empty<string>();
            Assert.Equal(expectedOmissions, summary.GetProperty("omittedIdFields").EnumerateArray().Select(item => item.GetString()));
            Assert.All(logger.Records, record => Assert.DoesNotContain(record.EnumerateObject(), property => property.Name.EndsWith("Hash")));
            Assert.DoesNotContain("PRIVATE", string.Join("\n", logger.Messages));
        }
    }

    [Fact]
    public void SharedEndpointCasesKeepOnlySchemeHostPortAndApiPath()
    {
        using var fixtures = ReadContractFixtures();
        foreach (var fixture in fixtures.RootElement.GetProperty("logging").GetProperty("endpoints").EnumerateArray())
        {
            var logger = new CapturingLogger();
            var log = new RequestLog(logger, "function-request", null, null, null);
            log.ProviderRequestBuilt(
                HttpMethod.Post,
                new Uri(fixture.GetProperty("url").GetString()!, UriKind.Absolute));
            log.ProviderRequestStarted(1500);
            log.Complete(200);
            Assert.All(logger.Records, record => Assert.Equal(fixture.GetProperty("logged").GetString(),
                record.GetProperty("providerEndpoint").GetString()));
            Assert.DoesNotContain("PRIVATE", string.Join("\n", logger.Messages));
        }
    }

    private static JsonElement Summary(HandlerRig rig)
    {
        var summary = rig.Log.Records.Last();
        Assert.Equal("request", summary.GetProperty("logType").GetString());
        Assert.Equal("request_completed", summary.GetProperty("eventName").GetString());
        Assert.Equal(SummaryFields.OrderBy(value => value),
            summary.EnumerateObject().Select(property => property.Name).OrderBy(value => value));
        var events = rig.Log.Records.Where(record => record.GetProperty("functionRequestId").GetString()
            == summary.GetProperty("functionRequestId").GetString()).ToArray();
        Assert.Single(events, record => record.GetProperty("logType").GetString() == "request");
        var prepared = Assert.Single(events, record => record.GetProperty("eventName").GetString() == "response_prepared");
        Assert.Equal("response_prepared", events[^2].GetProperty("eventName").GetString());
        Assert.Equal(summary.GetProperty("httpStatus").GetInt32(), prepared.GetProperty("httpStatus").GetInt32());
        Assert.Equal(summary.GetProperty("httpStatus").GetInt32() == 200, summary.GetProperty("responseContainsNonce").GetBoolean());
        Assert.Equal(summary.GetProperty("responseContainsNonce").GetBoolean(), prepared.GetProperty("responseContainsNonce").GetBoolean());
        Assert.Equal(summary.GetProperty("responseContainsCorrelationId").GetBoolean(), prepared.GetProperty("responseContainsCorrelationId").GetBoolean());
        Assert.All(events[..^1], record => Assert.Equal("service", record.GetProperty("logType").GetString()));
        Assert.All(events, record => Assert.Equal("SendOtp", record.GetProperty("functionName").GetString()));
        Assert.Equal(summary.EnumerateObject().Select(property => property.Name).OrderBy(value => value),
            rig.Log.States.Last().Keys.OrderBy(value => value));
        foreach (var value in new[] { PrivateError, Phone, "918273", Nonce, "private-api-key", "private-api-id" })
            Assert.DoesNotContain(value, string.Join("\n", rig.Log.Messages));
        return summary;
    }

    private static JsonDocument ReadContractFixtures() =>
        JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fixtures", "contract.json")));

    private static void AssertAccepted(ObjectResult result)
    {
        Assert.Equal(200, result.StatusCode);
        Assert.IsType<EndpointSuccessResponse>(result.Value);
        Assert.Equal(JsonSerializer.Serialize(new { nonce = Nonce, correlationId = Correlation, providerStatus = "accepted" }),
            JsonSerializer.Serialize(result.Value));
    }

    private static void AssertFailure(HandlerRig rig, ObjectResult result, int status, string error = "provider_delivery_failed")
    {
        Assert.Equal(status, result.StatusCode);
        Assert.IsType<EndpointErrorResponse>(result.Value);
        var body = JsonSerializer.SerializeToElement(result.Value);
        Assert.Equal(error, body.GetProperty("error").GetString());
        Assert.False(body.TryGetProperty("nonce", out _));
        var output = body.GetRawText() + string.Join("\n", rig.Log.Messages);
        foreach (var value in new[] { PrivateError, Phone, "918273", Nonce })
            Assert.DoesNotContain(value, output);
    }

    private static HttpResponseMessage Json(int status, string body) =>
        new((HttpStatusCode)status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };

    private sealed class HandlerRig : IDisposable
    {
        private readonly SendOtp _function;
        public TestEnv Env { get; }
        public TestSecrets Secrets { get; } = new();
        public TestHttp Http { get; } = new();
        public TestKeys Keys { get; } = new();
        public CapturingLogger Log { get; } = new();
        public SendOtp Function { get; }
        public CredentialTokenService Credentials { get; }
        public HandlerRig(Func<string, TokenCredential>? createIdentity = null,
            Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential>? createOAuth = null)
        {
            Env = new TestEnv
            {
                ["EPP_PROVIDER_NAME"] = "infobip",
                ["EPP_PROVIDER_ENDPOINT"] = "https://provider.example",
                ["EPP_PROVIDER_TIMEOUT_MS"] = "2500",
                ["EPP_DECRYPTION_KEY_PEM"] = Keys.Rsa.ExportPkcs8PrivateKeyPem(),
            };
            PhoneProviderBase[] providers =
            {
                new InfobipProvider(Secrets),
                new TelesignProvider(Secrets),
                new SopranoProvider(
                    createIdentity ?? (_ => throw new InvalidOperationException("Unexpected managed identity")),
                    createOAuth ?? ((_, _, _) => throw new InvalidOperationException("Unexpected OAuth"))),
                new SinchProvider(Secrets),
            };
            Credentials = new CredentialTokenService(providers, Env);
            _function = new SendOtp(providers, Credentials, Http, new JweDecryptor(Env), Env, Log);
            Function = _function;
        }
        public async Task<ObjectResult> Invoke(object? mode = null, string channel = "sms", string? tenantId = null,
            Jose.JweAlgorithm algorithm = Jose.JweAlgorithm.RSA_OAEP_256,
            Jose.JweEncryption encryption = Jose.JweEncryption.A256GCM, JsonElement? deliveryOverrides = null,
            string? plaintext = null, string? correlationId = Correlation, Dictionary<string, string>? headers = null,
            string? type = EntraSendOtpPayload.SupportedType, int? ttlSeconds = 60)
        {
            var context = new Dictionary<string, object?> { ["nonce"] = Nonce, ["phoneNumber"] = Phone, ["message"] = Message };
            if (deliveryOverrides is { } changes)
                foreach (var property in changes.EnumerateObject()) context[property.Name] = property.Value;
            var encrypted = Jose.JWT.Encode(plaintext ?? JsonSerializer.Serialize(context), Keys.Rsa, algorithm, encryption,
                extraHeaders: new Dictionary<string, object> { ["kid"] = Kid });
            return await InvokePayload(new EntraSendOtpPayload
            {
                Type = type,
                TenantId = tenantId,
                CorrelationId = correlationId,
                Channel = channel.Equals("voice", StringComparison.OrdinalIgnoreCase)
                    ? EntraOtpChannel.Voice
                    : EntraOtpChannel.Sms,
                Mode = mode is string text && text.Equals("evaluation", StringComparison.OrdinalIgnoreCase)
                    || mode is int code && code == 2
                        ? EntraOtpMode.Evaluation
                        : EntraOtpMode.Live,
                TtlSeconds = ttlSeconds,
                EncryptedDeliveryContext = encrypted,
            }, headers);
        }
        public async Task<ObjectResult> InvokePayload(
            EntraSendOtpPayload payload, Dictionary<string, string>? headers = null)
        {
            var request = new DefaultHttpContext().Request;
            request.Method = "POST";
            request.ContentType = "application/json";
            if (headers is not null)
                foreach (var (key, value) in headers) request.Headers[key] = value;
            return Assert.IsAssignableFrom<ObjectResult>(await _function.Run(request, payload));
        }
        public void Dispose() { Credentials.Dispose(); Keys.Dispose(); Http.Dispose(); }
    }

    private sealed class TestSecrets : ISecretResolver
    {
        public int Calls { get; private set; }
        public string Secret { get; set; } = "private-api-key";
        public string Identity { get; set; } = "private-api-id";
        public Exception? Error { get; set; }
        public Task<string> ResolveAsync(string? name, CancellationToken cancellationToken = default)
        {
            Calls++;
            if (Error is not null) throw Error;
            return Task.FromResult(name == "telesign-customer-id" ? Identity : Secret);
        }
    }

    private sealed class TestHttp : HttpMessageHandler, IHttpClientFactory
    {
        public int Calls { get; private set; }
        public string? Body { get; private set; }
        public Dictionary<string, string> Headers { get; private set; } = new(StringComparer.OrdinalIgnoreCase);
        public Func<CancellationToken, Task<HttpResponseMessage>> Respond { get; set; } =
            _ => Task.FromResult(Json(200, "{\"messages\":[{\"messageId\":\"id\",\"status\":{\"groupName\":\"PENDING\"}}]}"));
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            Body = await request.Content!.ReadAsStringAsync(cancellationToken);
            Headers = request.Headers.ToDictionary(header => header.Key, header => string.Join(",", header.Value), StringComparer.OrdinalIgnoreCase);
            return await Respond(cancellationToken);
        }
    }

    private sealed class CapturingLogger : ILogger<SendOtp>
    {
        private readonly object _gate = new();
        public List<(LogLevel Level, string Message)> Entries { get; } = new();
        public List<Dictionary<string, object?>> States { get; } = new();
        public IEnumerable<string> Messages => Entries.Select(entry => entry.Message);
        public IEnumerable<JsonElement> Records => Messages.Select(message => JsonSerializer.Deserialize<JsonElement>(message));
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
        public bool IsEnabled(LogLevel logLevel) => true;
        public void Log<TState>(LogLevel level, EventId id, TState state, Exception? error, Func<TState, Exception?, string> formatter)
        {
            lock (_gate)
            {
                Entries.Add((level, formatter(state, error) + (error?.ToString() ?? "")));
                States.Add(Assert.IsAssignableFrom<IEnumerable<KeyValuePair<string, object?>>>(state).ToDictionary(pair => pair.Key, pair => pair.Value));
            }
        }
    }

    // Headers arrive immediately; only reading the response body stalls until cancellation.
    private sealed class SlowBody : MemoryStream
    {
        public bool SawCancellationToken { get; private set; }
        public SlowBody() : base(new byte[] { 0 }) { }
        public override Task<int> ReadAsync(byte[] buffer, int offset, int count, CancellationToken cancellationToken) =>
            ReadAsync(buffer.AsMemory(offset, count), cancellationToken).AsTask();
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            SawCancellationToken = cancellationToken.CanBeCanceled;
            await Task.Delay(Timeout.Infinite, cancellationToken);
            return 0;
        }
    }
}
