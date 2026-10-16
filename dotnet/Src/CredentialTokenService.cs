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
        catch
        {
            // SendOtp logs the request failure without exposing SDK error details.
            throw Unavailable();
        }
    }

    internal static InvalidOperationException Unavailable() =>
        new("provider credential unavailable");
}
