using System.Text.Json;

namespace Epp.Otp.Providers;

// Sinch: SMS via XMS Batches (POST /xms/v1/{plan}/batches, Bearer). Voice via Calling TTS callout.
public sealed class SinchProvider : IProviderAdapter
{
    public ProviderManifest Manifest { get; } = new(
        Id: "sinch",
        Auth: new AuthConfig("apiKey", KeyVaultSecretName: "sinch-api-token"),
        ResponseMapping: new Dictionary<string, Outcome>
        {
            ["Dispatched"] = Outcome.Continue,
            ["Delivered"] = Outcome.Continue,
            ["Queued"] = Outcome.Continue,
            ["Failed"] = Outcome.Fail,
            ["Rejected"] = Outcome.Fail,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var bearer = credential.Mode == "oauth2" ? credential.Token : credential.Secret;
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = $"Bearer {bearer}",
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        };
        var reference = dispatch.CorrelationId ?? dispatch.MessageId;

        if (channel == "voice")
        {
            var voiceBase = env.Get("SINCH_VOICE_ENDPOINT") ?? "https://calling.api.sinch.com";
            var voiceBody = new
            {
                method = "ttsCallout",
                ttsCallout = new
                {
                    destination = new { type = "number", endpoint = dispatch.Destination },
                    text = dispatch.Message,
                    locale = dispatch.Locale ?? "en-US",
                    custom = reference,
                },
            };
            return new ProviderHttpRequest($"{voiceBase}/calling/v1/callouts", "POST", headers, JsonSerializer.Serialize(voiceBody));
        }

        var servicePlanId = env.Get("SINCH_SERVICE_PLAN_ID") ?? string.Empty;
        var body = new
        {
            from = env.Get("EPP_PROVIDER_ACCOUNT_NAME") ?? "Verify",
            to = new[] { dispatch.Destination },
            body = dispatch.Message,
            client_reference = reference,
        };
        return new ProviderHttpRequest($"{endpoint}/xms/v1/{servicePlanId}/batches", "POST", headers, JsonSerializer.Serialize(body));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        string? id = null, desc = null;
        if (json.ValueKind == JsonValueKind.Object)
        {
            if (json.TryGetProperty("id", out var idElement)) id = idElement.ToString();
            else if (json.TryGetProperty("callId", out var callIdElement)) id = callIdElement.ToString();
            if (json.TryGetProperty("text", out var textElement)) desc = textElement.GetString();
        }
        return new ParsedResponse(ok, httpStatus, id, ok ? "Dispatched" : null, null, desc);
    }
}
