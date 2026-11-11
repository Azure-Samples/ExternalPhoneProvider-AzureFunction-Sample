namespace Epp.Otp;

internal static class VoiceMessage
{
    public static string Build(string message, string? otp)
    {
        var pacedMessage = string.IsNullOrEmpty(otp) ? message
            : message.Replace(otp, string.Join(", ", otp.ToCharArray()), StringComparison.Ordinal);
        return $"{pacedMessage} {pacedMessage}";
    }
}
