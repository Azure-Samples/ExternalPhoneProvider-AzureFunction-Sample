targetScope = 'subscription'

@description('The exact resource names displayed in the approved setup plan.')
param resourceNames object

param location string
param tenantId string
param applicationId string
param callerApplicationId string
param providerSettings object
@allowed(['javascript', 'dotnet', 'python'])
param language string
param certificatePlan object
param executionId string
@allowed(['FC1', 'EP1'])
param servicePlan string = 'EP1'

@allowed([1, 2])
param tokenVersion int

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceNames.resourceGroup
  location: location
  tags: {
    managedBy: 'EPP-Setup'
    eppApplicationId: applicationId
    eppLanguage: language
    eppServicePlan: servicePlan
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
    tokenVersion: tokenVersion
    providerSettings: providerSettings
    language: language
    servicePlan: servicePlan
  }
}

var externalCertificate = certificatePlan.action == 'Reuse' && toLower(certificatePlan.vaultName) != toLower(resourceNames.keyVault)

module sourceVaultAccess 'certificate-access.bicep' = if (externalCertificate) {
  name: 'epp-certificate-access'
  scope: az.resourceGroup(certificatePlan.vaultSubscriptionId, split(certificatePlan.vaultResourceId, '/')[4])
  params: {
    vaultName: certificatePlan.vaultName
    certificateName: certificatePlan.certificateName
    tenantId: tenantId
    functionPrincipalId: endpoint.outputs.functionPrincipalId
    setupPrincipalId: endpoint.outputs.setupPrincipalId
    useRbac: certificatePlan.vaultRbac
    existingPolicies: certificatePlan.existingPolicies
    existingRoleAssignments: certificatePlan.existingRoleAssignments
  }
}

module certificate 'certificate.bicep' = {
  name: 'epp-certificate'
  scope: resourceGroup
  params: {
    location: location
    identityResourceId: endpoint.outputs.setupIdentityResourceId
    certificatePlan: certificatePlan
    executionId: executionId
  }
  dependsOn: [
    sourceVaultAccess
  ]
}

module encryption 'encryption-settings.bicep' = {
  name: 'epp-encryption-settings'
  scope: resourceGroup
  params: {
    functionAppName: endpoint.outputs.functionAppName
    certificateSecretUri: certificate.outputs.bundle.sid
    keyId: certificatePlan.keyId
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
output certificateBundle object = certificate.outputs.bundle
output certificateSecretVersions array = certificate.outputs.secretVersions
