using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Epp.Otp.Providers;

public sealed class TelesignProvider : IProviderAdapter
{
    private const string VoiceDigitSeparator = ", ";
    private const int VoiceRepeatCount = 2;
    private const string VoiceRepeatSeparator = " ";
    private static readonly Regex VoicePasscodePattern = new(
        @"(?<![0-9])[0-9]{6}(?![0-9])",
        RegexOptions.CultureInvariant);

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
            ["3001"] = Outcome.Continue,
            ["default"] = Outcome.Fail,
        });

    public ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env)
    {
        if (channel is not ("sms" or "voice")) throw new InvalidOperationException("unsupported channel");
        if (dispatch.Destination is null || !Regex.IsMatch(dispatch.Destination, @"\A\+[1-9][0-9]{1,14}\z"))
            throw new InvalidOperationException("invalid recipient");
        var authorization = "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes($"{credential.Identity}:{credential.Secret}"));
        var messageText = channel == "voice" ? BuildVoiceMessage(dispatch.Message!) : dispatch.Message;
        var message = new Dictionary<string, string?> { ["text"] = messageText };
        if (!string.IsNullOrWhiteSpace(dispatch.Locale)) message["language"] = dispatch.Locale;
        var body = new
        {
            recipient = new { phone_number = dispatch.Destination },
            message,
            channels = new[] { new { channel } },
            correlation_id = string.IsNullOrEmpty(dispatch.CorrelationId) ? dispatch.MessageId : dispatch.CorrelationId,
        };
        var headers = new Dictionary<string, string>
        {
            ["Authorization"] = authorization,
            ["Content-Type"] = "application/json",
            ["Accept"] = "application/json",
        };
        return new ProviderHttpRequest(endpoint, "POST", headers, JsonSerializer.Serialize(body));
    }

    private static string BuildVoiceMessage(string message)
    {
        var pacedMessage = VoicePasscodePattern.Replace(
            message,
            match => string.Join(VoiceDigitSeparator, match.Value.ToCharArray()));
        return string.Join(VoiceRepeatSeparator, Enumerable.Repeat(pacedMessage, VoiceRepeatCount));
    }

    public ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json)
    {
        string? refId = null, statusCode = "UNKNOWN", statusDesc = null;
        if (json.ValueKind == JsonValueKind.Object)
        {
            if (json.TryGetProperty("reference_id", out var referenceId) && referenceId.ValueKind == JsonValueKind.String)
                refId = referenceId.GetString();
            if (json.TryGetProperty("status", out var status) && status.ValueKind == JsonValueKind.Object)
            {
                if (status.TryGetProperty("code", out var code) && code.ValueKind == JsonValueKind.Number && code.TryGetInt32(out var numericCode))
                    statusCode = numericCode.ToString(System.Globalization.CultureInfo.InvariantCulture);
                if (status.TryGetProperty("description", out var description) && description.ValueKind == JsonValueKind.String)
                    statusDesc = description.GetString();
            }
        }
        return new ParsedResponse(ok, httpStatus, refId, null, statusCode, statusDesc);
    }
}
