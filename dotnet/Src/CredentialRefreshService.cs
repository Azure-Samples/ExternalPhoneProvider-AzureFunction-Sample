using Microsoft.Extensions.Hosting;

namespace Epp.Otp;

internal sealed class CredentialRefreshService(DispatchEngine engine) : IHostedService
{
    public Task StartAsync(CancellationToken cancellationToken) => engine.StartCredentialRefreshAsync(cancellationToken);

    public Task StopAsync(CancellationToken cancellationToken)
    {
        engine.Dispose();
        return Task.CompletedTask;
    }
}
