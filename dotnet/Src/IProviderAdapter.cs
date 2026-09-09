using System.Text.Json;

namespace Epp.Otp;

public interface IProviderAdapter
{
    ProviderManifest Manifest { get; }

    ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env);

    ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json);
}
