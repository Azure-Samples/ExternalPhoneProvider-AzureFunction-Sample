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
        using var context = new CredentialAcquisition();
        acquisition.CancelAfter(AcquisitionTimeout);
        try
        {
            acquisition.Token.ThrowIfCancellationRequested();
            if (provider.AuthenticationMode is not ("apiKey" or "oauth"))
                throw Unavailable();
            if (provider.AuthenticationMode == "apiKey") CredentialAcquisition.SetStage(CredentialStage.KeyVault);
            var credentials = await provider.FetchCredentialsAsync(config, acquisition.Token)
                .WaitAsync(acquisition.Token).ConfigureAwait(false);
            return credentials ?? throw Unavailable();
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested)
        {
            throw new OperationCanceledException(cancellationToken);
        }
        catch (Exception) when (acquisition.IsCancellationRequested)
        {
            throw new CredentialResolutionException(context.Stage, CredentialFailureKind.Timeout);
        }
        catch (Exception error)
        {
            throw CredentialResolutionException.From(error, context.Stage);
        }
    }

    internal static InvalidOperationException Unavailable() =>
        new("provider credential unavailable");
}
