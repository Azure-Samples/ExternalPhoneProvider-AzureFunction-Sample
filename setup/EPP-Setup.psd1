@{
    PackageName = 'EPP endpoint deployment'
    PackageVersion = '0.3.1'
    EntryPoint = 'Setup-Epp.ps1'
    MinimumPowerShellVersion = '7.0'
    Support = @(
        'Epp.Application.ps1'
        'Epp.Arm.ps1'
        'Epp.PostArm.ps1'
        'support/core/Epp.Setup.psm1'
        'support/core/Epp.Input.ps1'
        'support/core/Epp.Azure.ps1'
        'support/core/Epp.Graph.ps1'
        'support/planning/Epp.Selection.ps1'
        'support/planning/Epp.Providers.ps1'
        'support/planning/Epp.Preflight.ps1'
        'support/planning/Epp.Presentation.ps1'
        'support/deployment/Epp.Packages.ps1'
        'support/deployment/Epp.Certificates.ps1'
        'support/deployment/Epp.Deployment.ps1'
    )
    Infrastructure = @(
        'infra/main.bicep'
        'infra/resources.bicep'
        'infra/certificate-access.bicep'
        'infra/certificate.bicep'
        'infra/Invoke-Certificate.ps1'
        'infra/encryption-settings.bicep'
        'infra/app-settings.bicep'
        'infra/ingress.bicep'
        'infra/publish.bicep'
    )
    ProviderCatalog = 'providers/catalog.json'
    PackageCatalog = 'packages/catalog.json'
    RuntimeDirectories = @('epp-output')
}
