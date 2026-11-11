using System.Text.RegularExpressions;

namespace Epp.Otp;

internal static class VoiceMessage
{
    private static readonly Regex PasscodePattern = new(
        @"(?<![0-9])[0-9]{6}(?![0-9])",
        RegexOptions.CultureInvariant);

    public static string Build(string message)
    {
        var pacedMessage = PasscodePattern.Replace(
            message,
            match => string.Join(", ", match.Value.ToCharArray()));
        return $"{pacedMessage} {pacedMessage}";
    }
}
