// AVM Resource: Azure AI Search
// Reference: br/public:avm/res/search/search-service

@description('Location for Search resources')
param location string

@description('Environment name for resource naming')
param environmentName string

var searchServiceName = 'srch-${environmentName}-${uniqueString(resourceGroup().id)}'

resource searchService 'Microsoft.Search/searchServices@2024-03-01-preview' = {
  name: searchServiceName
  location: location
  sku: { name: 'basic' }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'Enabled'
    semanticSearch: 'free'
  }
  identity: { type: 'SystemAssigned' }
}

output searchServiceName string = searchService.name
output searchServiceEndpoint string = 'https://${searchService.name}.search.windows.net'
