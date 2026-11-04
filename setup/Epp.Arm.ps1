function Invoke-EppArmDeployment {
    param(
        [hashtable] $Inputs, $ApplicationState, $ProviderConfiguration, $Context,
        [string] $AssetDirectory, [string] $WorkingDirectory, $Package, [string] $OutputDirectory
    )

    Initialize-EppResourceProviders -Inputs $Inputs
    $parameters = Get-EppDeploymentParameters -Inputs $Inputs -Names $ApplicationState.Names `
        -ProviderConfiguration $ProviderConfiguration -Context $Context -Package $Package
    $outputs = Invoke-EppMainDeployment -Inputs $Inputs -Parameters $parameters `
        -AssetDirectory $AssetDirectory -Directory $WorkingDirectory
    return Get-EppArmState -Inputs $Inputs -Names $ApplicationState.Names -Context $Context `
        -Outputs $outputs -OutputDirectory $OutputDirectory
}
