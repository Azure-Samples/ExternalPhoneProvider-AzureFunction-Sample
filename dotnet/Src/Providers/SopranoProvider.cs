using Azure.Core;
using Azure.Identity;
using System.Globalization;
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;

namespace Epp.Otp.Providers;

public sealed class SopranoProvider : PhoneProviderBase
{
    private const string DefaultVoiceLanguage = "en-US";
    private const int VoiceGender = 1;
    private const int VoiceLoop = 2;
    private static readonly TimeSpan ExpirySkew = TimeSpan.FromSeconds(30);
    private readonly object _credentialGate = new();
    private readonly Func<string, TokenCredential> _createIdentity;
    private readonly Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> _createCredential;
    private TokenCredential? _identity;
    private TokenCredential? _credential;
    private string? _scope;

    public SopranoProvider()
        : this(
            identity => new ManagedIdentityCredential(identity, OAuthOptions()),
            (tenant, application, assertion) =>
                new ClientAssertionCredential(tenant, application, assertion, OAuthOptions()))
    {
    }

    internal SopranoProvider(
        Func<string, TokenCredential> createIdentity,
        Func<string, string, Func<CancellationToken, Task<string>>, TokenCredential> createCredential)
    {
        _createIdentity = createIdentity;
        _createCredential = createCredential;
    }

    public override string Name => "soprano";
    public override string AuthenticationMode => "oauth";

    public override Task<ProviderResult> SendOtpAsync(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credentials,
        IEnv env, HttpClient client, int timeoutMs, ILogger? logger = null) =>
        SendJsonAsync<ResponseBody>(
            () => CreateRequest(channel, endpoint, delivery, credentials, env),
            MapResponse,
            client,
            timeoutMs,
            logger);

    private static HttpRequestMessage CreateRequest(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credential, IEnv env)
    {
        Voice? voice = null;
        string? text = null;
        if (channel == "voice")
        {
            var message = delivery.Message ?? string.Empty;
            var passcode = Regex.Match(message, "[0-9]{6}");
            if (!passcode.Success)
                throw new InvalidOperationException("voice message does not contain a six-digit passcode");
            voice = new Voice(new TextToVoiceRequest(
                message[..passcode.Index],
                passcode.Value,
                message[(passcode.Index + passcode.Length)..],
                string.IsNullOrWhiteSpace(delivery.Locale) ? DefaultVoiceLanguage : delivery.Locale,
                VoiceGender,
                VoiceLoop));
        }
        else
        {
            text = delivery.Message;
        }

        var body = new Request(
            delivery.PhoneNumber.TrimStart('+'),
            [channel == "voice" ? "voice" : "sms"],
            delivery.CorrelationId ?? delivery.MessageId,
            false,
            voice,
            text);
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(body),
        };
        request.Headers.Accept.ParseAdd("application/json");
        request.Headers.Authorization = new("Bearer", credential.AccessToken);
        return request;
    }

    private static ProviderResult MapResponse(ResponseBody? responseBody, HttpStatusCode httpStatus)
    {
        var payload = responseBody?.Payload;
        var status = payload?.Status is null
            ? payload?.State?.Value
            : payload.Status.Value;
        status = string.IsNullOrWhiteSpace(status) ? "UNKNOWN" : status.ToUpperInvariant();
        var (outcome, recognized) = MapStatus(status);
        return new ProviderResult(
            (int)httpStatus is >= 200 and < 300 ? outcome : Outcome.Fail,
            recognized,
            (int)httpStatus,
            payload?.Id?.Value ?? payload?.MessageId?.Value,
            status);
    }

    public override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        ConfigureCredentials(config);
        await GetAssertionAsync(cancellationToken).ConfigureAwait(false);
        var token = CheckToken(await _credential!.GetTokenAsync(
            new TokenRequestContext([_scope!]),
            cancellationToken).ConfigureAwait(false));
        return new ProviderCredentials(
            AuthenticationMode,
            AccessToken: token.Token,
            ExpiresOn: token.ExpiresOn - ExpirySkew);
    }

    private void ConfigureCredentials(AppConfig config)
    {
        lock (_credentialGate)
        {
            if (_credential is not null) return;
            if (string.IsNullOrWhiteSpace(config.ProviderTenantId)
                || string.IsNullOrWhiteSpace(config.ProviderScope)
                || string.IsNullOrWhiteSpace(config.OutboundClientId)
                || string.IsNullOrWhiteSpace(config.OutboundManagedIdentityClientId))
                throw CredentialTokenService.Unavailable();
            _scope = config.ProviderScope;
            _identity = _createIdentity(config.OutboundManagedIdentityClientId);
            _credential = _createCredential(
                config.ProviderTenantId,
                config.OutboundClientId,
                async cancellation => (await GetAssertionAsync(cancellation).ConfigureAwait(false)).Token);
        }
    }

    private async Task<AccessToken> GetAssertionAsync(CancellationToken cancellationToken) =>
        CheckToken(await _identity!.GetTokenAsync(
            new TokenRequestContext(["api://AzureADTokenExchange/.default"]),
            cancellationToken).ConfigureAwait(false));

    private static AccessToken CheckToken(AccessToken token)
    {
        if (string.IsNullOrWhiteSpace(token.Token)
            || token.ExpiresOn <= DateTimeOffset.UtcNow + ExpirySkew)
            throw CredentialTokenService.Unavailable();
        return token;
    }

    private static ClientAssertionCredentialOptions OAuthOptions()
    {
        var options = new ClientAssertionCredentialOptions
        {
            AuthorityHost = AzureAuthorityHosts.AzurePublicCloud,
            Retry =
            {
                MaxRetries = 0,
                NetworkTimeout = CredentialTokenService.AcquisitionTimeout,
            },
            Diagnostics =
            {
                IsLoggingEnabled = false,
                IsLoggingContentEnabled = false,
            },
        };
        return options;
    }

    private static (Outcome Outcome, bool Recognized) MapStatus(string? status) => status switch
    {
        "ENROUTE" or "ACCEPTED" or "SUBMITTED" or "SENT" or "DELIVERED" or "QUEUED"
            => (Outcome.Continue, true),
        "BLOCKED" => (Outcome.Block, true),
        "FAILED" or "REJECTED" or "FILTERED" => (Outcome.Fail, true),
        _ => (Outcome.Fail, false),
    };

    private sealed record Request(
        [property: JsonPropertyName("destination")] string Destination,
        [property: JsonPropertyName("messageTypes")] IReadOnlyList<string> MessageTypes,
        [property: JsonPropertyName("correlationId")] string CorrelationId,
        [property: JsonPropertyName("shutterMode")] bool ShutterMode,
        [property: JsonPropertyName("voice"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] Voice? Voice,
        [property: JsonPropertyName("text"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Text);

    private sealed record Voice(
        [property: JsonPropertyName("text2voice")] TextToVoiceRequest TextToVoice);

    private sealed record TextToVoiceRequest(
        [property: JsonPropertyName("beforePasswordText")] string BeforePasswordText,
        [property: JsonPropertyName("password")] string Password,
        [property: JsonPropertyName("afterPasswordText")] string AfterPasswordText,
        [property: JsonPropertyName("language")] string Language,
        [property: JsonPropertyName("gender")] int Gender,
        [property: JsonPropertyName("loop")] int Loop);

    [JsonConverter(typeof(ResponseBodyConverter))]
    private sealed record ResponseBody(Response? Payload);

    private sealed record Response(
        [property: JsonPropertyName("id")] StringOrNumber? Id,
        [property: JsonPropertyName("messageId")] StringOrNumber? MessageId,
        [property: JsonPropertyName("status")] ResponseString? Status,
        [property: JsonPropertyName("state")] ResponseString? State);

    [JsonConverter(typeof(StringOrNumberConverter))]
    private sealed record StringOrNumber(string? Value);

    [JsonConverter(typeof(ResponseStringConverter))]
    private sealed record ResponseString(string? Value);

    private sealed class ResponseBodyConverter : JsonConverter<ResponseBody>
    {
        public override ResponseBody Read(
            ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.StartObject)
                return new ResponseBody(JsonSerializer.Deserialize<Response>(ref reader, options));

            if (reader.TokenType != JsonTokenType.StartArray)
            {
                reader.Skip();
                return new ResponseBody(null);
            }

            if (!reader.Read() || reader.TokenType == JsonTokenType.EndArray)
                return new ResponseBody(null);

            Response? payload = null;
            if (reader.TokenType == JsonTokenType.StartObject)
                payload = JsonSerializer.Deserialize<Response>(ref reader, options);
            else
                reader.Skip();

            while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
                reader.Skip();
            return new ResponseBody(payload);
        }

        public override void Write(Utf8JsonWriter writer, ResponseBody value, JsonSerializerOptions options) =>
            throw new NotSupportedException();
    }

    private sealed class StringOrNumberConverter : JsonConverter<StringOrNumber>
    {
        public override StringOrNumber Read(
            ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        {
            if (reader.TokenType == JsonTokenType.String)
                return new StringOrNumber(reader.GetString());
            if (reader.TokenType == JsonTokenType.Number && reader.TryGetInt64(out var number))
                return new StringOrNumber(number.ToString(CultureInfo.InvariantCulture));
            reader.Skip();
            return new StringOrNumber(null);
        }

        public override void Write(Utf8JsonWriter writer, StringOrNumber value, JsonSerializerOptions options) =>
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
