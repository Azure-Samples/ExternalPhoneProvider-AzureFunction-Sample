targetScope = 'subscription'

@minLength(3)
@maxLength(10)
param prefix string
@minLength(2)
@maxLength(3)
param locations string[]
param tenantId string
param applicationId string
param deployerObjectId string
param sourceResourceId string
param packageBlobName string
@secure()
param providerSettings object
param frontDoorId string
param issuer string
param audience string
@minLength(1)
param callerApplicationIds string[]

var names = [for (location, i) in locations: {
  resourceGroup: '${prefix}-${i}-rg'
  functionApp: '${prefix}-${i}-func'
  hostingPlan: '${prefix}-${i}-plan'
  storageAccount: 'eppfd${uniqueString(subscription().id, prefix, location)}'
  keyVault: '${prefix}-${i}-kv'
  outboundIdentity: '${prefix}-${i}-outbound'
  logAnalytics: '${prefix}-${i}-logs'
  applicationInsights: '${prefix}-${i}-insights'
}]

resource groups 'Microsoft.Resources/resourceGroups@2024-03-01' = [for (location, i) in locations: {
  name: names[i].resourceGroup
  location: location
  tags: {
    managedBy: 'EPP-FrontDoor-Setup'
    sourceResourceId: sourceResourceId
  }
}]

module regionalEndpoints 'resources.bicep' = [for (location, i) in locations: {
  name: 'epp-region-${i}'
  scope: groups[i]
  params: {
    resourceNames: names[i]
    location: location
    tenantId: tenantId
    applicationId: applicationId
    callerApplicationId: callerApplicationIds[0]
    deployerObjectId: deployerObjectId
    tokenVersion: 2
    providerSettings: providerSettings
    packageBlobName: packageBlobName
    language: 'javascript'
    remoteBuild: false
    frontDoor: {
      id: frontDoorId
      issuer: issuer
      audience: audience
      callerApplicationIds: callerApplicationIds
    }
  }
}]

output regions array = [for (location, i) in locations: {
  names: names[i]
  hostname: split(regionalEndpoints[i].outputs.endpointUrl, '/')[2]
  location: location
}]
