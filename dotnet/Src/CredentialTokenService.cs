using System.Text.RegularExpressions;

namespace Epp.Otp;

public sealed class CredentialTokenService
{
    internal static readonly TimeSpan AcquisitionTimeout = TimeSpan.FromSeconds(2.5);

    public async Task<ProviderCredentials> GetCredentialsAsync(
        PhoneProviderBase provider,
        AppConfig config,
        CancellationToken cancellationToken = default)
    {
        using var acquisition = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        acquisition.CancelAfter(AcquisitionTimeout);
        try
        {
            acquisition.Token.ThrowIfCancellationRequested();
            if (provider.AuthenticationMode is not ("apiKey" or "oauth"))
                throw Unavailable();
            var credentials = await provider.FetchCredentialsAsync(config, acquisition.Token)
                .WaitAsync(acquisition.Token).ConfigureAwait(false);
            return credentials ?? throw Unavailable();
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error)
        {
            // Retain only the numeric AADSTS identifier, never the SDK exception or response.
            throw Unavailable(error);
        }
    }

    internal static string? AadstsCode(Exception? error)
    {
        var match = Regex.Match(error?.Message ?? "", @"\bAADSTS[0-9]+\b");
        return match.Success ? match.Value : null;
    }

    internal static InvalidOperationException Unavailable(Exception? error = null) =>
        new(AadstsCode(error) ?? "provider credential unavailable");
}
