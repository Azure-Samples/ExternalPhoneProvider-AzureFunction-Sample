using System.Text.Json;

namespace Epp.Otp.Providers;

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
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = $"App {credential.Secret}",
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
        string? messageId = null, statusName = "UNKNOWN", statusDesc = null;
        if (json.ValueKind == JsonValueKind.Object && json.TryGetProperty("messages", out var messages)
            && messages.ValueKind == JsonValueKind.Array && messages.GetArrayLength() > 0
            && messages[0].ValueKind == JsonValueKind.Object)
        {
            var firstMessage = messages[0];
            if (firstMessage.TryGetProperty("messageId", out var messageIdElement)) messageId = messageIdElement.ToString();
            if (firstMessage.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Object)
            {
                if (!status.TryGetProperty("groupName", out var value) || value.ValueKind == JsonValueKind.Null)
                    status.TryGetProperty("name", out value);
                if (value.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(value.GetString()))
                    statusName = value.GetString()!.ToUpperInvariant();
                if (status.TryGetProperty("description", out var description) && description.ValueKind == JsonValueKind.String)
                    statusDesc = description.GetString();
            }
        }
        return new ParsedResponse(ok, httpStatus, messageId, statusName, null, statusDesc);
    }
}
