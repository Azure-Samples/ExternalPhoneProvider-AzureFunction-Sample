# External phone provider Azure Functions sample

This external phone provider (EPP) sample connects Microsoft Entra ID to a phone provider for
SMS and voice one-time passwords (OTPs). It includes **Infobip, Soprano, and Telesign** adapters
that use **OAuth through managed identity federation**.

Guided setup deploys one regional endpoint with one provider. Choose JavaScript, C#, or Python;
JavaScript is the default.

## Quick start

**[Start onboarding: download and run the setup script](docs/GETTING-STARTED.md#2-download-and-run-the-setup-script)**

Guided setup creates your application registration, deploys the Azure resources, and configures
the endpoint. Check the [required access and tools](docs/GETTING-STARTED.md#1-get-ready) first,
then follow the download-and-run instructions. The guide continues with provider authorization,
testing, and activation.

## Features

- One [Send OTP API](docs/CONTRACT.md) for SMS, voice, and evaluation requests.
- Guided deployment with Azure Functions authentication (Easy Auth), Key Vault, and monitoring.
- Evaluation mode to check authentication and decryption without sending a message.

## Prerequisites

- A Microsoft Entra ID tenant and Azure subscription with the required
  [roles, tools, regional availability, and quota](setup/docs/README.md#prerequisites).
- A provider account with access to the intended channels and destinations. Check
  [Microsoft's telephony-provider guidance](https://learn.microsoft.com/entra/identity/authentication/concept-phone-providers)
  for current availability and onboarding requirements.
- A separate test environment and resource prefix. Guided setup creates the dedicated application
  registration for you.
- A budget for [Azure hosting and provider charges](docs/COST-CALCULATOR.md).

## Architecture

![Single-region architecture showing Easy Auth, SendOtp, the Key Vault encryption certificate, outbound OAuth identity, monitoring, and phone delivery](docs/images/single-region-architecture.png)

[Open the full-size diagram](docs/images/single-region-architecture.svg).

Easy Auth validates the Microsoft caller. The Function decrypts the request and, in live mode,
submits it to the configured provider. A successful response confirms **provider acceptance**;
confirm recipient delivery separately.

## Get started

Follow the **[deployment guide](docs/GETTING-STARTED.md)**:

1. [Prepare access, tools, and budget](docs/GETTING-STARTED.md#1-get-ready).
2. [Download and run the setup script](docs/GETTING-STARTED.md#2-download-and-run-the-setup-script).
3. [Authorize the provider and test](docs/GETTING-STARTED.md#3-connect-your-provider-and-test).
4. [Activate and hand over](docs/GETTING-STARTED.md#4-activate-and-hand-over).

## Documentation

| Task | Guide |
| --- | --- |
| Deploy or rerun setup | [Setup reference](setup/docs/README.md) |
| Configure provider access | [Configuration and validation](docs/ONBOARDING.md) |
| Understand settings and provider behavior | [Technical reference](TECHNICAL.md) |
| Resolve a problem | [Troubleshooting](setup/docs/Troubleshooting.md) |
| Monitor requests and failures | [Monitoring](docs/MONITORING.md) |
| Review the request and response | [Send OTP API](docs/CONTRACT.md) |
| Develop or extend the sample | [JavaScript](javascript/README.md), [C#](dotnet/README.md), [Python](python/README.md), or [add a provider](docs/BRING-YOUR-OWN-PROVIDER.md) |

See the [documentation index](docs/README.md) for all guides.

### Advanced deployment guides

- [Multi-region resiliency](docs/MULTI-REGION-RESILIENCY.md).
- [Configure multiple phone providers](docs/MULTI-PROVIDER-IMPLEMENTATION.md).

## Get help

For provider access and account issues, use your provider's support channel. For Microsoft Entra ID
configuration, use Microsoft support. Report sample issues in
[GitHub Issues](https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample/issues).

Keep credentials, phone numbers, OTPs, encrypted request bodies, and raw provider responses out
of issues and support requests.
