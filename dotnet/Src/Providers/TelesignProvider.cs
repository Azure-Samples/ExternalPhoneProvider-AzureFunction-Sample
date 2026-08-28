using System.Text;
using System.Text.Json;

namespace Epp.Otp.Providers;

// Telesign: SMS via /v1/messaging, voice via /v1/voice (form-urlencoded). Auth: HTTP Basic (customer_id:api_key).
public sealed class TelesignProvider : IProviderAdapter
{
    public ProviderManifest Manifest { get; } = new(
        Id: "telesign",
        Auth: new AuthConfig("apiKey", KeyVaultSecretName: "telesign-api-key", IdentityKeyVaultSecretName: "telesign-customer-id"),
        ResponseMapping: new Dictionary<string, Outcome>
        {
            ["200"] = Outcome.Continue,
            ["203"] = Outcome.Continue,
            ["290"] = Outcome.Continue,
            ["291"] = Outcome.Continue,
            ["292"] = Outcome.Continue,
            ["100"] = Outcome.Continue,
            ["101"] = Outcome.Continue,
            ["102"] = Outcome.Continue,
            ["103"] = Outcome.Continue,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        var authorization = credential.Mode == "oauth2"
            ? $"Bearer {credential.Token}"
            : "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{credential.Identity}:{credential.Secret}"));

        var externalId = dispatch.CorrelationId ?? dispatch.MessageId;
        var form = new Dictionary<string, string>();
        string path;
        if (channel == "voice")
        {
            path = "/v1/voice";
            form["phone_number"] = dispatch.Destination;
            form["message"] = dispatch.Message ?? string.Empty;
            form["message_type"] = "OTP";
            form["voice"] = env.Get("TELESIGN_VOICE") ?? "f-en-US";
            form["external_id"] = externalId;
        }
        else
        {
            path = "/v1/messaging";
            form["phone_number"] = dispatch.Destination;
            form["message"] = dispatch.Message ?? string.Empty;
            form["sender_id"] = env.Get("EPP_PROVIDER_ACCOUNT_NAME") ?? string.Empty;
            form["message_type"] = "OTP";
            form["external_id"] = externalId;
            form["is_primary"] = "true";
        }

        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = authorization,
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
        };
        var encoded = string.Join("&", form.Select(kv => $"{Uri.EscapeDataString(kv.Key)}={Uri.EscapeDataString(kv.Value)}"));
        return new ProviderHttpRequest($"{endpoint}{path}", "POST", headers, encoded);
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        string? refId = null, statusCode = null, statusDesc = null;
        if (json.ValueKind == JsonValueKind.Object)
        {
            if (json.TryGetProperty("reference_id", out var referenceId)) refId = referenceId.GetString();
            if (json.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Object)
            {
                if (status.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.Number) statusCode = code.GetInt32().ToString();
                if (status.TryGetProperty("description", out var description)) statusDesc = description.GetString();
            }
        }
        return new ParsedResponse(ok, httpStatus, refId, null, statusCode, statusDesc);
    }
}
