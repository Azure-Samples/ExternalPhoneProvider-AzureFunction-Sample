// Callers read existing settings; this inner template only writes to avoid an ARM self-dependency.
param functionAppName string

@secure()
param appSettings object

resource site 'Microsoft.Web/sites@2024-04-01' existing = {
  name: functionAppName
}

resource settings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'appsettings'
  properties: appSettings
}
