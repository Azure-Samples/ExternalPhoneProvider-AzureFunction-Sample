using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Epp.Otp.Providers;

public sealed class SinchProvider : PhoneProviderBase
{
    private readonly ISecretResolver? _secrets;

    public SinchProvider(ISecretResolver? secrets = null) => _secrets = secrets;

    public override string Name => "sinch";
    public override string AuthenticationMode => "apiKey";

    public override Task<ProviderResult> SendOtpAsync(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credentials,
        IEnv env, HttpClient client, int timeoutMs, ILogger? logger = null) =>
        SendJsonAsync<Response>(
            () => CreateRequest(channel, endpoint, delivery, credentials, env),
            MapResponse,
            client,
            timeoutMs,
            logger);

    private static HttpRequestMessage CreateRequest(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credential, IEnv env)
    {
        var reference = delivery.CorrelationId ?? delivery.MessageId;
        object body;
        string url;

        if (channel == "voice")
        {
            var voiceBase = env.Get("SINCH_VOICE_ENDPOINT") ?? "https://calling.api.sinch.com";
            body = new VoiceRequest(
                "ttsCallout",
                new TtsCallout(
                    new Destination("number", delivery.PhoneNumber),
                    delivery.Message,
                    delivery.Locale ?? "en-US",
                    reference));
            url = $"{voiceBase}/calling/v1/callouts";
        }
        else
        {
            var servicePlanId = env.Get("SINCH_SERVICE_PLAN_ID") ?? string.Empty;
            body = new SmsRequest(
                env.Get("EPP_PROVIDER_ACCOUNT_NAME") ?? "Verify",
                [delivery.PhoneNumber],
                delivery.Message,
                reference);
            url = $"{endpoint}/xms/v1/{servicePlanId}/batches";
        }

        var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.TryAddWithoutValidation("Authorization", "******");
        request.Headers.Accept.ParseAdd("application/json");
        return request;
    }

    private static ProviderResult MapResponse(Response? payload, HttpStatusCode httpStatus)
    {
        var id = payload?.Id ?? payload?.CallId;
        var status = payload?.Status?.Value;
        var successful = (int)httpStatus is >= 200 and < 300;
        if (payload?.Status is null && successful && !string.IsNullOrWhiteSpace(id))
            status = "Dispatched";
        var (outcome, recognized) = MapStatus(status);
        return new ProviderResult(
            successful && !string.IsNullOrWhiteSpace(id) ? outcome : Outcome.Fail,
            recognized,
            (int)httpStatus,
            id,
            status,
            ProviderStatusDescription: payload?.Text);
    }

    public override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        if (_secrets is null) throw CredentialTokenService.Unavailable();
        var secret = await _secrets.ResolveAsync(
            "sinch-api-token", cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(secret)) throw CredentialTokenService.Unavailable();
        return new ProviderCredentials(
            AuthenticationMode,
            Secret: secret,
            ExpiresOn: DateTimeOffset.UtcNow.AddMinutes(5));
    }

    private static (Outcome Outcome, bool Recognized) MapStatus(string? status) => status switch
    {
        "Dispatched" or "Delivered" or "Queued" => (Outcome.Continue, true),
        "Failed" or "Rejected" => (Outcome.Fail, true),
        _ => (Outcome.Fail, false),
    };

    private sealed record VoiceRequest(
        [property: JsonPropertyName("method")] string Method,
        [property: JsonPropertyName("ttsCallout")] TtsCallout Callout);

    private sealed record TtsCallout(
        [property: JsonPropertyName("destination")] Destination Destination,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("locale")] string Locale,
        [property: JsonPropertyName("custom")] string Custom);

    private sealed record Destination(
        [property: JsonPropertyName("type")] string Type,
        [property: JsonPropertyName("endpoint")] string Endpoint);

    private sealed record SmsRequest(
        [property: JsonPropertyName("from")] string From,
        [property: JsonPropertyName("to")] IReadOnlyList<string> To,
        [property: JsonPropertyName("body")] string? Body,
        [property: JsonPropertyName("client_reference")] string ClientReference);

    private sealed record Response(
        [property: JsonPropertyName("id")] string? Id,
        [property: JsonPropertyName("callId")] string? CallId,
        [property: JsonPropertyName("text")] string? Text,
        [property: JsonPropertyName("status")] ResponseString? Status);

    [JsonConverter(typeof(ResponseStringConverter))]
    private sealed record ResponseString(string? Value);

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
