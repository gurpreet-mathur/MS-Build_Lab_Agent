// Azure Container Registry — Azure Verified Module
// br/public:avm/res/container-registry/registry:0.7.0

param location string
param tags object = {}
param environmentName string

var acrName = replace('acr${environmentName}', '-', '')

module containerRegistry 'br/public:avm/res/container-registry/registry:0.7.0' = {
  name: 'container-registry'
  params: {
    name: acrName
    location: location
    tags: tags
    acrSku: 'Basic'
    publicNetworkAccess: 'Enabled'
    acrAdminUserEnabled: true
  }
}

output acrName string = containerRegistry.outputs.name
output acrLoginServer string = containerRegistry.outputs.loginServer
