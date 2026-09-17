@{
    PackageName = 'EPP endpoint deployment'
    PackageVersion = '0.3.1'
    EntryPoint = 'Setup-Epp.ps1'
    MinimumPowerShellVersion = '7.0'
    Support = @('support/Epp.Setup.psm1', 'support/Epp.Packages.ps1')
    Infrastructure = @(
        'infra/main.bicep'
        'infra/resources.bicep'
    )
    ProviderCatalog = 'providers/catalog.json'
    PackageCatalog = 'packages/catalog.json'
    RuntimeDirectories = @('epp-output')
}
