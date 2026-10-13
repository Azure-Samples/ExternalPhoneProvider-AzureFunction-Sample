# Bring your own phone provider: a Twilio adapter example

This developer guide shows how to extend **this sample's code** with a customer-owned
Twilio adapter for SMS and voice. Twilio is the requested illustrative example, not a
preferred provider, endorsement, or claim of Microsoft Entra External Phone Provider
(EPP) eligibility. The adapters below are **documentation examples**, not installed
runtime implementations or live-integration-tested packages.

Choose [JavaScript](#javascript), [C#](#c-net), or [Python](#python); implement and maintain
only that adapter in your own copy. The existing HTTP contract, caller authentication,
decryption, evaluation mode, and transport remain the foundation.

## Scope and prerequisites

The [guided setup catalog](../setup/providers/catalog.json) contains Telesign and Soprano,
not Twilio. The bundled runtime factories also have no `twilio` entry. Setting
`EPP_PROVIDER_NAME=twilio`, changing URLs, or obtaining a Twilio account **does not add
an adapter**. Do not select another provider in setup as a stand-in: its credentials,
provider tenant, authorization, and deployment profile are not Twilio's. Adding a catalog
entry alone is not sufficient either. This guide does not change setup, release packages,
or the provider catalog.

Before purchasing, deploying, or requesting activation, confirm provider eligibility and
the approved testing/activation procedure with Microsoft and your tenant administrator;
follow [access and support guidance](ONBOARDING.md#before-purchasing-or-deploying).
This guide does not establish Twilio's availability in Security Store or authorize tenant
activation. If access is unavailable, stop at offline development. There are no portal,
deployment, purchase, or live-send steps to run here.

For eventual approved integration, the customer owns the Twilio account, API credentials,
SMS-capable sender and voice caller ID, destination permissions, regional compatibility,
registration/consent obligations, costs, and credential rotation. Trial accounts have
recipient restrictions. A voice caller ID must be a Twilio number or an account-authorized
verified outgoing caller ID; an SMS sender must be valid for the destination and account.
The examples use one E.164 `From` number for both channels; separate senders require
explicit channel-specific configuration and validation.

## Preserve the Entra contract

Read the [HTTP contract](CONTRACT.md) before extending the sample:

- Entra generates and validates the OTP. The decrypted `message` is **already rendered
  and localized**. Send it unchanged for SMS. Do not replace it with a Twilio-generated
  code or a new message template. Twilio Verify's OTP generation/verification workflow
  is not the delivery adapter used here; use Programmable Messaging and Voice.
- Easy Auth must still authenticate and authorize the Microsoft caller before the
  anonymous Function handler. JWE encryption and nonce possession are not caller
  authentication. Never forward the inbound bearer token to Twilio.
- Incoming `channel` selects SMS or voice; server-owned configuration selects the
  provider/account/endpoints. Do not accept a provider, URL, account SID, vault, or sender
  from the caller's request.
- Keep incoming `mode: 2` / `"evaluation"` ahead of provider selection and credential
  acquisition. It validates/decrypts and echoes the nonce **without provider sends**.
  Credential prewarming/refresh may run independently when caching is enabled; it never
  sends an OTP. Evaluation alone does not prove adapter configuration or delivery.
- Only recognized provider acceptance permits the live handler's `200` and matching
  nonce. Failures omit the nonce. A Twilio resource SID is internal provider metadata,
  not the Entra nonce, and a correlation ID is not an idempotency key.

`OtpDelivery` includes the phone number, message, channel, message/correlation IDs and
locale. It does **not** carry `extension` or `riskContext`, although the decrypted context
has them. These examples do not implement office extensions, risk policy, recordings,
answering-machine detection, or callbacks. Supporting those features needs separate
contract/model changes and tests; do not silently claim they work.

## Wire format, authentication, and result policy

Official Twilio references, checked on October 13, 2026:
[API requests/authentication](https://www.twilio.com/docs/usage/requests-to-twilio),
[Messages](https://www.twilio.com/docs/messaging/api/message-resource),
[Calls](https://www.twilio.com/docs/voice/api/call-resource), and
[TwiML Say](https://www.twilio.com/docs/voice/twiml/say).
Recheck these references and account capabilities before using customer code.

Use HTTP Basic authentication with **API key SID as username and API key secret as
password**, over HTTPS. The account SID identifies the account in the URL; it is not
the API-key username. Twilio recommends API keys for applications; choose the narrowest
key permissions compatible with the required Messages/Calls operations. Account SID +
Auth Token is a different credential pair and is not used below. Credentials are
region-specific; these examples deliberately pin the standard `api.twilio.com` endpoint.
Other Twilio regions/edges require reviewed host allowlists and matching credentials,
not a caller-supplied URL.

Both operations are `POST`, with `Content-Type: application/x-www-form-urlencoded`
and `Accept: application/json`:

| Channel | Complete endpoint | Form fields |
| --- | --- | --- |
| SMS | `https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Messages.json` | `To`, `From`, `Body` (the original message) |
| Voice | `https://api.twilio.com/2010-04-01/Accounts/{AccountSid}/Calls.json` | `To`, `From`, `Twiml` (inline XML instructions) |

Use a form encoder, not string concatenation: a literal `+` must survive as a plus
in E.164 numbers, and `&`, `=`, Unicode, and XML must round-trip. The XML is a **form
field**, not the HTTP body's content type. Inline `Twiml` avoids a public OTP-bearing
webhook/`Url`; Twilio ignores `Twiml` if `Url` is also supplied, so do not add `Url`.
Keep generated TwiML within Twilio's 4,000-character limit.

Voice examples escape XML, comma-space standalone six-digit ASCII numeric runs
(preserving leading zeros), and speak the entire message twice with `<Say loop="2">`.
They use `voice="woman"` with `en-US` when locale is absent/blank and **reject other
voice locales**, rather than reading a localized message in the wrong language.
Extend an explicit locale/voice allowlist using Twilio's supported combinations and
test audio before enabling more locales. This illustrative six-digit pacing rule does
not assert a universal Entra code length; agree on supported message formats and test
non-six-digit codes as well. The examples also reject characters forbidden in XML 1.0
before submitting a voice call; escaping alone is not XML character validation.

The examples require HTTP **201 Created**, a correctly shaped resource SID, and a
recognized state. They accept SMS `queued`, `sending`, `sent`, `delivered`; voice
`queued`, `ringing`, `in-progress`, `completed`. Recognized failure states are SMS
`failed`, `undelivered`, `canceled`; voice `busy`, `failed`, `no-answer`, `canceled`.
Unknown/missing/malformed states or SIDs fail closed. Do not turn a non-201 response
into success because its JSON says `queued`. This is a deliberately narrow
**immediate-send, From-number policy**: Messaging Service `accepted` and scheduling
`scheduled` are not enabled. Supporting `MessagingServiceSid` requires a reviewed SMS
configuration/result-policy change, not just adding a success string.

Queued/accepted means submitted, not received. Even a completed call can have reached
voicemail or an IVR; it is not evidence the user heard the code. The adapter does not
wait/poll for handset delivery. Return the sample's `ProviderResult` and let its
existing outcome-to-HTTP mapping handle 401/403, 429, other 4xx, 502 and transport 504.
Do not invent `Block` from a generic Twilio error or expose raw `error_message` values.

## Customer configuration and Key Vault

After implementing and registering your adapter, configure these values in your
customer-managed deployment (all app-setting values are strings):

| Setting or secret | Value/purpose |
| --- | --- |
| `EPP_PROVIDER_NAME` | `twilio` **only after adding the factory/DI registration** |
| `EPP_PROVIDER_AUTH_MODE` | `apiKey`; the adapter implements Twilio Basic auth, not Bearer auth |
| `EPP_TWILIO_ACCOUNT_SID` | Account SID matching `AC` + 32 hexadecimal characters; a **new adapter-owned setting** |
| `EPP_TWILIO_FROM` | Approved E.164 sender/caller ID; a **new adapter-owned setting** |
| `EPP_PROVIDER_SMS_ENDPOINT` | Complete Messages URL above, containing that account SID |
| `EPP_PROVIDER_VOICE_ENDPOINT` | Complete Calls URL above, containing that account SID |
| `KEY_VAULT_URL` | Approved vault URL used by the sample's provider-secret resolver |
| `AZURE_CLIENT_ID` | Vault-reader user-assigned managed identity client ID, if used; otherwise system-assigned identity |
| Key Vault secret `twilio-api-key-sid` | API key SID (`SK` + 32 hexadecimal characters), returned as credential `identity` |
| Key Vault secret `twilio-api-key-secret` | API key secret, returned as credential `secret` |
| `EPP_KEY_VAULT_CACHE_ENABLED` | Existing API-key cache switch; omitted defaults to `true`, `false` acquires per live request |
| `EPP_PROVIDER_TIMEOUT_MS` | Existing provider timeout, e.g. `"1500"`; positive values capped at 2,500 ms |

The two `EPP_TWILIO_*` names and secret names are **defined by these customer examples**,
not recognized Twilio options in today's runtime. JavaScript/Python can read adapter
settings from the existing `config.env`; C# receives `IEnv`. No shared `AppConfig`
property is needed for this approach. Use server-owned immutable configuration and
restart workers after changing it.

The Key Vault resolver uses managed identity, not local Azure CLI sign-in. Attach the
chosen user-assigned identity to the Function if applicable and grant scoped secret-read
access (for example Key Vault Secrets User); setting its client ID grants no permission.
Do not put API secrets in source, local settings, URLs, documentation, screenshots, or logs.
Keep the existing decryption-key Key Vault reference and Easy Auth settings separate from
provider credentials.

**Where authentication must be customized:** the new adapter declares `apiKey`, chooses
the two new secret names, and constructs Twilio's Basic header. JavaScript's
`CredentialTokenService`/`ApiKeyCache` already returns `{mode, identity, secret}` from
`credentialSpec`; Python's service does the same from `credential_spec` using
`SecretResolver`. C# implements `FetchCredentialsAsync` using injected `ISecretResolver`;
`CredentialTokenService` then caches its expiring `ProviderCredentials`. Do not alter
the shared service to perform Twilio OAuth/client-assertion exchange: that existing
path is for other providers and is not this API's authentication.

Keep the existing acquisition bounds, refresh/shutdown behavior and sanitized failure
reporting. JavaScript/Python use worker-local refresh loops when caching is enabled;
C# warms at startup and refetches on cache miss, without a poller. These services assume
one provider/account per deployment; do not reuse them to switch accounts per request.
JavaScript checks Key Vault secret metadata; the current Python/.NET string resolvers
do not expose that metadata. The C# example follows the existing five-minute credential
expiry convention, not a Twilio-issued expiry. Plan coordinated SID/secret rotation
and cache invalidation; do not claim these abstractions enforce identical vault expiry
semantics in every language.

## JavaScript

Add **customer file** `javascript/src/functions/providers/twilio.js` with the following
example. It uses the existing result contract and lets
[providerTransport.js](../javascript/src/functions/providerTransport.js) perform HTTP,
JSON parsing, timeout handling and redirect rejection.

```javascript
'use strict';

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');
const smsSuccess = new Set(['queued', 'sending', 'sent', 'delivered']);
const smsFailure = new Set(['failed', 'undelivered', 'canceled']);
const callSuccess = new Set(['queued', 'ringing', 'in-progress', 'completed']);
const callFailure = new Set(['busy', 'failed', 'no-answer', 'canceled']);
const e164 = /^\+[1-9][0-9]{1,14}(?![\s\S])/;
const xmlEscape = (text) => text.replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&apos;',
}[character]));

module.exports = Object.freeze({
    name: 'twilio',
    authenticationMode: 'apiKey',
    credentialSpec: Object.freeze({
        mode: 'apiKey',
        keyVaultSecretName: 'twilio-api-key-secret',
        identityKeyVaultSecretName: 'twilio-api-key-sid',
    }),

    createRequest({ channel, endpoint, delivery, credential, env }) {
        if (!['sms', 'voice'].includes(channel)) throw new Error('unsupported channel');
        const account = env.EPP_TWILIO_ACCOUNT_SID;
        const from = env.EPP_TWILIO_FROM;
        const resource = channel === 'sms' ? 'Messages' : 'Calls';
        if (typeof account !== 'string' || !/^AC[0-9a-fA-F]{32}(?![\s\S])/.test(account)
            || endpoint !== `https://api.twilio.com/2010-04-01/Accounts/${account}/${resource}.json`
            || typeof from !== 'string' || !e164.test(from)
            || typeof delivery.phoneNumber !== 'string' || !e164.test(delivery.phoneNumber)
            || typeof delivery.message !== 'string' || !delivery.message.trim()
            || credential.mode !== 'apiKey'
            || typeof credential.identity !== 'string' || !/^SK[0-9a-fA-F]{32}(?![\s\S])/.test(credential.identity)
            || typeof credential.secret !== 'string' || !credential.secret.trim()) {
            throw new Error('invalid provider configuration or delivery');
        }
        const form = new URLSearchParams({ To: delivery.phoneNumber, From: from });
        if (channel === 'sms') {
            form.set('Body', delivery.message);
        } else {
            const locale = delivery.locale?.trim() || 'en-US';
            if (locale !== 'en-US') throw new Error('unsupported voice locale');
            const speech = delivery.message.replace(
                /(?<![0-9])[0-9]{6}(?![0-9])/g, (digits) => [...digits].join(', '));
            const xmlValid = [...speech].every((character) => {
                const code = character.codePointAt(0);
                return [9, 10, 13].includes(code) || (code >= 0x20 && code <= 0xd7ff)
                    || (code >= 0xe000 && code <= 0xfffd) || (code >= 0x10000 && code <= 0x10ffff);
            });
            if (!xmlValid) throw new Error('invalid voice text');
            const twiml = `<Response><Say voice="woman" language="en-US" loop="2">${xmlEscape(speech)}</Say></Response>`;
            if ([...twiml].length > 4000) throw new Error('voice message too long');
            form.set('Twiml', twiml);
        }
        return {
            url: endpoint,
            method: 'POST',
            headers: {
                Authorization: `Basic ${Buffer.from(`${credential.identity}:${credential.secret}`, 'utf8').toString('base64')}`,
                'Content-Type': 'application/x-www-form-urlencoded',
                Accept: 'application/json',
            },
            body: form.toString(),
        };
    },

    interpretResponse(response) {
        const payload = response.json;
        const sid = payload && typeof payload === 'object' && !Array.isArray(payload)
            && typeof payload.sid === 'string' ? payload.sid : '';
        const sms = /^SM[0-9a-fA-F]{32}(?![\s\S])/.test(sid);
        const call = /^CA[0-9a-fA-F]{32}(?![\s\S])/.test(sid);
        const status = typeof payload?.status === 'string' ? payload.status : '';
        const success = sms ? smsSuccess : call ? callSuccess : new Set();
        const failure = sms ? smsFailure : call ? callFailure : new Set();
        const recognized = response.validJson && (success.has(status) || failure.has(status));
        const outcome = response.providerHttpStatus === 201 && recognized && success.has(status)
            ? OUTCOME.CONTINUE : OUTCOME.FAIL;
        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: sms || call ? sid : null,
            providerStatusName: recognized ? status : null,
            failureReason: classifyFailure({
                providerHttpStatus: response.providerHttpStatus,
                outcome,
                statusRecognized: recognized,
                validJson: response.validJson,
            }),
        });
    },
});
```

In [providers/index.js](../javascript/src/functions/providers/index.js), import
`const twilio = require('./twilio');`, add `case 'twilio': return twilio;` to
`selectProvider`, and include `twilio` in the module exports alongside the others.
Do not replace another adapter. [config.js](../javascript/src/functions/config.js)
already preserves `env`, and [SendOtp.js](../javascript/src/functions/SendOtp.js)
passes it to `createRequest`. Keep the existing live/evaluation branches and startup/
termination hooks in that handler. The new credential spec is used on both warmup and
live paths, so no custom secret client or extra send logic belongs in the handler.

## C# (.NET)

Add **customer file** `dotnet/Src/Providers/TwilioProvider.cs`:

```csharp
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;
using Microsoft.Extensions.Logging;

namespace Epp.Otp.Providers;

public sealed class TwilioProvider(ISecretResolver secrets) : PhoneProviderBase
{
    public override string Name => "twilio";
    public override string AuthenticationMode => "apiKey";

    public override async Task<ProviderCredentials> FetchCredentialsAsync(
        AppConfig config, CancellationToken cancellationToken = default)
    {
        var secretTask = secrets.ResolveAsync("twilio-api-key-secret", cancellationToken);
        var sidTask = secrets.ResolveAsync("twilio-api-key-sid", cancellationToken);
        await Task.WhenAll(secretTask, sidTask).ConfigureAwait(false);
        var secret = await secretTask;
        var sid = await sidTask;
        if (string.IsNullOrWhiteSpace(secret) || sid is null
            || !Regex.IsMatch(sid, @"\ASK[0-9a-fA-F]{32}\z"))
            throw new InvalidOperationException("provider credential unavailable");
        return new ProviderCredentials(AuthenticationMode, Secret: secret, Identity: sid,
            ExpiresOn: DateTimeOffset.UtcNow.AddMinutes(5));
    }

    public override Task<ProviderResult> SendOtpAsync(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credentials,
        IEnv env, HttpClient client, int timeoutMs, ILogger? logger = null) =>
        SendJsonAsync<Response>(
            () => CreateRequest(channel, endpoint, delivery, credentials, env),
            MapResponse, client, timeoutMs, logger);

    private static HttpRequestMessage CreateRequest(
        string channel, string endpoint, OtpDelivery delivery, ProviderCredentials credential, IEnv env)
    {
        if (channel is not ("sms" or "voice"))
            throw new InvalidOperationException("unsupported channel");
        var account = env.Get("EPP_TWILIO_ACCOUNT_SID");
        var from = env.Get("EPP_TWILIO_FROM");
        var resource = channel == "sms" ? "Messages" : "Calls";
        if (account is null || !Regex.IsMatch(account, @"\AAC[0-9a-fA-F]{32}\z")
            || endpoint != $"https://api.twilio.com/2010-04-01/Accounts/{account}/{resource}.json"
            || from is null || !Regex.IsMatch(from, @"\A\+[1-9][0-9]{1,14}\z")
            || !Regex.IsMatch(delivery.PhoneNumber, @"\A\+[1-9][0-9]{1,14}\z")
            || string.IsNullOrWhiteSpace(delivery.Message)
            || credential.Mode != "apiKey" || string.IsNullOrWhiteSpace(credential.Secret)
            || credential.Identity is null || !Regex.IsMatch(credential.Identity, @"\ASK[0-9a-fA-F]{32}\z"))
            throw new InvalidOperationException("invalid provider configuration or delivery");
        var fields = new Dictionary<string, string> { ["To"] = delivery.PhoneNumber, ["From"] = from };
        if (channel == "sms")
            fields["Body"] = delivery.Message;
        else
        {
            var locale = string.IsNullOrWhiteSpace(delivery.Locale) ? "en-US" : delivery.Locale.Trim();
            if (locale != "en-US") throw new InvalidOperationException("unsupported voice locale");
            var speech = Regex.Replace(delivery.Message, @"(?<![0-9])[0-9]{6}(?![0-9])",
                match => string.Join(", ", match.Value.ToCharArray()));
            XmlConvert.VerifyXmlChars(speech);
            var twiml = new XElement("Response", new XElement("Say",
                new XAttribute("voice", "woman"), new XAttribute("language", "en-US"),
                new XAttribute("loop", "2"), speech)).ToString(SaveOptions.DisableFormatting);
            if (twiml.EnumerateRunes().Count() > 4000)
                throw new InvalidOperationException("voice message too long");
            fields["Twiml"] = twiml;
        }
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = new FormUrlEncodedContent(fields),
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Basic",
            Convert.ToBase64String(Encoding.UTF8.GetBytes($"{credential.Identity}:{credential.Secret}")));
        request.Headers.Accept.ParseAdd("application/json");
        return request;
    }

    private static ProviderResult MapResponse(Response? payload, HttpStatusCode httpStatus)
    {
        var sid = payload?.Sid ?? "";
        var sms = Regex.IsMatch(sid, @"\ASM[0-9a-fA-F]{32}\z");
        var call = Regex.IsMatch(sid, @"\ACA[0-9a-fA-F]{32}\z");
        var status = payload?.Status ?? "";
        var success = sms ? status is "queued" or "sending" or "sent" or "delivered"
            : call && status is "queued" or "ringing" or "in-progress" or "completed";
        var failure = sms ? status is "failed" or "undelivered" or "canceled"
            : call && status is "busy" or "failed" or "no-answer" or "canceled";
        var recognized = success || failure;
        var outcome = httpStatus == HttpStatusCode.Created && success ? Outcome.Continue : Outcome.Fail;
        return new ProviderResult(outcome, recognized, (int)httpStatus,
            ProviderMessageId: sms || call ? sid : null,
            ProviderStatusName: recognized ? status : null)
        {
            FailureReason = ClassifyFailure(httpStatus, outcome, recognized),
        };
    }

    public sealed class Response
    {
        [JsonPropertyName("sid")] public string? Sid { get; init; }
        [JsonPropertyName("status")] public string? Status { get; init; }
    }
}
```

In [Program.cs](../dotnet/Program.cs), add
`builder.Services.AddSingleton<PhoneProviderBase, TwilioProvider>();` beside the other
registrations. Its existing `using Epp.Otp.Providers;` and
`AddSingleton<ISecretResolver, SecretResolver>()` provide the class and constructor
dependency. No change to [SendOtp.cs](../dotnet/Functions/SendOtp.cs)'s
`SelectProvider` is needed: it searches registered `PhoneProviderBase` instances by name.
`CredentialTokenService` also uses those instances for startup warmup.

Despite its name, [PhoneProviderBase.SendJsonAsync](../dotnet/Src/PhoneProviderBase.cs)
parses a **JSON response**, not a requirement to send JSON. Its request factory accepts
the form-encoded `HttpRequestMessage` above. Retain the named HTTP client in `Program.cs`,
redirects disabled, suppressed HTTP factory logs, typed response DTO and bounded send/body
read. Do not add a second HTTP client or transport with different privacy/retry behavior.

## Python

Add **customer file** `python/src/providers/twilio.py`:

```python
import base64
import re
from urllib.parse import urlencode
from xml.etree.ElementTree import Element, SubElement, tostring

from ..models import Outcome, ProviderResult
from ..provider import OutboundRequest, PhoneProviderBase, classify_failure


class TwilioProvider(PhoneProviderBase):
    name = "twilio"
    authentication_mode = "apiKey"

    @property
    def credential_spec(self):
        return {
            "mode": self.authentication_mode,
            "key_vault_secret_name": "twilio-api-key-secret",
            "identity_key_vault_secret_name": "twilio-api-key-sid",
        }

    def build_request(self, channel, endpoint, delivery, credential, env):
        if channel not in ("sms", "voice"):
            raise ValueError("unsupported channel")
        account, sender = env.get("EPP_TWILIO_ACCOUNT_SID"), env.get("EPP_TWILIO_FROM")
        resource = "Messages" if channel == "sms" else "Calls"
        if (
            not isinstance(account, str) or not re.fullmatch(r"AC[0-9a-fA-F]{32}", account)
            or endpoint != f"https://api.twilio.com/2010-04-01/Accounts/{account}/{resource}.json"
            or not isinstance(sender, str) or not re.fullmatch(r"\+[1-9][0-9]{1,14}", sender)
            or not isinstance(delivery.phone_number, str)
            or not re.fullmatch(r"\+[1-9][0-9]{1,14}", delivery.phone_number)
            or not isinstance(delivery.message, str) or not delivery.message.strip()
            or credential.get("mode") != "apiKey"
            or not isinstance(credential.get("identity"), str)
            or not re.fullmatch(r"SK[0-9a-fA-F]{32}", credential["identity"])
            or not isinstance(credential.get("secret"), str) or not credential["secret"].strip()
        ):
            raise ValueError("invalid provider configuration or delivery")
        fields = {"To": delivery.phone_number, "From": sender}
        if channel == "sms":
            fields["Body"] = delivery.message
        else:
            locale = (delivery.locale or "").strip() or "en-US"
            if locale != "en-US":
                raise ValueError("unsupported voice locale")
            speech = re.sub(r"(?<![0-9])[0-9]{6}(?![0-9])",
                            lambda match: ", ".join(match.group(0)), delivery.message)
            if not all(ord(char) in (9, 10, 13) or 0x20 <= ord(char) <= 0xD7FF
                       or 0xE000 <= ord(char) <= 0xFFFD or 0x10000 <= ord(char) <= 0x10FFFF
                       for char in speech):
                raise ValueError("invalid voice text")
            root = Element("Response")
            SubElement(root, "Say", voice="woman", language="en-US", loop="2").text = speech
            twiml = tostring(root, encoding="unicode")
            if len(twiml) > 4000:
                raise ValueError("voice message too long")
            fields["Twiml"] = twiml
        raw = f"{credential['identity']}:{credential['secret']}".encode("utf-8")
        return OutboundRequest("POST", endpoint, {
            "Authorization": "Basic " + base64.b64encode(raw).decode("ascii"),
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        }, urlencode(fields))

    def map_response(self, payload, http_status):
        body = payload if isinstance(payload, dict) else {}
        sid = body.get("sid") if isinstance(body.get("sid"), str) else ""
        sms = bool(re.fullmatch(r"SM[0-9a-fA-F]{32}", sid))
        call = bool(re.fullmatch(r"CA[0-9a-fA-F]{32}", sid))
        status = body.get("status") if isinstance(body.get("status"), str) else ""
        success = ({"queued", "sending", "sent", "delivered"} if sms else
                   {"queued", "ringing", "in-progress", "completed"} if call else set())
        failure = ({"failed", "undelivered", "canceled"} if sms else
                   {"busy", "failed", "no-answer", "canceled"} if call else set())
        recognized = status in success or status in failure
        outcome = Outcome.CONTINUE if http_status == 201 and status in success else Outcome.FAIL
        return ProviderResult(
            outcome, recognized, http_status,
            provider_message_id=sid if sms or call else None,
            provider_status_name=status if recognized else None,
            failure_reason=classify_failure(http_status, outcome, recognized),
        )
```

In [function_app.py](../python/function_app.py), add
`from src.providers.twilio import TwilioProvider` and add `TwilioProvider()` to the
tuple that constructs `_providers`. The empty
[providers/__init__.py](../python/src/providers/__init__.py) needs no registration.
[config.py](../python/src/config.py) already preserves `env`; `_send_to_provider` passes
it to the adapter. Keep `CredentialTokenService(SecretResolver())`, credential warmup,
`atexit` cleanup and the evaluation branch unchanged.
[provider.py](../python/src/provider.py) sends `OutboundRequest.body` via `data=`,
not `json=`, so the encoded form is compatible with the existing transport.

## Endpoint security, deadlines, and privacy

The sample's shared validators enforce HTTPS and reject credentials/fragments in URLs,
and its transports disable redirects. They are **not destination/SSRF allowlists**:
an arbitrary HTTPS URL can still target an internal service or leak the Basic credential.
The examples additionally require exact equality with the channel's pinned Twilio URL
and validated server-owned account SID, rejecting ports, alternate hosts, userinfo,
queries, fragments, and the wrong operation path. Keep both checks. If supporting a
regional/custom endpoint, review the approved hosts, account/path binding, DNS/egress
controls and ports; never weaken validation to "any HTTPS URL" or take it from a request.
Selected endpoint paths appear in sample telemetry, so treat account identifiers as
restricted operational metadata and never put OTPs/secrets in the path.

Provider sends use the sample's normalized timeout (default 1,500 ms, cap 2,500 ms).
JavaScript/.NET bound the send and response body read; Python Requests' timeout is
connect/read inactivity, **not a hard total deadline**. Credential acquisition has a
separate budget and cold starts add time. `ttlSeconds` validation does not implement
an end-to-end delivery deadline. Twilio Calls' optional `Timeout` field controls
**phone ringing**, not the Function's HTTP timeout; it is not a replacement for the
transport bound.

Do not enable HTTP/SDK automatic retries, provider fallback, or background sends after
replying. Timeout, cancellation, lost/malformed response, or 5xx may occur **after
Twilio accepted a send**. Returning failure can also cause Entra's native fallback.
Do not blindly resubmit or infer nonacceptance from a generic status. The sample has no
durable deduplication or provider idempotency contract; see the separate
[conservative fallback walkthrough](MULTI-PROVIDER-IMPLEMENTATION.md) before designing
such behavior. A queued SMS/call may outlive the OTP; assess queue/capacity and expiry
policy with the approved integration owner.

Never log the decrypted context, message/OTP, nonce, full phone numbers, form/TwiML,
Authorization header, credential objects, raw provider bodies or exception strings.
The examples return only recognized fixed states and validated SIDs to the shared
result path; raw error details stay out of telemetry and caller responses. Retain the
sample's sanitized logging helpers, disable body/header tracing in all proxies/SDKs,
and restrict provider-side message/call records and retention too. Do not turn on call
recording or transcription to debug OTP audio.

## Tests and customer release checklist

Before publishing a customer package, add adapter tests next to
[JavaScript provider tests](../javascript/test/provider-flow.test.js),
[C# contract tests](../dotnet/tests/ContractTests.cs), or
[Python engine tests](../python/tests/test_engine.py), plus handler-path tests:

| Test area | Required assertions |
| --- | --- |
| Registration/config | `twilio` selects only the new adapter; existing names still work; missing/invalid account, sender, endpoint or auth mode fails before send |
| Credential path | The exact two vault names map SID to `identity` and secret to `secret`; Basic header decodes to that pair, never account SID/inbound bearer; missing/blank/wrong SID and vault failures do not send |
| Cache lifecycle | Enabled/disabled caching, expiry/rotation, startup failure, concurrent acquisition and shutdown preserve each runtime's existing behavior |
| SMS form | Original Unicode message including `+`, `&`, `=`, `<` and apostrophes round-trips; E.164 plus survives; correct Messages URL and form content type; no new OTP |
| Voice form/XML | Correct Calls URL; `Twiml` only (no `Url`); parse XML; escaped text cannot inject verbs; leading-zero six-digit pacing, loop 2, blank/default locale, unsupported locales, control characters and 4,000-character boundary |
| Result policy | Both resource types and all listed states; malformed/missing SID/status, arrays, wrong JSON types, unknown/scheduled/accepted states and invalid JSON fail closed; 401/403/429/5xx cannot succeed with a success-looking body |
| Transport | HTTPS and exact-host/account/path checks, redirects, timeout/network/body-read errors; one attempt only, no retry/fallback; sanitized logs contain no fixture OTP/credential/phone/body |
| Handler contract | Live acceptance echoes the decrypted nonce; failure omits it; mode 2 skips provider validation/acquisition/send; invalid envelope/JWE never reaches provider I/O |

Use mocks/fake transports and fake credentials for offline tests; do not use live sends
in unit tests. Existing runners are `npm test` in `javascript`, `dotnet test` against
`dotnet/tests/Epp.Otp.Tests.csproj`, and `python -m pytest` in `python` with the repository's
runtime requirements and pytest installed. Include the new adapter in the chosen suite.

Review and build your **modified source**, not the unmodified public release ZIP.
Follow the chosen [language guide](../TECHNICAL.md#implementations) and
[custom packaging instructions](../TECHNICAL.md#build-zips-locally); .NET's ZIP is source
requiring publish, and Python's ZIP requires Linux remote dependency build. Package
generation does not configure authorization or prove live delivery. Keep customer
deployment/IaC settings, identity permissions and package provenance under review;
this guide does not make the guided setup accept a custom provider.

Only after provider eligibility and the approved procedure are established, arrange
separate authorized nonproduction checks for caller rejection, evaluation, live SMS
receipt, voice receipt/audio/locales, credential rotation, ambiguous outcomes and
monitoring. Keep Easy Auth enabled throughout. Do not treat offline checks, Twilio
test credentials, HTTP 201, or a nonce echo as a completed live integration or permission
to activate a tenant. Use the [existing validation guidance](ONBOARDING.md#validate-the-deployed-endpoint)
and [production limitations](CONTRACT.md#production-limitations) for the final handoff.
