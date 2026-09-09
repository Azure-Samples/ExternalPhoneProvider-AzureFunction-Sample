namespace Epp.Otp;

// Maps a provider status to an outcome, then to an HTTP status. Fail-closed: unknown status is Fail.
public static class OutcomeMapper
{
    public static readonly string[] DefaultChannels = { "sms", "voice" };

    public static Outcome ResolveOutcome(ProviderManifest manifest, ParsedResponse parsed)
    {
        var key = parsed.ProviderStatusName ?? parsed.ProviderStatusCode;
        Outcome outcome;
        if (!string.IsNullOrEmpty(key))
        {
            outcome = manifest.ResponseMapping.TryGetValue(key, out var mapped) ? mapped
                : manifest.ResponseMapping.TryGetValue("default", out var defaultOutcome) ? defaultOutcome : Outcome.Fail;
        }
        else
        {
            outcome = parsed.Success ? Outcome.Continue
                : manifest.ResponseMapping.TryGetValue("default", out var fallbackOutcome) ? fallbackOutcome : Outcome.Fail;
        }
        // A success-shaped body cannot turn a failed HTTP request into an acknowledgement.
        return outcome == Outcome.Continue && !parsed.Success ? Outcome.Fail : outcome;
    }

    public static int ToHttpStatus(Outcome outcome, int providerHttpStatus) => outcome switch
    {
        Outcome.Continue => 200,
        Outcome.Block => 403,
        Outcome.StepUp => 409,
        Outcome.Fail when providerHttpStatus == 429 => 429,
        Outcome.Fail when providerHttpStatus is 401 or 403 => 401,
        Outcome.Fail when providerHttpStatus >= 400 && providerHttpStatus < 500 => 400,
        _ => 502,
    };
}
