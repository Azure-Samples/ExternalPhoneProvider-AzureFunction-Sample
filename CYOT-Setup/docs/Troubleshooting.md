> **Produced by:** GitHub Copilot | **Session:** S0915a

# Troubleshooting

## Start with diagnostics

```powershell
.\Setup-Cyot.ps1 -Stage Diagnostics
```

Review the newest file under `logs/`. The log records stage boundaries and failure locations without intentionally recording credentials.

## Resume after a failure

Correct the reported problem, then run:

```powershell
.\Setup-Cyot.ps1 -Resume
```

The orchestrator skips stages listed in `state/cyot-setup-state.json`. Step 2 also supports an internal `StartFromStep` value from 1 through 11 in the configuration file when recovery must continue inside endpoint provisioning.

## Microsoft Graph sign-in is required

Interactive runs open the normal delegated sign-in flow. For a noninteractive run, connect in the same PowerShell process with the scopes needed by the stage before launching setup.

Registration requires `Application.ReadWrite.All`. Activation requires `Policy.ReadWrite.AuthenticationMethod` and the Authentication Policy Administrator role.

## CYOT isn't exposed by Microsoft Graph

Validation reads the selected public Graph metadata document. If the exact `authenticationMethodsPolicy.cyot` contract isn't present, activation stops. Don't substitute a guessed property or a different authentication method. Confirm the supported contract with Microsoft before retrying.

## Azure CLI reports `ValueError: Not a boolean`

Confirm the current value:

```powershell
az config get core.login_experience_v2
```

Set a literal lowercase Boolean and retry the Azure sign-in command directly:

```powershell
az config set core.login_experience_v2=false --only-show-errors
```

Also check whether `AZURE_CORE_LOGIN_EXPERIENCE_V2` is set in the process, user, or machine environment. Remove an invalid override before retrying. Step 1 treats its optional Azure CLI sign-in as nonfatal; Step 2 requires a working Azure CLI session when it provisions Azure resources.

## State is invalid

The state file uses schema version 1. If it is truncated or manually changed, preserve it for investigation, move it out of `state/`, and rerun the required stages. Never insert credentials into the state file.

## Policy activation was cancelled

Cancellation leaves completed registration and endpoint changes in place. No cleanup is automatic. Rerun `-Stage Activate` when the endpoint is tested and the administrator is ready to approve the policy change.