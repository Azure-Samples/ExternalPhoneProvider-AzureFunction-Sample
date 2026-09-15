@{
    PackageName = 'CYOT guided setup'
    PackageVersion = '0.1.0'
    EntryPoint = 'Setup-Cyot.ps1'
    MinimumPowerShellVersion = '7.0'
    Stages = @(
        'stages/Step1-Register-CyotApplication.ps1'
        'stages/Deploy-CyotInfrastructure.ps1'
        'stages/Step2-Setup-ExternalPhoneProvider.ps1'
        'stages/Step3-Set-CyotPolicy.ps1'
    )
    Infrastructure = @(
        'infra/main.bicep'
        'infra/resources.bicep'
    )
    RuntimeDirectories = @('logs', 'state', 'policy-backups')
}
