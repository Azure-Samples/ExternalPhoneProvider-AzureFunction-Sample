using System.Text.Json;

namespace Epp.Otp;

// A provider is one adapter: manifest (protocol facts) + build/parse. Onboarding = add one class.
public interface IProviderAdapter
{
    ProviderManifest Manifest { get; }

    ProviderHttpRequest BuildRequest(string channel, string endpoint, DispatchRequest dispatch, ProviderCredential credential, IEnv env);

    ParsedResponse ParseResponse(int httpStatus, bool ok, JsonElement json);
}
