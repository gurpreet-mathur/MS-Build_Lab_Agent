targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment used for resource naming')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

@description('Principal ID for RBAC assignments')
param principalId string = ''

@description('Principal type (User or ServicePrincipal)')
param principalType string = 'User'

var tags = {
  'azd-env-name': environmentName
  'generated-by': 'lab-lifecycle-skill'
  'lab-code': 'UNKNOWN'
}

var resourceGroupName = 'rg-${environmentName}'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// Resource: Storage Account (Blob, Files, Queue, Table)
module storageaccount './modules/storage-account.bicep' = {
  scope: rg
  name: 'storage-account-deploy'
  params: {
    location: location
    environmentName: environmentName
  }
}

// Outputs for azd
output AZURE_RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId

