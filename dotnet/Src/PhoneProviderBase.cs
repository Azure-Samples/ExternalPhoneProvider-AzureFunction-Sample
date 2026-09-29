using System.Net;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Epp.Otp;

public abstract class PhoneProviderBase
{
    public abstract string Name { get; }
    public abstract string AuthenticationMode { get; }

    public abstract Task<ProviderResult> SendOtpAsync(
        string channel,
        string endpoint,
        OtpDelivery delivery,
        ProviderCredentials credentials,
        IEnv env,
        HttpClient client,
        int timeoutMs,
        RequestLog? log = null);

    public abstract HttpRequestMessage CreateRequest(
        string channel,
        string endpoint,
        OtpDelivery delivery,
        ProviderCredentials credentials,
        IEnv env);

    public abstract Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config,
        CancellationToken cancellationToken = default);

    protected async Task<ProviderResult> SendJsonAsync<TResponse>(
        Func<HttpRequestMessage> createRequest,
        Func<TResponse?, HttpStatusCode, ProviderResult> mapResponse,
        HttpClient client,
        int timeoutMs,
        RequestLog? log)
    {
        ProviderSendException Failure(int status, string stage, string reason)
        {
            log?.Failure(stage, reason, status);
            return new ProviderSendException(status);
        }

        var stage = "provider_request_build";
        try
        {
            log?.Service("provider_request_build_started");
            using var request = createRequest();
            if (request.RequestUri is null || !IsHttpsEndpoint(request.RequestUri.AbsoluteUri))
                throw Failure(502, stage, "invalid_provider_request_url");
            log?.ProviderRequestBuilt(request.Method, request.RequestUri);

            stage = "provider_transport";
            ProviderResult? result = null;
            var validJson = true;
            using var cts = new CancellationTokenSource(timeoutMs);
            log?.ProviderRequestStarted(timeoutMs);
            try
            {
                using var response = await client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cts.Token).ConfigureAwait(false);
                log?.ProviderResponseReceived((int)response.StatusCode);
                var bytes = await response.Content.ReadAsByteArrayAsync(cts.Token).ConfigureAwait(false);
                try
                {
                    var body = JsonSerializer.Deserialize<TResponse>(
                        bytes,
                        new JsonSerializerOptions(JsonSerializerDefaults.Web));
                    result = mapResponse(body, response.StatusCode);
                }
                catch (JsonException)
                {
                    try
                    {
                        using var _ = JsonDocument.Parse(bytes);
                    }
                    catch (JsonException)
                    {
                        result = new ProviderResult(
                            Outcome.Fail,
                            false,
                            (int)response.StatusCode);
                        validJson = false;
                    }

                    if (validJson)
                        throw Failure(502, "provider_response", "response_parse_failed");
                }
                catch (OperationCanceledException)
                {
                    throw;
                }
                catch
                {
                    throw Failure(502, "provider_response", "response_parse_failed");
                }
            }
            finally
            {
                log?.ProviderRequestFinished();
            }

            if (!validJson)
                log?.Service("provider_response_invalid_json", level: LogLevel.Warning);
            var httpStatus = ToEndpointHttpStatus(result!);
            log?.ProviderResponseProcessed(result!, httpStatus, validJson);
            return result!;
        }
        catch (OperationCanceledException)
        {
            throw Failure(504, stage, "provider_timeout");
        }
        catch (ProviderSendException)
        {
            throw;
        }
        catch
        {
            var reason = stage == "provider_request_build"
                ? "request_build_failed"
                : "provider_network_error";
            throw Failure(502, stage, reason);
        }
    }

    internal static bool IsHttpsEndpoint(string? endpoint) =>
        Uri.TryCreate(endpoint, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps
        && !string.IsNullOrEmpty(uri.Host)
        && uri.Port > 0
        && string.IsNullOrEmpty(uri.UserInfo)
        && string.IsNullOrEmpty(uri.Fragment);

    internal static int ToEndpointHttpStatus(ProviderResult result) => result.Outcome switch
    {
        Outcome.Continue => 200,
        Outcome.Block => 403,
        Outcome.Fail when result.ProviderHttpStatus == 429 => 429,
        Outcome.Fail when result.ProviderHttpStatus is 401 or 403 => 401,
        Outcome.Fail when result.ProviderHttpStatus >= 400 && result.ProviderHttpStatus < 500 => 400,
        _ => 502,
    };

    internal sealed class ProviderSendException(int statusCode) : Exception
    {
        public int StatusCode { get; } = statusCode;
    }
}
