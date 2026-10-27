param functionAppName string
param certificateSecretUri string
param keyId string

resource site 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

resource settings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'appsettings'
  properties: union(list('${site.id}/config/appsettings', '2024-04-01').properties, {
    EPP_DECRYPTION_KEY_PEM: '@Microsoft.KeyVault(SecretUri=${certificateSecretUri})'
    EPP_ENCRYPTION_KEY_ID: keyId
  })
}
