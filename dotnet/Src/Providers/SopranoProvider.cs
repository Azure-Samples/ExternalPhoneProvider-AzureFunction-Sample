using System.Text.Json;

namespace Epp.Otp.Providers;

public sealed class SopranoProvider : IProviderAdapter
{
    public ProviderManifest Manifest { get; } = new(
        Id: "soprano",
        Auth: new AuthConfig("oauth"),
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
            ["FILTERED"] = Outcome.Fail,
            ["BLOCKED"] = Outcome.Block,
            ["default"] = Outcome.Fail,
        },
        RequiresTextToVoice: true);

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var headers = new Dictionary<string, string>
        {
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " + credential.AccessToken,
        };
        var body = new Dictionary<string, object?>
        {
            ["destination"] = dispatch.Destination.TrimStart('+'),
            ["messageTypes"] = new[] { channel == "voice" ? "voice" : "sms" },
            ["correlationId"] = dispatch.CorrelationId ?? dispatch.MessageId,
            ["shutterMode"] = false,
        };
        if (channel == "voice")
        {
            var voice = dispatch.TextToVoice;
            if (voice?.IsComplete != true) throw new InvalidOperationException("incomplete voice context");
            body["voice"] = new { text2voice = voice };
        }
        else
        {
            body["text"] = dispatch.Message;
        }

        return new ProviderHttpRequest(endpoint, "POST", headers, JsonSerializer.Serialize(body));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        var payload = json.ValueKind == JsonValueKind.Array && json.GetArrayLength() > 0 ? json[0] : json;
        string? id = null, status = null;
        if (payload.ValueKind == JsonValueKind.Object)
        {
            if (payload.TryGetProperty("id", out var idElement)) id = idElement.ToString();
            else if (payload.TryGetProperty("messageId", out var messageIdElement)) id = messageIdElement.ToString();
            if (!payload.TryGetProperty("status", out var statusElement) || statusElement.ValueKind == JsonValueKind.Null)
                payload.TryGetProperty("state", out statusElement);
            if (statusElement.ValueKind == JsonValueKind.String) status = statusElement.GetString();
        }
        status = string.IsNullOrWhiteSpace(status) ? "UNKNOWN" : status.ToUpperInvariant();
        return new ParsedResponse(ok, httpStatus, id, status);
    }
}
