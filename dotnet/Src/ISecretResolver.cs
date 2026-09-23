namespace Epp.Otp;

public interface ISecretResolver
{
    Task<string> ResolveAsync(string? secretName, CancellationToken cancellationToken = default);
}
