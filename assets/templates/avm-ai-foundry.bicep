// AVM Pattern: AI Foundry (account + project + model deployments)
// Reference: br/public:avm/ptn/ai-ml/ai-foundry

@description('Location for AI resources')
param location string

@description('Environment name for resource naming')
param environmentName string

@description('Principal ID for RBAC')
param principalId string = ''

var aiServicesName = 'ais-${environmentName}-${uniqueString(resourceGroup().id)}'
var aiHubName = 'aih-${environmentName}'
var aiProjectName = 'aip-${environmentName}'

// AI Services account (Azure OpenAI + multi-service)
resource aiServices 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: aiServicesName
  location: location
  kind: 'AIServices'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: aiServicesName
    publicNetworkAccess: 'Enabled'
  }
  identity: { type: 'SystemAssigned' }
}

// GPT-4.1 model deployment
resource gpt41Deployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
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

// Text embedding deployment
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aiServices
  name: 'text-embedding-ada-002'
  sku: { name: 'Standard', capacity: 30 }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-ada-002'
      version: '2'
    }
  }
  dependsOn: [gpt41Deployment]
}

// Storage for AI Hub
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${uniqueString(resourceGroup().id)}ai'
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

// Key Vault for AI Hub
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${uniqueString(resourceGroup().id)}-ai'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// AI Hub (workspace)
resource aiHub 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: aiHubName
  location: location
  kind: 'Hub'
  sku: { name: 'Basic', tier: 'Basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    friendlyName: 'AI Hub - ${environmentName}'
    storageAccount: storageAccount.id
    keyVault: keyVault.id
  }
}

// AI Hub connection to AI Services
resource aiServicesConnection 'Microsoft.MachineLearningServices/workspaces/connections@2024-10-01' = {
  parent: aiHub
  name: 'ai-services'
  properties: {
    category: 'AIServices'
    target: aiServices.properties.endpoint
    authType: 'AAD'
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiServices.id
    }
  }
}

// AI Project
resource aiProject 'Microsoft.MachineLearningServices/workspaces@2024-10-01' = {
  name: aiProjectName
  location: location
  kind: 'Project'
  sku: { name: 'Basic', tier: 'Basic' }
  identity: { type: 'SystemAssigned' }
  properties: {
    friendlyName: 'AI Project - ${environmentName}'
    hubResourceId: aiHub.id
  }
}

// RBAC: Cognitive Services OpenAI User
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  name: guid(resourceGroup().id, principalId, 'cognitive-services-openai-user')
  scope: aiServices
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: principalId
    principalType: 'User'
  }
}

output aiServicesEndpoint string = aiServices.properties.endpoint
output aiServicesName string = aiServices.name
output aiProjectName string = aiProject.name
output aiHubName string = aiHub.name
