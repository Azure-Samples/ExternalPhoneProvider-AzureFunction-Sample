using System.Net;
using System.Diagnostics;
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
        ILogger? logger = null);

    public abstract Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config,
        CancellationToken cancellationToken = default);

    protected async Task<ProviderResult> SendJsonAsync<TResponse>(
        Func<HttpRequestMessage> createRequest,
        Func<TResponse?, HttpStatusCode, ProviderResult> mapResponse,
        HttpClient client,
        int timeoutMs,
        ILogger? logger)
    {
        ProviderSendException Failure(int status, string stage, string reason)
        {
            if (logger is not null)
                OtpLog.RequestFailed(
                    logger,
                    status >= 500 ? LogLevel.Error : LogLevel.Warning,
                    stage,
                    reason,
                    status);
            return new ProviderSendException(status);
        }

        var stage = "provider_request_build";
        try
        {
            if (logger is not null) OtpLog.ProviderRequestBuildStarted(logger);
            using var request = createRequest();
            if (request.RequestUri is null || !IsHttpsEndpoint(request.RequestUri.AbsoluteUri))
                throw Failure(502, stage, "invalid_provider_request_url");
            if (logger is not null)
            {
                var method = NormalizeHttpMethod(request.Method);
                var endpoint = SanitizeEndpoint(request.RequestUri);
                OtpLog.ProviderRequestBuilt(logger, method, endpoint);
            }

            stage = "provider_transport";
            ProviderResult? result = null;
            var validJson = true;
            using var cts = new CancellationTokenSource(timeoutMs);
            var providerStarted = Stopwatch.StartNew();
            if (logger is not null) OtpLog.ProviderRequestStarted(logger, timeoutMs);
            try
            {
                using var response = await client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cts.Token).ConfigureAwait(false);
                if (logger is not null)
                    OtpLog.ProviderResponseReceived(logger, (int)response.StatusCode);
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
                            (int)response.StatusCode)
                        {
                            FailureReason = "invalid_provider_json",
                        };
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
            finally { providerStarted.Stop(); }

            if (!validJson)
                if (logger is not null) OtpLog.ProviderResponseInvalidJson(logger);
            var httpStatus = ToEndpointHttpStatus(result!);
            if (logger is not null)
            {
                var status = result!.StatusRecognized
                    ? result.ProviderStatusName ?? result.ProviderStatusCode ?? "unmapped"
                    : "unmapped";
                OtpLog.ProviderResponseProcessed(
                    logger,
                    httpStatus >= 500 ? LogLevel.Error
                        : httpStatus == 200 ? LogLevel.Information : LogLevel.Warning,
                    result.ProviderHttpStatus,
                    status,
                    result.Outcome.ToString(),
                    result.FailureReason,
                    providerStarted.ElapsedMilliseconds);
            }
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

    internal static string SanitizeEndpoint(Uri endpoint) =>
        endpoint.GetComponents(UriComponents.SchemeAndServer, UriFormat.UriEscaped)
        + endpoint.AbsolutePath;

    private static string NormalizeHttpMethod(HttpMethod? method)
    {
        var value = method?.Method.ToUpperInvariant();
        return value is "GET" or "HEAD" or "POST" or "PUT" or "DELETE"
            or "CONNECT" or "OPTIONS" or "TRACE" or "PATCH" ? value : "other";
    }

    internal static int ToEndpointHttpStatus(ProviderResult result) => result.Outcome switch
    {
        Outcome.Continue => 200,
        Outcome.Block => 403,
        Outcome.Fail when result.ProviderHttpStatus == 429 => 429,
        Outcome.Fail when result.ProviderHttpStatus is 401 or 403 => 401,
        Outcome.Fail when result.ProviderHttpStatus >= 400 && result.ProviderHttpStatus < 500 => 400,
        _ => 502,
    };

    protected static string? ClassifyFailure(
        HttpStatusCode httpStatus,
        Outcome outcome,
        bool statusRecognized)
    {
        if ((int)httpStatus is < 200 or >= 300)
            return "provider_http_error";
        if (outcome != Outcome.Fail)
            return null;
        return statusRecognized
            ? "provider_rejected"
            : "unrecognized_provider_status";
    }

    internal sealed class ProviderSendException(int statusCode) : Exception
    {
        public int StatusCode { get; } = statusCode;
    }
}
