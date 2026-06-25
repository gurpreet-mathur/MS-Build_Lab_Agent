// AKS Cluster — Azure Verified Module
// br/public:avm/res/container-service/managed-cluster:0.8.0

param location string
param tags object = {}
param environmentName string

var aksName = 'aks-${environmentName}'

module aksCluster 'br/public:avm/res/container-service/managed-cluster:0.8.0' = {
  name: 'aks-cluster'
  params: {
    name: aksName
    location: location
    tags: tags
    managedIdentities: {
      systemAssigned: true
    }
    primaryAgentPoolProfiles: [
      {
        name: 'systempool'
        count: 2
        vmSize: 'Standard_DS2_v2'
        mode: 'System'
        osType: 'Linux'
        availabilityZones: []
      }
    ]
    agentPools: [
      {
        name: 'userpool'
        count: 1
        vmSize: 'Standard_DS3_v2'
        mode: 'User'
        osType: 'Linux'
        availabilityZones: []
      }
    ]
    networkPlugin: 'azure'
    networkPolicy: 'calico'
    enableRBAC: true
    aadProfile: {
      aadProfileManaged: true
      aadProfileEnableAzureRBAC: true
    }
  }
}

output aksClusterName string = aksCluster.outputs.name
