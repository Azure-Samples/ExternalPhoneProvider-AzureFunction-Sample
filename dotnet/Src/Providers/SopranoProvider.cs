using System.Text.Json;

namespace Epp.Otp.Providers;

// Soprano Connect (MEMS): POST {base}/messages/{sms|voice}. Auth: X-MEMS-API-ID + X-MEMS-API-Key.
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
            ["FAILED"] = Outcome.Fail,
            ["REJECTED"] = Outcome.Fail,
            ["BLOCKED"] = Outcome.Block,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var messageType = channel == "voice" ? "voice" : "sms";
        var headers = new Dictionary<string, string> { ["Content-Type"] = "application/json", ["Accept"] = "application/json" };
        if (credential.Mode == "oauth2") headers["Authorization"] = $"Bearer {credential.Token}";
        else { headers["X-MEMS-API-ID"] = credential.Identity ?? string.Empty; headers["X-MEMS-API-Key"] = credential.Secret ?? string.Empty; }

        // Soprano wants a provisioned source endpoint (endpoints:[{type,id}]), which is numeric. A
        // non-numeric account name is sent as a free-text source instead.
        object endpoints_or_source()
        {
            var account = env.Get("EPP_PROVIDER_ACCOUNT_NAME");
            if (!string.IsNullOrEmpty(account) && int.TryParse(account, out var sourceId))
                return new { endpoints = new[] { new { type = int.TryParse(env.Get("SOPRANO_SOURCE_TYPE"), out var parsedSourceType) ? parsedSourceType : 1, id = sourceId } } };
            return new { source = account };
        }

        var clientRef = dispatch.CorrelationId ?? dispatch.MessageId;
        object body;
        if (messageType == "voice")
        {
            var voiceLanguage = env.Get("SOPRANO_VOICE_LANGUAGE") ?? ((dispatch.Locale?.Contains('-') ?? false) ? dispatch.Locale! : "en-US");
            body = Merge(endpoints_or_source(), new
            {
                messageType,
                destination = dispatch.Destination,
                clientReference = clientRef,
                voice = new
                {
                    text2voice = new
                    {
                        beforePasswordText = dispatch.Message ?? string.Empty,
                        password = string.Empty,
                        afterPasswordText = string.Empty,
                        language = voiceLanguage,
                        gender = int.TryParse(env.Get("SOPRANO_VOICE_GENDER"), out var parsedGender) ? parsedGender : 1,
                        loop = 1,
                    },
                },
            });
        }
        else
        {
            body = Merge(endpoints_or_source(), new { messageType, destination = dispatch.Destination, text = dispatch.Message, clientReference = clientRef });
        }

        return new ProviderHttpRequest($"{endpoint}/messages/{messageType}", "POST", headers, JsonSerializer.Serialize(body));
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

    // Shallow-merge two anonymous objects into a dictionary for JSON serialization.
    private static Dictionary<string, object?> Merge(object first, object second)
    {
        var merged = new Dictionary<string, object?>();
        foreach (var property in first.GetType().GetProperties()) merged[property.Name] = property.GetValue(first);
        foreach (var property in second.GetType().GetProperties()) merged[property.Name] = property.GetValue(second);
        return merged;
    }
}
