param location string
param identityResourceId string
param certificatePlan object
param executionId string

resource certificate 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'epp-certificate-${uniqueString(identityResourceId)}'
  location: location
  kind: 'AzurePowerShell'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    azPowerShellVersion: '16.2'
    timeout: 'PT15M'
    retentionInterval: 'P1D'
    cleanupPreference: 'Always'
    forceUpdateTag: executionId
    environmentVariables: [
      {
        name: 'EPP_CERTIFICATE_PLAN'
        value: string(certificatePlan)
      }
    ]
    scriptContent: loadTextContent('Invoke-Certificate.ps1')
  }
}

output bundle object = certificate.properties.outputs.bundle
output secretVersions array = certificate.properties.outputs.secretVersions
