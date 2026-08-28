namespace Epp.Otp;

// Maps a provider status to an outcome, then to an HTTP status. Fail-closed: unknown status is Fail.
public static class OutcomeMapper
{
    public static readonly string[] DefaultChannels = { "sms", "voice" };

    public static Outcome ResolveOutcome(ProviderManifest manifest, ParsedResponse parsed)
    {
        var key = parsed.ProviderStatusName ?? parsed.ProviderStatusCode;
        if (!string.IsNullOrEmpty(key))
        {
            if (manifest.ResponseMapping.TryGetValue(key, out var mapped)) return mapped;
            return manifest.ResponseMapping.TryGetValue("default", out var defaultOutcome) ? defaultOutcome : Outcome.Fail;
        }
        if (parsed.Success) return Outcome.Continue;
        return manifest.ResponseMapping.TryGetValue("default", out var fallbackOutcome) ? fallbackOutcome : Outcome.Fail;
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
