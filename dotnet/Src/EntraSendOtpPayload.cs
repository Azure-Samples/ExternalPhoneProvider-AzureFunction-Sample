using System.Text.Json.Serialization;

namespace Epp.Otp;

[JsonConverter(typeof(JsonStringEnumConverter<EntraOtpChannel>))]
public enum EntraOtpChannel
{
    Sms = 1,
    Voice = 2,
}

[JsonConverter(typeof(JsonStringEnumConverter<EntraOtpMode>))]
public enum EntraOtpMode
{
    Live = 1,
    Evaluation = 2,
}

public sealed record EntraSendOtpPayload
{
    public const string SupportedType = "microsoft.mfa.otpDeliver.v1";

    [JsonPropertyName("type")]
    public string? Type { get; init; }

    [JsonPropertyName("tenantId")]
    public string? TenantId { get; init; }

    [JsonPropertyName("correlationId")]
    public string? CorrelationId { get; init; }

    [JsonPropertyName("channel")]
    public EntraOtpChannel Channel { get; init; }

    [JsonPropertyName("mode")]
    public EntraOtpMode Mode { get; init; }

    [JsonPropertyName("ttlSeconds")]
    public int? TtlSeconds { get; init; }

    [JsonPropertyName("encryptedDeliveryContext")]
    public string? EncryptedDeliveryContext { get; init; }

    [JsonIgnore]
    public string ChannelName => Channel == EntraOtpChannel.Voice ? "voice" : "sms";

    [JsonIgnore]
    public bool IsEvaluation => Mode == EntraOtpMode.Evaluation;

    public string? Validate()
    {
        if (Type != SupportedType) return "unsupported payload type";
        if (string.IsNullOrWhiteSpace(EncryptedDeliveryContext))
            return "encryptedDeliveryContext is required";
        if (Channel is not (EntraOtpChannel.Sms or EntraOtpChannel.Voice))
            return "unsupported channel";
        if (Mode is not (EntraOtpMode.Live or EntraOtpMode.Evaluation))
            return "unsupported mode";
        if (TtlSeconds <= 0) return "ttlSeconds expired";
        return null;
    }
}
