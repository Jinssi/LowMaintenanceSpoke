// Azure Monitor alerting = the spoke's ticketing system.
// Every alert instance is a ticket: New -> Acknowledged -> Closed, with state-change comments as notes.
// Severity drives ownership: Sev0-1 -> SRE agent L2 (+ on-call email), Sev2-4 -> SRE agent L1.
targetScope = 'resourceGroup'

param location string
param tags object
param names object

@description('E-mail addresses notified for Sev0/Sev1 alerts (humans stay in the loop for approvals).')
param alertEmailAddresses array

param logAnalyticsWorkspaceId string
param appInsightsResourceId string
param containerAppsEnvironmentId string
param keyVaultId string

@description('Empty = not deployed.')
param foundryAccountId string

@description('Empty = not deployed.')
param appGatewayId string

@description('Empty = not deployed (only the optional test hub has a firewall managed by this template).')
param firewallId string

@description('Resource groups watched by the Resource Health alert.')
param resourceHealthScopes array

var prefix = names.alertRulePrefix
var oncall = [{ actionGroupId: actionGroup.outputs.resourceId }]

module actionGroup 'br/public:avm/res/insights/action-group:0.8.0' = {
  name: 'ag-oncall'
  params: {
    name: names.actionGroup
    groupShortName: 'oncall'
    location: 'global'
    tags: tags
    emailReceivers: [
      for (email, i) in alertEmailAddresses: {
        name: 'oncall-${i}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Metric alerts (Sev0/Sev1 also notify the on-call action group)
// ---------------------------------------------------------------------------
var metricAlerts = filter(
  [
    {
      name: 'aca-env-cores-quota'
      description: 'Container Apps environment is using more than 80% of its cores quota; new replicas may fail to schedule.'
      severity: 2
      scope: containerAppsEnvironmentId
      metric: 'EnvCoresQuotaUtilization'
      aggregation: 'Average'
      operator: 'GreaterThan'
      threshold: 80
      window: 'PT15M'
      dimensions: []
    }
    {
      name: 'kv-availability'
      description: 'Key Vault availability dropped below 99%; apps may fail to read secrets.'
      severity: 2
      scope: keyVaultId
      metric: 'Availability'
      aggregation: 'Average'
      operator: 'LessThan'
      threshold: 99
      window: 'PT15M'
      dimensions: []
    }
    {
      name: 'kv-saturation'
      description: 'Key Vault saturation above 75%; requests may be throttled.'
      severity: 3
      scope: keyVaultId
      metric: 'SaturationShoebox'
      aggregation: 'Average'
      operator: 'GreaterThan'
      threshold: 75
      window: 'PT15M'
      dimensions: []
    }
    {
      name: 'foundry-server-errors'
      description: 'Azure AI Foundry returned more than 10 server errors in 5 minutes.'
      severity: 2
      scope: foundryAccountId
      metric: 'ServerErrors'
      aggregation: 'Total'
      operator: 'GreaterThan'
      threshold: 10
      window: 'PT5M'
      dimensions: []
    }
    {
      name: 'foundry-throttling'
      description: 'Azure AI Foundry is rate limiting requests (more than 50 in 15 minutes); consider raising deployment capacity.'
      severity: 3
      scope: foundryAccountId
      metric: 'Ratelimit'
      aggregation: 'Total'
      operator: 'GreaterThan'
      threshold: 50
      window: 'PT15M'
      dimensions: []
    }
    {
      name: 'agw-no-healthy-backend'
      description: 'App Gateway has no healthy backend: every app behind the gateway is down.'
      severity: 0
      scope: appGatewayId
      metric: 'HealthyHostCount'
      aggregation: 'Average'
      operator: 'LessThan'
      threshold: 1
      window: 'PT5M'
      dimensions: []
    }
    {
      name: 'agw-backend-5xx'
      description: 'Apps behind the App Gateway returned more than 25 HTTP 5xx responses in 5 minutes.'
      severity: 2
      scope: appGatewayId
      metric: 'BackendResponseStatus'
      aggregation: 'Total'
      operator: 'GreaterThan'
      threshold: 25
      window: 'PT5M'
      dimensions: [{ name: 'HttpStatusGroup', operator: 'Include', values: ['5xx'] }]
    }
    {
      name: 'afw-health'
      description: 'Hub Azure Firewall health dropped below 90%; spoke egress is degraded.'
      severity: 1
      scope: firewallId
      metric: 'FirewallHealth'
      aggregation: 'Average'
      operator: 'LessThan'
      threshold: 90
      window: 'PT5M'
      dimensions: []
    }
    {
      name: 'afw-snat'
      description: 'Hub Azure Firewall SNAT port utilization above 80%; outbound connections may fail.'
      severity: 2
      scope: firewallId
      metric: 'SNATPortUtilization'
      aggregation: 'Maximum'
      operator: 'GreaterThan'
      threshold: 80
      window: 'PT15M'
      dimensions: []
    }
  ],
  a => !empty(a.scope)
)

module metricAlert 'br/public:avm/res/insights/metric-alert:0.4.1' = [
  for a in metricAlerts: {
    name: 'ma-${a.name}'
    params: {
      name: '${prefix}-${a.name}'
      alertDescription: a.description
      location: 'global'
      tags: tags
      severity: a.severity
      scopes: [a.scope]
      evaluationFrequency: 'PT1M'
      windowSize: a.window
      autoMitigate: true
      actions: a.severity <= 1 ? oncall : []
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allof: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: a.metric
            metricName: a.metric
            operator: a.operator
            threshold: a.threshold
            timeAggregation: a.aggregation
            dimensions: a.dimensions
          }
        ]
      }
    }
  }
]

// ---------------------------------------------------------------------------
// Log search alerts (tables may not exist until the first app logs, so validation is skipped)
// ---------------------------------------------------------------------------
var logAlerts = [
  {
    name: 'aca-replica-crashloop'
    displayName: 'Container app replicas are crash looping or failing probes'
    description: 'Container Apps system logs report back-off, terminated containers or failed probes. Investigate the app revision and recent deployments.'
    severity: 1
    scope: logAnalyticsWorkspaceId
    query: 'ContainerAppSystemLogs_CL\n| where Type_s == "Warning" or Reason_s has_any ("BackOff", "Crash", "Terminated", "ProbeFailed", "Unhealthy", "Failed")\n| summarize Events = count() by ContainerAppName_s, RevisionName_s'
    threshold: 5
    dimension: 'ContainerAppName_s'
    window: 'PT15M'
  }
  {
    name: 'appi-exceptions-spike'
    displayName: 'Application exceptions spike'
    description: 'More than 25 exceptions in 15 minutes for a single app (cloud role).'
    severity: 3
    scope: appInsightsResourceId
    query: 'exceptions\n| summarize Exceptions = count() by cloud_RoleName'
    threshold: 25
    dimension: 'cloud_RoleName'
    window: 'PT15M'
  }
]

module logAlert 'br/public:avm/res/insights/scheduled-query-rule:0.6.0' = [
  for a in logAlerts: {
    name: 'sq-${a.name}'
    params: {
      name: '${prefix}-${a.name}'
      alertDisplayName: a.displayName
      alertDescription: a.description
      location: location
      tags: tags
      kind: 'LogAlert'
      severity: a.severity
      scopes: [a.scope]
      evaluationFrequency: 'PT5M'
      windowSize: a.window
      autoMitigate: true
      skipQueryValidation: true
      actions: { actionGroupResourceIds: a.severity <= 1 ? [actionGroup.outputs.resourceId] : [] }
      criterias: {
        allOf: [
          {
            query: a.query
            timeAggregation: 'Count'
            operator: 'GreaterThan'
            threshold: a.threshold
            dimensions: [{ name: a.dimension, operator: 'Include', values: ['*'] }]
            failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
          }
        ]
      }
    }
  }
]

// ---------------------------------------------------------------------------
// Activity log alerts (fired as Sev4 -> L1 triage)
// ---------------------------------------------------------------------------
module resourceHealthAlert 'br/public:avm/res/insights/activity-log-alert:0.4.2' = {
  name: 'ala-resource-health'
  params: {
    name: '${prefix}-resource-health'
    alertDescription: 'A resource in the spoke (or test hub) became Degraded or Unavailable according to Azure Resource Health.'
    location: 'global'
    tags: tags
    scopes: resourceHealthScopes
    actions: oncall
    conditions: [
      { field: 'category', equals: 'ResourceHealth' }
      {
        anyOf: [
          { field: 'properties.currentHealthStatus', equals: 'Degraded' }
          { field: 'properties.currentHealthStatus', equals: 'Unavailable' }
        ]
      }
    ]
  }
}

module serviceHealthAlert 'br/public:avm/res/insights/activity-log-alert:0.4.2' = {
  name: 'ala-service-health'
  params: {
    name: '${prefix}-service-health'
    alertDescription: 'Azure Service Health incident affecting this subscription.'
    location: 'global'
    tags: tags
    scopes: [subscription().id]
    actions: oncall
    conditions: [
      { field: 'category', equals: 'ServiceHealth' }
      { field: 'properties.incidentType', equals: 'Incident' }
    ]
  }
}

output actionGroupResourceId string = actionGroup.outputs.resourceId
output alertRuleCount int = length(metricAlerts) + length(logAlerts) + 2
