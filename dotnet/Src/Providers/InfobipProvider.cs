using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Epp.Otp.Providers;

public sealed class InfobipProvider : PhoneProviderBase
{
    private readonly ISecretResolver? _secrets;

    public InfobipProvider(ISecretResolver? secrets = null) => _secrets = secrets;

    public override string Name => "infobip";
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
        var senderId = env.Get("EPP_PROVIDER_ACCOUNT_NAME") ?? "Verify";
        var messageId = delivery.CorrelationId ?? delivery.MessageId;
        object body;
        string url;

        if (channel == "voice")
        {
            body = new VoiceRequest(
                [
                    new VoiceMessage(
                        senderId,
                        [new Destination(delivery.PhoneNumber, messageId)],
                        delivery.Message,
                        delivery.Locale ?? "en",
                        new Voice("Joanna", "female"))
                ]);
            url = $"{endpoint}/tts/3/advanced";
        }
        else
        {
            body = new SmsRequest(
                [
                    new SmsMessage(
                        senderId,
                        [new Destination(delivery.PhoneNumber, messageId)],
                        new SmsContent(delivery.Message))
                ]);
            url = $"{endpoint}/sms/3/messages";
        }

        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.TryAddWithoutValidation("Authorization", $"App {credential.Secret}");
        request.Headers.Accept.ParseAdd("application/json");
        return request;
    }

    private static ProviderResult MapResponse(Response? payload, HttpStatusCode httpStatus)
    {
        var message = payload?.Messages?.FirstOrDefault();
        var status = message?.Status;
        var statusName = (status?.GroupName?.Value ?? status?.Name?.Value)?.ToUpperInvariant();
        var (outcome, recognized) = MapStatus(statusName);
        return new ProviderResult(
            (int)httpStatus is >= 200 and < 300 ? outcome : Outcome.Fail,
            recognized,
            (int)httpStatus,
            message?.MessageId,
            statusName,
            ProviderStatusDescription: status?.Description?.Value);
    }

    public override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        if (_secrets is null) throw CredentialTokenService.Unavailable();
        var secret = await _secrets.ResolveAsync(
            "infobip-api-key", cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(secret)) throw CredentialTokenService.Unavailable();
        return new ProviderCredentials(
            AuthenticationMode,
            Secret: secret,
            ExpiresOn: DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private static (Outcome Outcome, bool Recognized) MapStatus(string? status) => status switch
    {
        "ACCEPTED" or "PENDING" or "DELIVERED" => (Outcome.Continue, true),
        "REJECTED" or "EXPIRED" or "UNDELIVERABLE" => (Outcome.Fail, true),
        _ => (Outcome.Fail, false),
    };

    private sealed record SmsRequest(
        [property: JsonPropertyName("messages")] IReadOnlyList<SmsMessage> Messages);

    private sealed record SmsMessage(
        [property: JsonPropertyName("sender")] string Sender,
        [property: JsonPropertyName("destinations")] IReadOnlyList<Destination> Destinations,
        [property: JsonPropertyName("content")] SmsContent Content);

    private sealed record SmsContent(
        [property: JsonPropertyName("text")] string? Text);

    private sealed record VoiceRequest(
        [property: JsonPropertyName("messages")] IReadOnlyList<VoiceMessage> Messages);

    private sealed record VoiceMessage(
        [property: JsonPropertyName("from")] string From,
        [property: JsonPropertyName("destinations")] IReadOnlyList<Destination> Destinations,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("language")] string Language,
        [property: JsonPropertyName("voice")] Voice Voice);

    private sealed record Destination(
        [property: JsonPropertyName("to")] string To,
        [property: JsonPropertyName("messageId")] string MessageId);

    private sealed record Voice(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("gender")] string Gender);

    private sealed record Response(
        [property: JsonPropertyName("messages")] IReadOnlyList<ResponseMessage>? Messages);

    private sealed record ResponseMessage(
        [property: JsonPropertyName("messageId")] string? MessageId,
        [property: JsonPropertyName("status")] ResponseStatus? Status);

    [JsonConverter(typeof(ResponseStatusConverter))]
    private sealed record ResponseStatus(
        [property: JsonPropertyName("groupName")] ResponseString? GroupName,
        [property: JsonPropertyName("name")] ResponseString? Name,
        [property: JsonPropertyName("description")] ResponseString? Description);

    private sealed record ResponseStatusProperties(
        [property: JsonPropertyName("groupName")] ResponseString? GroupName,
        [property: JsonPropertyName("name")] ResponseString? Name,
        [property: JsonPropertyName("description")] ResponseString? Description);

    [JsonConverter(typeof(ResponseStringConverter))]
    private sealed record ResponseString(string? Value);

    private sealed class ResponseStatusConverter : JsonConverter<ResponseStatus>
    {
        public override ResponseStatus Read(
            ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType != JsonTokenType.StartObject)
            {
                reader.Skip();
                return new ResponseStatus(null, null, null);
            }

            var value = JsonSerializer.Deserialize<ResponseStatusProperties>(ref reader, options);
            return new ResponseStatus(value?.GroupName, value?.Name, value?.Description);
        }

        public override void Write(Utf8JsonWriter writer, ResponseStatus value, JsonSerializerOptions options) =>
            throw new NotSupportedException();
    }

    private sealed class ResponseStringConverter : JsonConverter<ResponseString>
    {
        public override ResponseString Read(
            ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.String)
                return new ResponseString(reader.GetString());
            reader.Skip();
            return new ResponseString(null);
        }

        public override void Write(Utf8JsonWriter writer, ResponseString value, JsonSerializerOptions options) =>
            throw new NotSupportedException();
    }
}
