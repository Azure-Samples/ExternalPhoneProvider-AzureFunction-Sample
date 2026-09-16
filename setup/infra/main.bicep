targetScope = 'subscription'

@description('The exact resource names displayed in the approved setup plan.')
param resourceNames object

param location string
param tenantId string
param applicationId string
param callerApplicationId string
param deployerObjectId string
param providerSettings object
param packageBlobName string
@allowed(['javascript', 'dotnet', 'python'])
param language string
param remoteBuild bool

@allowed([1, 2])
param tokenVersion int

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceNames.resourceGroup
  location: location
  tags: {
    managedBy: 'EPP-Setup'
    eppApplicationId: applicationId
    eppLanguage: language
  }
}

module endpoint 'resources.bicep' = {
  name: 'epp-endpoint'
  scope: resourceGroup
  params: {
    resourceNames: resourceNames
    location: location
    tenantId: tenantId
    applicationId: applicationId
    callerApplicationId: callerApplicationId
    deployerObjectId: deployerObjectId
    tokenVersion: tokenVersion
    providerSettings: providerSettings
    packageBlobName: packageBlobName
    language: language
    remoteBuild: remoteBuild
  }
}

output resourceGroupName string = resourceGroup.name
output functionAppName string = endpoint.outputs.functionAppName
output storageAccountName string = endpoint.outputs.storageAccountName
output keyVaultName string = endpoint.outputs.keyVaultName
output outboundPrincipalId string = endpoint.outputs.outboundPrincipalId
output endpointUrl string = endpoint.outputs.endpointUrl
output identifierUri string = endpoint.outputs.identifierUri
output packageContainerUrl string = endpoint.outputs.packageContainerUrl
