using System.Text.Json;

namespace Epp.Otp.Providers;

// Infobip: SMS via /sms/3/messages, voice via /tts/3/advanced. Auth: App API key.
public sealed class InfobipProvider : IProviderAdapter
{
    public ProviderManifest Manifest { get; } = new(
        Id: "infobip",
        Auth: new AuthConfig("apiKey", KeyVaultSecretName: "infobip-api-key"),
        ResponseMapping: new Dictionary<string, Outcome>
        {
            ["ACCEPTED"] = Outcome.Continue,
            ["PENDING"] = Outcome.Continue,
            ["DELIVERED"] = Outcome.Continue,
            ["REJECTED"] = Outcome.Fail,
            ["EXPIRED"] = Outcome.Fail,
            ["UNDELIVERABLE"] = Outcome.Fail,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var senderId = env.Get("EPP_PROVIDER_ACCOUNT_NAME") ?? "Verify";
        var auth = credential.Mode == "oauth2" ? $"Bearer {credential.Token}" : $"App {credential.Secret}";
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = auth,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        };
        var messageId = dispatch.CorrelationId ?? dispatch.MessageId;

        if (channel == "voice")
        {
            var voiceBody = new
            {
                messages = new[]
                {
                    new
                    {
                        from = senderId,
                        destinations = new[] { new { to = dispatch.Destination, messageId } },
                        text = dispatch.Message,
                        language = dispatch.Locale ?? "en",
                        voice = new { name = "Joanna", gender = "female" },
                    },
                },
            };
            return new ProviderHttpRequest($"{endpoint}/tts/3/advanced", "POST", headers, JsonSerializer.Serialize(voiceBody));
        }

        var body = new
        {
            messages = new[]
            {
                new
                {
                    sender = senderId,
                    destinations = new[] { new { to = dispatch.Destination, messageId } },
                    content = new { text = dispatch.Message },
                },
            },
        };
        return new ProviderHttpRequest($"{endpoint}/sms/3/messages", "POST", headers, JsonSerializer.Serialize(body));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        string? messageId = null, statusName = null, statusDesc = null;
        if (json.ValueKind == JsonValueKind.Object && json.TryGetProperty("messages", out var messages) && messages.ValueKind == JsonValueKind.Array && messages.GetArrayLength() > 0)
        {
            var firstMessage = messages[0];
            if (firstMessage.TryGetProperty("messageId", out var messageIdElement)) messageId = messageIdElement.ToString();
            if (firstMessage.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Object)
            {
                if (status.TryGetProperty("groupName", out var groupName)) statusName = groupName.GetString()?.ToUpperInvariant();
                else if (status.TryGetProperty("name", out var name)) statusName = name.GetString()?.ToUpperInvariant();
                if (status.TryGetProperty("description", out var description)) statusDesc = description.GetString();
            }
        }
        return new ParsedResponse(ok, httpStatus, messageId, statusName, null, statusDesc);
    }
}
