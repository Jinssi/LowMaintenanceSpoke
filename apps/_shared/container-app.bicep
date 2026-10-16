// Shared module for every app slot. An app is just a .bicepparam file that uses this module:
//   apps/<name>/main.bicepparam -> using '../_shared/container-app.bicep'
// Platform resources are found by naming convention (infra/naming.bicep), so apps need no platform outputs.
targetScope = 'resourceGroup'

import { resourceNames, uniqueToken } from '../../infra/naming.bicep'

@description('Must match the platform deployment.')
param workloadName string

@description('Must match the platform deployment.')
param environmentName string

@description('App name (lowercase, 2-32 chars). Becomes the FQDN prefix: <name>.<apps domain>.')
@minLength(2)
@maxLength(32)
param name string

@description('Container image. Images from the spoke ACR are pulled with the shared managed identity.')
param image string

param targetPort int = 80

@description('CPU cores, e.g. \'0.25\', \'0.5\', \'1\'.')
param cpu string = '0.5'

@description('Memory, must pair with CPU (0.5 -> 1Gi, 1 -> 2Gi).')
param memory string = '1Gi'

param minReplicas int = 0
param maxReplicas int = 3

@description('vnet = reachable from the VNet/App Gateway; environment = only from other apps in the environment.')
@allowed(['vnet', 'environment'])
param exposure string = 'vnet'

@description('HTTP path for liveness/readiness probes. Empty = platform defaults.')
param healthPath string = ''

@description('Plain environment variables: { KEY: \'value\' }.')
param env object = {}

@description('Key Vault secrets exposed as env vars: { ENV_VAR_NAME: \'key-vault-secret-name\' }.')
param keyVaultReferences object = {}

@description('Inject FOUNDRY_PROJECT_ENDPOINT / AZURE_OPENAI_ENDPOINT (requires deployFoundry in the platform).')
param useFoundry bool = true

@description('Create the standard Azure Monitor alerts for this app (picked up by the SRE agents).')
param enableAlerts bool = true

@description('HTTP 5xx responses in 5 minutes that raise a Sev2 alert.')
param http5xxThreshold int = 10

param tags object = {}

var names = resourceNames(workloadName, environmentName, uniqueToken(subscription().subscriptionId, workloadName, environmentName))
var acrLoginServer = '${names.containerRegistry}${environment().suffixes.acrLoginServer}'
var keyVaultUri = 'https://${names.keyVault}${environment().suffixes.keyvaultDns}/'
var usesAcr = startsWith(image, acrLoginServer)

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = {
  name: names.identity
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: names.appInsights
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2025-07-01' existing = {
  name: names.containerAppsEnvironment
}

var platformEnv = union(
  {
    AZURE_CLIENT_ID: identity.properties.clientId
    APPLICATIONINSIGHTS_CONNECTION_STRING: appInsights.properties.ConnectionString
    KEY_VAULT_URI: keyVaultUri
  },
  useFoundry
    ? {
        FOUNDRY_PROJECT_ENDPOINT: 'https://${names.foundry}.services.ai.azure.com/api/projects/${names.foundryProject}'
        AZURE_OPENAI_ENDPOINT: 'https://${names.foundry}.openai.azure.com/'
      }
    : {}
)

var secretList = items(keyVaultReferences)

var probes = empty(healthPath)
  ? []
  : [
      {
        type: 'Liveness'
        httpGet: { path: healthPath, port: targetPort }
        periodSeconds: 30
      }
      {
        type: 'Readiness'
        httpGet: { path: healthPath, port: targetPort }
        periodSeconds: 10
      }
    ]

module app 'br/public:avm/res/app/container-app:0.23.0' = {
  name: 'app-${name}'
  params: {
    name: name
    location: resourceGroup().location
    tags: union({ app: name }, tags)
    environmentResourceId: managedEnvironment.id
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [identity.id]
    }
    registries: usesAcr ? [{ server: acrLoginServer, identity: identity.id }] : []
    ingressExternal: exposure == 'vnet'
    ingressTargetPort: targetPort
    ingressTransport: 'auto'
    ingressAllowInsecure: false
    scaleSettings: {
      minReplicas: minReplicas
      maxReplicas: maxReplicas
      rules: [
        {
          name: 'http-scaling'
          http: { metadata: { concurrentRequests: '50' } }
        }
      ]
    }
    secrets: [
      for s in secretList: {
        name: toLower(replace(s.key, '_', '-'))
        keyVaultUrl: '${keyVaultUri}secrets/${s.value}'
        identity: identity.id
      }
    ]
    containers: [
      {
        name: name
        image: image
        resources: {
          cpu: json(cpu)
          memory: memory
        }
        probes: probes
        env: concat(
          map(items(union(platformEnv, env)), e => { name: e.key, value: string(e.value) }),
          map(secretList, s => { name: s.key, secretRef: toLower(replace(s.key, '_', '-')) })
        )
      }
    ]
  }
}

output name string = app.outputs.name
output fqdn string = app.outputs.fqdn

// Per-app alerts. Severity routes the ticket: Sev2-4 -> SRE agent L1, Sev0-1 -> SRE agent L2.
var appAlerts = [
  {
    name: 'http-5xx'
    description: 'App ${name} returned more than ${http5xxThreshold} HTTP 5xx responses in 5 minutes.'
    severity: 2
    metric: 'Requests'
    aggregation: 'Total'
    threshold: http5xxThreshold
    window: 'PT5M'
    dimensions: [{ name: 'statusCodeCategory', operator: 'Include', values: ['5xx'] }]
  }
  {
    name: 'cpu-high'
    description: 'App ${name} CPU above 85% of its allocation for 15 minutes; consider scaling out or up.'
    severity: 3
    metric: 'CpuPercentage'
    aggregation: 'Average'
    threshold: 85
    window: 'PT15M'
    dimensions: []
  }
  {
    name: 'memory-high'
    description: 'App ${name} memory above 85% of its allocation for 15 minutes; risk of OOM restarts.'
    severity: 3
    metric: 'MemoryPercentage'
    aggregation: 'Average'
    threshold: 85
    window: 'PT15M'
    dimensions: []
  }
]

module alert 'br/public:avm/res/insights/metric-alert:0.4.1' = [
  for a in (enableAlerts ? appAlerts : []): {
    name: 'ma-${name}-${a.name}'
    params: {
      name: '${names.alertRulePrefix}-app-${name}-${a.name}'
      alertDescription: a.description
      location: 'global'
      tags: union({ app: name }, tags)
      severity: a.severity
      scopes: [app.outputs.resourceId]
      evaluationFrequency: 'PT1M'
      windowSize: a.window
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allof: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: a.metric
            metricName: a.metric
            operator: 'GreaterThan'
            threshold: a.threshold
            timeAggregation: a.aggregation
            dimensions: a.dimensions
          }
        ]
      }
    }
  }
]
