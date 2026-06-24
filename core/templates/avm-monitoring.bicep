// AVM Pattern: Monitoring (Log Analytics + Application Insights)
// Reference: br/public:avm/ptn/azd/monitoring

@description('Location for monitoring resources')
param location string

@description('Environment name for resource naming')
param environmentName string

@description('Unused — kept for interface consistency')
param principalId string = ''

var logAnalyticsName = 'log-${environmentName}'
var appInsightsName = 'appi-${environmentName}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.id
output logAnalyticsName string = logAnalytics.name
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
