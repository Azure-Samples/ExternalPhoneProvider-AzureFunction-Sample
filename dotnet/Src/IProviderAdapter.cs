using System.Text.Json;

namespace Epp.Otp;

public interface IProviderAdapter
{
    ProviderManifest Manifest { get; }

    Task<string?> AcquireTokenAsync(IEnv env) => Task.FromResult<string?>(null);

    ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env);

    ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json);
}
