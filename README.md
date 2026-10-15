# External Phone Provider: Azure Function Sample

Connect Microsoft Entra ID to your phone provider for SMS and voice one-time passwords.
Deploy **one endpoint in one Azure region**, using JavaScript, C#, or Python.
Guided setup handles Azure resources and code publication; no repository clone is needed.

**Start in a dedicated nonproduction tenant and subscription.** This is a sample, not
production certification. Before deploying, [confirm supported provider access and Microsoft's
approved testing and activation procedure](docs/GETTING-STARTED.md#1-get-ready).
If either is unavailable, stop. Azure resources and provider services can incur charges.

## Architecture

![Microsoft Entra ID sends an encrypted request through Easy Auth to a Function, which uses Key Vault and calls the phone provider](docs/images/single-region-architecture.png)

*Easy Auth checks the Microsoft caller; the Function decrypts the request.
Live success means provider acceptance, not confirmed delivery; evaluation sends nothing. Region, credentials, caching, and
telemetry are illustrative: see [architecture details](TECHNICAL.md#single-region-architecture).
[Open the full-size diagram](docs/images/single-region-architecture.png).*

## Get started

Follow the **[five-step setup guide](docs/GETTING-STARTED.md)** in order:

1. <a id="1-get-ready"></a>[Get ready](docs/GETTING-STARTED.md#1-get-ready): confirm access, approvals, permissions, tools, and budget.
2. <a id="2-register-your-application"></a>[Register your application](docs/GETTING-STARTED.md#2-register-your-application): save the tenant and application client IDs.
3. <a id="3-run-guided-setup"></a>[Run guided setup](docs/GETTING-STARTED.md#3-run-guided-setup): choose a provider and runtime, then review the deployment plan before approving.
4. <a id="4-connect-your-provider-and-test"></a>[Connect and test](docs/GETTING-STARTED.md#4-connect-your-provider-and-test): configure provider authentication, then complete approved evaluation and live checks for each intended channel.
5. <a id="5-activate-and-hand-over"></a>[Activate and hand over](docs/GETTING-STARTED.md#5-activate-and-hand-over): have the policy administrator activate only after validation; assign monitoring, renewal, and rollback owners.

**Deployment does not activate policy. Keep Easy Auth enabled**; never bypass it to test.
See the [sample's production limitations](docs/CONTRACT.md#production-limitations).

<a id="find-more-detail"></a>
## References

- [Setup reference](setup/docs/README.md) and [troubleshooting](setup/docs/Troubleshooting.md)
- [Provider configuration and validation](docs/ONBOARDING.md)
- [Monitoring](docs/MONITORING.md), [Entra sign-in alerts](docs/SIGN-IN-MONITORING.md#recommended-monitors), and [SMS cost estimation](docs/COST-CALCULATOR.md)
- [Technical reference](TECHNICAL.md), [HTTP contract](docs/CONTRACT.md), and [BYOT integration](docs/BRING-YOUR-OWN-PROVIDER.md)

Optional multi-region and custom-provider designs are in the [detailed reference index](docs/GETTING-STARTED.md#find-more-detail);
they are not built-in guided setup features.
