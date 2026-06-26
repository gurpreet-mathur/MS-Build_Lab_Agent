// AVM Resource: Cognitive Services (standalone, without full Foundry pattern)
// Reference: br/public:avm/res/cognitive-services/account

@description('Location for AI resources')
param location string

@description('Environment name for resource naming')
param environmentName string

var aiServicesName = 'oai-${environmentName}-${uniqueString(resourceGroup().id)}'

resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aiServicesName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: aiServicesName
    publicNetworkAccess: 'Enabled'
  }
  identity: { type: 'SystemAssigned' }
}

// GPT-4o deployment
resource gpt41 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiServices
  name: 'gpt-4-1'
  sku: { name: 'GlobalStandard', capacity: 30 }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4.1'
      version: '2025-04-14'
    }
  }
}

output openAiEndpoint string = aiServices.properties.endpoint
output openAiName string = aiServices.name
