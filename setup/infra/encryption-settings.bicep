param functionAppName string
param certificateSecretUri string
param keyId string

resource site 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

module settings 'app-settings.bicep' = {
  name: 'epp-encryption-app-settings'
  params: {
    functionAppName: site.name
    appSettings: union(list('${site.id}/config/appsettings', '2024-04-01').properties, {
      EPP_DECRYPTION_KEY_PEM: '@Microsoft.KeyVault(SecretUri=${certificateSecretUri})'
      EPP_ENCRYPTION_KEY_ID: keyId
    })
  }
}
