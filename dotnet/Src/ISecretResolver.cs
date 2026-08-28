namespace Epp.Otp;

// Seam over Key Vault so the engine can be unit-tested with a fake.
public interface ISecretResolver
{
    Task<string> ResolveAsync(string? secretName);
}
