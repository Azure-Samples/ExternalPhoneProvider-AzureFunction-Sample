param vaultName string
param certificateName string
param tenantId string
param functionPrincipalId string
param setupPrincipalId string
param useRbac bool
param existingPolicies array
param existingRoleAssignments array

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

var matchingFunctionPolicies = filter(existingPolicies, policy => toLower(policy.objectId) == toLower(functionPrincipalId))
var matchingSetupPolicies = filter(existingPolicies, policy => toLower(policy.objectId) == toLower(setupPrincipalId))
var functionPermissions = !empty(matchingFunctionPolicies) ? matchingFunctionPolicies[0].permissions : {}
var setupPermissions = !empty(matchingSetupPolicies) ? matchingSetupPolicies[0].permissions : {}
var accessPoliciesValid = length(matchingFunctionPolicies) <= 1 && length(matchingSetupPolicies) <= 1 && empty(filter(concat(matchingFunctionPolicies, matchingSetupPolicies), policy => toLower(policy.tenantId) != toLower(tenantId) || !empty(policy.?applicationId ?? '')))
var existingFunctionGrants = filter(existingRoleAssignments, grant => toLower(grant.principalId) == toLower(functionPrincipalId) && endsWith(toLower(grant.roleDefinitionId), '/4633458b-17de-408a-b874-0445c86b69e6'))
var existingSetupGrants = filter(existingRoleAssignments, grant => toLower(grant.principalId) == toLower(setupPrincipalId) && toLower(grant.scope) == toLower(vault.id) && endsWith(toLower(grant.roleDefinitionId), '/21090545-7ca7-4776-b22c-e363652d74d2'))

resource secret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: vault
  name: certificateName
}

resource functionAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useRbac && empty(existingFunctionGrants)) {
  name: guid(secret.id, functionPrincipalId, 'epp-certificate-read')
  scope: secret
  properties: {
    principalId: functionPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
  }
}

resource setupAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (useRbac && empty(existingSetupGrants)) {
  name: guid(vault.id, setupPrincipalId, 'epp-certificate-metadata')
  scope: vault
  properties: {
    principalId: setupPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '21090545-7ca7-4776-b22c-e363652d74d2')
  }
}

// Validate runtime identity matches before modifying an existing legacy policy.
resource policyValidation 'Microsoft.Resources/deployments@2022-09-01' = if (!useRbac) {
  name: 'epp-certificate-policy-validation'
  properties: {
    mode: 'Incremental'
    expressionEvaluationOptions: {
      scope: 'inner'
    }
    parameters: {
      accessPoliciesValid: {
        value: accessPoliciesValid
      }
    }
    template: {
      '$schema': 'https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        accessPoliciesValid: {
          type: 'bool'
          allowedValues: [true]
        }
      }
      resources: []
    }
  }
}

resource policies 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = if (!useRbac) {
  parent: vault
  name: 'add'
  properties: {
    accessPolicies: [
      union(!empty(matchingFunctionPolicies) ? matchingFunctionPolicies[0] : {}, {
        tenantId: tenantId
        objectId: functionPrincipalId
        permissions: union(functionPermissions, {
          secrets: union(functionPermissions.?secrets ?? [], ['get'])
        })
      })
      union(!empty(matchingSetupPolicies) ? matchingSetupPolicies[0] : {}, {
        tenantId: tenantId
        objectId: setupPrincipalId
        permissions: union(setupPermissions, {
          certificates: union(setupPermissions.?certificates ?? [], ['get', 'list'])
          secrets: union(setupPermissions.?secrets ?? [], ['list'])
        })
      })
    ]
  }
  dependsOn: [policyValidation]
}
