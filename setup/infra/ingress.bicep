param site object
@allowed(['Enabled', 'Disabled'])
param access string

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: site.name
  location: site.location
  kind: site.kind
  identity: site.identity
  tags: site.?tags ?? {}
  properties: union(site.properties, {
    publicNetworkAccess: access
  })
}
