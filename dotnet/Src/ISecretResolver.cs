namespace Epp.Otp;

// Abstraction over Key Vault secret retrieval.
public interface ISecretResolver
{
    Task<string> ResolveAsync(string? secretName);
}
