targetScope = 'subscription'

@description('Resource group that contains the CYOT endpoint resources.')
param resourceGroupName string = 'rg-external-phone-provider'

@description('Azure region for all CYOT endpoint resources.')
param location string

@minLength(2)
@maxLength(12)
@description('Short environment discriminator used in deterministic resource names.')
param environmentName string = 'prod'

param resourceTagName string = 'Purpose'
param resourceTagValue string = 'Entra - External Phone Provider'

@description('Object ID of the operator who may write the endpoint encryption secret.')
param deployerObjectId string

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: {
    '${resourceTagName}': resourceTagValue
  }
}

module endpoint 'resources.bicep' = {
  name: 'cyot-endpoint-${environmentName}'
  scope: resourceGroup
  params: {
    location: location
    environmentName: environmentName
    resourceTagName: resourceTagName
    resourceTagValue: resourceTagValue
    deployerObjectId: deployerObjectId
  }
}

output resourceGroupName string = resourceGroup.name
output functionAppName string = endpoint.outputs.functionAppName
output storageAccountName string = endpoint.outputs.storageAccountName
output keyVaultName string = endpoint.outputs.keyVaultName