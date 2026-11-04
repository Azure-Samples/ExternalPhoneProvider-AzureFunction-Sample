param functionAppName string
param location string
@secure()
@description('Public, versioned release URL ending in released-package.zip, as required by Flex Consumption.')
param packageUri string
@allowed(['FC1', 'EP1'])
param servicePlan string

resource code 'Microsoft.Web/sites/extensions@2024-04-01' = {
  name: '${functionAppName}/${servicePlan == 'FC1' ? 'onedeploy' : 'ZipDeploy'}'
  location: location
  properties: {
    packageUri: packageUri
    remoteBuild: false
  }
}
