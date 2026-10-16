// One Azure SRE Agent (Microsoft.App/agents) at a fixed skill level, wired to Azure Monitor as its incident platform.
// Mirrors the official IaC templates in https://github.com/microsoft/sre-agent (sreagent-templates/bicep/agent-core.bicep).
// Data-plane configuration (skills, custom agents, response plans, scheduled tasks, knowledge) is applied by
// scripts/configure-sre-agents.ps1 because it is not exposed through ARM.
targetScope = 'resourceGroup'

param location string
param tags object

param agentName string
param identityName string

@description('Low = Reader-level agent (L1). High = privileged agent that can act after approval (L2).')
@allowed(['Low', 'High'])
param accessLevel string

@description('Resource groups the agent watches (alerts, knowledge graph) and can read.')
param managedResourceGroupNames array

@description('Resource group where writeRoleDefinitionIds are granted. Empty = read-only agent.')
param writeResourceGroupName string

param writeRoleDefinitionIds array

@description('Dedicated delegated subnet for Azure VNet egress mode. Empty = Unrestricted egress.')
param subnetResourceId string

@description('Agent telemetry (separate from workload telemetry).')
param agentAppInsightsAppId string
param agentAppInsightsConnectionString string

@description('Workload telemetry the agent investigates.')
param workloadAppInsightsResourceId string
param workloadAppInsightsAppId string
param logAnalyticsWorkspaceId string

param defaultModelProvider string
param defaultModelName string
param monthlyAgentUnitLimit int

@allowed(['Stable', 'Preview'])
param upgradeChannel string

@description('Gets SRE Agent Administrator (approves actions, manages configuration). Empty = none.')
param adminPrincipalId string

@allowed(['User', 'Group', 'ServicePrincipal'])
param adminPrincipalType string

@description('Entra group that gets SRE Agent Standard User (chat, request actions). Empty = none.')
param operatorsGroupId string

var roles = {
  reader: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  logAnalyticsReader: '73c42c96-874c-492b-b04d-ab87d138a893'
  monitoringReader: '43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  monitoringContributor: '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
  sreAgentAdministrator: 'e79298df-d852-4c6d-84f9-5d13249d1e55'
  sreAgentStandardUser: '2d84a65a-63b2-4343-bbb6-31105d857bc1'
}
var readRoles = [roles.reader, roles.logAnalyticsReader, roles.monitoringReader]
var useVnet = !empty(subnetResourceId)
var identityResourceId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', identityName)

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'id-${agentName}'
  params: {
    name: identityName
    location: location
    tags: tags
  }
}

// --- RBAC for the user-assigned identity (before the agent is created) ---
module readRbacUami 'rbac-rg.bicep' = [
  for rg in managedResourceGroupNames: {
    name: take('rbac-read-uami-${agentName}-${rg}', 64)
    scope: resourceGroup(rg)
    params: {
      principalIds: [identity.outputs.principalId]
      roleDefinitionIds: readRoles
    }
  }
]

module writeRbacUami 'rbac-rg.bicep' = if (!empty(writeResourceGroupName)) {
  name: 'rbac-write-uami-${agentName}'
  scope: resourceGroup(writeResourceGroupName)
  params: {
    principalIds: [identity.outputs.principalId]
    roleDefinitionIds: writeRoleDefinitionIds
  }
}

// Monitoring Contributor on the subscription lets the agent acknowledge/close Azure Monitor alerts (the "tickets").
module alertLifecycleUami 'rbac-subscription.bicep' = {
  name: 'rbac-alerts-uami-${agentName}'
  scope: subscription()
  params: {
    principalIds: [identity.outputs.principalId]
    roleDefinitionIds: [roles.monitoringContributor]
  }
}

#disable-next-line BCP081
resource agent 'Microsoft.App/agents@2025-05-01-preview' = {
  name: agentName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${identityResourceId}': {}
    }
  }
  properties: {
    knowledgeGraphConfiguration: {
      identity: identityResourceId
      managedResources: [for rg in managedResourceGroupNames: subscriptionResourceId('Microsoft.Resources/resourceGroups', rg)]
    }
    actionConfiguration: {
      accessLevel: accessLevel
      identity: identityResourceId
      mode: 'Review'
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: agentAppInsightsAppId
        connectionString: agentAppInsightsConnectionString
      }
    }
    upgradeChannel: upgradeChannel
    monthlyAgentUnitLimit: monthlyAgentUnitLimit
    defaultModel: {
      provider: defaultModelProvider
      name: defaultModelName
    }
    experimentalSettings: {
      EnableWorkspaceTools: true
      EnableV2AgentLoop: true
    }
    vnetConfiguration: useVnet ? { subnetResourceId: subnetResourceId } : null
    sandboxConfiguration: useVnet
      ? {
          egress: {
            mode: 'AzureVNet'
            allowedHosts: []
            allowedRegistries: ['pypi']
            allowedCodeRepositories: ['Github']
            allowHttpMcpServerNetworkAccess: false
            vnetConfiguration: {
              usePrivateDnsResolution: true
            }
          }
        }
      : null
  }
  dependsOn: [identity, readRbacUami, writeRbacUami, alertLifecycleUami]
}

// --- Connectors: the agent queries workload telemetry with its system-assigned identity ---
#disable-next-line BCP081
resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'app-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: workloadAppInsightsResourceId
    extendedProperties: {
      armResourceId: workloadAppInsightsResourceId
      resource: { name: last(split(workloadAppInsightsResourceId, '/')) }
      appId: workloadAppInsightsAppId
    }
    identity: 'system'
  }
}

#disable-next-line BCP081
resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: agent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: logAnalyticsWorkspaceId
    extendedProperties: {
      armResourceId: logAnalyticsWorkspaceId
      resource: { name: last(split(logAnalyticsWorkspaceId, '/')) }
    }
    identity: 'system'
  }
  dependsOn: [appInsightsConnector]
}

// --- Same RBAC for the system-assigned identity (used by the connectors) ---
module readRbacSystem 'rbac-rg.bicep' = [
  for rg in managedResourceGroupNames: {
    name: take('rbac-read-smi-${agentName}-${rg}', 64)
    scope: resourceGroup(rg)
    params: {
      principalIds: [agent.identity.principalId]
      roleDefinitionIds: readRoles
    }
  }
]

module writeRbacSystem 'rbac-rg.bicep' = if (!empty(writeResourceGroupName)) {
  name: 'rbac-write-smi-${agentName}'
  scope: resourceGroup(writeResourceGroupName)
  params: {
    principalIds: [agent.identity.principalId]
    roleDefinitionIds: writeRoleDefinitionIds
  }
}

module alertLifecycleSystem 'rbac-subscription.bicep' = {
  name: 'rbac-alerts-smi-${agentName}'
  scope: subscription()
  params: {
    principalIds: [agent.identity.principalId]
    roleDefinitionIds: [roles.monitoringContributor]
  }
}

// --- Who can use the agent ---
resource adminRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminPrincipalId)) {
  name: guid(agent.id, adminPrincipalId, roles.sreAgentAdministrator)
  scope: agent
  properties: {
    principalId: adminPrincipalId
    principalType: adminPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sreAgentAdministrator)
  }
}

resource operatorsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(operatorsGroupId)) {
  name: guid(agent.id, operatorsGroupId, roles.sreAgentStandardUser)
  scope: agent
  properties: {
    principalId: operatorsGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.sreAgentStandardUser)
  }
}

output name string = agent.name
output resourceId string = agent.id
output identityPrincipalId string = identity.outputs.principalId
output portalUrl string = 'https://sre.azure.com/#/agent/${subscription().subscriptionId}/${resourceGroup().name}/${agent.name}'
