using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Epp.Otp.Providers;

public sealed class TelesignProvider : PhoneProviderBase
{
    private const string VoiceDigitSeparator = ", ";
    private const int VoiceRepeatCount = 2;
    private const string VoiceRepeatSeparator = " ";
    private static readonly Regex VoicePasscodePattern = new(
        @"(?<![0-9])[0-9]{6}(?![0-9])",
        RegexOptions.CultureInvariant);
    private readonly ISecretResolver? _secrets;

    public TelesignProvider(ISecretResolver? secrets = null) => _secrets = secrets;

    public override string Name => "telesign";
    public override string AuthenticationMode => "apiKey";

    public override Task<ProviderResult> SendOtpAsync(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credentials,
        IEnv env, HttpClient client, int timeoutMs, RequestLog? log = null) =>
        SendJsonAsync<Response>(
            () => CreateRequest(channel, endpoint, delivery, credentials, env),
            MapResponse,
            client,
            timeoutMs,
            log);

    public override HttpRequestMessage CreateRequest(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credential, IEnv env)
    {
        if (channel is not ("sms" or "voice")) throw new InvalidOperationException("unsupported channel");
        if (delivery.PhoneNumber is null || !Regex.IsMatch(delivery.PhoneNumber, @"\A\+[1-9][0-9]{1,14}\z"))
            throw new InvalidOperationException("invalid recipient");

        var authorization = "Basic " + Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{credential.Identity}:{credential.Secret}"));
        var messageText = channel == "voice" ? BuildVoiceMessage(delivery.Message!) : delivery.Message;
        var body = new Request(
            new Recipient(delivery.PhoneNumber),
            new Message(messageText, string.IsNullOrWhiteSpace(delivery.Locale) ? null : delivery.Locale),
            [new Channel(channel)],
            string.IsNullOrEmpty(delivery.CorrelationId) ? delivery.MessageId : delivery.CorrelationId);

        var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.TryAddWithoutValidation("Authorization", authorization);
        request.Headers.Accept.ParseAdd("application/json");
        return request;
    }

    private static string BuildVoiceMessage(string message)
    {
        var pacedMessage = VoicePasscodePattern.Replace(
            message,
            match => string.Join(VoiceDigitSeparator, match.Value.ToCharArray()));
        return string.Join(VoiceRepeatSeparator, Enumerable.Repeat(pacedMessage, VoiceRepeatCount));
    }

    private static ProviderResult MapResponse(Response? payload, HttpStatusCode httpStatus)
    {
        var statusCode = payload?.Status?.Code?.ToString(CultureInfo.InvariantCulture) ?? "UNKNOWN";
        var (outcome, recognized) = MapStatus(statusCode);
        return new ProviderResult(
            (int)httpStatus is >= 200 and < 300 ? outcome : Outcome.Fail,
            recognized,
            (int)httpStatus,
            payload?.ReferenceId,
            ProviderStatusCode: statusCode,
            ProviderStatusDescription: payload?.Status?.Description);
    }

    public override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        if (_secrets is null) throw CredentialTokenService.Unavailable();
        var key = _secrets.ResolveAsync("telesign-api-key", cancellationToken);
        var identity = _secrets.ResolveAsync("telesign-customer-id", cancellationToken);
        await Task.WhenAll(key, identity).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(key.Result)
            || string.IsNullOrWhiteSpace(identity.Result))
            throw CredentialTokenService.Unavailable();
        return new ProviderCredentials(
            AuthenticationMode,
            Secret: key.Result,
            Identity: identity.Result,
            ExpiresOn: DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private static (Outcome Outcome, bool Recognized) MapStatus(string? status) => status switch
    {
        "200" or "203" or "290" or "291" or "292"
            or "100" or "101" or "102" or "103" or "3001" => (Outcome.Continue, true),
        _ => (Outcome.Fail, false),
    };

    private sealed record Request(
        [property: JsonPropertyName("recipient")] Recipient Recipient,
        [property: JsonPropertyName("message")] Message Message,
        [property: JsonPropertyName("channels")] IReadOnlyList<Channel> Channels,
        [property: JsonPropertyName("correlation_id")] string CorrelationId);

    private sealed record Recipient(
        [property: JsonPropertyName("phone_number")] string PhoneNumber);

    private sealed record Message(
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("language"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Language);

    private sealed record Channel(
        [property: JsonPropertyName("channel")] string Name);

    private sealed record Response(
        [property: JsonPropertyName("reference_id")] string? ReferenceId,
        [property: JsonPropertyName("status")] Status? Status);

    private sealed record Status(
        [property: JsonPropertyName("code"), JsonNumberHandling(JsonNumberHandling.Strict)] int? Code = null,
        [property: JsonPropertyName("description")] string? Description = null);
}
