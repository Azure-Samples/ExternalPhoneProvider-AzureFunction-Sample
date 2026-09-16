param resourceNames object
param location string
param tenantId string
param applicationId string
param callerApplicationId string
param deployerObjectId string
param tokenVersion int
param providerSettings object
param packageBlobName string
param language string
param remoteBuild bool

var runtimes = {
  javascript: {
    worker: 'node'
    stack: 'NODE|22'
  }
  dotnet: {
    worker: 'dotnet-isolated'
    stack: 'DOTNET-ISOLATED|8.0'
  }
  python: {
    worker: 'python'
    stack: 'PYTHON|3.11'
  }
}
var runtime = runtimes[language]

var tags = {
  managedBy: 'EPP-Setup'
  eppApplicationId: applicationId
  eppLanguage: language
}
var blobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var blobDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var queueDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var tableDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var keyVaultSecretsOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
var monitoringMetricsPublisherRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '3913510d-42f4-4e42-8a64-420c390055eb')

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: resourceNames.logAnalytics
  location: location
  tags: tags
  properties: {
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource outboundIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: resourceNames.outboundIdentity
  location: location
  tags: tags
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: resourceNames.applicationInsights
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
    DisableLocalAuth: true
    IngestionMode: 'LogAnalytics'
    RetentionInDays: 30
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: resourceNames.storageAccount
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource packages 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'packages'
  properties: {
    publicAccess: 'None'
  }
}

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: resourceNames.keyVault
  location: location
  tags: tags
  properties: {
    tenantId: tenantId
    enableRbacAuthorization: true
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
  }
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: resourceNames.hostingPlan
  location: location
  kind: 'linux'
  tags: tags
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    capacity: 1
  }
  properties: {
    reserved: true
    maximumElasticWorkerCount: 3
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: resourceNames.functionApp
  location: location
  kind: 'functionapp,linux'
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${outboundIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    // The script verifies Easy Auth before opening ingress for publication or Python remote build.
    publicNetworkAccess: 'Disabled'
    siteConfig: {
      alwaysOn: true
      minimumElasticInstanceCount: 1
      ftpsState: 'Disabled'
      http20Enabled: true
      linuxFxVersion: runtime.stack
      minTlsVersion: '1.2'
    }
  }
}

var identifierUri = 'api://${functionApp.properties.defaultHostName}/${applicationId}'
var issuer = tokenVersion == 2 ? '${environment().authentication.loginEndpoint}${tenantId}/v2.0' : 'https://sts.windows.net/${tenantId}/'
var audience = tokenVersion == 2 ? applicationId : identifierUri

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(providerSettings, {
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: runtime.worker
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
    KEY_VAULT_URL: vault.properties.vaultUri
    EPP_DECRYPTION_KEY_PEM: '@Microsoft.KeyVault(SecretUri=${vault.properties.vaultUri}secrets/phone-provider-decryption-key)'
    EPP_OUTBOUND_CLIENT_ID: applicationId
    EPP_OUTBOUND_MI_CLIENT_ID: outboundIdentity.properties.clientId
    EPP_EXPECTED_AUDIENCE: audience
    EPP_EXPECTED_ISSUER: issuer
    EPP_EXPECTED_CLIENT_ID: callerApplicationId
    EPP_TENANT_ID: tenantId
  }, remoteBuild ? {
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
    ENABLE_ORYX_BUILD: 'true'
  } : {
    WEBSITE_RUN_FROM_PACKAGE: '${storage.properties.primaryEndpoints.blob}${packages.name}/${packageBlobName}'
    WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID: 'SystemAssigned'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
    ENABLE_ORYX_BUILD: 'false'
  })
}

resource authentication 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'Return401'
      excludedPaths: []
    }
    httpSettings: {
      requireHttps: true
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: applicationId
          openIdIssuer: issuer
        }
        validation: {
          allowedAudiences: [audience]
          defaultAuthorizationPolicy: {
            allowedApplications: [callerApplicationId]
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
    }
  }
}

resource systemStorageRoles 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for roleId in [
  blobDataOwnerRoleId
  queueDataContributorRoleId
  tableDataContributorRoleId
]: {
  name: guid(storage.id, functionApp.id, roleId)
  scope: storage
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleId
  }
}]

resource packageUploadRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, deployerObjectId, blobDataContributorRoleId)
  scope: storage
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: blobDataContributorRoleId
  }
}

resource vaultReadRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource vaultWriteRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployerObjectId, keyVaultSecretsOfficerRoleId)
  scope: vault
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: keyVaultSecretsOfficerRoleId
  }
}

resource metricsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(insights.id, functionApp.id, monitoringMetricsPublisherRoleId)
  scope: insights
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringMetricsPublisherRoleId
  }
}

resource functionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: functionApp
  properties: {
    workspaceId: workspace.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource scmCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

resource ftpCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

output functionAppName string = functionApp.name
output storageAccountName string = storage.name
output keyVaultName string = vault.name
output outboundPrincipalId string = outboundIdentity.properties.principalId
output endpointUrl string = 'https://${functionApp.properties.defaultHostName}/api/SendOtp'
output identifierUri string = identifierUri
output packageContainerUrl string = '${storage.properties.primaryEndpoints.blob}${packages.name}/'
