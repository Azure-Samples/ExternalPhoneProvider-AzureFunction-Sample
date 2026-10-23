using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Identity.Client;

namespace Epp.Otp;

internal enum CredentialStage { Unknown, Configuration, ManagedIdentity, ProviderTokenExchange, KeyVault }
internal enum CredentialFailureKind
{
    Unavailable, ConfigurationInvalid, Timeout, Cancelled,
    MissingFederation, MismatchedFederation, ProviderApplicationNotFound,
}

internal sealed class CredentialResolutionException(
    CredentialStage stage,
    CredentialFailureKind failure = CredentialFailureKind.Unavailable,
    string? aadstsCode = null) : InvalidOperationException("provider credential unavailable")
{
    private static readonly Regex CodePattern = new(@"\bAADSTS(70025|70021|700016)\b",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    internal string CredentialStage { get; } = stage switch
    {
        Epp.Otp.CredentialStage.Configuration => "configuration",
        Epp.Otp.CredentialStage.ManagedIdentity => "managed_identity",
        Epp.Otp.CredentialStage.ProviderTokenExchange => "provider_token_exchange",
        Epp.Otp.CredentialStage.KeyVault => "key_vault",
        _ => "unknown",
    };
    internal string CredentialFailure { get; } = failure switch
    {
        CredentialFailureKind.ConfigurationInvalid => "configuration_invalid",
        CredentialFailureKind.Timeout => "timeout",
        CredentialFailureKind.Cancelled => "cancelled",
        CredentialFailureKind.MissingFederation => "federated_credential_missing",
        CredentialFailureKind.MismatchedFederation => "federated_credential_mismatch",
        CredentialFailureKind.ProviderApplicationNotFound => "provider_application_not_found",
        _ => "credential_unavailable",
    };
    internal string? AadstsCode { get; } = KnownCode(aadstsCode);

    internal static CredentialResolutionException From(
        Exception? error, CredentialStage stage = Epp.Otp.CredentialStage.Unknown)
    {
        var pending = new Queue<Exception>();
        if (error is not null) pending.Enqueue(error);
        var seen = new HashSet<Exception>();
        string? code = null;
        string? messageCode = null;
        var failure = CredentialFailureKind.Unavailable;
        for (var count = 0; pending.Count > 0 && count < 8; count++)
        {
            var current = pending.Dequeue();
            if (!seen.Add(current)) continue;
            if (current is CredentialResolutionException classified) return classified;
            code ??= ReadStructuredCode(current);
            if (messageCode is null)
            {
                var message = current.Message;
                var match = CodePattern.Match(message[..Math.Min(message.Length, 8192)]);
                if (match.Success) messageCode = match.Groups[1].Value;
            }
            if (current is TimeoutException) failure = CredentialFailureKind.Timeout;
            else if (current is OperationCanceledException && failure != CredentialFailureKind.Timeout)
                failure = CredentialFailureKind.Cancelled;
            if (current is AggregateException aggregate)
                foreach (var inner in aggregate.InnerExceptions.Take(8)) pending.Enqueue(inner);
            else if (current.InnerException is { } inner) pending.Enqueue(inner);
        }
        code ??= messageCode;
        if (stage == Epp.Otp.CredentialStage.Configuration) failure = CredentialFailureKind.ConfigurationInvalid;
        else if (stage == Epp.Otp.CredentialStage.ProviderTokenExchange && code is not null)
            failure = code switch
            {
                "70025" => CredentialFailureKind.MissingFederation,
                "70021" => CredentialFailureKind.MismatchedFederation,
                _ => CredentialFailureKind.ProviderApplicationNotFound,
            };
        // Do not retain the SDK exception as InnerException or attach its response/body to Data.
        return new(stage, failure, code);
    }

    private static string? KnownCode(string? value) => value is "70025" or "70021" or "700016" ? value : null;

    private static string? ReadStructuredCode(Exception error)
    {
        if (error is MsalServiceException { ResponseBody: { Length: > 0 and <= 8192 } body })
        {
            try
            {
                using var document = JsonDocument.Parse(body);
                if (document.RootElement.ValueKind == JsonValueKind.Object
                    && document.RootElement.TryGetProperty("error_codes", out var codes)
                    && codes.ValueKind == JsonValueKind.Array)
                {
                    foreach (var value in codes.EnumerateArray().Take(8))
                        if (KnownCode(value.ToString()) is { } code) return code;
                }
            }
            catch (JsonException) { /* A malformed SDK error body may still have an AADSTS code in Message. */ }
        }
        return null;
    }
}

internal sealed class CredentialAcquisition : IDisposable
{
    private static readonly AsyncLocal<CredentialAcquisition?> Current = new();
    private readonly CredentialAcquisition? _previous = Current.Value;
    internal CredentialStage Stage { get; private set; } = CredentialStage.Configuration;

    internal CredentialAcquisition() => Current.Value = this;

    internal static void SetStage(CredentialStage stage)
    {
        if (Current.Value is { } current) current.Stage = stage;
    }

    public void Dispose() => Current.Value = _previous;
}
