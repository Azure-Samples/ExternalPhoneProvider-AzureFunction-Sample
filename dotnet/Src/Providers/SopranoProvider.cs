using System.Text.Json;

namespace Epp.Otp.Providers;

// Soprano Connect (MEMS): POST {base}/messages/omnimsg. One endpoint for every channel —
// `messageTypes` picks it and Soprano does the TTS for voice.
// Auth: an Entra ID v2.0 Bearer JWT (audience = Soprano's app id), or X-MEMS-API-ID + X-MEMS-API-Key.
public sealed class SopranoProvider : IProviderAdapter
{
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
            // Accepted (HTTP 201) but stopped by an account/destination filter — nothing was delivered.
            ["FILTERED"] = Outcome.Fail,
            ["FAILED"] = Outcome.Fail,
            ["REJECTED"] = Outcome.Fail,
            ["BLOCKED"] = Outcome.Block,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var headers = new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Accept"] = "application/json" };
        if (credential.Mode == "oauth2") headers["Authorization"] = $"Bearer {credential.Token}";
        else { headers["X-MEMS-API-ID"] = credential.Identity ?? string.Empty; headers["X-MEMS-API-Key"] = credential.Secret ?? string.Empty; }

        var body = new
        {
            text = dispatch.Message,
            destination = (dispatch.Destination ?? string.Empty).TrimStart('+'), // E.164 without the leading +
            messageTypes = new[] { channel == "voice" ? "voice" : "sms" },
            correlationId = dispatch.CorrelationId ?? dispatch.MessageId,
            // Soprano processes the request but delivers nothing — connectivity/credential testing.
            shutterMode = string.Equals(env.Get("SOPRANO_SHUTTER_MODE"), "true", StringComparison.OrdinalIgnoreCase),
        };

        return new ProviderHttpRequest($"{endpoint}/messages/omnimsg", "POST", headers, JsonSerializer.Serialize(body));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        var payload = json.ValueKind == JsonValueKind.Array && json.GetArrayLength() > 0 ? json[0] : json;
        string? id = null, status = null, desc = null;
        if (payload.ValueKind == JsonValueKind.Object)
        {
            if (payload.TryGetProperty("id", out var idElement)) id = idElement.ToString();
            else if (payload.TryGetProperty("messageId", out var messageIdElement)) id = messageIdElement.ToString();
            if (payload.TryGetProperty("status", out var statusElement)) status = statusElement.GetString()?.ToUpperInvariant();
            else if (payload.TryGetProperty("state", out var stateElement)) status = stateElement.GetString()?.ToUpperInvariant();
            if (payload.TryGetProperty("errorDescription", out var errorElement)) desc = errorElement.GetString();
            else if (payload.TryGetProperty("statusText", out var statusTextElement)) desc = statusTextElement.GetString();
            else if (payload.TryGetProperty("description", out var descriptionElement)) desc = descriptionElement.GetString();
        }
        status ??= ok ? "SUBMITTED" : null;
        return new ParsedResponse(ok, httpStatus, id, status, null, desc);
    }
}
