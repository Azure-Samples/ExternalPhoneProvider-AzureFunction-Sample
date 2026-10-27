param resourceNames object
param location string
param tenantId string
param applicationId string
param callerApplicationId string
param tokenVersion int
param providerSettings object
param language string
@allowed(['FC1', 'EP1'])
param servicePlan string = 'EP1'

var isFlexConsumption = servicePlan == 'FC1'

var runtimes = {
  javascript: {
    worker: 'node'
    stack: 'NODE|22'
    version: '22'
  }
  dotnet: {
    worker: 'dotnet-isolated'
    stack: 'DOTNET-ISOLATED|8.0'
    version: '8.0'
  }
  python: {
    worker: 'python'
    stack: 'PYTHON|3.11'
    version: '3.11'
  }
}
var runtime = runtimes[language]

var tags = {
  managedBy: 'EPP-Setup'
  eppApplicationId: applicationId
  eppLanguage: language
  eppServicePlan: servicePlan
}
var blobDataOwnerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b')
var queueDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
var tableDataContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3')
var keyVaultSecretsUserRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var keyVaultCertificatesOfficerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'a4417e6f-fecd-4de8-b567-7b0420556985')
var keyVaultReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '21090545-7ca7-4776-b22c-e363652d74d2')
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

resource setupIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resourceNames.outboundIdentity}-setup'
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
  kind: isFlexConsumption ? 'functionapp' : 'linux'
  tags: tags
  sku: isFlexConsumption ? {
    name: 'FC1'
    tier: 'FlexConsumption'
  } : {
    name: 'EP1'
    tier: 'ElasticPremium'
    capacity: 1
  }
  properties: union({
    reserved: true
  }, isFlexConsumption ? {} : {
    maximumElasticWorkerCount: 3
  })
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
  // Keep serverFarmId visible to preflight instead of deferring all properties with the storage reference.
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: 'SystemAssigned'
    // The script verifies Easy Auth before opening ingress for publication.
    publicNetworkAccess: 'Disabled'
    siteConfig: union({
      http20Enabled: true
      minTlsVersion: '1.2'
    }, isFlexConsumption ? {} : {
      alwaysOn: true
      minimumElasticInstanceCount: 1
      ftpsState: 'Disabled'
      linuxFxVersion: runtime.stack
    })
    functionAppConfig: isFlexConsumption ? {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${packages.name}'
          authentication: {
            type: 'SystemAssignedIdentity'
          }
        }
      }
      runtime: {
        name: runtime.worker
        version: runtime.version
      }
      scaleAndConcurrency: {
        instanceMemoryMB: 2048
        maximumInstanceCount: 40
        alwaysReady: []
      }
    } : null
  }
}

var identifierUri = 'api://${functionApp.properties.defaultHostName}/${applicationId}'
var issuer = tokenVersion == 2 ? '${environment().authentication.loginEndpoint}${tenantId}/v2.0' : 'https://sts.windows.net/${tenantId}/'
var audience = tokenVersion == 2 ? applicationId : identifierUri

resource appSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union(functionApp.listApplicationSettings().properties, providerSettings, {
    AzureWebJobsStorage__accountName: storage.name
    AzureWebJobsStorage__credential: 'managedidentity'
    APPLICATIONINSIGHTS_CONNECTION_STRING: insights.properties.ConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD'
    KEY_VAULT_URL: vault.properties.vaultUri
    // The encryption module pins the versioned reference after certificate execution.
    EPP_OUTBOUND_CLIENT_ID: applicationId
    EPP_OUTBOUND_MI_CLIENT_ID: outboundIdentity.properties.clientId
    EPP_EXPECTED_AUDIENCE: audience
    EPP_EXPECTED_ISSUER: issuer
    EPP_EXPECTED_CLIENT_ID: callerApplicationId
    EPP_TENANT_ID: tenantId
  }, isFlexConsumption ? {} : union({
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: runtime.worker
  }, {
    WEBSITE_RUN_FROM_PACKAGE: '1'
    SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
    ENABLE_ORYX_BUILD: 'false'
  }))
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

resource vaultReadRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, functionApp.id, keyVaultSecretsUserRoleId)
  scope: vault
  properties: {
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleId
  }
}

resource vaultMetadataRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, setupIdentity.id, keyVaultReaderRoleId)
  scope: vault
  properties: {
    principalId: setupIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultReaderRoleId
  }
}

resource vaultCertificateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, setupIdentity.id, keyVaultCertificatesOfficerRoleId)
  scope: vault
  properties: {
    principalId: setupIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultCertificatesOfficerRoleId
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

resource ftpCredentials 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = if (!isFlexConsumption) {
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
output functionPrincipalId string = functionApp.identity.principalId
output setupPrincipalId string = setupIdentity.properties.principalId
output setupIdentityResourceId string = setupIdentity.id
output endpointUrl string = 'https://${functionApp.properties.defaultHostName}/api/SendOtp'
output identifierUri string = identifierUri
output packageContainerUrl string = '${storage.properties.primaryEndpoints.blob}${packages.name}/'
