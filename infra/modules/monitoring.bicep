// Single log sink for the whole spoke + Application Insights for apps.
targetScope = 'resourceGroup'

param location string
param tags object
param names object
param retentionInDays int

module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'log-analytics'
  params: {
    name: names.logAnalytics
    location: location
    tags: tags
    skuName: 'PerGB2018'
    dataRetention: retentionInDays
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'app-insights'
  params: {
    name: names.appInsights
    location: location
    tags: tags
    applicationType: 'web'
    workspaceResourceId: logAnalytics.outputs.resourceId
    disableLocalAuth: false
  }
}

output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output logAnalyticsCustomerId string = logAnalytics.outputs.logAnalyticsWorkspaceId
output appInsightsResourceId string = appInsights.outputs.resourceId
output appInsightsAppId string = appInsights.outputs.applicationId
output appInsightsConnectionString string = appInsights.outputs.connectionString
