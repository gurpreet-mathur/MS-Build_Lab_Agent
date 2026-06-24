// AVM Resource: Azure SQL Server + Database
// Reference: br/public:avm/res/sql/server

@description('Location for SQL resources')
param location string

@description('Environment name for resource naming')
param environmentName string

@description('SQL admin username')
param sqlAdminLogin string = 'sqladmin'

@secure()
@description('SQL admin password (auto-generated if not provided)')
param sqlAdminPassword string = 'P${uniqueString(resourceGroup().id)}!1a'

@description('SQL Database SKU')
@allowed(['Basic', 'S0', 'S1', 'S2', 'P1', 'HS_Gen5_2'])
param databaseSku string = 'S0'

var serverName = 'sql-${environmentName}-${uniqueString(resourceGroup().id)}'
var databaseName = '${environmentName}-db'

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: serverName
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

// Allow Azure services
resource firewallAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllAzureIPs'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// Allow client IP (broad range for lab purposes)
resource firewallAllowAll 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowLabClients'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: {
    name: databaseSku
    tier: databaseSku == 'HS_Gen5_2' ? 'Hyperscale' : (startsWith(databaseSku, 'P') ? 'Premium' : (databaseSku == 'Basic' ? 'Basic' : 'Standard'))
    capacity: databaseSku == 'HS_Gen5_2' ? 2 : (databaseSku == 'Basic' ? 5 : (databaseSku == 'S0' ? 10 : (databaseSku == 'S1' ? 20 : (databaseSku == 'S2' ? 50 : 125))))
    family: databaseSku == 'HS_Gen5_2' ? 'Gen5' : null
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: databaseSku == 'HS_Gen5_2' ? null : 2147483648
  }
}

output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlServerName string = sqlServer.name
output databaseName string = database.name
